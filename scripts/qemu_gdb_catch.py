#!/usr/bin/env python3
"""Drive QEMU under gdb while feeding a command over the UART PTY.

Boots the yasos kernel halted with a gdbstub, starts a background serial
sender that types --cmd at the shell prompt, then runs gdb-multiarch with the
given --gdb-cmds (semicolon-separated) and prints gdb's output. Used to catch
the YAFF heap corruptor with breakpoints/watchpoints.
"""
import argparse, os, re, subprocess, sys, threading, time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
KERNEL = REPO / "zig-out/bin/yasos_kernel"
PTY_RE = re.compile(r"char device redirected to (\S+)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", required=True)
    ap.add_argument("--gdb-cmds", help="semicolon-separated gdb commands")
    ap.add_argument("--gdb-file", help="path to a gdb command file (preferred; avoids shell escaping)")
    ap.add_argument("--port", type=int, default=1234)
    ap.add_argument("--settle", type=float, default=3.0, help="seconds after prompt before sending cmd")
    ap.add_argument("--gdb-timeout", type=float, default=90)
    args = ap.parse_args()

    log = "/tmp/qemu_gdb_catch.log"
    qcmd = ["qemu-system-arm", "-machine", "mps2-an505", "-cpu", "cortex-m33",
            "-display", "none", "-monitor", "none",
            "-semihosting-config", "enable=on,target=native",
            "-serial", "pty", "-kernel", str(KERNEL),
            "-S", "-gdb", f"tcp::{args.port}"]
    qf = open(log, "w+")
    qproc = subprocess.Popen(qcmd, stdin=subprocess.DEVNULL, stdout=qf, stderr=subprocess.STDOUT)
    # wait for pty
    pty = None
    deadline = time.time() + 20
    while time.time() < deadline:
        m = PTY_RE.search(Path(log).read_text(errors="ignore"))
        if m:
            pty = m.group(1); break
        if qproc.poll() is not None:
            print("qemu died:\n" + Path(log).read_text()); sys.exit(1)
        time.sleep(0.05)
    print(f">> qemu pty={pty} gdbport={args.port}")

    import serial
    ser = serial.Serial(pty, timeout=5)

    # Background sender: wait for prompt, then type the cmd.
    def sender():
        buf = b""
        end = time.time() + 60
        while time.time() < end:
            try:
                n = ser.in_waiting
            except OSError:
                return
            if n:
                buf += ser.read(n)
                if b"$ " in buf:
                    break
            else:
                time.sleep(0.05)
        time.sleep(args.settle)
        try:
            ser.write(args.cmd.encode() + b"\n")
        except OSError:
            pass
    t = threading.Thread(target=sender, daemon=True)
    t.start()

    # gdb command file
    cmds = ["set pagination off", "set confirm off",
            f"target remote :{args.port}"]
    if args.gdb_file:
        cmds += [l.rstrip("\n") for l in Path(args.gdb_file).read_text().splitlines()]
    else:
        cmds += [c.strip() for c in args.gdb_cmds.split(";") if c.strip()]
    cmds += ["detach", "quit"]
    gf = "/tmp/gdb_cmds.txt"
    Path(gf).write_text("\n".join(cmds) + "\n")

    gdb = subprocess.Popen(["gdb-multiarch", "-nx", "-batch", "-x", gf, str(KERNEL)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        out, _ = gdb.communicate(timeout=args.gdb_timeout)
    except subprocess.TimeoutExpired:
        gdb.kill(); out, _ = gdb.communicate()
        out += "\n>> GDB TIMEOUT"
    print(out)
    try: ser.close()
    except Exception: pass
    qproc.terminate()
    try: qproc.wait(timeout=5)
    except subprocess.TimeoutExpired: qproc.kill()


if __name__ == "__main__":
    main()
