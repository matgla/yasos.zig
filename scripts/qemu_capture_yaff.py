#!/usr/bin/env python3
"""Capture device-compiled binaries out of a running QEMU yasos guest.

Why this exists
---------------
When debugging tinycc self-host miscompiles we need to see the *exact* machine
code the on-device tcc emits for a test program. Pulling files back over the
UART is unreliable (the guest has no base64/od and the single-byte console
write drops bytes). Instead we back QEMU's main RAM (`mps.ram` @ 0x80000000,
the 16 MB region that holds the kernel heap, the /tmp RamFs and every loaded
process) with a host file via `memory-backend-file,share=on`. The host file is
a live mmap of guest RAM, so after the guest compiles/runs a program we just
scan the backing file for the YAFF magic and carve the binaries out — no kernel
or QEMU-machine changes required.

Usage
-----
  scripts/qemu_capture_yaff.py --cmd 'tcc /usr/citests/arr.c -o /tmp/x && /tmp/x'
  scripts/qemu_capture_yaff.py --cmd '...' --disasm     # also objdump each .text

Outputs <out>/cap_<addr>.yaff (full image) and <out>/cap_<addr>.text (code
section) for every distinct YAFF image found. With --disasm, prints a Thumb
disassembly of each code section (needs arm-none-eabi-objdump).

Tip: to also see the device tcc's IR, build with `./build_rootfs.sh --debug-tcc`
and pass `-dump-ir` in --cmd, or temporarily force the `DUMP_IR_CG` getenv check
in ir/codegen.c (editing only that file does not perturb the codegen functions
under suspicion).
"""
import argparse
import re
import struct
import subprocess
import sys
import time
from pathlib import Path

import serial

REPO = Path(__file__).resolve().parent.parent
KERNEL = REPO / "zig-out/bin/yasos_kernel"
PTY_RE = re.compile(r"char device redirected to (\S+)")

# YaffHeader (libs/tinycc/tccyaff.h), packed. Field byte offsets we use:
H_CODE_LEN = 8      # uint32 code_length
H_DATA_LEN = 16     # uint32 data_length
H_ENTRY = 24        # uint32 entry
H_TEXT_OFF = 70     # uint16 text_offset (code section start, relative to header)


def launch(backing, ram_mb):
    Path(backing).unlink(missing_ok=True)
    subprocess.run(["truncate", "-s", f"{ram_mb}M", backing], check=True)
    logf = open("/tmp/qemu_capture_yaff.log", "w+")
    cmd = [
        "qemu-system-arm", "-machine", "mps2-an505,memory-backend=mem0",
        "-object", f"memory-backend-file,id=mem0,size={ram_mb}M,mem-path={backing},share=on",
        "-cpu", "cortex-m33", "-display", "none", "-monitor", "none",
        "-semihosting-config", "enable=on,target=native",
        "-serial", "pty", "-kernel", str(KERNEL),
    ]
    logf.write("$ " + " ".join(cmd) + "\n"); logf.flush()
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT)
    pty, deadline = None, time.time() + 20
    while time.time() < deadline:
        m = PTY_RE.search(Path("/tmp/qemu_capture_yaff.log").read_text(errors="ignore"))
        if m:
            pty = m.group(1); break
        if proc.poll() is not None:
            print(Path("/tmp/qemu_capture_yaff.log").read_text()); sys.exit(1)
        time.sleep(0.05)
    if not pty:
        print("no pty"); sys.exit(1)
    return proc, pty


def carve(backing, out):
    d = Path(backing).read_bytes()
    out.mkdir(parents=True, exist_ok=True)
    seen, found = set(), []
    for m in re.finditer(b"YAFF", d):
        i = m.start()
        if i + 80 > len(d):
            continue
        code_len = struct.unpack_from("<I", d, i + H_CODE_LEN)[0]
        text_off = struct.unpack_from("<H", d, i + H_TEXT_OFF)[0]
        if not (0 < code_len < 0x10000 and 0 < text_off < 0x4000):
            continue
        code = d[i + text_off: i + text_off + code_len]
        if len(code) < code_len or code[:16] in seen:
            continue
        seen.add(code[:16])
        # full image: header..end of code is enough for disasm; grab a generous span
        (out / f"cap_{i:x}.yaff").write_bytes(d[i: i + text_off + code_len])
        (out / f"cap_{i:x}.text").write_bytes(code)
        found.append((i, code_len))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", required=True, help="shell command to run on the guest")
    ap.add_argument("--out", default="/tmp/yaff_cap", help="output dir")
    ap.add_argument("--backing", default="/tmp/mpsram.bin")
    ap.add_argument("--ram-mb", type=int, default=16)
    ap.add_argument("--boot-wait", type=float, default=6)
    ap.add_argument("--timeout", type=float, default=25)
    ap.add_argument("--disasm", action="store_true")
    args = ap.parse_args()

    proc, pty = launch(args.backing, args.ram_mb)
    print(f">> qemu pty={pty}")
    ser = serial.Serial(pty, timeout=5)
    time.sleep(args.boot_wait)
    ser.read(ser.in_waiting or 1)
    ser.write(args.cmd.encode() + b"\n")
    end, out = time.time() + args.timeout, b""
    while time.time() < end:
        n = ser.in_waiting
        if n:
            out += ser.read(n); end = time.time() + 3
        else:
            time.sleep(0.05)
    sys.stdout.write(out.decode(errors="replace"))
    time.sleep(0.5)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()

    found = carve(args.backing, Path(args.out))
    print(f"\n>> {len(found)} YAFF image(s) in {args.out}:")
    for i, clen in found:
        print(f"   cap_{i:x}.text  (code_len={clen})")
        if args.disasm:
            subprocess.run(["arm-none-eabi-objdump", "-D", "-b", "binary",
                            "-m", "arm", "-M", "force-thumb",
                            f"{args.out}/cap_{i:x}.text"])


if __name__ == "__main__":
    main()
