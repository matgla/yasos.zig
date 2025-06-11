#!/usr/bin/env python3
"""Minimal QEMU repro driver for the tcc self-host corruptor.

Boots the yasos.zig QEMU kernel, drives the shell over the UART PTY, runs a
single command (default: compile a baked tcc test source), and prints the
captured output. Detects the kernel panic-loop (no prompt return) as a crash.

Usage:
  scripts/qemu_tcc_repro.py [--cmd 'tcc ...'] [--gdb PORT] [--timeout S]

With --gdb PORT, qemu is started halted (-S) with a gdbstub on tcp::PORT so you
can attach gdb-multiarch before the guest runs. Without it, qemu free-runs.
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
PTY_RE = re.compile(r"char device redirected to (\S+)")
PROMPT = b"$ "


def launch(gdb_port=None):
    logf = open("/tmp/qemu_tcc_repro.log", "w+")
    cmd = [
        "qemu-system-arm", "-machine", "mps2-an505", "-cpu", "cortex-m33",
        "-display", "none", "-monitor", "none",
        "-semihosting-config", "enable=on,target=native",
        "-serial", "pty", "-kernel", str(KERNEL),
    ]
    if gdb_port:
        cmd += ["-S", "-gdb", f"tcp::{gdb_port}"]
    logf.write("$ " + " ".join(cmd) + "\n"); logf.flush()
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT)
    # wait for pty
    deadline = time.time() + 20
    pty = None
    while time.time() < deadline:
        m = PTY_RE.search(Path("/tmp/qemu_tcc_repro.log").read_text(errors="ignore"))
        if m:
            pty = m.group(1); break
        if proc.poll() is not None:
            print("qemu exited early:\n" + Path("/tmp/qemu_tcc_repro.log").read_text())
            sys.exit(1)
        time.sleep(0.05)
    if not pty:
        print("no pty"); sys.exit(1)
    print(f">> qemu pty={pty} gdb={gdb_port}")
    return proc, pty


def drain(ser, secs):
    out = b""
    end = time.time() + secs
    while time.time() < end:
        try:
            n = ser.in_waiting
        except OSError:
            break
        if n:
            out += ser.read(n)
            end = time.time() + secs  # keep reading while data flows
        else:
            time.sleep(0.05)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", default="tcc /usr/citests/02_printf.c -o /tmp/02_printf && /tmp/02_printf; echo RC=$?")
    ap.add_argument("--gdb", type=int, default=None)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--boot-wait", type=float, default=6)
    args = ap.parse_args()

    proc, pty = launch(args.gdb)
    if args.gdb:
        print(f">> attach: gdb-multiarch -ex 'target remote :{args.gdb}' {KERNEL}")
        print(">> qemu is halted; this harness will now just hold the process. Ctrl-C to stop.")
        try:
            proc.wait()
        except KeyboardInterrupt:
            proc.terminate()
        return

    ser = serial.Serial(pty, timeout=5)
    boot = drain(ser, args.boot_wait)
    sys.stdout.write(boot.decode(errors="replace"))
    print("\n>> sending: " + args.cmd)
    ser.write(args.cmd.encode() + b"\n")
    out = drain(ser, args.timeout / 6)
    text = out.decode(errors="replace")
    sys.stdout.write(text)
    if PROMPT not in out[-8:] and b"RC=" not in out:
        print("\n>> NO PROMPT RETURNED — likely crash/panic-loop")
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


if __name__ == "__main__":
    main()
