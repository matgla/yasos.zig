#!/bin/bash
# Render Zig's compiler-rt through the C backend and compile it for YasOS.
#
# The Zig compiler holds every comptime float in an f128, so it reaches the
# f16/f80/f128 routines whatever the program being compiled contains, and it
# reaches far more of them than is worth hand-writing. compiler_rt.zig renders
# for this target like any other Zig source; two things in the output are
# beyond tinycc, and strip_naked_asm.py adapts both (see it for why).
#
#   build_compiler_rt.sh <zig-source-dir> <cross-tcc> <out.o> [workdir]
set -euo pipefail

ZIG_SRC="${1:?zig source dir}"
TCC="${2:?cross tcc}"
OUT="${3:?output object}"
WORK="${4:-$(dirname "$OUT")}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK"
ZIG_LIB_DIR="$ZIG_SRC/lib" zig build-obj -ofmt=c \
    -target thumb-freestanding -mcpu=cortex_m33 -OReleaseSmall \
    --zig-lib-dir "$ZIG_SRC/lib" \
    -femit-bin="$WORK/compiler_rt.c" "$ZIG_SRC/lib/compiler_rt.zig"

python3 "$HERE/strip_naked_asm.py" "$WORK/compiler_rt.c" "$WORK/compiler_rt_tcc.c"

"$TCC" -O0 -c "$WORK/compiler_rt_tcc.c" -o "$OUT" \
    -I "$ZIG_SRC/lib" -include "$HERE/zig_c_prelude.h" -fvisibility=hidden
