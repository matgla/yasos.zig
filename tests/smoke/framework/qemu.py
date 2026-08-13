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
    YASOS_QEMU_LOG_DIR       where to write qemu stdout/stderr (default: the
                             run's log directory, i.e. YASOS_SMOKE_LOG_DIR or
                             ./logs)

File-backed guest RAM (how the source corpus gets onto the device without being
transferred, see scripts/build_smoke_fatdisk.py):

    YASOS_QEMU_RAM_BACKING_DIR  enables it; one mem_<worker>.bin is created here
    YASOS_QEMU_RAM_SIZE         backend size, must equal the machine's RAM
                                (default: 2G, which is what mps3-an524 demands)
    YASOS_QEMU_FATDISK_IMAGE    FAT image laid into the backing file before launch
    YASOS_QEMU_FATDISK_OFFSET   where in the file the fatdisk window starts
                                (default: 0x10000000, the an524 value)
    YASOS_QEMU_PRESERVE_STATE   1 to seed once and keep whatever the guest writes
                                across relaunches; 0 (default) restores the
                                pristine image on every launch
"""

import datetime
import os
import re
import shlex
import subprocess
import time
from pathlib import Path

import serial

from .paths import smoke_log_dir

# Matches QEMU's "char device redirected to /dev/pts/N (label serial0)" line.
_PTY_RE = re.compile(r"char device redirected to (\S+)")
_SERIAL_TIMEOUT = float(os.environ.get("YASOS_SMOKE_SERIAL_TIMEOUT", "1"))


def _parse_size(text: str) -> int:
    """Parse a qemu-style size ("2G", "16M", "1024") into bytes."""
    text = text.strip()
    units = {"K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}
    if text and text[-1].upper() in units:
        return int(float(text[:-1]) * units[text[-1].upper()])
    return int(text, 0)


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
        qemu_log_dir = os.environ.get("YASOS_QEMU_LOG_DIR", "").strip()
        self.log_dir = Path(qemu_log_dir) if qemu_log_dir else smoke_log_dir()
        self.label = f"qemu:{self.machine}"

        # File-backed guest RAM. When enabled, the board's fatdisk window is a
        # fixed slice of this file, so the host can put the source corpus on the
        # device by writing it there -- no transfer, and it outlives the qemu
        # process, which a RAM-backed disk reformatted on every boot does not.
        backing_dir = os.environ.get("YASOS_QEMU_RAM_BACKING_DIR", "").strip()
        self.ram_backing: Path | None = None
        if backing_dir:
            # One file per xdist worker: two guests sharing a RAM image would
            # scribble over each other.
            worker = os.environ.get("PYTEST_XDIST_WORKER", "main")
            self.ram_backing = Path(backing_dir) / f"mem_{worker}.bin"
        self.ram_size = os.environ.get("YASOS_QEMU_RAM_SIZE", "2G").strip()
        self.fatdisk_image = os.environ.get("YASOS_QEMU_FATDISK_IMAGE", "").strip()
        self.fatdisk_offset = int(
            os.environ.get("YASOS_QEMU_FATDISK_OFFSET", "0x10000000"), 0
        )
        # Off by default: every launch restores the pristine corpus, so a test
        # cannot be influenced by what an earlier one wrote. Turning it on keeps
        # whatever the guest put there, which is what makes a run that relaunches
        # between tests cheap.
        self.preserve_state = os.environ.get(
            "YASOS_QEMU_PRESERVE_STATE", "0"
        ).strip() in ("1", "true", "yes", "on")
        self._seeded = False

        self.proc: subprocess.Popen | None = None
        self.serial: serial.Serial | None = None
        self.pty: str | None = None
        self._logf = None
        # Peak resident memory of the qemu processes this target has run, in KiB.
        # See tests/smoke/heavy_tests.txt.
        self.peak_rss_kb = 0

    def _seed_ram_backing(self) -> None:
        """Create the backing file and lay the pristine FAT image into it.

        Called before every launch unless state preservation is on, in which case
        only the first launch seeds and later ones inherit whatever the guest
        left behind.
        """
        if self.ram_backing is None:
            return
        if self.preserve_state and self._seeded:
            return
        self.ram_backing.parent.mkdir(parents=True, exist_ok=True)
        # qemu validates the backend against the machine's fixed RAM size, but
        # the file is sparse: only pages the guest touches are ever allocated.
        size = _parse_size(self.ram_size)
        with open(self.ram_backing, "a+b") as f:
            f.truncate(size)
        if self.fatdisk_image:
            data = Path(self.fatdisk_image).read_bytes()
            with open(self.ram_backing, "r+b") as f:
                f.seek(self.fatdisk_offset)
                f.write(data)
        self._seeded = True

    def _build_command(self) -> list[str]:
        machine = self.machine
        objects: list[str] = []
        if self.ram_backing is not None:
            machine = f"{machine},memory-backend=mem0"
            objects = [
                "-object",
                f"memory-backend-file,id=mem0,size={self.ram_size},"
                f"mem-path={self.ram_backing},share=on",
            ]
        return [
            self.qemu_bin,
            "-machine", machine,
            "-cpu", self.cpu,
            "-display", "none",
            "-monitor", "none",
            "-semihosting-config", "enable=on,target=native",
            "-serial", "pty",
            "-kernel", self.kernel,
        ] + objects + self.extra_args

    def _launch_qemu(self) -> None:
        if not Path(self.kernel).is_file():
            raise RuntimeError(f"QEMU kernel ELF not found: {self.kernel}")
        self._seed_ram_backing()
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

    def is_alive(self) -> bool:
        """True while the qemu process is running (its PTY is usable)."""
        return self.proc is not None and self.proc.poll() is None

    def reset(self) -> serial.Serial:
        """Reboot the target by relaunching qemu; returns a fresh serial."""
        self.stop()
        self._launch_qemu()
        return self._open_serial()

    def _record_peak_rss(self) -> None:
        """Take the qemu process's high-water memory mark before it exits.

        VmHWM rather than a sampler: the kernel already tracks the peak, so one
        read at teardown catches a spike that polling would step over. Kept as a
        running max because a test that relaunches the target (Session.reset)
        runs more than one qemu, and the interesting number is the worst of them.

        Guest RAM is a shared file-backed mapping, so the pages the guest has
        touched are exactly what shows up here -- which is the quantity that
        decides whether N of these fit in host memory at once.
        """
        if self.proc is None:
            return
        try:
            with open(f"/proc/{self.proc.pid}/status", encoding="ascii") as status:
                for line in status:
                    if line.startswith("VmHWM:"):
                        self.peak_rss_kb = max(self.peak_rss_kb, int(line.split()[1]))
                        return
        except (OSError, ValueError, IndexError):
            # Diagnostics only; a process that has already gone, or a platform
            # without VmHWM, must never turn into a test failure.
            pass

    def peak_rss(self) -> int:
        """Peak resident KiB across the qemu processes run since the last reset.

        Folds in the live process first, because the usual caller is a test
        teardown that runs while qemu is still up.
        """
        self._record_peak_rss()
        return self.peak_rss_kb

    def reset_peak_rss(self) -> None:
        """Start a new measurement window.

        The target outlives individual tests -- a healthy qemu is reused by the
        next test rather than relaunched -- and VmHWM only ever grows for a live
        process. Clearing the local max is therefore not enough: without also
        resetting the kernel's high-water mark, every test after the first big
        one in a worker inherits its peak and the report says they are all
        equally heavy (which is exactly what the first run of this showed).
        `clear_refs` type 5 resets VmHWM down to the current VmRSS.
        """
        self.peak_rss_kb = 0
        if self.proc is None:
            return
        try:
            with open(f"/proc/{self.proc.pid}/clear_refs", "w", encoding="ascii") as clear:
                clear.write("5")
        except OSError:
            # Older kernels have no peak-reset. The numbers then read as
            # "worst test so far in this worker", which is still ordered
            # correctly for picking out the big ones, just less precise.
            pass

    def stop(self) -> None:
        """Tear down the serial connection and the qemu process."""
        # Before terminate(), or /proc/<pid>/status is gone and the peak with it.
        self._record_peak_rss()
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
