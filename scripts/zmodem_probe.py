#!/usr/bin/env python3
"""Boot the QEMU kernel, drive the shell to launch `rz --zmodem`, and dump the
raw serial bytes the target emits (hex) so we can see exactly how the ZRINIT
frame is corrupted. Diagnostic only."""
import os, re, shlex, subprocess, sys, time
from pathlib import Path
import serial

KERNEL = os.environ.get("YASOS_QEMU_KERNEL") or "zig-out/bin/yasos_kernel"
PTY_RE = re.compile(r"char device redirected to (\S+)")

logf = open("/tmp/zmodem_probe_qemu.log", "w+")
cmd = ["qemu-system-arm", "-machine", "mps2-an505", "-cpu", "cortex-m33",
       "-display", "none", "-monitor", "none",
       "-semihosting-config", "enable=on,target=native",
       "-serial", "pty", "-kernel", KERNEL]
proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT)

# wait for pty
pty = None
deadline = time.time() + 20
while time.time() < deadline:
    m = PTY_RE.search(Path("/tmp/zmodem_probe_qemu.log").read_text(errors="ignore"))
    if m:
        pty = m.group(1); break
    time.sleep(0.05)
if not pty:
    print("no pty"); proc.kill(); sys.exit(1)
print("PTY:", pty)

ser = serial.Serial(pty, timeout=8)

def read_for(secs):
    end = time.time() + secs
    buf = bytearray()
    while time.time() < end:
        n = ser.in_waiting
        if n:
            buf += ser.read(n)
        else:
            time.sleep(0.01)
    return bytes(buf)

# boot
boot = read_for(4)
sys.stdout.write(boot.decode("latin1"))
# get a prompt
ser.write(b"\n")
read_for(1)
ser.reset_input_buffer()

# launch rz; it should emit ZRINIT (* ZDLE A 01 ...)
ser.write(b"rz --zmodem /tmp/probe.bin\n")
raw = read_for(4)

print("\n\n===== RAW BYTES FROM TARGET AFTER rz (%d bytes) =====" % len(raw))
# hex dump
for i in range(0, len(raw), 16):
    chunk = raw[i:i+16]
    hexs = " ".join("%02x" % b for b in chunk)
    asci = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
    print("%04x  %-47s  %s" % (i, hexs, asci))

# Find the '*' (0x2a) and show the bytes around the ZRINIT header
idx = raw.find(b"\x2a\x18")  # ZPAD ZDLE
print("\nZPAD+ZDLE at offset:", idx)
if idx >= 0:
    print("header window:", " ".join("%02x" % b for b in raw[idx:idx+16]))

ser.close()
proc.kill()
proc.wait()
