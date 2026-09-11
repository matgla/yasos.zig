"""
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 """

"""
Host-side Zmodem file sender for the smoke-test framework.

Sends files to the target using a simplified Zmodem protocol
(ZBIN frames with CRC-16) matching the target-side rz --zmodem receiver.
"""

import logging
import re
import struct
import time

logger = logging.getLogger(__name__)

# ---- Zmodem constants ----
ZPAD = ord('*')
ZDLE = 0x18

ZBIN = ord('A')
ZHEX = ord('B')

ZRQINIT = 0x00
ZRINIT  = 0x01
ZSINIT  = 0x02
ZACK    = 0x03
ZFILE   = 0x04
ZSKIP   = 0x05
ZNAK    = 0x06
ZABORT  = 0x07
ZFIN    = 0x08
ZRPOS   = 0x09
ZDATA   = 0x0a
ZEOF    = 0x0b

ZCRCE = ord('h')
ZCRCG = ord('i')
ZCRCQ = ord('j')
ZCRCW = ord('k')

CANFDX = 0x01
ESCCTL = 0x40

DATA_SUBPACKET_SIZE = 1024
MAX_RESEND_ATTEMPTS = 3

# Largest number of bytes to hand the serial port in one uninterrupted write.
#
# Somewhere between the host tty and the target's UART pin -- the USB-CDC pipe
# and the debug probe that bridges it -- a burst is buffered and drained at line
# rate, and whatever a single burst pushes past that buffer is dropped. The
# target proved it was not the one losing them: /proc/uart reported rx_overruns
# 0 and rx_dropped 0 on every failing sub-packet, so nothing arrived to be lost.
#
# The budget has to be counted in *encoded* bytes. Sizing by raw payload cannot
# work, because ZDLE escaping is content-dependent: 1024 raw bytes of C source
# went 30-80 bytes over, which is exactly the deficits the receiver reported,
# and they varied with how many control characters each chunk happened to hold.
#
# The evidence puts the limit near 1024 encoded bytes; this sits comfortably
# under it rather than at the edge, since the cost of being wrong is a silent
# retry storm and the cost of being conservative is only a few more round trips.
WIRE_BURST_BUDGET = 768

# Header, sub-packet terminator and CRC ride in the same burst as the payload.
WIRE_BURST_OVERHEAD = 32

READY_MARKER = "READY\n"


class TransferError(Exception):
    """Raised when a file transfer fails."""


# ---- CRC-16-CCITT ----

def _crc16_ccitt_table():
    table = []
    for i in range(256):
        crc = i << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xffff
            else:
                crc = (crc << 1) & 0xffff
        table.append(crc)
    return table

_CRC16_TABLE = _crc16_ccitt_table()


def _crc16_update(crc: int, byte: int) -> int:
    return ((crc << 8) ^ _CRC16_TABLE[((crc >> 8) ^ byte) & 0xff]) & 0xffff


def _crc16(data: bytes) -> int:
    crc = 0
    for b in data:
        crc = _crc16_update(crc, b)
    return crc


# ---- ZDLE encoding ----

_MUST_ESCAPE = {ZDLE, 0x11, 0x13}
# With ESCCTL, also escape all control chars except \n (0x0a) and \r (0x0d)
_MUST_ESCAPE.update(b for b in range(0x20) if b not in (0x0a, 0x0d))


def _zdle_encode_byte(b: int) -> bytes:
    if b in _MUST_ESCAPE:
        return bytes([ZDLE, b ^ 0x40])
    return bytes([b])


def _zdle_encode(data: bytes) -> bytes:
    out = bytearray()
    for b in data:
        if b in _MUST_ESCAPE:
            out.append(ZDLE)
            out.append(b ^ 0x40)
        else:
            out.append(b)
    return bytes(out)


# ---- Frame construction ----

def _build_header(frame_type: int, f3: int, f2: int, f1: int, f0: int) -> bytes:
    """Build a ZBIN header with CRC-16."""
    payload = bytes([frame_type, f3, f2, f1, f0])
    crc = _crc16(payload)
    buf = bytearray([ZPAD, ZDLE, ZBIN])
    buf.extend(_zdle_encode(payload))
    buf.extend(_zdle_encode(bytes([(crc >> 8) & 0xff, crc & 0xff])))
    return bytes(buf)


def _chunk_end_within_wire_budget(data: bytes, start: int) -> int:
    """End offset of the largest chunk from *start* that fits one wire burst.

    Walks the payload counting what each byte will cost once encoded -- two
    bytes for anything ZDLE has to escape, one otherwise -- and stops before the
    budget is exceeded. Always advances by at least one byte so a pathological
    payload cannot stall the transfer.
    """
    budget = WIRE_BURST_BUDGET - WIRE_BURST_OVERHEAD
    hard_end = min(start + DATA_SUBPACKET_SIZE, len(data))
    used = 0
    end = start
    while end < hard_end:
        cost = 2 if data[end] in _MUST_ESCAPE else 1
        if used + cost > budget:
            break
        used += cost
        end += 1
    return max(end, min(start + 1, hard_end))


def _build_data_subpacket(data: bytes, terminator: int) -> bytes:
    """Build a data sub-packet with CRC-16."""
    crc = 0
    for b in data:
        crc = _crc16_update(crc, b)
    crc = _crc16_update(crc, terminator)

    buf = bytearray()
    buf.extend(_zdle_encode(data))
    buf.append(ZDLE)
    buf.append(terminator)
    buf.extend(_zdle_encode(bytes([(crc >> 8) & 0xff, crc & 0xff])))
    return bytes(buf)


# ---- Frame parsing ----

def _read_byte(ser) -> int:
    """Read one raw byte from serial, returns -1 on timeout."""
    b = ser.read(1)
    if not b:
        return -1
    return b[0]


def _read_zdle_byte(ser) -> int:
    """Read one byte, handling ZDLE escapes. Returns -1 on error."""
    b = _read_byte(ser)
    if b < 0:
        return -1
    if b == ZDLE:
        b = _read_byte(ser)
        if b < 0:
            return -1
        return b ^ 0x40
    return b


def _recv_header(ser, timeout=None, on_garbage=None) -> tuple:
    """Receive a ZBIN header. Returns (frame_type, [f3,f2,f1,f0]) or None on error.

    Non-header bytes are skipped; when *on_garbage* is given they are handed to
    it as a bytes object so the session can log them and scan for crash
    markers — a target-side HardFault mid-transfer announces itself only here
    (its diagnostics dump arrives instead of the expected ZACK).
    """
    old_timeout = ser.timeout
    if timeout is not None:
        ser.timeout = timeout

    garbage = bytearray()
    try:
      for _retry in range(2):
        # Scan for ZPAD ZDLE ZBIN, tolerating stray bytes and echoed fragments.
        scan_state = 0
        while True:
            b = _read_byte(ser)
            if b < 0:
                return None
            if scan_state == 0:
                if b == ZPAD:
                    scan_state = 1
                    continue
                garbage.append(b)
                continue
            if scan_state == 1:
                if b == ZPAD:
                    continue
                if b == ZDLE:
                    scan_state = 2
                    continue
                scan_state = 0
                continue
            if b == ZBIN:
                break
            scan_state = 1 if b == ZPAD else 0

        frame_type = _read_zdle_byte(ser)
        if frame_type < 0:
            return None

        fields = []
        crc = _crc16_update(0, frame_type)
        malformed_header = False
        for _ in range(4):
            v = _read_zdle_byte(ser)
            if v < 0:
                malformed_header = True
                break
            fields.append(v)
            crc = _crc16_update(crc, v)

        if malformed_header:
            continue

        crc_hi = _read_zdle_byte(ser)
        crc_lo = _read_zdle_byte(ser)
        if crc_hi < 0 or crc_lo < 0:
            return None

        recv_crc = (crc_hi << 8) | crc_lo
        if recv_crc != crc:
            logger.warning("zmodem: header CRC mismatch (got %04x, expected %04x)",
                           recv_crc, crc)
            continue

        return (frame_type, fields)

      return None
    finally:
        if garbage and on_garbage is not None:
            try:
                on_garbage(bytes(garbage))
            except Exception:
                pass
        if timeout is not None:
            ser.timeout = old_timeout


def _frame_offset(fields: list[int]) -> int:
    return ((fields[0] << 24) |
            (fields[1] << 16) |
            (fields[2] << 8) |
            fields[3])


def _split_offset(offset: int) -> tuple[int, int, int, int]:
    return (
        (offset >> 24) & 0xff,
        (offset >> 16) & 0xff,
        (offset >> 8) & 0xff,
        offset & 0xff,
    )


def _recv_ack_or_zrpos(ser, error_message: str, chunk_end: int = 0, on_garbage=None) -> tuple[str, int]:
    for _attempt in range(2):
        hdr = _recv_header(ser, on_garbage=on_garbage)
        if hdr is not None:
            break
        logger.debug("zmodem: no header received, retrying (%d/2)", _attempt + 1)
    else:
        raise TransferError(error_message)

    frame_type, fields = hdr
    offset = _frame_offset(fields)
    if frame_type == ZACK:
        return ("ack", offset)
    if frame_type == ZRPOS:
        # The ZRPOS may be stale — left over from a previous error-recovery
        # cycle on the target whose response arrived after our
        # reset_input_buffer().  Peek for a subsequent ZACK that would prove
        # the chunk was actually received.
        if chunk_end and offset < chunk_end:
            follow = _recv_header(ser, on_garbage=on_garbage)
            if follow is not None:
                ft2, f2 = follow
                off2 = _frame_offset(f2)
                if ft2 == ZACK and off2 >= chunk_end:
                    logger.debug(
                        "zmodem: ignoring stale ZRPOS(%d), using ZACK(%d)",
                        offset, off2)
                    return ("ack", off2)
                if ft2 == ZRPOS:
                    # Use the more recent ZRPOS
                    return ("zrpos", off2)
        return ("zrpos", offset)
    raise TransferError(f"expected ZACK or ZRPOS, got 0x{frame_type:02x}")


# ---- Public API ----

def _abort_transfer(ser) -> None:
    """Best-effort receiver shutdown after a failed transfer.

    If rz is still alive (desynced), a ZFIN header makes it close the file,
    answer with its own ZFIN and exit — restoring the shell prompt so the
    caller's retry starts from a live session instead of feeding commands to
    a still-running rz. If rz is already dead, these 14 bytes are harmless
    line noise to the shell.
    """
    try:
        ser.write(_build_header(ZFIN, 0, 0, 0, 0))
        time.sleep(0.3)
        ser.reset_input_buffer()
    except Exception:
        pass


def _send_one_file(ser, remote_path: str, file_data: bytes, on_garbage,
                   on_progress, end_frame: int) -> None:
    """Send ZFILE..ZEOF for one file on an already-open zmodem session.

    The caller has just received a ZRINIT, which is the receiver saying it is
    ready for a file. *end_frame* is what the receiver answers ZEOF with: ZFIN
    when it was told to take exactly one file, ZRINIT in a batch, where it is
    inviting the next one.
    """
    file_size = len(file_data)

    # 3. Send ZFILE with filename and size
    zfile_info = b"\x00".join([
        remote_path.encode('utf-8'),
        str(file_size).encode('utf-8'),
        b"0",   # mtime
        b"0",   # mode
    ]) + b"\x00"
    # 4. ...and wait for the ZRPOS that says where to start. A lost ZFILE would
    # otherwise strand a whole batch: the receiver is still waiting for a file
    # while we wait for its answer. Re-sending is safe either way -- a receiver
    # that did get the first one is inside the file body, where an unexpected
    # header is answered with a ZRPOS for what it has so far.
    for _attempt in range(MAX_RESEND_ATTEMPTS):
        ser.write(_build_header(ZFILE, 0, 0, 0, 0))
        ser.write(_build_data_subpacket(zfile_info, ZCRCW))

        hdr = _recv_header(ser, on_garbage=on_garbage)
        if hdr is None:
            logger.warning("zmodem: no ZRPOS for %s, re-sending ZFILE", remote_path)
            continue
        frame_type, fields = hdr
        if frame_type != ZRPOS:
            raise TransferError(f"expected ZRPOS (0x09), got 0x{frame_type:02x}")
        break
    else:
        raise TransferError("failed to receive ZRPOS from target")
    offset = _frame_offset(fields)
    resend_attempts = 0

    # 5. Send ZDATA + file data sub-packets, resuming from requested offsets.
    while True:
        if offset > file_size:
            raise TransferError(f"target requested invalid resume offset {offset}")

        if offset < file_size:
            start_offset = offset
            ser.write(_build_header(ZDATA, *_split_offset(start_offset)))

            restart_transfer = False
            while offset < file_size:
                chunk_start = offset
                end = _chunk_end_within_wire_budget(file_data, offset)
                chunk = file_data[chunk_start:end]
                is_last = (end == file_size)
                term = ZCRCW if is_last else ZCRCQ
                ser.write(_build_data_subpacket(chunk, term))
                ser.flush()

                ack_error = (
                    "failed to receive ZACK after data"
                    if is_last
                    else f"failed to receive ZACK after chunk ending at offset {end}"
                )

                try:
                    response, response_offset = _recv_ack_or_zrpos(
                        ser, ack_error, chunk_end=end, on_garbage=on_garbage)
                except TransferError:
                    resend_attempts += 1
                    if resend_attempts > MAX_RESEND_ATTEMPTS:
                        raise
                    logger.warning(
                        "zmodem: retrying from offset %d after missing response to chunk ending at %d (%d/%d)",
                        chunk_start,
                        end,
                        resend_attempts,
                        MAX_RESEND_ATTEMPTS,
                    )
                    ser.reset_input_buffer()
                    time.sleep(0.2)
                    ser.reset_input_buffer()
                    offset = chunk_start
                    restart_transfer = True
                    break

                if response == "zrpos":
                    resend_attempts += 1
                    if resend_attempts > MAX_RESEND_ATTEMPTS:
                        raise TransferError(
                            f"target repeatedly requested resume at offset {response_offset}"
                        )
                    logger.warning(
                        "zmodem: target requested resume at offset %d after chunk ending at %d (%d/%d)",
                        response_offset,
                        end,
                        resend_attempts,
                        MAX_RESEND_ATTEMPTS,
                    )
                    ser.reset_input_buffer()
                    time.sleep(0.2)
                    ser.reset_input_buffer()
                    offset = response_offset
                    restart_transfer = True
                    break

                if response_offset < end:
                    resend_attempts += 1
                    if resend_attempts > MAX_RESEND_ATTEMPTS:
                        raise TransferError(
                            f"target only acknowledged offset {response_offset} after chunk ending at {end}"
                        )
                    logger.warning(
                        "zmodem: short ZACK for offset %d after chunk ending at %d, resending (%d/%d)",
                        response_offset,
                        end,
                        resend_attempts,
                        MAX_RESEND_ATTEMPTS,
                    )
                    offset = response_offset
                    restart_transfer = True
                    break

                resend_attempts = 0
                offset = response_offset
                if on_progress is not None:
                    on_progress(offset, file_size)

            if restart_transfer:
                continue

        # 6. Send ZEOF and allow the receiver to request a rewind if needed.
        ser.write(_build_header(ZEOF, *_split_offset(file_size)))

        hdr = _recv_header(ser, on_garbage=on_garbage)
        if hdr is None:
            resend_attempts += 1
            if resend_attempts > MAX_RESEND_ATTEMPTS:
                raise TransferError("failed to receive ZFIN from target")
            logger.warning(
                "zmodem: retrying ZEOF after missing final response (%d/%d)",
                resend_attempts,
                MAX_RESEND_ATTEMPTS,
            )
            continue

        frame_type, fields = hdr
        if frame_type == end_frame:
            return
        if frame_type == ZRPOS:
            resend_attempts += 1
            if resend_attempts > MAX_RESEND_ATTEMPTS:
                raise TransferError(
                    f"target repeatedly requested resume at offset {_frame_offset(fields)} during finalization"
                )
            offset = _frame_offset(fields)
            logger.warning(
                "zmodem: receiver requested rewind to offset %d during finalization (%d/%d)",
                offset,
                resend_attempts,
                MAX_RESEND_ATTEMPTS,
            )
            continue
        raise TransferError(
            f"expected 0x{end_frame:02x} or ZRPOS, got 0x{frame_type:02x}"
        )


_RZDBG_RX_PATTERN = re.compile(rb"RZDBG[^\n]*?\brx=(\d+)")


class _CountingSerial:
    """Serial proxy that records how many bytes have been handed to the port.

    The target prints its own cumulative received-byte count on every failed
    sub-packet. Comparing the two at that instant is the only thing that
    separates bytes lost on the wire from bytes that arrived and were then lost
    or mangled inside the target, and from the host side nothing else can tell
    them apart.
    """

    def __init__(self, serial):
        self._serial = serial
        self.written = 0

    def write(self, data):
        self.written += len(data)
        return self._serial.write(data)

    def __getattr__(self, name):
        return getattr(self._serial, name)

    @property
    def timeout(self):
        return self._serial.timeout

    @timeout.setter
    def timeout(self, value):
        self._serial.timeout = value


class _LinkAccounting:
    """Track host-sent against target-received across the target's failure lines.

    Both counters are cumulative but start from different origins -- the target
    has been counting since boot -- so the absolute difference means nothing.
    The *drift* in that difference does: the transfer is lockstep, so when the
    target reports a sub-packet failure it has already consumed the whole burst
    and the host is waiting, leaving nothing in flight. A drift that grows by
    the size of each deficit means the wire is eating them; a drift that stays
    put means every byte arrived and the fault is inside the target.
    """

    def __init__(self):
        self._pending = bytearray()
        self._baseline = None

    def observe(self, data: bytes, written: int) -> None:
        self._pending.extend(data)
        # Keep only what could still be part of an unterminated line.
        while True:
            match = _RZDBG_RX_PATTERN.search(self._pending)
            if match is None:
                break
            self._report(int(match.group(1)), written)
            del self._pending[: match.end()]
        if len(self._pending) > 512:
            del self._pending[:-512]

    def _report(self, target_rx: int, written: int) -> None:
        unaccounted = written - target_rx
        if self._baseline is None:
            self._baseline = unaccounted
            print(
                "  link check: baseline set (target rx={}, host wrote={})".format(
                    target_rx, written
                ),
                flush=True,
            )
            return
        print(
            "  link check: drift {:+d} bytes (target rx={}, host wrote={})".format(
                unaccounted - self._baseline, target_rx, written
            ),
            flush=True,
        )


def send_files(session, transfers, timeout: float = 30.0, on_progress=None,
               on_bytes=None) -> int:
    """Send many files to the target in ONE ``rz --batch`` session.

    *transfers* is an iterable of ``(local_path, remote_path)``. Each file
    names itself in its ZFILE header and the receiver creates the directories
    it needs, so nothing has to exist on the target beforehand.

    This exists because the per-file cost of ``send_file`` is not the data --
    the smoke corpus is 4546 files averaging under a kilobyte -- it is the rz
    spawn, the handshake and the shell round trip around each one. Returns the
    number of bytes sent.

    Files are sent in sorted order: the receiver only walks a path creating
    directories when the parent differs from the previous file's, so grouping
    a directory's files together turns thousands of mkdir syscalls into one
    per directory.

    *on_progress* is called ``on_progress(files_done, file_count, sent_bytes)``
    once per completed file; *on_bytes* is called
    ``on_bytes(offset, file_size)`` as the current file is acknowledged. A
    corpus of small sources only ever needs the first, but a batch holding one
    multi-megabyte binary would otherwise show no movement for minutes, so a
    caller drawing a bar wants both.
    """
    entries = sorted(
        ((str(local), str(remote)) for local, remote in transfers),
        key=lambda entry: entry[1],
    )
    if not entries:
        return 0

    ser = _CountingSerial(session.serial)
    link = _LinkAccounting()

    def _record_garbage(data: bytes) -> None:
        session._record_serial_output(data.decode('utf-8', 'ignore'))
        link.observe(data, ser.written)

    # "--zmodem" as well as "--batch" so a target still running an older rz --
    # which takes any unrecognised argument as the output filename -- runs a
    # single-file zmodem receive into a file called "--batch" and answers our
    # first ZEOF with ZFIN. That is a clean protocol error the caller can fall
    # back from; passing "--batch" alone would put it in the chunked protocol,
    # where it would sit waiting for a length prefix that never comes.
    session.write_command("rz --zmodem --batch")

    old_timeout = ser.timeout
    ser.timeout = timeout
    sent_bytes = 0
    try:
        hdr = _recv_header(ser, on_garbage=_record_garbage)
        if hdr is None:
            raise TransferError("failed to receive ZRINIT from target")
        frame_type, _ = hdr
        if frame_type != ZRINIT:
            raise TransferError(f"expected ZRINIT (0x01), got 0x{frame_type:02x}")

        for index, (local_path, remote_path) in enumerate(entries):
            with open(local_path, "rb") as fh:
                file_data = fh.read()
            # The receiver answers each ZEOF with ZRINIT, which doubles as the
            # invitation for the next file.
            _send_one_file(ser, remote_path, file_data, _record_garbage,
                           on_bytes, ZRINIT)
            sent_bytes += len(file_data)
            if on_progress is not None:
                on_progress(index + 1, len(entries), sent_bytes)

        # No more files: ZFIN ends the session, and the receiver echoes it back.
        ser.write(_build_header(ZFIN, 0, 0, 0, 0))
        hdr = _recv_header(ser, on_garbage=_record_garbage)
        if hdr is None or hdr[0] != ZFIN:
            raise TransferError("target did not acknowledge the end of the batch")
    except TransferError:
        _abort_transfer(ser)
        raise
    finally:
        ser.timeout = old_timeout

    response_lines = session.wait_for_prompt_except_logs()
    for line in response_lines:
        if line.startswith("ERROR"):
            raise TransferError(f"target reported: {line}")
    _report_rx_losses(session)
    return sent_bytes


def _report_rx_losses(session) -> None:
    """Print where the target lost received bytes, if it lost any.

    A batch this long is the one place the serial link is driven flat out, and
    a sub-packet CRC failure on its own does not say whether the bytes died in
    the UART's 32-byte FIFO (receive interrupt masked for too long), in the
    kernel ring above it (nothing read it fast enough), or never arrived. The
    counters distinguish those, and they are only worth a round trip once, at
    the end. A target without /proc/uart just says nothing.
    """
    try:
        session.write_command("cat /proc/uart")
        lines = session.wait_for_prompt_except_logs() or []
    except Exception:  # noqa: BLE001 - a diagnostic must never fail the transfer
        return
    stats = {}
    for line in lines:
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            stats[parts[0]] = int(parts[1])
    interesting = ("rx_overruns", "rx_dropped", "rx_fifo_full", "rx_framing_errors")
    if not stats or not any(stats.get(key) for key in interesting):
        return
    print(
        "  uart rx losses: {} FIFO overrun(s), {} ring drop(s), {} late "
        "arrival(s) at a full FIFO, {} framing error(s); worst masked window "
        "{} us (overrun) / {} us (late), over {} bytes received".format(
            stats.get("rx_overruns", 0),
            stats.get("rx_dropped", 0),
            stats.get("rx_fifo_full", 0),
            stats.get("rx_framing_errors", 0),
            stats.get("max_overrun_gap_us", 0),
            stats.get("max_late_gap_us", 0),
            stats.get("rx_bytes", 0),
        ),
        flush=True,
    )


def send_file(session, local_path: str, remote_path: str, timeout: float = 5.0,
              on_progress=None) -> None:
    """Transfer *local_path* to *remote_path* on the target using Zmodem protocol.

    Parameters
    ----------
    session : Session
        An open smoke-test session.
    local_path : str
        Absolute path to the file on the host.
    remote_path : str
        Absolute path where the file should be written on the target.
    timeout : float
        Seconds to wait for target responses.
    on_progress : callable, optional
        Called ``on_progress(sent_bytes, total_bytes)`` as the target
        acknowledges data. Test sources transfer in a blink, but a large file on
        a link that keeps asking for resends can sit silent for minutes, so the
        caller gets the chance to say something.
    """
    with open(local_path, "rb") as fh:
        file_data = fh.read()

    file_size = len(file_data)
    logger.debug("send_file (zmodem): %s -> %s  (%d bytes)",
                 local_path, remote_path, file_size)

    ser = session.serial

    # Bytes skipped while scanning for zmodem headers go to the session log,
    # which also scans them for crash markers: a target HardFault mid-transfer
    # (its diagnostics arrive in place of the expected ZACK) then flags
    # Session.target_crashed so the framework resets instead of retrying
    # against a dead receiver.
    def _record_garbage(data: bytes) -> None:
        session._record_serial_output(data.decode('utf-8', 'ignore'))

    # 1. Launch the receiver on the target with --zmodem
    session.write_command("rz --zmodem " + remote_path)

    old_timeout = ser.timeout
    ser.timeout = timeout

    try:
        # 2. Wait for ZRINIT from target
        hdr = _recv_header(ser, on_garbage=_record_garbage)
        if hdr is None:
            raise TransferError("failed to receive ZRINIT from target")
        frame_type, fields = hdr
        if frame_type != ZRINIT:
            raise TransferError(f"expected ZRINIT (0x01), got 0x{frame_type:02x}")

        # 3-6. ZFILE, the data sub-packets, then ZEOF. The receiver answers
        # ZEOF with ZFIN here: it was told to take exactly one file.
        _send_one_file(ser, remote_path, file_data, _record_garbage,
                       on_progress, ZFIN)

        # 8. Send our ZFIN
        ser.write(_build_header(ZFIN, 0, 0, 0, 0))

    except TransferError:
        _abort_transfer(ser)
        raise
    finally:
        ser.timeout = old_timeout

    # Wait for shell prompt to return
    response_lines = session.wait_for_prompt_except_logs()
    for line in response_lines:
        if line.startswith("OK"):
            logger.debug("send_file (zmodem): transfer OK")
            break
        if line.startswith("ERROR"):
            raise TransferError(f"target reported: {line}")
    else:
        logger.debug("send_file (zmodem): prompt returned, lines=%r", response_lines)
