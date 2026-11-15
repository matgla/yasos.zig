#!/usr/bin/env python3
"""Pack flash images into one RP2350 UF2 for BOOTSEL drag-and-drop.

  make_uf2.py OUT.uf2 ADDR:FILE [ADDR:FILE ...]

e.g. the partition table at the flash base, the kernel at the start of
partition 1 (its ELF load addresses) and the romfs 1 MiB into the partition
(hal/source/raspberry/rp2350/partitions).  The kernel ELF carries the table
too; strip it there, or objcopy -O binary would start at offset 0 and fill
the bootloader's partition with zeros:

  arm-none-eabi-objcopy -O binary -R .partition_table zig-out/bin/yasos_kernel kernel.bin
  make_uf2.py yasos.uf2 \
      0x10000000:hal/source/raspberry/rp2350/partitions/partition_table.bin \
      0x10020000:kernel.bin 0x10120000:rootfs.img
"""
import struct
import sys

RP2350_ARM_S = 0xE48BFF59  # family id: RP2350 ARM Secure
CHUNK = 256


def blocks(parts):
    out = []
    for addr, data in parts:
        data += b"\0" * (-len(data) % CHUNK)
        out += [(addr + o, data[o:o + CHUNK]) for o in range(0, len(data), CHUNK)]
    return out


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    parts = []
    for spec in argv[2:]:
        a, f = spec.split(":", 1)
        parts.append((int(a, 0), open(f, "rb").read()))
    bl = blocks(parts)
    with open(argv[1], "wb") as o:
        for i, (addr, data) in enumerate(bl):
            hdr = struct.pack("<8I", 0x0A324655, 0x9E5D5157, 0x00002000, addr, CHUNK, i, len(bl), RP2350_ARM_S)
            o.write(hdr + data + b"\0" * (476 - CHUNK) + struct.pack("<I", 0x0AB16F30))


main(sys.argv)
