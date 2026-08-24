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
import termios
import time
import logging

import serial
from .detect_serial_port import detect_probe_serial_port
from .paths import smoke_log_dir
from . import qemu

current_dir = os.path.dirname(os.path.abspath(__file__)) + "/.."
logger = logging.getLogger(__name__)
LOG_PREFIXES = ("[DBG]", "[ERR]", "[INF]", "[WRN]")

# Every "the serial handle may have died under us" except clause.
#
# termios.error must be in it: pyserial's POSIX backend calls termios directly
# for the buffer flushes (tcflush), the drain (tcdrain) and every timeout change
# (tcsetattr, via _reconfigure_port) without wrapping them, and termios.error
# derives straight from Exception -- not from OSError, and so not from
# SerialException either. When the /dev node dies under an open handle (the
# probe re-enumerates, the hub glitches) the EIO therefore surfaces as a bare
# termios.error and sails through `except (OSError, serial.SerialException)`.
# That is what took out a whole CI run: the first stale-handle flush aborted
# Session.__init__ inside the recovery ladder, and because a dead handle still
# reports is_open, every remaining test errored at setup the same way.
SERIAL_ERRORS = (OSError, serial.SerialException, termios.error)

# The device's interactive shell echoes normal typing one character at a time,
# but draws its prompt with ANSI escapes (CR, "$ ", erase-to-EOL \x1b[K, cursor
# move \x1b[<n>C) and redraws the whole line for editing keys (cursor moves,
# deletes, history). Enter is echoed as CRLF. So a command's echo never appears
# as a clean "command\n"; this strips CSI / Fe escape sequences and carriage
# returns so the echo can be matched against its plain text.
_ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]')


def _strip_ansi(text):
    return _ANSI_RE.sub('', text).replace('\r', '')


def _restore_timeout(port, value):
    """Put a serial read timeout back, tolerating a handle that died meanwhile.

    Assigning ``timeout`` reconfigures the port (tcsetattr), so it fails on a
    /dev node that has gone away -- and every caller restores from a ``finally``,
    where that would replace the real error with a confusing termios one.
    """
    try:
        port.timeout = value
    except SERIAL_ERRORS:
        pass


def _open_serial_port(port, deadline=None):
    """Open *port*, retrying until *deadline* while a fresh node settles.

    A re-enumerated /dev node exists a little before it is usable: the open can
    fail with ENOENT (udev has not caught up) or EBUSY, and because pyserial
    configures the line immediately after open() it can also come back as a bare
    termios error. Returns None when it never opens.
    """
    last = None
    while True:
        try:
            return serial.Serial(port, CONSOLE_BAUDRATE, timeout=SERIAL_TIMEOUT)
        except SERIAL_ERRORS as exc:
            last = exc
        if deadline is None or time.monotonic() >= deadline:
            logger.warning("could not open serial port %s: %s", port, last)
            return None
        time.sleep(0.5)


# Serial read timeout (seconds). Deliberately short so genuine hangs fail
# fast; individual call sites that legitimately need longer (boot, compile,
# slow programs) pass an explicit ``timeout=`` or use ``Session.timeout()``.
SERIAL_TIMEOUT = float(os.environ.get("YASOS_SMOKE_SERIAL_TIMEOUT", "1"))

# Idle timeout for a command echo specifically, much tighter than SERIAL_TIMEOUT.
#
# The debug probe drops the occasional host->target byte; the harness recovers by
# resyncing and resending, but on the shared SERIAL_TIMEOUT noticing costs a full
# second of silence per drop. An echo cannot legitimately be slow -- the shell
# echoes character by character as it reads the line, so this is an idle deadline
# reset on every byte, and even a 200-character command echoes inside ~5 ms. The
# cost of being wrong is one extra resend, not a failure.
#
# Lowering the line rate instead was measured and rejected: 3 Mbaud -> 1 Mbaud
# adds ~33 s to the source upload alone, against ~23 s of drops per run.
ECHO_IDLE_TIMEOUT = float(os.environ.get("YASOS_SMOKE_ECHO_TIMEOUT", "0.25"))
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
                # The node can still be re-enumerating from a previous test's
                # reset, so give it the boot window to settle instead of
                # erroring this test out at setup on a transient ENOENT/EIO.
                port = Session.serial_port
                Session.serial = _open_serial_port(
                    port, time.monotonic() + BOOT_TIMEOUT)
                if Session.serial is None:
                    # Forget the port too: it may come back under another name,
                    # and the next session then re-detects the probe.
                    Session.serial_port = None
                    raise RuntimeError(
                        f"Could not open the debug-probe serial port {port}")
                Session.target_needs_reset = True
            self.serial = Session.serial
        logs_dir = smoke_log_dir()
        os.makedirs(logs_dir, exist_ok=True)
        log_file = name.split(':')[-1].split(' ')[0]
        log_file = log_file.replace('/', '_').replace('[', '_').replace(']', '_')
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        self.log_path = os.path.abspath(logs_dir / f"{log_file}_{date}.txt")
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
    def expect_process_fault(self):
        """Run a block that deliberately faults a *user process*.

        The kernel survives those by design -- it resumes the faulting process
        at _exit(-1) and carries on -- but the diagnostics it prints carry the
        same marker as a kernel that died, so the scanner would call the target
        crashed and reset it out from under the test. Scanning is suppressed
        for the block and the flags are put back exactly as they were, so a
        crash that had already been recorded still counts.

        This does not weaken what such a test proves: a kernel that really did
        die returns no prompt, and the test fails on that instead.

        Usage::

            with session.expect_process_fault():
                session.write_command("/tmp/crashes")
                output = session.read_until_prompt()
        """
        previous_collecting = Session._collecting
        previous_crashed = Session.target_crashed
        previous_needs_reset = Session.target_needs_reset
        Session._collecting = True
        try:
            yield
        finally:
            Session._collecting = previous_collecting
            Session.target_crashed = previous_crashed
            Session.target_needs_reset = previous_needs_reset

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
            _restore_timeout(self.serial, old_timeout)

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
            _restore_timeout(self.serial, old_timeout)

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
            except SERIAL_ERRORS:
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
        self._flush_input()
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
            self._flush_input()
            try:
                self.wait_for_prompt_except_logs(timeout=BOOT_TIMEOUT)
            except (RuntimeError,) + SERIAL_ERRORS as exc:
                # Serial errors escalate like a missing prompt does: a handle
                # that EIOs is exactly what the next rung's reopen fixes, and
                # letting it out here would fail the test without ever trying.
                last_exc = exc
                continue
            try:
                while self.serial.in_waiting > 0:
                    self.wait_for_prompt_except_logs()
            except SERIAL_ERRORS as exc:
                last_exc = exc
                continue
            Session.target_needs_reset = False
            Session.target_crashed = False
            return
        raise last_exc if last_exc is not None else RuntimeError(
            "Prompt not found on serial port: '$ '"
        )

    def _flush_input(self):
        """Drop pending input, reopening the port if the handle has gone stale.

        The flush is a tcflush straight on the fd, so it is the first thing to
        fail once the /dev node dies -- and not noticing leaves the rest of the
        run talking to a dead descriptor. Returns True when the port is usable
        afterwards.
        """
        try:
            self.serial.reset_input_buffer()
            return True
        except SERIAL_ERRORS as exc:
            self.file.write(f"Serial flush failed ({exc}); the handle is stale.\n")
            self.file.flush()
            return self._reopen_serial(required=False)

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

    def _reopen_serial(self, required=True):
        """Reopen the debug-probe serial port after it re-enumerated.

        Called both after a deliberate power cycle and whenever a serial op dies
        with EIO because the /dev node went away under an open handle. pyserial
        keeps reporting ``is_open`` for such a handle, so nothing reopens it
        unless we do -- and the handle is shared by every Session, so one stale
        descriptor otherwise fails the whole rest of the run at setup.

        The /dev node can change, so prefer the pinned SERIAL_DEVICE when it
        reappears and otherwise re-detect the probe. With *required* set, never
        getting the port back raises; otherwise it returns False and the caller
        escalates. Returns True when the port is open again.
        """
        if Session.backend is not None:
            return False  # QEMU: the PTY is the backend's to recreate
        try:
            if Session.serial is not None and Session.serial.is_open:
                Session.serial.close()
        except SERIAL_ERRORS:
            pass
        Session.serial = None

        previous = Session.serial_port
        port = self._wait_for_serial_port(time.monotonic() + BOOT_TIMEOUT, previous)
        # A fresh window for the open: the node appearing and the node working
        # are separate waits, and spending the first on the second's budget is
        # how a reopen fails a second before it would have succeeded.
        handle = None if port is None else _open_serial_port(
            port, time.monotonic() + BOOT_TIMEOUT)
        if handle is None:
            # Forget the port as well: it may come back under a different name,
            # and the next session then re-detects the probe. self.serial keeps
            # pointing at the closed handle rather than None, so the callers
            # that carry on get a SerialException they already handle instead of
            # an AttributeError.
            Session.serial_port = None
            if required:
                raise RuntimeError("serial port did not re-enumerate")
            self.file.write("Serial port did not come back; escalating reset.\n")
            self.file.flush()
            return False

        Session.serial_port = port
        Session.serial = handle
        self.serial = handle
        self.file.write(f"Reopened serial on {port}.\n")
        self.file.flush()
        return True

    def _wait_for_serial_port(self, deadline, previous=None):
        """Wait for the probe's /dev node to (re)appear; None if it never does.

        Prefers the pinned SERIAL_DEVICE, then a live probe detection, then the
        port this run was already on. That last fallback is for the CI
        container: the node is handed in with ``--device`` at start, so it stays
        present (and usable again, same major:minor) across a re-enumeration
        that the udev-based detection cannot see from inside. Returning a node
        that exists but is not working yet is fine -- the open retries.
        """
        configured = (os.environ.get("SERIAL_DEVICE") or "").strip()
        while True:
            if configured and os.path.exists(configured):
                return configured
            try:
                detected = detect_probe_serial_port()
            except Exception:
                detected = None
            if detected:
                return detected
            if previous and os.path.exists(previous):
                return previous
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.5)

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

    # How long to keep reading after a crash marker before resetting, and how
    # long a gap counts as "the dump has finished".
    CRASH_DUMP_QUIET_S = float(os.environ.get("YASOS_SMOKE_CRASH_QUIET", "2.0"))
    CRASH_DUMP_CAP_S = float(os.environ.get("YASOS_SMOKE_CRASH_CAP", "20.0"))

    def _drain_crash_dump(self):
        """Read the rest of the HardFault postmortem before resetting.

        ``collect_crash_logs`` used to reset immediately, on the stated grounds
        that "the live HardFault postmortem is already in this file from the
        serial stream". It was not. ``_record_serial_output`` raises
        ``target_crashed`` the moment it sees ``hardfault diagnostics:``, and
        the reader that noticed it unwinds straight out of the read loop -- so
        what reached the log was whatever happened to be in the same 256-byte
        chunk as the marker. Every dump in runs 47-49 is cut off two or three
        lines in, mid-token:

            [ERR][hardfault]   stacked r0=0x100407C8 r1=0xFFFFFFED ...
            er[ER
            ===== crash detected: rebooting ... =====

        The parts that would actually identify the bug -- the fault status
        registers, the module map that turns a stacked PC into a file, and the
        per-core context-switch event ring -- are all printed *after* that and
        were being thrown away, on every crash, for every run. The SD fallback
        did not cover it either: ``cat /root/logs/kernel.prev.log`` came back
        "cat: /root/logs/kernel.prev.log" (no such file) in all of them.

        So: keep reading until the target has been quiet for
        ``CRASH_DUMP_QUIET_S``, capped at ``CRASH_DUMP_CAP_S`` in case the fault
        path is stuck in a loop emitting forever. Crash-marker scanning is
        suppressed meanwhile -- the target is already flagged as crashed, and
        the dump is full of markers that would just re-flag it.
        """
        was_collecting = Session._collecting
        Session._collecting = True
        old_timeout = self.serial.timeout
        deadline = time.monotonic() + Session.CRASH_DUMP_CAP_S
        try:
            self.serial.timeout = 0.25
            last_data = time.monotonic()
            while time.monotonic() < deadline:
                pending = self.serial.in_waiting
                chunk = self.serial.read(pending if pending > 0 else 1)
                if chunk:
                    self._record_serial_output(chunk.decode("utf-8", "ignore"))
                    last_data = time.monotonic()
                elif time.monotonic() - last_data >= Session.CRASH_DUMP_QUIET_S:
                    break
        except SERIAL_ERRORS as exc:
            self.file.write(f"\n(crash-dump drain stopped: {exc})\n")
        finally:
            _restore_timeout(self.serial, old_timeout)
            Session._collecting = was_collecting
            self.file.flush()

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
        self._drain_crash_dump()
        self.file.write("\n===== crash detected: rebooting to collect persisted SD logs =====\n")
        self.file.flush()
        try:
            self._reset_and_wait_for_prompt()
        except SERIAL_ERRORS + (RuntimeError,) as exc:
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
                except SERIAL_ERRORS + (RuntimeError, AssertionError) as exc:
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
                _restore_timeout(self.serial, old_timeout)

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
        try:
            return self.serial.read(size)
        finally:
            _restore_timeout(self.serial, old_timeout)

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

        Capped at ``ECHO_IDLE_TIMEOUT`` rather than following the session's read
        timeout, because those measure different things: callers raise the read
        timeout for a slow *program* (a compile, a boot), but the echo of the
        command that starts it is immediate either way. See ECHO_IDLE_TIMEOUT.
        """
        idle_timeout = min(self.serial.timeout or ECHO_IDLE_TIMEOUT,
                           ECHO_IDLE_TIMEOUT)
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
            _restore_timeout(self.serial, old_timeout)
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
            except SERIAL_ERRORS:
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
        logs_dir = smoke_log_dir()
        os.makedirs(logs_dir, exist_ok=True)
        date = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
        session = cls.__new__(cls)
        session.serial = cls.serial
        session.file = open(logs_dir / f"{name}_{date}.txt", 'w')
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
            if cls.serial is not None:
                # A recovery inside shutdown_target may already have dropped it.
                with contextlib.suppress(*SERIAL_ERRORS):
                    cls.serial.close()
            cls.serial = None
            cls.target_needs_reset = True
            cls.target_crashed = False


    def close(self):
        self.file.close()

