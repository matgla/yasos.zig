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
layout (FAT /boot, ext4 /var /opt /home) left 1.5 KB of a 71.5 KB heap, and
the first pipe -- a 4 KB ring -- panicked the kernel.

The test walks the storage through a working set -- metadata on /root, a copy
onto /opt, a listing of every volume, a pipe -- and prints /proc/meminfo after
each step (`HEAPBENCH <step>` marks them in the transcript), then measures what
unmounting and remounting /opt and /boot gives back. Only the last step
asserts, so a failing run still records every number. On QEMU the heap is
megabytes and the check passes trivially; it is the board it is for.
"""

import re
import time

from .conftest import session_key

# Left free with everything mounted and warm: a pipe ring (4 KB), a process
# being spawned and an open file or two, with margin.
REQUIRED_HEADROOM = 16 * 1024


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

    opt = _mounted(session, "/opt")
    if opt:
        _timed(session, "cp /usr/bin/toybox /opt/heapbench.bin && sha256sum /opt/heapbench.bin")
    _timed(session, "ls -la /var /opt /home /boot /root > /dev/null")
    _sample(session, "after-all-volumes", samples)

    _timed(session, "rm -rf /root/heapbench /opt/heapbench.bin")
    _sample(session, "after-cleanup", samples)

    for target in ("/opt", "/boot"):
        if not _mounted(session, target):
            continue
        before = _meminfo(session).get("MemKernelUsed", 0)
        _run(session, f"umount {target}")
        _sample(session, f"umounted-{target[1:]}", samples)
        after = samples[-1][1].get("MemKernelUsed", 0)
        print(f"HEAPBENCH cost of {target}: {before - after} B")
        _run(session, f"mount {target}")
        _sample(session, f"remounted-{target[1:]}", samples)
        assert _mounted(session, target), target

    # A pipe needs its 4 KB ring; a heap without room for it panics the
    # kernel, which would take the rest of the numbers with it.
    info = samples[-1][1]
    if "MemKernelLimit" in info and info["MemKernelLimit"] - info["MemKernelUsed"] < 8 * 1024:
        print("HEAPBENCH skipping the pipe: under 8 KB free")
    else:
        _timed(session, "cat /usr/bin/toybox | cat > /dev/null")
        _sample(session, "after-pipe", samples)

    final = _sample(session, "final", samples)
    if "MemKernelLimit" not in final:
        return  # host-side kernel without a break to measure
    headroom = final["MemKernelLimit"] - final["MemKernelUsed"]
    assert headroom >= REQUIRED_HEADROOM, (headroom, samples)
