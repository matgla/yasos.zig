#!/usr/bin/env python3
import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else "rootfs/usr/bin/toybox"
with open(path, "rb") as f:
    data = f.read()

# Parse header
data_length = struct.unpack_from("<I", data, 16)[0]
bss_length = struct.unpack_from("<I", data, 20)[0]
exp_amt = struct.unpack_from("<H", data, 44)[0]
exp_off = struct.unpack_from("<H", data, 68)[0]

print(f"data_length=0x{data_length:x} bss_length=0x{bss_length:x}")
print(f"exported_symbols: amount={exp_amt} offset=0x{exp_off:x}")
print(f"BSS range in DATA: [0x{data_length:x}, 0x{data_length+bss_length:x})")
print()

pos = exp_off
for i in range(exp_amt):
    word = struct.unpack_from("<I", data, pos)[0]
    section = word & 0x3
    weak = (word >> 2) & 0x1
    offset = word >> 3
    pos += 4
    end = data.index(b"\x00", pos)
    name = data[pos:end].decode("ascii", errors="replace")
    pos = end + 1
    sec = ["CODE", "DATA", "INIT", "UNK"][section]
    in_bss = section == 1 and offset >= data_length
    tag = " [BSS]" if in_bss else ""
    if i < 5 or in_bss or name in ("toys","main","toy_list","toybox_main","xexit","_start"):
        print(f"[{i:3d}] {sec} weak={weak} offset=0x{offset:08x} {name}{tag}")

print(f"\n... {exp_amt} total exported symbols")
