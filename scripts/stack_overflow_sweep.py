#!/usr/bin/env python3
"""Overflow a process stack at every depth of the filesystem paths on an SD card.

The smoke suite has no card, so its sweep (tests/smoke/user_fault_test.py) never
reaches ext4 or FAT. This one boots QEMU with a partitioned image and walks the
same probe over them. It fails when the kernel dies, when a probe comes back with
anything but "finished" or "killed", when a process is killed holding a filesystem
lock (what that lock protects may then be half updated), or when the filesystems
do not work afterwards.

usage: stack_overflow_sweep.py [--kernel ELF] [--stack BYTES] [--step BYTES]
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

TARGETS = [
    ("/root/t", 0),
    ("/root/t", 1),
    ("/root/new", 2),
    ("/root", 3),
    ("/boot/t", 1),
    ("/boot/new", 2),
    ("/home/root/t", 1),
]


def probe_source():
    """The C lines of the smoke test's probe, which that file keeps free of imports."""
    text = (REPO / "tests/smoke/user_fault_test.py").read_text()
    body = text.split("_STACK_PROBE = [", 1)[1].split("\n]\n", 1)[0]
    return [eval(line.strip().rstrip(",")) for line in body.splitlines() if line.strip()]


def commands(stack, step):
    out = ["rm -f /tmp/p /tmp/p.c"]
    for index, line in enumerate(probe_source()):
        out.append(f"echo '{line}' {'>' if index == 0 else '>>'} /tmp/p.c")
    out.append(f"tcc /tmp/p.c -o /tmp/p -stack-size={stack}")
    out.append("echo hello > /root/t; echo hello > /boot/t")
    for path, mode in TARGETS:
        out.append(
            f"n={stack - 8}; while [ $n -gt 0 ]; do /tmp/p $n {path} {mode} >/dev/null 2>&1; "
            f'echo "SWEEP {path}:{mode} $n $?"; n=$((n-{step})); done'
        )
    out.append("/tmp/p 8 /root/t 1; echo AFTER $?")
    out.append("/tmp/p 8 /root/after 2; echo AFTER $?")
    out.append("/tmp/p 8 /boot/t 1; echo AFTER $?")
    out.append("cat /proc/faultstat")
    out.append("cat /root/t; echo SWEEP_DONE")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--kernel", default=str(REPO / "zig-out/bin/yasos_kernel"))
    parser.add_argument("--stack", type=int, default=8192)
    parser.add_argument("--step", type=int, default=16)
    args = parser.parse_args()

    run = [sys.executable, str(REPO / "scripts/qemu_mount.py"), "--kernel", args.kernel]
    run += ["--sdcard", "--silence", "60", "--keep"]
    for command in commands(args.stack, args.step):
        run += ["-c", command]
    cache = REPO / ".cache"
    before = set(cache.glob("qemu_mount_*"))
    booted = subprocess.run(run, capture_output=True, text=True, errors="replace", cwd=REPO)
    if not re.search(r"SWEEP_DONE", booted.stdout):
        # qemu_mount failing to start (no pyserial, say) says why only here.
        print(booted.stderr[-1000:], file=sys.stderr)
    # The kernel's own lines go to the serial log only, not to stdout.
    work = sorted(set(cache.glob("qemu_mount_*")) - before)
    if len(work) != 1:
        print(f"FAILED: expected one new qemu_mount work directory, found {len(work)}")
        return 1
    output = "".join(p.read_text(errors="replace") for p in work[0].glob("qemu_mount_*.txt"))
    shutil.rmtree(work[0])

    runs = {}
    for target, _, status in re.findall(r"^SWEEP (\S+) (\d+) (\d+)", output, re.MULTILINE):
        runs.setdefault(target, []).append(status)
    failed = []
    expected = (args.stack - 8 + args.step - 1) // args.step
    for path, mode in TARGETS:
        statuses = runs.get(f"{path}:{mode}", [])
        fine = statuses.count("0")
        killed = statuses.count("255")
        print(f"{path}:{mode:<2} finished {fine:4}  killed {killed:4}  stack needed ~{killed * args.step} B")
        if len(statuses) != expected or fine + killed != len(statuses) or not fine or not killed:
            failed.append(f"{path}:{mode}: {len(statuses)} of {expected} runs, {fine} finished, {killed} killed")
    after = re.findall(r"^AFTER (\d+)", output, re.MULTILINE)
    if after != ["0", "0", "0"]:
        failed.append(f"filesystems after the sweep: {after}")
    if "SWEEP_DONE" not in output:
        failed.append("the kernel did not reach the end")
    held = re.search(r"^fault_kills_holding_locks (\d+)", output, re.MULTILINE)
    if held is None:
        failed.append("no /proc/faultstat")
    elif held.group(1) != "0":
        failed.append(f"{held.group(1)} processes killed holding a lock")
    for name in ("KERNEL PANIC", "lock order violation"):
        count = output.count(name)
        if count:
            failed.append(f"{count} x {name}")
    for line in failed:
        print("FAILED:", line)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
