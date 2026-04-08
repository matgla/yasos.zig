#!/usr/bin/env python3
"""Parse YAFF local relocations and data relocations to verify BSS offsets."""
import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else "rootfs/usr/bin/toybox"
with open(path, "rb") as f:
    data = f.read()

# Header fields
code_length = struct.unpack_from("<I", data, 8)[0]
data_length = struct.unpack_from("<I", data, 16)[0]
bss_length = struct.unpack_from("<I", data, 20)[0]
local_amt = struct.unpack_from("<H", data, 38)[0]
data_reloc_amt = struct.unpack_from("<H", data, 40)[0]
reloc_offset = struct.unpack_from("<H", data, 64)[0]
sym_reloc_amt = struct.unpack_from("<H", data, 36)[0]

print(f"code_length=0x{code_length:x}")
print(f"data_length=0x{data_length:x}")
print(f"bss_length=0x{bss_length:x}")
print(f"sym_table_relocs={sym_reloc_amt}")
print(f"local_relocs={local_amt}")
print(f"data_relocs={data_reloc_amt}")
print(f"relocations_offset=0x{reloc_offset:x}")
print()

SEC = ["CODE", "DATA", "INIT", "UNK"]

# Relocations are at: reloc_offset
# Order: sym_table_relocs, local_relocs, data_relocs
# YaffSymbolTableRelocationEntry: 8 bytes each
# YaffLocalRelocationEntry: 8 bytes each (section:2 + index:30, target_offset:32)
# YaffDataRelocationEntry: 8 bytes each (to:32, section:2 + from:30)

sym_reloc_size = sym_reloc_amt * 8
local_start = reloc_offset + sym_reloc_size
data_reloc_start = local_start + local_amt * 8

print(f"=== LOCAL GOT RELOCATIONS ({local_amt}) ===")
print(f"  starts at file offset 0x{local_start:x}")
pos = local_start
bss_locals = 0
for i in range(local_amt):
    w0 = struct.unpack_from("<I", data, pos)[0]
    w1 = struct.unpack_from("<I", data, pos + 4)[0]
    section = w0 & 0x3
    index = w0 >> 2
    target_offset = w1
    in_bss = (section == 1 and target_offset >= data_length)
    tag = " [BSS]" if in_bss else ""
    if in_bss:
        bss_locals += 1
    print(f"  [{i:3d}] {SEC[section]} GOT[{index}] -> offset=0x{target_offset:08x}{tag}")
    pos += 8
print(f"  {bss_locals} BSS-targeting local relocations\n")

print(f"=== DATA RELOCATIONS (showing first 30 + BSS-related) ===")
print(f"  starts at file offset 0x{data_reloc_start:x}")
pos = data_reloc_start
bss_data = 0
for i in range(data_reloc_amt):
    to_val = struct.unpack_from("<I", data, pos)[0]
    w1 = struct.unpack_from("<I", data, pos + 4)[0]
    section = w1 & 0x3
    from_val = w1 >> 2
    pos += 8
    in_bss_to = to_val >= data_length and to_val < data_length + bss_length
    in_bss_from = (section == 1 and from_val >= data_length)
    tag = ""
    if in_bss_to: tag += " [to=BSS]"
    if in_bss_from: tag += " [from=BSS]"
    if in_bss_to or in_bss_from:
        bss_data += 1
    # Show first 30, BSS-related, or section=UNK
    if i < 10 or in_bss_to or in_bss_from or section == 3:
        print(f"  [{i:3d}] {SEC[section]} to=0x{to_val:08x} from=0x{from_val:08x}{tag}")

print(f"\n  {bss_data} BSS-related data relocations out of {data_reloc_amt}")

# Statistics
sec_counts = [0,0,0,0]
code_targets = []
unk_entries = []
pos2 = data_reloc_start
for i in range(data_reloc_amt):
    to_val = struct.unpack_from("<I", data, pos2)[0]
    w1 = struct.unpack_from("<I", data, pos2 + 4)[0]
    section = w1 & 0x3
    from_val = w1 >> 2
    sec_counts[section] += 1
    if section == 0:  # CODE
        code_targets.append((i, to_val, from_val))
    if section == 3:  # UNK
        unk_entries.append((i, to_val, from_val))
    pos2 += 8

print(f"\n  Section distribution: CODE={sec_counts[0]} DATA={sec_counts[1]} INIT={sec_counts[2]} UNK={sec_counts[3]}")
print(f"\n  CODE-targeting data relocations ({len(code_targets)}):")
for idx, to, fr in code_targets[:20]:
    print(f"    [{idx:3d}] to=0x{to:08x} from=0x{fr:08x}")
if len(code_targets) > 20:
    print(f"    ... {len(code_targets)} total")

if unk_entries:
    print(f"\n  UNK (GOT-indirect) data relocations ({len(unk_entries)}):")
    for idx, to, fr in unk_entries:
        print(f"    [{idx:3d}] to=0x{to:08x} got_index={fr}")
