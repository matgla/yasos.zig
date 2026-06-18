#!/usr/bin/env python3
"""Boot the kernel under a gdb stub, run a command over serial, leave QEMU
hung so gdb can attach and read the spinning PC."""
import os, re, subprocess, sys, time, serial, pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO / "zig-out/bin/yasos_kernel"
FATIMG = REPO / "scripts/fatimg/fatimg"
RAM_BASE = 0x80000000
FATDISK_ADDR = 0x80EC0000
FATDISK_SIZE = 1024 * 1024
FATDISK_OFFSET = FATDISK_ADDR - RAM_BASE
PTY_RE = re.compile(r"char device redirected to (\S+)")

backing = sys.argv[1]
srcfile = sys.argv[2]   # host C file
cmd = sys.argv[3]
gdbport = int(sys.argv[4]) if len(sys.argv) > 4 else 1234
hangwait = float(sys.argv[5]) if len(sys.argv) > 5 else 20

# build FAT image with IN.C
img = "/tmp/hang_fd.img"
subprocess.run([str(FATIMG), "mkfs", img, "1024"], check=True)
subprocess.run([str(FATIMG), "cp", img, srcfile, "IN.C"], check=True)
data = pathlib.Path(img).read_bytes()
subprocess.run(["truncate", "-s", "16M", backing], check=True)
with open(backing, "r+b") as f:
    f.seek(FATDISK_OFFSET); f.write(data)

logf = open("/tmp/hang_qemu.log", "w+")
qcmd = ["qemu-system-arm", "-machine", "mps2-an505,memory-backend=mem0",
        "-object", f"memory-backend-file,id=mem0,size=16M,mem-path={backing},share=on",
        "-cpu", "cortex-m33", "-display", "none", "-monitor", "none",
        "-semihosting-config", "enable=on,target=native",
        "-serial", "pty", "-kernel", str(KERNEL),
        "-icount", "shift=3,sleep=off", "-gdb", f"tcp::{gdbport}"]
proc = subprocess.Popen(qcmd, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT)
print("qemu pid", proc.pid)
pty = None; deadline = time.time() + 20
while time.time() < deadline:
    m = PTY_RE.search(pathlib.Path("/tmp/hang_qemu.log").read_text(errors="ignore"))
    if m: pty = m.group(1); break
    time.sleep(0.05)
print("pty", pty)
time.sleep(7)  # boot
ser = serial.Serial(pty, 115200, timeout=0.2)
ser.write((cmd + "\n").encode())
ser.flush()
end = time.time() + hangwait
while time.time() < end:
    n = ser.in_waiting
    if n:
        sys.stdout.write(ser.read(n).decode(errors="replace")); sys.stdout.flush()
    else:
        time.sleep(0.1)
print(f"\n>> QEMU left running (pid {proc.pid}) gdb port {gdbport}; attach now.")
