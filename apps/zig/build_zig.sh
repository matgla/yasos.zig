#!/bin/bash
# Build the Zig compiler for YasOS and install it into a rootfs.
#
#   build_zig.sh <zig-source-dir> <rootfs-dir> [workdir]
#
# <zig-source-dir> is a Zig tree (the yasos fork). The compiler reaches YasOS
# as C: its own C backend renders it as one file, and the YasOS cross compiles
# that. Steps, each cached in [workdir] (default .cache/zig-build):
#
#  1. A HOST compiler built from <zig-source-dir>. `zig build -Donly-c` renders
#     with the C backend of the compiler RUNNING the build, so the fork's C
#     backend changes (undefined renders as 0 without safety: -77 KB of
#     .text) only reach zig.c when the fork itself does the rendering. No LLVM:
#     the C backend and the x86_64 backend for build.zig are all it needs.
#  2. zig.c, rendered by it for thumb-linux-musleabi. YasOS is not a target Zig
#     knows; its libc is Linux-flavoured, and yasos_compat.c bridges the rest.
#  3. Zig's compiler-rt through the same C backend (build_compiler_rt.sh).
#  4. zig.c and yasos_compat.c through the cross, then the link.
#  5. The binary into <rootfs-dir>/usr/bin/zig. lib/std plus the headers a
#     compile of its output needs go to the SD card, not the romfs image (18.6
#     MB, four fifths of it otherwise): into $ZIG_CARD_DIR/var/lib/zig
#     (default: sdcard/ beside <rootfs-dir>, a staging tree laid out like the
#     card), which the compiler searches when no lib sits next to it
#     (-Dzig-lib-search). Copy it onto a board's card with
#     `scripts/target_sync.py push sdcard/var/lib/zig /var/lib/zig`; on QEMU
#     the harnesses put it on the fatdisk volume and pass --zig-lib-dir.
#
# CC is the YasOS cross (default armv8m-tcc); ZIG is the host zig that builds
# the host compiler (default zig). ZIG_OPT is the cross's level (default -O2).
# ZIG_CPU_FAMILIES (default arm) are the architecture families the device
# compiler can target: the CPU tables of every other family are left out, which
# is ~200 KB of .data, i.e. RAM in every run. Empty keeps all of them.
# ZIG_ZIR_BUDGET (default 1572864) is how many bytes of ZIR the device compiler
# keeps loaded; the rest is dropped and re-read from the ZIR cache when needed
# (~32 ms a re-read on the Pico Plus 2's card).  Kernel render on the board,
# 2026-11-09: 1 MB 307 s 6.14 MB peak, 1.5 MB 288 s 6.75 MB, 2 MB 281 s 7.45 MB.
# 0 keeps all ZIR loaded.
# zig.c is compiled with lseek/ftruncate renamed to yasos_compat.c's 64-bit
# wrappers: Zig's off_t is 64-bit, YasOS's libc takes a 32-bit one.
set -euo pipefail

ZIG_SRC="$(realpath "${1:?zig source dir}")"
ROOTFS="$(realpath "${2:?rootfs dir}")"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(realpath -m "${3:-$HERE/../../.cache/zig-build}")"
CC="${CC:-armv8m-tcc}"
HOST_ZIG="${ZIG:-zig}"
ZIG_OPT="${ZIG_OPT:--O2}"
CPU_FAMILY_FLAGS=()
for family in ${ZIG_CPU_FAMILIES-arm}; do CPU_FAMILY_FLAGS+=("-Dcpu-family=$family"); done
ZIR_BUDGET="${ZIG_ZIR_BUDGET-1572864}"
CARD_DIR="$(realpath -m "${ZIG_CARD_DIR:-$(dirname "$ROOTFS")/sdcard}")"
LIB_ON_CARD=/var/lib/zig
mkdir -p "$WORK"

echo "zig: host compiler from $ZIG_SRC"
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$HOST_ZIG" build -Doptimize=ReleaseFast -Denable-llvm=false \
    -Dno-lib --prefix "$WORK/host")
FORK_ZIG="$WORK/host/bin/zig"

# The device compiler is single-threaded, and single-threaded the fork numbers its
# output differently (declarations get their Nav when first used): this one makes the
# host references the device's output must equal (scripts/kernel_tcc/zig_device.py).
# Without threads the fork needs libc's allocator.
echo "zig: single-threaded host compiler (references for the device's output)"
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$HOST_ZIG" build -Doptimize=ReleaseFast -Denable-llvm=false \
    -Dno-lib -Dsingle-threaded -Dforce-link-libc --prefix "$WORK/host-st")

echo "zig: rendering the compiler as C"
# -Ddev must be explicit: -Donly-c alone pins the bootstrap feature set.
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$FORK_ZIG" build -Donly-c -Dofmt=c -Ddev=cbe \
    -Denable-llvm=false -Dsingle-threaded -Dforce-link-libc -Dtarget=thumb-linux-musleabi \
    -Dcpu=cortex_m33 -Doptimize=ReleaseFast -Dstrip ${CPU_FAMILY_FLAGS[@]+"${CPU_FAMILY_FLAGS[@]}"} \
    -Dzir-budget="$ZIR_BUDGET" -Dzig-lib-search="$LIB_ON_CARD" --prefix "$WORK/zigc")

echo "zig: compiler-rt"
ZIG="$FORK_ZIG" "$HERE/build_compiler_rt.sh" "$ZIG_SRC" "$CC" "$WORK/compiler_rt.o" "$WORK/compiler_rt"

echo "zig: compiling zig.c with $CC $ZIG_OPT"
# -ffunction-sections: the link's --hot-text picks functions by their sections.
"$CC" $ZIG_OPT -w -c "$WORK/zigc/bin/zig.c" -o "$WORK/zig.o" -ffunction-sections \
    -I "$ZIG_SRC/lib" -include "$HERE/zig_c_prelude.h" -fvisibility=hidden \
    -Dlseek=yz_lseek64 -Dftruncate=yz_ftruncate64
"$CC" -O2 -c "$HERE/yasos_compat.c" -o "$WORK/compat.o" -fvisibility=hidden

# The stack is reserved in full at exec (16 MB made the process 21 MB instead of 5).
# Deepest stack use of the device compiler, scanned for the lowest written word below
# main (2026-11-08, QEMU): 144 KB, for hello world and for the whole yasos kernel
# alike; 512 KB -> 320 KB gave a board compile that memory back.  2026-11-09, the board
# model's watch on the stack (zig's own stores only): 151 KB for the kernel render, deepest
# in Sema's type-layout and inline-body recursion (~3 KB a level).  192 KB keeps the stack
# and zig's 124 KB .data both in SRAM: exec allocates the stack first, and the pool's fast
# tier is ~430 KB.  ZIG_STACK_SIZE overrides; a deeper compile faults (STKOF), not corrupts.
# hot_functions.txt: the functions the loader copies to SRAM (fetch stalls of the kernel
# render; the stack, its hot block and .data all fit the pool's ~430 KB fast tier).
"$CC" -fvisibility=hidden -stack-size=${ZIG_STACK_SIZE:-196608} -Wl,--hot-text="$HERE/hot_functions.txt" "$WORK/zig.o" "$WORK/compat.o" "$WORK/compiler_rt.o" \
    -lm -o "$WORK/zig"

echo "zig: installing into $ROOTFS, the lib into $CARD_DIR$LIB_ON_CARD"
install -D -m 755 "$WORK/zig" "$ROOTFS/usr/bin/zig"
rm -rf "$ROOTFS/usr/lib/zig" "$CARD_DIR$LIB_ON_CARD"
mkdir -p "$CARD_DIR$LIB_ON_CARD"
cp -r "$ZIG_SRC/lib/std" "$CARD_DIR$LIB_ON_CARD/std"
# compiler-rt as source too: the kernel's tcc build renders it with the C
# backend like the kernel itself (build/kernel_tcc.zig), on the device as well.
cp -r "$ZIG_SRC/lib/compiler_rt" "$CARD_DIR$LIB_ON_CARD/compiler_rt"
cp "$ZIG_SRC/lib/compiler_rt.zig" "$CARD_DIR$LIB_ON_CARD/"
cp "$ZIG_SRC/lib/zig.h" "$HERE/zig_c_prelude.h" "$CARD_DIR$LIB_ON_CARD/"
echo "zig: done ($(stat -c %s "$WORK/zig") bytes; lib $(du -sb "$CARD_DIR$LIB_ON_CARD" | cut -f1) bytes for the card)"
