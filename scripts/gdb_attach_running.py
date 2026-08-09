#!/usr/bin/env python3
"""Attach gdb to an ALREADY-BOOTED rp2350 (no reset) and run a watchpoint script,
then type a command over serial. Avoids the gdb-live double-fault caused by
setting flash HW breakpoints at reset-halt before XIP is up.

Prereq: the board must already be booted to a shell prompt (e.g. after a
`--force` flash). Run on the REMOTE host (mateusz@...), driven via ssh -s.

argv: <repo> <kernel_elf> <serial_dev> <gdb_script> <cmd> <gdb_port>
"""
import sys, os, time, subprocess, threading

repo, kernel, serial_dev, gdb_script, cmd, port = sys.argv[1:7]

# 1. openocd: attach WITHOUT reset (init only), leave gdbserver up.
oocd = subprocess.Popen(
    ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/rp2350.cfg",
     "-c", "adapter speed 20000", "-c", "init",
     "-c", f"gdb_port {port}", "-c", "halt"],
    stdout=open("/tmp/oocd_attach.log", "w"), stderr=subprocess.STDOUT)
time.sleep(2)

# 2. background serial sender: type cmd after gdb continues (after a delay).
def sender():
    time.sleep(8)  # let gdb attach + source script + continue + board resume
    try:
        with open(serial_dev, "wb", buffering=0) as s:
            s.write(b"\r")
            time.sleep(0.3)
            s.write(cmd.encode() + b"\r")
    except OSError as e:
        sys.stderr.write(f"serial write failed: {e}\n")
threading.Thread(target=sender, daemon=True).start()

# 3. gdb: source the watchpoint script, continue. The board is RUNNING, so flash
#    breakpoints set by the script are safe.
gdb_cmds = [
    "set pagination off", "set confirm off",
    f"file {kernel}",
    f"target extended-remote :{port}",
    "continue",   # resume the (halted) board; script's own `continue` runs after sourcing
]
gf = "/tmp/gdb_attach_cmds.txt"
# Source the script BEFORE continue so its breakpoints/`continue` take effect.
with open(gf, "w") as f:
    f.write("set pagination off\nset confirm off\n")
    f.write(f"file {kernel}\n")
    f.write(f"target extended-remote :{port}\n")
    f.write(f"source {gdb_script}\n")

gdb = subprocess.Popen(["gdb", "-nx", "-batch", "-x", gf],
                       cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    out, _ = gdb.communicate(timeout=70)
except subprocess.TimeoutExpired:
    gdb.kill(); out, _ = gdb.communicate()
    out += "\n>> GDB TIMEOUT"
print(out)
oocd.terminate()
