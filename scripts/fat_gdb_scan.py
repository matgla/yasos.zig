#!/usr/bin/env python3
"""Boot qemu with the FAT drive AND a gdb stub, drive the shell to run a -O1
compile, and use gdb to log every lazy_resolve symbol + catch the fault."""
import os, re, subprocess, sys, threading, time
from pathlib import Path
import serial

REPO = Path(__file__).resolve().parent.parent
KERNEL = REPO / "zig-out/bin/yasos_kernel"
FATIMG = REPO / "scripts/fatimg/fatimg"
PTY_RE = re.compile(r"char device redirected to (\S+)")
RAM_BASE = 0x80000000
FATDISK_OFFSET = 0x80EC0000 - RAM_BASE
FATDISK_SIZE = 1024 * 1024

backing = "/tmp/fg_back.bin"
img = "/tmp/fg.img"
src = sys.argv[1]
cmd = sys.argv[2]
ram_mb = 16

# build fat image
Path(backing).unlink(missing_ok=True)
subprocess.run(["truncate", "-s", f"{ram_mb}M", backing], check=True)
subprocess.run([str(FATIMG), "mkfs", img, str(FATDISK_SIZE // 1024)], check=True)
subprocess.run([str(FATIMG), "cp", img, src, "IN.C"], check=True)
data = Path(img).read_bytes()
with open(backing, "r+b") as f:
    f.seek(FATDISK_OFFSET); f.write(data)

log = "/tmp/fg_qemu.log"
qcmd = ["qemu-system-arm", "-machine", "mps2-an505,memory-backend=mem0",
        "-object", f"memory-backend-file,id=mem0,size={ram_mb}M,mem-path={backing},share=on",
        "-cpu", "cortex-m33", "-display", "none", "-monitor", "none",
        "-semihosting-config", "enable=on,target=native",
        "-serial", "pty", "-kernel", str(KERNEL), "-S", "-gdb", "tcp::1234"]
qf = open(log, "w+")
qproc = subprocess.Popen(qcmd, stdin=subprocess.DEVNULL, stdout=qf, stderr=subprocess.STDOUT)
pty, deadline = None, time.time() + 20
while time.time() < deadline:
    m = PTY_RE.search(Path(log).read_text(errors="ignore"))
    if m: pty = m.group(1); break
    if qproc.poll() is not None:
        print(Path(log).read_text()); sys.exit(1)
    time.sleep(0.05)
print(f">> pty={pty}")
ser = serial.Serial(pty, timeout=5)

def sender():
    # wait for boot prompt then type the cmd
    time.sleep(12)
    ser.write(cmd.encode() + b"\n")
threading.Thread(target=sender, daemon=True).start()

import shutil; gdb_script="/tmp/fg2.gdb"; shutil.copy("scripts/fg2.gdb", gdb_script); _x="/tmp/unused.gdb"
Path(_x).write_text("""
set pagination off
set confirm off
target remote :1234
# break at lazy_resolve, print the symbol name being resolved
break lazy_resolve
commands
  silent
  printf "LAZY_RESOLVE name=%s\\n", (char*)info->symbol_name
  continue
end
# catch the hardfault entry
break irq_hard_fault
commands
  printf "=== HARDFAULT entry ===\\n"
  bt
end
continue
""")
gdb = subprocess.run(["gdb-multiarch", "-q", "-x", gdb_script, str(KERNEL)],
                     timeout=90, capture_output=True, text=True)
print(gdb.stdout[-8000:])
print("STDERR:", gdb.stderr[-2000:])
try: qproc.terminate(); qproc.wait(timeout=5)
except Exception: qproc.kill()
