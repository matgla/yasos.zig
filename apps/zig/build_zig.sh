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
#  5. The binary into <rootfs-dir>/usr/bin/zig, and lib/std plus the headers a
#     compile of its output needs into <rootfs-dir>/usr/lib/zig.
#
# CC is the YasOS cross (default armv8m-tcc); ZIG is the host zig that builds
# the host compiler (default zig). ZIG_OPT is the cross's level (default -O2).
# ZIG_CPU_FAMILIES (default arm) are the architecture families the device
# compiler can target: the CPU tables of every other family are left out, which
# is ~200 KB of .data, i.e. RAM in every run. Empty keeps all of them.
# ZIG_ZIR_BUDGET (default 262144) is how many bytes of ZIR the device compiler
# keeps loaded; the rest is dropped and re-read from the ZIR cache when needed.
# 256 KiB gets nearly all of the saving (fs_hellofmt peak -28%) for a few MB of
# re-reads per small compile. 0 keeps all ZIR loaded.
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
ZIR_BUDGET="${ZIG_ZIR_BUDGET-262144}"
mkdir -p "$WORK"

echo "zig: host compiler from $ZIG_SRC"
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$HOST_ZIG" build -Doptimize=ReleaseFast -Denable-llvm=false \
    -Dno-lib --prefix "$WORK/host")
FORK_ZIG="$WORK/host/bin/zig"

echo "zig: rendering the compiler as C"
# -Ddev must be explicit: -Donly-c alone pins the bootstrap feature set.
(cd "$ZIG_SRC" && ZIG_LIB_DIR="$ZIG_SRC/lib" "$FORK_ZIG" build -Donly-c -Dofmt=c -Ddev=cbe \
    -Denable-llvm=false -Dsingle-threaded -Dforce-link-libc -Dtarget=thumb-linux-musleabi \
    -Dcpu=cortex_m33 -Doptimize=ReleaseFast -Dstrip ${CPU_FAMILY_FLAGS[@]+"${CPU_FAMILY_FLAGS[@]}"} \
    -Dzir-budget="$ZIR_BUDGET" --prefix "$WORK/zigc")

echo "zig: compiler-rt"
ZIG="$FORK_ZIG" "$HERE/build_compiler_rt.sh" "$ZIG_SRC" "$CC" "$WORK/compiler_rt.o" "$WORK/compiler_rt"

echo "zig: compiling zig.c with $CC $ZIG_OPT"
"$CC" $ZIG_OPT -w -c "$WORK/zigc/bin/zig.c" -o "$WORK/zig.o" \
    -I "$ZIG_SRC/lib" -include "$HERE/zig_c_prelude.h" -fvisibility=hidden \
    -Dlseek=yz_lseek64 -Dftruncate=yz_ftruncate64
"$CC" -O2 -c "$HERE/yasos_compat.c" -o "$WORK/compat.o" -fvisibility=hidden

# The stack is reserved in full at exec. Compiling hello world peaks at
# 306-356 KB of it (measured on QEMU); 16 MB made the process 21 MB instead of 5.
"$CC" -fvisibility=hidden -stack-size=524288 "$WORK/zig.o" "$WORK/compat.o" "$WORK/compiler_rt.o" \
    -lm -o "$WORK/zig"

echo "zig: installing into $ROOTFS"
install -D -m 755 "$WORK/zig" "$ROOTFS/usr/bin/zig"
rm -rf "$ROOTFS/usr/lib/zig"
mkdir -p "$ROOTFS/usr/lib/zig"
cp -r "$ZIG_SRC/lib/std" "$ROOTFS/usr/lib/zig/std"
cp "$ZIG_SRC/lib/zig.h" "$HERE/zig_c_prelude.h" "$ROOTFS/usr/lib/zig/"
echo "zig: done ($(stat -c %s "$WORK/zig") bytes)"
