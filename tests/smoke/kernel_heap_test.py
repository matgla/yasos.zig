"""
 Copyright (c) 2026 Mateusz Stadnik

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

"""What the mounted storage costs the kernel heap, and what it leaves.

On the rp2350 the kernel heap is what kernel_ram keeps after .data/.bss, and
every mounted filesystem keeps part of it for good: 2026-10-01 the card's full
layout (FAT /boot, ext4 /var /opt /home, since folded to /var /home) left 1.5 KB of a 71.5 KB heap, and
the first pipe -- a 4 KB ring -- panicked the kernel.

The test walks the storage through a working set -- metadata on /root, a copy
onto /home, a listing of every volume, a pipe -- and prints /proc/meminfo after
each step (`HEAPBENCH <step>` marks them in the transcript), then measures what
unmounting and remounting /boot gives back (/home cannot go: /root is
bound into it). Only the last step
asserts, so a failing run still records every number. On QEMU the heap is
megabytes and the check passes trivially; it is the board it is for.
"""

import re
import termios
import time

import serial

from .conftest import session_key
from .framework.session import Session

# Left free with everything mounted and warm. On the PSRAM boards the heap is about
# 16 KB and holds little beyond the processes: a pipe's ring, open files and fd tables
# are on the slow heap. A dozen more processes' worth, with margin.
REQUIRED_HEADROOM = 8 * 1024
# The break never comes back, so this is what the whole run left of the heap at worst,
# fragmentation included. Past it the next allocation panics.
REQUIRED_UNCLAIMED = 4 * 1024
MOUNT_STACK_KB = 7


def _run(session, command):
    session.write_command(command)
    return session.read_until_prompt()


def _size(text):
    value, unit = text.split()
    return int(value) * {"B": 1, "KB": 1024, "MB": 1024 * 1024}[unit]


def _meminfo(session):
    fields = {}
    for line in _run(session, "cat /proc/meminfo").splitlines():
        match = re.match(r"(Mem\w+):\s+(\d+ (?:B|KB|MB))\s*$", line.strip())
        if match:
            fields[match.group(1)] = _size(match.group(2))
    return fields


def _sample(session, step, samples):
    _run(session, f"echo HEAPBENCH {step}")
    info = _meminfo(session)
    samples.append((step, info))
    print(f"HEAPBENCH {step:<22} used={info.get('MemKernelUsed')} brk={info.get('MemKernelBrk')} "
          f"limit={info.get('MemKernelLimit')} peak={info.get('MemKernelPeak')}")
    return info


def _timed(session, command):
    # Storage work is silent until the prompt: 40 file creations, or a copy and
    # hash on the card, outlast the session's 1 s silence window on a slower
    # (ReleaseSafe) kernel, and the harness then gives up on a healthy board.
    start = time.monotonic()
    with session.timeout(60):
        out = _run(session, command)
    elapsed = time.monotonic() - start
    print(f"HEAPBENCH time {elapsed * 1000:8.0f} ms  {command[:60]}")
    return out


def _mounted(session, target):
    return any(line.split()[1:2] == [target] for line in _run(session, "cat /proc/mounts").splitlines())


def test_storage_leaves_kernel_heap_headroom(request):
    session = request.node.stash[session_key]
    samples = []

    _sample(session, "idle", samples)
    _sample(session, "idle-again", samples)

    # /proc renders into a buffer that only lives while the file is open.
    _run(session, "cat /proc/mounts /proc/partitions /proc/filesystems /proc/cpus > /dev/null")
    _sample(session, "after-proc-reads", samples)

    names = " ".join(f"f{i}" for i in range(40))
    _timed(session, f"mkdir -p /root/heapbench && cd /root/heapbench && for f in {names}; do echo $f > $f; done; cd /")
    _timed(session, "ls -l /root/heapbench > /dev/null")
    _sample(session, "after-root-files", samples)

    if _mounted(session, "/home"):
        _timed(session, "cp /usr/bin/toybox /home/heapbench.bin && sha256sum /home/heapbench.bin")
    _timed(session, "ls -la /var /home /boot /root > /dev/null")
    _sample(session, "after-all-volumes", samples)

    _timed(session, "rm -rf /root/heapbench /home/heapbench.bin")
    _sample(session, "after-cleanup", samples)

    for target in ("/boot",):
        if not _mounted(session, target):
            continue
        before = _meminfo(session).get("MemKernelUsed", 0)
        _run(session, f"umount {target}")
        _sample(session, f"umounted-{target[1:]}", samples)
        after = samples[-1][1].get("MemKernelUsed", 0)
        print(f"HEAPBENCH cost of {target}: {before - after} B")
        # Below toybox's 8 KB: mount(2) runs on the caller's stack, and an overflow in it
        # dies holding a lock. It once took 9 KB, and QEMU has no card to find that.
        _run(session, f"(ulimit -s {MOUNT_STACK_KB}; mount {target})")
        _sample(session, f"remounted-{target[1:]}", samples)
        assert _mounted(session, target), target

    _timed(session, "cat /usr/bin/toybox | cat > /dev/null")
    _sample(session, "after-pipe", samples)

    final = _sample(session, "final", samples)
    if "MemKernelLimit" not in final:
        return  # host-side kernel without a break to measure
    headroom = final["MemKernelLimit"] - final["MemKernelUsed"]
    assert headroom >= REQUIRED_HEADROOM, (headroom, samples)
    unclaimed = final["MemKernelLimit"] - final["MemKernelBrk"]
    assert unclaimed >= REQUIRED_UNCLAIMED, (unclaimed, samples)


def test_many_processes_do_not_run_the_kernel_heap_dry(request):
    """A process costs kernel heap, and the heap running out is a panic. Past what fits,
    the shell has to be told to try again, keep going, and work again once they are gone."""
    session = request.node.stash[session_key]
    with session.timeout(60):
        _run(session, "for i in " + " ".join(str(i) for i in range(64)) + "; do (sleep 2 &) ; done 2>/dev/null")
        # A pipeline needs processes of its own, which an echo builtin alone would not.
        deadline = time.monotonic() + 20
        while True:
            out = _run(session, "echo still alive | cat")
            if "still alive" in out and "vfork" not in out:
                break
            assert time.monotonic() < deadline, out
            time.sleep(0.5)
    final = _meminfo(session)
    if "MemKernelLimit" in final:
        assert final["MemKernelBrk"] < final["MemKernelLimit"]


def test_shutdown_gives_everything_back_without_a_fault(request):
    """Leaving the root shell tears the kernel down: every process, driver and
    filesystem, in an order nothing else exercises. The harness kills QEMU rather than
    shut it down, so two bad frees here passed every QEMU run and only faulted on a board."""
    session = request.node.stash[session_key]
    seen = b""
    stopped = False
    session.serial.write(b"exit\n")
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            seen += session.serial.read(4096)
            if b"turn off your PC" in seen or b"KERNEL PANIC" in seen:
                break
    except (OSError, termios.error, serial.SerialException):
        stopped = True  # QEMU exits with its guest, and the pty goes with it.
    finally:
        Session.target_needs_reset = True
    text = seen.decode(errors="replace")
    assert "hardfault" not in text and "PANIC" not in text, text[-2000:]
    assert stopped or "turn off your PC" in text, text[-2000:]
