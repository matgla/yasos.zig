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


def _recv_header(ser, timeout=None) -> tuple:
    """Receive a ZBIN header. Returns (frame_type, [f3,f2,f1,f0]) or None on error."""
    old_timeout = ser.timeout
    if timeout is not None:
        ser.timeout = timeout

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


def _recv_ack_or_zrpos(ser, error_message: str, chunk_end: int = 0) -> tuple[str, int]:
    for _attempt in range(2):
        hdr = _recv_header(ser)
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
            follow = _recv_header(ser)
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

def send_file(session, local_path: str, remote_path: str, timeout: float = 5.0) -> None:
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
    """
    with open(local_path, "rb") as fh:
        file_data = fh.read()

    file_size = len(file_data)
    logger.debug("send_file (zmodem): %s -> %s  (%d bytes)",
                 local_path, remote_path, file_size)

    ser = session.serial

    # 1. Launch the receiver on the target with --zmodem
    session.write_command("rz --zmodem " + remote_path)

    old_timeout = ser.timeout
    ser.timeout = timeout

    try:
        # 2. Wait for ZRINIT from target
        hdr = _recv_header(ser)
        if hdr is None:
            raise TransferError("failed to receive ZRINIT from target")
        frame_type, fields = hdr
        if frame_type != ZRINIT:
            raise TransferError(f"expected ZRINIT (0x01), got 0x{frame_type:02x}")

        # 3. Send ZFILE with filename and size
        zfile_info = b"\x00".join([
            remote_path.encode('utf-8'),
            str(file_size).encode('utf-8'),
            b"0",   # mtime
            b"0",   # mode
        ]) + b"\x00"
        ser.write(_build_header(ZFILE, 0, 0, 0, 0))
        ser.write(_build_data_subpacket(zfile_info, ZCRCW))

        # 4. Wait for ZRPOS
        hdr = _recv_header(ser)
        if hdr is None:
            raise TransferError("failed to receive ZRPOS from target")
        frame_type, fields = hdr
        if frame_type != ZRPOS:
            raise TransferError(f"expected ZRPOS (0x09), got 0x{frame_type:02x}")
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
                    end = min(offset + DATA_SUBPACKET_SIZE, file_size)
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
                        response, response_offset = _recv_ack_or_zrpos(ser, ack_error, chunk_end=end)
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

                if restart_transfer:
                    continue

            # 6. Send ZEOF and allow the receiver to request a rewind if needed.
            ser.write(_build_header(ZEOF, *_split_offset(file_size)))

            hdr = _recv_header(ser)
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
            if frame_type == ZFIN:
                break
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
            raise TransferError(f"expected ZFIN or ZRPOS, got 0x{frame_type:02x}")

        # 8. Send our ZFIN
        ser.write(_build_header(ZFIN, 0, 0, 0, 0))

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
