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

"""QEMU backend for the smoke-test Session.

Boots the yasos.zig kernel ELF on a QEMU machine (default: mps2-an505 /
Cortex-M33) with UART0 wired to a pseudo-terminal, so the existing serial-based
smoke Session can drive it exactly like a real debug probe.  A PTY is used
(rather than a TCP socket) because it is a real tty: ``in_waiting`` is accurate,
which the Session relies on for ``read(in_waiting)`` draining.

Activated by the smoke Session when ``YASOS_QEMU_KERNEL`` is set.  Configuration
is entirely via environment variables so no test code needs to change:

    YASOS_QEMU_KERNEL        path to the kernel ELF (required; activates QEMU mode)
    YASOS_QEMU_BIN           qemu binary            (default: qemu-system-arm)
    YASOS_QEMU_MACHINE       -machine value         (default: mps2-an505)
    YASOS_QEMU_CPU           -cpu value             (default: cortex-m33)
    YASOS_QEMU_EXTRA_ARGS    extra args, shell-split and appended to the cmdline
    YASOS_QEMU_BOOT_TIMEOUT  seconds to wait for the PTY to appear (default: 20)
    YASOS_QEMU_LOG_DIR       where to write qemu stdout/stderr (default: ./logs)
"""

import datetime
import os
import re
import shlex
import subprocess
import time
from pathlib import Path

import serial

# Matches QEMU's "char device redirected to /dev/pts/N (label serial0)" line.
_PTY_RE = re.compile(r"char device redirected to (\S+)")
_SERIAL_TIMEOUT = float(os.environ.get("YASOS_SMOKE_SERIAL_TIMEOUT", "1"))


def qemu_kernel() -> str | None:
    """Return the configured kernel path, or None when QEMU mode is off."""
    value = os.environ.get("YASOS_QEMU_KERNEL", "").strip()
    return value or None


class QemuTarget:
    """Owns a qemu subprocess and the pyserial connection to its UART PTY."""

    def __init__(self):
        kernel = qemu_kernel()
        if not kernel:
            raise RuntimeError("YASOS_QEMU_KERNEL is not set")
        self.kernel = kernel
        self.qemu_bin = os.environ.get("YASOS_QEMU_BIN", "qemu-system-arm").strip()
        self.machine = os.environ.get("YASOS_QEMU_MACHINE", "mps2-an505").strip()
        self.cpu = os.environ.get("YASOS_QEMU_CPU", "cortex-m33").strip()
        self.boot_timeout = float(os.environ.get("YASOS_QEMU_BOOT_TIMEOUT", "20"))
        self.extra_args = shlex.split(os.environ.get("YASOS_QEMU_EXTRA_ARGS", ""))
        self.log_dir = Path(os.environ.get("YASOS_QEMU_LOG_DIR", "logs"))
        self.label = f"qemu:{self.machine}"

        self.proc: subprocess.Popen | None = None
        self.serial: serial.Serial | None = None
        self.pty: str | None = None
        self._logf = None

    def _build_command(self) -> list[str]:
        return [
            self.qemu_bin,
            "-machine", self.machine,
            "-cpu", self.cpu,
            "-display", "none",
            "-monitor", "none",
            "-semihosting-config", "enable=on,target=native",
            "-serial", "pty",
            "-kernel", self.kernel,
        ] + self.extra_args

    def _launch_qemu(self) -> None:
        if not Path(self.kernel).is_file():
            raise RuntimeError(f"QEMU kernel ELF not found: {self.kernel}")
        self.log_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S_%f")
        # The PID keeps the name unique across parallel pytest-xdist workers:
        # _wait_for_pty parses the PTY path out of this file, and a timestamp
        # collision between two workers would cross-wire their serial streams.
        log_path = self.log_dir / f"qemu_{stamp}_pid{os.getpid()}.log"
        self._logf = open(log_path, "w+")

        command = self._build_command()
        self._logf.write("$ " + " ".join(shlex.quote(part) for part in command) + "\n")
        self._logf.flush()
        # stdin from /dev/null: the guest UART is on the PTY, not stdin, and a
        # closed stdin keeps qemu from ever trying to read the controlling tty.
        self.proc = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=self._logf,
            stderr=subprocess.STDOUT,
        )

        self.pty = self._wait_for_pty(log_path)

    def _wait_for_pty(self, log_path: Path) -> str:
        deadline = time.time() + self.boot_timeout
        while time.time() < deadline:
            text = log_path.read_text(errors="ignore")
            match = _PTY_RE.search(text)
            if match:
                return match.group(1)
            if self.proc.poll() is not None:
                raise RuntimeError(
                    f"qemu exited early (rc={self.proc.returncode}) before opening a "
                    f"PTY. Log:\n{text}"
                )
            time.sleep(0.05)
        raise RuntimeError(
            f"qemu did not report a serial PTY within {self.boot_timeout}s. "
            f"Log:\n{log_path.read_text(errors='ignore')}"
        )

    def _open_serial(self) -> serial.Serial:
        # The PTY exists as soon as qemu prints it (at init, before the guest
        # runs), so opening it now reliably catches the first boot prompt.
        self.serial = serial.Serial(self.pty, timeout=_SERIAL_TIMEOUT)
        return self.serial

    def start(self) -> serial.Serial:
        """Launch qemu and return a live serial connection to its UART."""
        self._launch_qemu()
        return self._open_serial()

    def reset(self) -> serial.Serial:
        """Reboot the target by relaunching qemu; returns a fresh serial."""
        self.stop()
        self._launch_qemu()
        return self._open_serial()

    def stop(self) -> None:
        """Tear down the serial connection and the qemu process."""
        if self.serial is not None:
            try:
                self.serial.close()
            except Exception:
                pass
            self.serial = None
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            self.proc = None
        if self._logf is not None:
            try:
                self._logf.close()
            except Exception:
                pass
            self._logf = None
        self.pty = None
