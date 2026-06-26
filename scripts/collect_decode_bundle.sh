#!/bin/bash
#
# collect_decode_bundle.sh — gather everything needed to decode a YasOS
# HardFault stacktrace into one directory.
#
# The kernel fault handler prints, per faulting process, a module map plus a
# backtrace of stacked return addresses, e.g.:
#
#   [ERR][loader]   armv8m-tcc .text 0x800e8340 0x22a2e8
#   [ERR][loader]   libc.so .text    0x8002f900 0x10dd8
#   [ERR][hardfault]  [sp+0x010] ret=0x800313C1 ...
#
# To symbolize those addresses you need the *symbol-bearing* ELF for each
# module. The on-device binaries in rootfs.img are in YAFF format ("data"), so
# they cannot be fed to addr2line directly — this script collects the matching
# ARM ELFs (built with debug info) alongside the firmware and rootfs image.
#
# Collected layout:
#   <dest>/symbols/yasos_kernel        firmware ELF (kernel-space addresses)
#   <dest>/symbols/armv8m-tcc.elf      native ARM tcc (the common compile-crash module)
#   <dest>/symbols/lib*.so.elf         per-library ARM ELFs (libc/libm/...)
#   <dest>/rootfs.img                  exact userspace image that ran (unless --symbols-only)
#   <dest>/dump_decoder.py             helper to symbolize a numbered backtrace
#   <dest>/DECODE.txt                  how to use the bundle
#
# Usage: scripts/collect_decode_bundle.sh <dest_dir> [--symbols-only]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

DEST="${1:-}"
if [ -z "$DEST" ]; then
    echo "usage: $0 <dest_dir> [--symbols-only]" >&2
    exit 2
fi
INCLUDE_ROOTFS=1
if [ "${2:-}" = "--symbols-only" ]; then
    INCLUDE_ROOTFS=0
fi

SYM="$DEST/symbols"
mkdir -p "$SYM"

# True for a 32-bit little-endian ARM ELF (EI_MAG + e_machine == 0x28 at
# offset 18). Filters out x86 host builds and YAFF "data" files. Portable:
# only needs head/od/grep from coreutils.
is_arm_elf() {
    head -c 20 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n' \
        | grep -qiE '^7f454c46.{28}2800'
}

copied_any=0
copy_sym() {  # copy_sym <src> — copy into symbols/ if it is an ARM ELF
    local src="$1"
    [ -e "$src" ] || return 0
    if is_arm_elf "$src"; then
        cp -f "$src" "$SYM/$(basename "$src")"
        echo "  + symbols/$(basename "$src")  (${src#$REPO_ROOT/})"
        copied_any=1
    fi
}

echo ">> Collecting decode bundle into $DEST"

# Firmware (kernel) — ARM ELF with debug_info.
copy_sym "$REPO_ROOT/zig-out/bin/yasos_kernel"

# Native ARM tcc — the module named "armv8m-tcc" in the fault maps.
copy_sym "$REPO_ROOT/libs/tinycc/bin/armv8m-tcc.elf"

# Per-library ARM symbol ELFs (libc/libm/libdl/libpthread/ncurses/termcap/fp).
# A clean device build emits these as elf32-littlearm next to the YAFF .so.
while IFS= read -r f; do
    copy_sym "$f"
done < <(find "$REPO_ROOT/libs" -name '*.so.elf' 2>/dev/null || true)

# The exact userspace image that ran on the device. Kept for completeness and
# for byte-matching code bytes from the dump when a symbol ELF is unavailable.
if [ "$INCLUDE_ROOTFS" -eq 1 ] && [ -e "$REPO_ROOT/rootfs.img" ]; then
    cp -f "$REPO_ROOT/rootfs.img" "$DEST/rootfs.img"
    echo "  + rootfs.img"
fi

# Helper + instructions.
cp -f "$SCRIPT_DIR/dump_decoder.py" "$DEST/dump_decoder.py" 2>/dev/null || true

cat > "$DEST/DECODE.txt" <<'EOF'
Decoding a YasOS HardFault stacktrace
=====================================

The kernel fault handler logs, for the faulting process, a module map and a
backtrace of stacked return addresses:

  [ERR][loader]   armv8m-tcc .text 0x800e8340 0x22a2e8   <- module .text base, size
  [ERR][loader]   libc.so .text    0x8002f900 0x10dd8
  [ERR][hardfault]  [sp+0x010] ret=0x800313C1 ...        <- a stacked return addr

To symbolize an address ADDR:

1. Find which module's .text range [BASE, BASE+SIZE) contains ADDR (from the map).
2. Subtract the module's load base and run addr2line on the matching ELF here
   (the bundled ELFs are linked with .text at vaddr 0):

     arm-none-eabi-addr2line -f -e symbols/armv8m-tcc.elf $((ADDR - BASE))

   For a kernel-space address use symbols/yasos_kernel (kernel .text is at its
   absolute link address, so usually no subtraction is needed).

Notes
-----
* symbols/armv8m-tcc.elf is the stage-1 bootstrap native tcc. The on-device tcc
  is the stage-2 self-host, so its .text size may differ by a few hundred bytes.
  If addr2line lands slightly off, byte-match the "code @0x..." bytes from the
  dump against the ELF (objdump -d) to recover the exact offset.
* rootfs.img is the exact userspace image (YAFF format) that ran; use it to
  byte-match code bytes when a symbol ELF is missing.
* dump_decoder.py automates the numbered-backtrace form:
    python3 dump_decoder.py -i <dumpfile> -t symbols/armv8m-tcc.elf
EOF

if [ "$copied_any" -eq 0 ]; then
    echo ">> WARNING: no ARM symbol ELFs found — was the target built?" >&2
fi
echo ">> Decode bundle ready: $DEST"
