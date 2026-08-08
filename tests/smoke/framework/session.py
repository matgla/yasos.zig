"""
 Copyright (c) 2025 Mateusz Stadnik

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 """

import os
import codecs
import contextlib
import datetime
import subprocess
import re
import time
import logging

import serial
from .detect_serial_port import detect_probe_serial_port
from . import qemu

current_dir = os.path.dirname(os.path.abspath(__file__)) + "/.."
logger = logging.getLogger(__name__)
LOG_PREFIXES = ("[DBG]", "[ERR]", "[INF]", "[WRN]")

# The device's interactive shell echoes normal typing one character at a time,
# but draws its prompt with ANSI escapes (CR, "$ ", erase-to-EOL \x1b[K, cursor
# move \x1b[<n>C) and redraws the whole line for editing keys (cursor moves,
# deletes, history). Enter is echoed as CRLF. So a command's echo never appears
# as a clean "command\n"; this strips CSI / Fe escape sequences and carriage
# returns so the echo can be matched against its plain text.
_ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]')


def _strip_ansi(text):
    return _ANSI_RE.sub('', text).replace('\r', '')

# Serial read timeout (seconds). Deliberately short so genuine hangs fail
# fast; individual call sites that legitimately need longer (boot, compile,
# slow programs) pass an explicit ``timeout=`` or use ``Session.timeout()``.
SERIAL_TIMEOUT = float(os.environ.get("YASOS_SMOKE_SERIAL_TIMEOUT", "1"))
# Reset/boot produces the prompt much later than a regular command echo.
BOOT_TIMEOUT = float(os.environ.get("YASOS_SMOKE_BOOT_TIMEOUT", "15"))

# Must match the target's `console_baudrate` (source/kernel/drivers/uart/
# uart_driver.zig) and CONSOLE_BAUDRATE in scripts/remote_smoke_tui.py. A
# mismatch does not fail loudly, it just turns the console into garbage.
#
# 3 Mbaud is the target PL011's ceiling: clk_peri/(16*divisor) with clk_peri at
# 48 MHz and the divisor bottoming out at 1. It is exact, unlike 921600.
#
# This was 460800 until the rig's debug probe was reflashed off debugprobe
# 2.0.1, which predates the v2.2.1/v2.2.2 UART-TX fixes; at 921600 that firmware
# was measured dropping 32-48 bytes out of roughly every fourth bulk-transfer
# burst; see docs/remote_smoke_speedup_plan.md.
CONSOLE_BAUDRATE = int(os.environ.get("YASOS_SMOKE_CONSOLE_BAUDRATE", "3000000"))

class Session:
    serial_port = None
    serial = None
    backend = None
    target_needs_reset = True
    target_crashed = False
    # remote_source_path -> local sha256 of content last uploaded-and-verified
    # to that path during this session. Lets upload_testcase skip the device
    # side sha256sum on a cache hit (the device copy cannot drift between our
    # own commands). Cleared in reset_target() because a board reboot / QEMU
    # relaunch wipes the (RAM-backed) device filesystem.
    confirmed_uploads = {}
    # Bumped every time the cache above is cleared. Callers that bulk-seed it
    # (the smoke source manifest) compare against this to notice their seed was
    # thrown away and re-seed, instead of running unseeded for the rest of the
    # run.
    confirmed_uploads_generation = 0
    # While True, _record_serial_output does not scan for crash markers. Set
    # during post-crash log collection so the markers contained in the dumped
    # kernel.prev.log don't re-flag the (already rebooted) target as crashed.
    _collecting = False
    file = None
    prompt = "$ "
    crash_markers = (
        "hardfault diagnostics:",
        "hard fault occured",
        "kernel has halted.",
    )

    def __init__(self, name):
        if qemu.qemu_kernel() is not None:
            # QEMU mode: a relaunchable qemu process replaces the debug probe.
            if Session.backend is None:
                Session.backend = qemu.QemuTarget()
                Session.serial = Session.backend.start()
                Session.serial_port = Session.backend.label
                Session.target_needs_reset = True
            elif not Session.backend.is_alive() or Session.serial is None or not Session.serial.is_open:
                # qemu died mid-test (guest fault, semihosting exit, ...);
                # the shared PTY is gone and every serial op would EIO.
                Session.serial = Session.backend.reset()
                Session.target_needs_reset = True
            self.serial = Session.serial
        else:
            if Session.serial_port is None:
                serial_device = os.environ.get("SERIAL_DEVICE")

                if serial_device != None and len(serial_device.strip()) > 0:
                    logger.info("Using serial port %s", serial_device)
                    Session.serial_port = serial_device
                else:
                    Session.serial_port = detect_probe_serial_port()
            if Session.serial_port is None:
                raise RuntimeError("No serial port found for the debug probe.")
            if Session.serial is None or not Session.serial.is_open:
                Session.serial = serial.Serial(Session.serial_port, CONSOLE_BAUDRATE, timeout=SERIAL_TIMEOUT)
                Session.target_needs_reset = True
            self.serial = Session.serial
        os.makedirs("logs", exist_ok=True)
        log_file = name.split(':')[-1].split(' ')[0]
        log_file = log_file.replace('/', '_').replace('[', '_').replace(']', '_')
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_file = f"logs/{log_file}_{date}.txt"
        self.log_path = os.path.abspath(log_file)
        self.file = open(self.log_path, 'w')
        # Timed and left on the instance rather than reported from here: this is
        # the per-test prompt resync plus `cd /`, which is harness overhead the
        # test folds into its own setup_ms (tests/smoke/timing.py). Recording it
        # here keeps `framework` free of a dependency on the suite package. A
        # reset makes this large and that is the point — it is the cost of the
        # recovery, not of the test.
        _prepare_start = time.monotonic()
        self._prepare_target()
        self.prepare_ms = (time.monotonic() - _prepare_start) * 1000.0

    # Bytes to accumulate before flushing mid-read to the session log (and thus
    # to the crash-marker scan). Small enough that a crash dump is noticed while
    # it is still streaming, large enough not to make a file write per byte.
    RECORD_CHUNK = 256

    def _record_complete_lines(self, buf, recorded):
        """Log the whole lines of *buf* after *recorded*; return the new mark.

        Whole lines only, because ``_record_serial_output`` looks for the crash
        markers within the text it is handed: flushing at an arbitrary byte
        boundary could split ``hardfault diagnostics:`` across two calls and
        neither would match.
        """
        end = buf.rfind(b"\n", recorded) + 1
        if end <= recorded:
            return recorded
        self._record_serial_output(buf[recorded:end].decode('utf-8', 'ignore'))
        return end

    def _record_serial_output(self, text):
        if not text:
            return
        self.file.write(text)
        self.file.flush()
        if Session._collecting:
            return
        normalized = text.lower()
        if any(marker in normalized for marker in Session.crash_markers):
            Session.target_crashed = True
            Session.target_needs_reset = True

    @contextlib.contextmanager
    def timeout(self, seconds):
        """Temporarily override the serial read timeout for slow operations.

        Usage::

            with session.timeout(10):
                session.write_command("slow_command")
                session.wait_for_prompt_except_logs()
        """
        old_timeout = self.serial.timeout
        self.serial.timeout = seconds
        try:
            yield
        finally:
            self.serial.timeout = old_timeout

    def _read_until(self, marker, timeout=None):
        # Idle (silence) timeout rather than a total deadline: keep reading as
        # long as the target emits *anything*, and only give up after `timeout`
        # seconds of complete silence.  pyserial's read_until() uses a total
        # deadline, which under heavy parallel load (one QEMU per xdist worker,
        # host CPU oversubscribed) spuriously trips on slow-but-alive targets —
        # a sha256sum or compile that is making progress (loader logs, output
        # still streaming) gets cut off mid-flight.  An idle timeout tolerates
        # that wall-clock slowness while still failing fast on a genuine hang
        # (a hung target emits nothing, so the silence window elapses).
        idle_timeout = self.serial.timeout if timeout is None else timeout
        marker_b = marker.encode('utf-8')
        lenterm = len(marker_b)
        poll = min(0.1, idle_timeout) if idle_timeout else 0.1
        old_timeout = self.serial.timeout
        self.serial.timeout = poll
        buf = bytearray()
        recorded = 0
        # Only a crash seen *during this read* may end it early. A flag left
        # over from an earlier crash says nothing about the bytes arriving now
        # -- honouring it would truncate the very read that is meant to observe
        # the recovery.
        crashed_on_entry = Session.target_crashed
        try:
            deadline = time.monotonic() + idle_timeout
            while True:
                # Read one byte at a time so we stop exactly at the marker
                # (matching pyserial read_until semantics) and never over-read
                # into the next command's output.  read(1) returns immediately
                # while bytes are available and blocks up to `poll` when idle,
                # which is how we sample the silence deadline.
                c = self.serial.read(1)
                if c:
                    buf += c
                    deadline = time.monotonic() + idle_timeout
                    if buf[-lenterm:] == marker_b:
                        break
                    # Log as we go rather than only on the way out. A target
                    # that faults mid-command dumps diagnostics forever, and
                    # every byte of that dump pushes the silence deadline back:
                    # holding the text until the loop ends means the crash
                    # markers are never scanned and the loop never ends.
                    if len(buf) - recorded >= Session.RECORD_CHUNK:
                        recorded = self._record_complete_lines(buf, recorded)
                        if Session.target_crashed and not crashed_on_entry:
                            break
                elif time.monotonic() >= deadline:
                    break
        finally:
            self.serial.timeout = old_timeout

        self._record_serial_output(buf[recorded:].decode('utf-8', 'ignore'))
        return buf.decode('utf-8', 'ignore')

    def _drain_serial_buffer(self):
        if self.serial.in_waiting <= 0:
            return ""
        data = self.serial.read(self.serial.in_waiting)
        text = data.decode('utf-8', 'ignore')
        self._record_serial_output(text)
        return text

    def _try_recover_prompt(self):
        buffered = self._drain_serial_buffer()
        if Session.prompt in buffered:
            return True

        self.serial.write(b"\n")
        recovered = self._read_until(Session.prompt, timeout=2)
        return recovered.endswith(Session.prompt)

    def _prepare_target(self):
        needs_reset = Session.target_needs_reset
        if not needs_reset:
            try:
                needs_reset = not self._try_recover_prompt()
            except (OSError, serial.SerialException):
                # Dead PTY / unplugged probe: every serial op raises EIO, so
                # only a full target reset can bring the session back.
                needs_reset = True
            if needs_reset:
                self.file.write("Prompt recovery failed, resetting target.\n")
                self.file.flush()
                Session.target_needs_reset = True
        if needs_reset:
            self._reset_and_wait_for_prompt()

        self.write_command("cd /")
        self.wait_for_prompt_except_logs()

    def _reset_and_wait_for_prompt(self):
        try:
            self.serial.reset_input_buffer()
        except (OSError, serial.SerialException):
            pass  # serial already dead; reset_target replaces/revives it
        # Escalating recovery ladder. Each rung first applies a stronger remedy
        # (none -> USB power-cycle -> reflash), then resets and waits for a
        # prompt; we stop at the first rung that yields one. A rung whose remedy
        # isn't applicable (QEMU mode, probe/artifacts missing) returns False and
        # we re-raise the last failure rather than escalate blindly. The classic
        # trigger is a double-fault lockup ("clearing lockup after double fault")
        # that sysresetreq + rescue DP can't clear.
        last_exc = None
        for remedy in (None, self.power_reset_target, self.reflash_target):
            if remedy is not None and not remedy():
                break
            self.reset_target()
            try:
                self.serial.reset_input_buffer()
            except (OSError, serial.SerialException):
                pass
            try:
                self.wait_for_prompt_except_logs(timeout=BOOT_TIMEOUT)
            except RuntimeError as exc:
                last_exc = exc
                continue
            while self.serial.in_waiting > 0:
                self.wait_for_prompt_except_logs()
            Session.target_needs_reset = False
            Session.target_crashed = False
            return
        raise last_exc if last_exc is not None else RuntimeError(
            "Prompt not found on serial port: '$ '"
        )

    def power_reset_target(self):
        """Power-cycle the USB hub the debug probe sits on, to recover a board
        the OpenOCD reset could not revive. Returns True only when a cycle
        actually happened. No-op (returns False) in QEMU mode or when the probe
        can't be located -- the caller then re-raises the original reset error.

        The cycle also drops the probe (the board has no independently switchable
        power on this rig), so the old serial handle dies; we reopen it on the
        re-enumerated /dev node before returning.
        """
        if Session.backend is not None:
            return False
        self.file.write(
            "OpenOCD reset did not recover the board; power-cycling via "
            + current_dir + "/power_reset_target.sh\n"
        )
        self.file.flush()
        output = subprocess.run(
            "./power_reset_target.sh", shell=True, cwd=current_dir,
            stderr=subprocess.STDOUT, stdout=subprocess.PIPE,
        )
        self.file.write(output.stdout.decode('utf-8'))
        self.file.flush()
        if output.returncode != 0:
            self.file.write(
                f"power_reset_target.sh exited {output.returncode}; no power reset performed.\n"
            )
            self.file.flush()
            return False
        # The whole hub (probe included) was power-cycled, so the old serial
        # handle is dead -- reopen on the re-enumerated port.
        self._reopen_serial()
        return True

    def _reopen_serial(self):
        """Reopen the debug-probe serial port after a power cycle re-enumerated
        it. The /dev node can change, so prefer the pinned SERIAL_DEVICE when it
        reappears and otherwise re-detect the probe. Raises if it never returns.
        """
        try:
            if Session.serial is not None and Session.serial.is_open:
                Session.serial.close()
        except (OSError, serial.SerialException):
            pass
        Session.serial = None

        configured = (os.environ.get("SERIAL_DEVICE") or "").strip()
        port = None
        deadline = time.monotonic() + BOOT_TIMEOUT
        while time.monotonic() < deadline:
            if configured and os.path.exists(configured):
                port = configured
                break
            try:
                detected = detect_probe_serial_port()
            except Exception:
                detected = None
            if detected:
                port = detected
                break
            time.sleep(0.5)

        if port is None:
            Session.serial_port = None
            raise RuntimeError("serial port did not re-enumerate after power cycle")

        Session.serial_port = port
        Session.serial = serial.Serial(port, CONSOLE_BAUDRATE, timeout=SERIAL_TIMEOUT)
        self.serial = Session.serial
        self.file.write(f"Reopened serial on {port} after power cycle.\n")
        self.file.flush()

    def reflash_target(self):
        """Reflash the board (rootfs + kernel) as the final reset escalation,
        when even a power cycle won't bring it back to a prompt. Returns True
        only when a reflash actually ran. No-op (returns False) in QEMU mode or
        when the flash artifacts aren't available -- the caller then re-raises
        the prior failure. The probe is untouched, so self.serial stays valid;
        the caller's reset_target() + wait handles the post-flash boot.
        """
        if Session.backend is not None:
            return False
        self.file.write(
            "Power cycle did not recover the board; reflashing via "
            + current_dir + "/reflash_target.sh\n"
        )
        self.file.flush()
        output = subprocess.run(
            "./reflash_target.sh", shell=True, cwd=current_dir,
            stderr=subprocess.STDOUT, stdout=subprocess.PIPE,
        )
        self.file.write(output.stdout.decode('utf-8'))
        self.file.flush()
        if output.returncode != 0:
            self.file.write(
                f"reflash_target.sh exited {output.returncode}; no reflash performed.\n"
            )
            self.file.flush()
            return False
        return True

    def collect_crash_logs(self):
        """After a crash: reboot the board and pull the persisted kernel logs
        off the SD card into this test's log file.

        The kernel rotates /root/logs/kernel.log -> kernel.prev.log on every
        boot, so after this reset kernel.prev.log holds the full log of the run
        that just crashed (dynamic-loader load addresses, pre-fault kernel
        messages). The live HardFault postmortem is already in this file from
        the serial stream; this appends the persisted context next to it and
        leaves the target at a clean prompt for the next test.
        """
        self.file.write("\n===== crash detected: rebooting to collect persisted SD logs =====\n")
        self.file.flush()
        try:
            self._reset_and_wait_for_prompt()
        except (OSError, serial.SerialException, RuntimeError) as exc:
            self.file.write(f"crash-log collection: target reset failed: {exc}\n")
            self.file.flush()
            return
        Session._collecting = True
        try:
            for name in ("kernel.prev.log", "kernel.log"):
                path = f"/root/logs/{name}"
                self.file.write(f"\n----- {path} (persisted) -----\n")
                self.file.flush()
                try:
                    self.write_command(f"cat {path}")
                    self.wait_for_prompt_except_logs(timeout=BOOT_TIMEOUT)
                except (OSError, serial.SerialException, RuntimeError, AssertionError) as exc:
                    self.file.write(f"(could not read {path}: {exc})\n")
                    self.file.flush()
        finally:
            Session._collecting = False

    def wait_for_prompt(self, timeout=None):
        return self.wait_for_data("$ ", timeout=timeout)

    def wait_for_prompt_except_logs(self, timeout=None):
        while True:
            lines = self._read_until(Session.prompt, timeout=timeout)
            if not lines.endswith(Session.prompt):
                if Session.target_crashed:
                    raise RuntimeError("Target crashed while waiting for prompt")
                raise RuntimeError("Prompt not found on serial port: '$ '")
            response = lines[:-len(Session.prompt)]
            split_lines = response.splitlines()
            filtered_lines = []
            for line in split_lines:
                if line.startswith(LOG_PREFIXES):
                    continue
                stripped = line.strip()
                if stripped:
                    filtered_lines.append(stripped)

            return filtered_lines

    def wait_for_prompt_streaming(self, on_line=None, timeout=None):
        """Stream output line-by-line until the prompt, allowing an early abort.

        ``timeout`` (seconds) bounds the *silence* between output chunks, not
        the total runtime; a program may run arbitrarily long as long as it
        keeps printing. ``None`` keeps the session default.

        Behaves like ``wait_for_prompt_except_logs`` (returning the same
        stripped, log-filtered lines) but invokes ``on_line(line)`` for every
        complete, non-log, non-empty output line as it arrives. If ``on_line``
        returns a truthy value, reading stops immediately and the call returns
        with ``aborted=True`` instead of waiting for the prompt or the serial
        timeout. Because the foreground program may still be running at that
        point (e.g. a miscompiled loop printing forever), the target is flagged
        for a reset so the next test starts from a clean state.

        Returns a ``(filtered_lines, aborted)`` tuple.
        """
        pending = ""
        filtered_lines = []
        # A read can end mid multi-byte UTF-8 sequence (e.g. the first byte of
        # 'п'); a plain decode(errors='ignore') would silently drop those bytes
        # and a chunk holding only a partial sequence would decode to "" and be
        # mistaken for a timeout. The incremental decoder buffers partial
        # sequences until the rest arrives.
        decoder = codecs.getincrementaldecoder('utf-8')('ignore')
        old_timeout = self.serial.timeout
        if timeout is not None:
            self.serial.timeout = timeout
        try:
            while True:
                chunk = self.serial.read(self.serial.in_waiting or 1)
                if not chunk:
                    if Session.target_crashed:
                        raise RuntimeError("Target crashed while waiting for prompt")
                    raise RuntimeError("Prompt not found on serial port: '$ '")
                text = decoder.decode(chunk)
                if Session.target_crashed:
                    raise RuntimeError("Target crashed while waiting for prompt")
                if not text:
                    continue
                self._record_serial_output(text)
                pending += text
                while "\n" in pending:
                    raw_line, pending = pending.split("\n", 1)
                    if raw_line.startswith(LOG_PREFIXES):
                        continue
                    line = raw_line.strip()
                    if not line:
                        continue
                    filtered_lines.append(line)
                    if on_line is not None and on_line(line):
                        Session.target_needs_reset = True
                        return filtered_lines, True
                if pending.endswith(Session.prompt):
                    return filtered_lines, False
        finally:
            if timeout is not None:
                self.serial.timeout = old_timeout

    def wait_for_data(self, data, timeout=None):
        line = self._read_until(data, timeout=timeout)
        line = line.strip()
        if not line.endswith(data.strip()):
            if Session.target_crashed:
                raise RuntimeError("Target crashed while waiting for serial data: '" + data + "'")
            raise RuntimeError("Prompt not found on serial port: '" + data + "'")
        return line

    def read_until(self, data):
        return self.wait_for_data(data)

    def read_raw(self, size, timeout=3):
        old_timeout = self.serial.timeout
        self.serial.timeout = timeout
        data = self.serial.read(size)
        self.serial.timeout = old_timeout
        return data

    def read_until_prompt(self):
        return self.read_until("$")

    def write_raw(self, data, timeout):
        self.serial.write(data)

    def _wait_for_echo(self, command):
        """Read and confirm the device echoed *command* back intact.

        The shell draws its prompt with ANSI escapes and echoes Enter as CRLF,
        so a literal ``command\\n`` never appears verbatim. We match the command
        against an ANSI/CR-stripped view of the stream (gating the whole-buffer
        check on the command's last byte), then drain one byte at a time through
        the newline that commits the line -- leaving the stream where the
        command's own output (or the zmodem handshake) begins, without swallowing
        the first byte of output.

        Returns True if the command echoed back intact; False on idle timeout
        (a byte was dropped in flight, or the target went quiet -> resend).
        """
        idle_timeout = self.serial.timeout
        poll = min(0.1, idle_timeout) if idle_timeout else 0.1
        tail = command.encode('utf-8')[-1:]
        old_timeout = self.serial.timeout
        self.serial.timeout = poll
        buf = bytearray()
        recorded = 0
        # See _read_until: a stale crash flag must not cut this read short.
        crashed_on_entry = Session.target_crashed
        seen = False
        try:
            deadline = time.monotonic() + idle_timeout
            while True:
                c = self.serial.read(1)
                if c:
                    buf += c
                    deadline = time.monotonic() + idle_timeout
                    if not seen:
                        if c == tail and command in _strip_ansi(
                                buf.decode('utf-8', 'ignore')):
                            seen = True
                    elif c == b'\n':
                        break
                    # See _read_until: a faulting target streams diagnostics
                    # indefinitely, so the echo we are waiting for never
                    # arrives while the silence deadline never expires. Feeding
                    # the crash-marker scan as we read is what ends the wait.
                    if not seen and len(buf) - recorded >= Session.RECORD_CHUNK:
                        recorded = self._record_complete_lines(buf, recorded)
                        if Session.target_crashed and not crashed_on_entry:
                            break
                elif time.monotonic() >= deadline:
                    break
        finally:
            self.serial.timeout = old_timeout
        self._record_serial_output(buf[recorded:].decode('utf-8', 'ignore'))
        return seen

    def write_command(self, command, retries=2):
        """Send *command* and confirm the device echoed it back intact.

        The shell's line editor echoes normal typing one character at a time
        (full-line redraws are reserved for actual editing -- cursor moves,
        deletes, history), so the command comes back cleanly. We still verify it
        and resend up to ``retries`` times to ride out a transient dropped byte
        (a UART RX hiccup) without failing the whole test, recovering a clean
        prompt between attempts. The success path leaves the stream positioned
        right after the echoed line (past the committing newline), so callers
        that stream data immediately afterwards -- e.g. the zmodem ``rz``
        handshake -- are unaffected.
        """
        last_error = None
        for attempt in range(retries + 1):
            self.serial.write((command + '\n').encode('utf-8'))
            if self._wait_for_echo(command):
                return
            # Echo never completed -> a byte was dropped in flight, or the
            # target crashed (which we must not paper over).
            if Session.target_crashed:
                raise RuntimeError(
                    f"Target crashed while waiting for echo of {command!r}")
            last_error = RuntimeError(
                f"command echo not seen for {command!r} "
                f"after {attempt + 1} attempt(s)")
            if attempt == retries:
                raise last_error
            self.file.write(
                f"write_command: echo mismatch for {command!r}, "
                f"resending ({attempt + 1}/{retries})\n"
            )
            self.file.flush()
            self._recover_after_truncated_command()
        raise last_error

    def _recover_after_truncated_command(self):
        """Drain the garbled (truncated) command's output and resync to a prompt.

        A truncation usually still delivered the trailing newline, so the bad
        command already ran and the shell is at (or heading toward) a fresh
        prompt. Drain stale output and nudge with a newline until the prompt
        reappears, so the resend starts from a known-good state.
        """
        for _ in range(3):
            try:
                if self._try_recover_prompt():
                    return
            except (OSError, serial.SerialException):
                break

    def read_line(self):
        line = self.serial.readline().decode('utf-8', 'ignore')
        self._record_serial_output(line)
        line = line.strip()
        return line


    def read_line_except(self, regex):
        while True:
            line = self.serial.readline().decode('utf-8', 'ignore')
            self._record_serial_output(line)
            line = line.strip()
            if not re.search(regex, line):
                return line
        return ""

    def read_line_except_logs(self):
         while True:
            line = self.serial.readline().decode('utf-8', 'ignore')
            self._record_serial_output(line)
            if line.startswith(LOG_PREFIXES):
                continue
            return line.strip()

    def reset_target(self):
        # A reset wipes the device filesystem, so previously uploaded sources
        # are gone; drop their cached hashes to force re-verification/upload.
        Session.confirmed_uploads.clear()
        Session.confirmed_uploads_generation += 1
        # The crash flag describes the boot we are about to terminate, and a
        # reset is the remedy for it -- so it must not survive into the wait for
        # the *new* boot. It used to: the mid-read crash-marker abort in
        # _read_until fires on this flag, so a still-set flag cut the boot wait
        # short after the first 256 bytes of banner, no prompt was ever seen,
        # and the recovery ladder escalated to a power cycle and a reflash that
        # were equally doomed. One crash then failed every remaining test on a
        # board that was in fact booting fine. If the new boot itself faults,
        # the marker scan sets the flag again and the abort works as intended.
        Session.target_crashed = False
        if Session.backend is not None:
            self.file.write("Resetting QEMU target (relaunching qemu).\n")
            self.file.flush()
            Session.serial = Session.backend.reset()
            self.serial = Session.serial
            return
        self.file.write("Resetting target with command: " + current_dir + "/reset_target.sh\n")
        output = subprocess.run("./reset_target.sh", shell=True, cwd=current_dir, stderr=subprocess.STDOUT, stdout=subprocess.PIPE)
        if (output.returncode != 0):
            output = subprocess.run("./reset_target.sh", shell=True, cwd=current_dir, stderr=subprocess.STDOUT, stdout=subprocess.PIPE)
        self.file.write(output.stdout.decode('utf-8'))
        self.file.flush()

    def shutdown_target(self):
        if Session.target_needs_reset or Session.target_crashed:
            self.file.write("Skipping target shutdown because the target is not running cleanly.\n")
            self.file.flush()
            return
        if not self._try_recover_prompt():
            self.file.write("Skipping target shutdown because prompt recovery failed.\n")
            self.file.flush()
            return
        self.write_command("exit")
        data = self.wait_for_data("You can turn off your PC now!", timeout=BOOT_TIMEOUT)
        assert not "Memory leaks detected" in data
        Session.target_needs_reset = True

    @classmethod
    def detached(cls, name):
        """A session on the shared serial port that belongs to no test.

        End-of-run work (shutting the target down, recording the source
        manifest) still needs to talk to the device after every per-test session
        has closed its log file, so it gets a session of its own with a log file
        of its own. Returns None when there is no serial port left to talk to.
        """
        if cls.serial is None:
            return None
        os.makedirs("logs", exist_ok=True)
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        session = cls.__new__(cls)
        session.serial = cls.serial
        session.file = open(f"logs/{name}_{date}.txt", 'w')
        return session

    @classmethod
    def finalize(cls):
        if cls.backend is not None:
            cls.backend.stop()
            cls.backend = None
            cls.serial = None
            cls.serial_port = None
            cls.target_needs_reset = True
            cls.target_crashed = False
            return

        if cls.serial is None:
            return

        session = cls.detached("session_shutdown")
        try:
            session.shutdown_target()
        finally:
            session.file.close()
            cls.serial.close()
            cls.serial = None
            cls.target_needs_reset = True
            cls.target_crashed = False


    def close(self):
        self.file.close()

