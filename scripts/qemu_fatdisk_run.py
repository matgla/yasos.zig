#!/usr/bin/env python3
"""Exchange files with the QEMU yasos guest over a host-readable FAT drive.

This replaces the slow/flaky YAFF RAM-scan (scripts/qemu_capture_yaff.py) for the
tinycc self-host debugging loop. The kernel mounts a FatFs at /mnt backed by the
`fatdisk0` window (hal/.../linker_script.ld: 1 MB at guest 0x80EC0000). Under a
host-mmap'd RAM launch (`memory-backend-file,share=on`) that window is a fixed
slice of the backing file (offset 0x00EC0000), so we:

  1. build a FAT image on the host (fatimg) with the requested input files,
  2. splice it into the backing file at the fatdisk offset,
  3. boot QEMU, drive the shell to run a command (e.g. compile /mnt/IN.C),
  4. splice the (now guest-modified) window back out and pull files with fatimg.

No kernel rebuild and no RAM scanning — drop sources in, read binaries out.

Usage:
  scripts/qemu_fatdisk_run.py \
      --put tests/tests2/09_do_while.c:IN.C \
      --cmd 'tcc /mnt/IN.C -o /mnt/OUT && /mnt/OUT; echo RC=$?' \
      --get OUT:/tmp/09.elf
"""
import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import serial

REPO = Path(__file__).resolve().parent.parent
KERNEL = REPO / "zig-out/bin/yasos_kernel"
FATIMG = REPO / "scripts/fatimg/fatimg"
PTY_RE = re.compile(r"char device redirected to (\S+)")

# MUST match hal/.../linker_script.ld + qemu_mps2_an505.zig fatdisk_address/size.
RAM_BASE = 0x80000000
FATDISK_ADDR = 0x80EC0000
FATDISK_SIZE = 1024 * 1024
FATDISK_OFFSET = FATDISK_ADDR - RAM_BASE


def fatimg(*args):
    subprocess.run([str(FATIMG), *map(str, args)], check=True)


def build_image(img, puts, size_kb):
    fatimg("mkfs", img, size_kb)
    for host, fat in puts:
        fatimg("cp", img, host, fat)


def splice_in(backing, img):
    """Write the FAT image into the backing file at the fatdisk offset."""
    data = Path(img).read_bytes()
    assert len(data) <= FATDISK_SIZE, "image larger than fatdisk window"
    with open(backing, "r+b") as f:
        f.seek(FATDISK_OFFSET)
        f.write(data)


def splice_out(backing, img):
    """Extract the fatdisk window from the backing file into a standalone image."""
    with open(backing, "rb") as f:
        f.seek(FATDISK_OFFSET)
        data = f.read(FATDISK_SIZE)
    Path(img).write_bytes(data)


def launch(backing, ram_mb):
    logf = open("/tmp/qemu_fatdisk_run.log", "w+")
    cmd = [
        "qemu-system-arm", "-machine", "mps2-an505,memory-backend=mem0",
        "-object", f"memory-backend-file,id=mem0,size={ram_mb}M,mem-path={backing},share=on",
        "-cpu", "cortex-m33", "-display", "none", "-monitor", "none",
        "-semihosting-config", "enable=on,target=native",
        "-serial", "pty", "-kernel", str(KERNEL),
    ]
    logf.write("$ " + " ".join(cmd) + "\n")
    logf.flush()
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT)
    pty, deadline = None, time.time() + 20
    while time.time() < deadline:
        m = PTY_RE.search(Path("/tmp/qemu_fatdisk_run.log").read_text(errors="ignore"))
        if m:
            pty = m.group(1)
            break
        if proc.poll() is not None:
            print(Path("/tmp/qemu_fatdisk_run.log").read_text())
            sys.exit(1)
        time.sleep(0.05)
    if not pty:
        print("no pty")
        sys.exit(1)
    return proc, pty


def drain(ser, idle, hard_cap=None, stop=None):
    """Read until `idle` seconds pass with no new data, or `hard_cap` seconds
    elapse total, or the `stop` marker appears. Streams to stdout live so a guest
    that hangs (or spews forever) is visible and bounded — unlike a deadline that
    resets on every byte."""
    out = b""
    start = time.time()
    idle_deadline = start + idle
    while True:
        now = time.time()
        if hard_cap is not None and now - start > hard_cap:
            break
        if now > idle_deadline:
            break
        n = ser.in_waiting
        if n:
            chunk = ser.read(n)
            out += chunk
            sys.stdout.write(chunk.decode(errors="replace"))
            sys.stdout.flush()
            idle_deadline = time.time() + idle
            if stop is not None and stop in out:
                break
        else:
            time.sleep(0.05)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--put", action="append", default=[], metavar="HOST:FAT",
                    help="copy host file into the FAT image as FAT (8.3 name)")
    ap.add_argument("--get", action="append", default=[], metavar="FAT:HOST",
                    help="after the run, extract FAT file to host path")
    ap.add_argument("--cmd", required=True, help="shell command to run on the guest")
    ap.add_argument("--backing", default="/tmp/mpsram_fat.bin")
    ap.add_argument("--img", default="/tmp/fatdisk.img")
    ap.add_argument("--ram-mb", type=int, default=16)
    ap.add_argument("--boot-wait", type=float, default=7)
    ap.add_argument("--timeout", type=float, default=20)
    args = ap.parse_args()

    if not FATIMG.is_file():
        print("fatimg not built — run scripts/fatimg/build.sh")
        sys.exit(1)

    puts = []
    for spec in args.put:
        host, _, fat = spec.partition(":")
        puts.append((host, fat or os.path.basename(host).upper()))

    # 1. fresh backing file, 2. FAT image w/ inputs, 3. splice into backing.
    Path(args.backing).unlink(missing_ok=True)
    subprocess.run(["truncate", "-s", f"{args.ram_mb}M", args.backing], check=True)
    build_image(args.img, puts, FATDISK_SIZE // 1024)
    splice_in(args.backing, args.img)

    # 4. boot + drive shell.
    proc, pty = launch(args.backing, args.ram_mb)
    print(f">> qemu pty={pty}")
    ser = serial.Serial(pty, timeout=5)
    drain(ser, idle=1.0, hard_cap=args.boot_wait)
    ser.write(args.cmd.encode() + b"\n")
    # Return once output goes idle for 2s, but never run past the hard cap — a
    # hung or runaway guest must not wedge the harness forever (output streams
    # live above so a hang is still diagnosable).
    drain(ser, idle=2.0, hard_cap=args.timeout)
    time.sleep(0.4)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

    # 5. splice the modified window back out, pull requested files.
    splice_out(args.backing, args.img)
    print("\n>> /mnt contents after run:")
    fatimg("ls", args.img)
    for spec in args.get:
        fat, _, host = spec.partition(":")
        try:
            fatimg("get", args.img, fat, host)
            print(f">> extracted {fat} -> {host} ({os.path.getsize(host)} bytes)")
        except subprocess.CalledProcessError:
            print(f">> FAILED to extract {fat}")


if __name__ == "__main__":
    main()
