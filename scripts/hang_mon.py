#!/usr/bin/env python3
"""Boot kernel (identical qemu args to the fatdisk harness, which hangs), but add
an HMP monitor on a TCP socket. Run the command over serial, let it hang, then
sample CPU PC via `info registers` repeatedly."""
import re, socket, subprocess, sys, time, serial, pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
KERNEL = REPO / "zig-out/bin/yasos_kernel"
FATIMG = REPO / "scripts/fatimg/fatimg"
FATDISK_OFFSET = 0x80EC0000 - 0x80000000
PTY_RE = re.compile(r"char device redirected to (\S+)")

backing, srcfile, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
hangwait = float(sys.argv[4]) if len(sys.argv) > 4 else 25
MONPORT = 4499

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
        "-cpu", "cortex-m33", "-display", "none",
        "-monitor", f"tcp:127.0.0.1:{MONPORT},server,nowait",
        "-semihosting-config", "enable=on,target=native",
        "-serial", "pty", "-kernel", str(KERNEL)]
proc = subprocess.Popen(qcmd, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT)
print("qemu pid", proc.pid)
pty = None; deadline = time.time() + 20
while time.time() < deadline:
    m = PTY_RE.search(pathlib.Path("/tmp/hang_qemu.log").read_text(errors="ignore"))
    if m: pty = m.group(1); break
    time.sleep(0.05)
print("pty", pty); time.sleep(7)
ser = serial.Serial(pty, 115200, timeout=0.2)
ser.write((cmd + "\n").encode()); ser.flush()
end = time.time() + hangwait
while time.time() < end:
    n = ser.in_waiting
    if n: sys.stdout.write(ser.read(n).decode(errors="replace")); sys.stdout.flush()
    else: time.sleep(0.1)

# Now sample PC via monitor
def mon(c):
    s = socket.create_connection(("127.0.0.1", MONPORT), timeout=3)
    s.settimeout(1.0)
    time.sleep(0.2)
    try:
        while True: s.recv(4096)
    except Exception: pass
    s.sendall((c + "\n").encode())
    time.sleep(0.3)
    out = b""
    try:
        while True:
            d = s.recv(4096)
            if not d: break
            out += d
    except Exception: pass
    s.close()
    return out.decode(errors="replace")

print("\n=== PC samples ===")
for i in range(8):
    r = mon("info registers")
    m = re.search(r"R15=([0-9a-fA-F]+)|PC=([0-9a-fA-F]+)|pc *0x([0-9a-fA-F]+)", r)
    pcs = re.findall(r"(?:R15|PC|pc)[ =]*0?x?([0-9a-fA-F]{6,})", r)
    print(f"sample {i}: pcs={pcs}")
    time.sleep(0.4)
print(">> qemu pid", proc.pid, "still running")
