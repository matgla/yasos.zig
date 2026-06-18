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

# Serial read timeout (seconds). Deliberately short so genuine hangs fail
# fast; individual call sites that legitimately need longer (boot, compile,
# slow programs) pass an explicit ``timeout=`` or use ``Session.timeout()``.
SERIAL_TIMEOUT = float(os.environ.get("YASOS_SMOKE_SERIAL_TIMEOUT", "1"))
# Reset/boot produces the prompt much later than a regular command echo.
BOOT_TIMEOUT = float(os.environ.get("YASOS_SMOKE_BOOT_TIMEOUT", "15"))

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
                Session.serial = serial.Serial(Session.serial_port, 921600, timeout=SERIAL_TIMEOUT)
                Session.target_needs_reset = True
            self.serial = Session.serial
        os.makedirs("logs", exist_ok=True)
        log_file = name.split(':')[-1].split(' ')[0]
        log_file = log_file.replace('/', '_').replace('[', '_').replace(']', '_')
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_file = f"logs/{log_file}_{date}.txt"
        self.log_path = os.path.abspath(log_file)
        self.file = open(self.log_path, 'w')
        self._prepare_target()

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
                elif time.monotonic() >= deadline:
                    break
        finally:
            self.serial.timeout = old_timeout

        text = buf.decode('utf-8', 'ignore')
        self._record_serial_output(text)
        return text

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
        self.reset_target()
        self.serial.reset_input_buffer()
        self.wait_for_prompt_except_logs(timeout=BOOT_TIMEOUT)
        while self.serial.in_waiting > 0:
            self.wait_for_prompt_except_logs()
        Session.target_needs_reset = False
        Session.target_crashed = False

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

    def write_command(self, command, retries=2):
        """Send *command* and confirm the device echoed it back intact.

        The host blasts the whole line at 921600 baud; if a byte is dropped
        (UART RX overrun while the device is mid-transmit, or a hiccup in the
        debug-probe's USB<->UART bridge) the device runs a *truncated* command
        and our echo marker never appears. Rather than fail the whole test on
        that transient, verify the echo and resend up to ``retries`` times,
        recovering a clean prompt between attempts. The success path is
        unchanged (wait for the echo, return), so callers that stream data
        right after the echo -- e.g. the zmodem ``rz`` handshake -- are
        unaffected.
        """
        marker = command + '\n'
        last_error = None
        for attempt in range(retries + 1):
            self.serial.write(marker.encode('utf-8'))
            try:
                data = self.wait_for_data(marker)
            except RuntimeError as exc:
                # Echo never completed -> the line was truncated in flight (or
                # the target crashed, which we must not paper over).
                last_error = exc
                if Session.target_crashed or attempt == retries:
                    raise
                self.file.write(
                    f"write_command: echo mismatch for {command!r}, "
                    f"resending ({attempt + 1}/{retries})\n"
                )
                self.file.flush()
                self._recover_after_truncated_command()
                continue
            line = data.strip()
            assert command in line, f"expected command '{command}' not found in: {line}"
            return
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

        os.makedirs("logs", exist_ok=True)
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        log_file = f"logs/session_shutdown_{date}.txt"
        session = cls.__new__(cls)
        session.serial = cls.serial
        session.file = open(log_file, 'w')
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

