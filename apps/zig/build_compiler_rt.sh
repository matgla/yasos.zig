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
#
# ZIG picks the compiler that renders it (default: zig on PATH).
set -euo pipefail

ZIG_SRC="${1:?zig source dir}"
TCC="${2:?cross tcc}"
OUT="${3:?output object}"
WORK="${4:-$(dirname "$OUT")}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$WORK"
ZIG_LIB_DIR="$ZIG_SRC/lib" "${ZIG:-zig}" build-obj -ofmt=c \
    -target thumb-freestanding -mcpu=cortex_m33 -OReleaseSmall \
    --zig-lib-dir "$ZIG_SRC/lib" \
    -femit-bin="$WORK/compiler_rt.c" "$ZIG_SRC/lib/compiler_rt.zig"

# Exports the link already gets from its runtime archives and libm are renamed
# out of the way (see strip_naked_asm.py). The archives are the ones this cross
# links by default -- libtcc1 and the __aeabi_ FP library it selects for its
# FPU (fp/libsoftfp.a and friends, which define the compare helpers too) --
# read back from a probe link with -vv rather than guessed.
printf 'int main(void) { return 0; }\n' > "$WORK/probe.c"
RUNTIME_ARCHIVES=$("$TCC" -vv "$WORK/probe.c" -o "$WORK/probe" | awk '/^-> .*\.a$/ { print $2 }')
LIBTCC1=$("$TCC" -print-search-dirs | awk '/^libtcc1:/ { getline; print $1 }')
LIBM=$(dirname "$LIBTCC1")/libm.a
# shellcheck disable=SC2086  # one archive path per word
"${NM:-nm}" --defined-only -g $RUNTIME_ARCHIVES "$LIBTCC1" "$LIBM" | awk 'NF == 3 { print $3 }' \
    | sort -u > "$WORK/provided.txt"

python3 "$HERE/strip_naked_asm.py" "$WORK/compiler_rt.c" "$WORK/compiler_rt_tcc.c" \
    "$WORK/provided.txt"

# -O2: these routines are on the Zig compiler's hot paths (wyhash's 64x64->128
# multiply is __multi3, ~2.9M calls per compile), and at -O0 __multi3 alone is
# ~1000 instructions a call.
"$TCC" -O2 -c "$WORK/compiler_rt_tcc.c" -o "$OUT" \
    -I "$ZIG_SRC/lib" -include "$HERE/zig_c_prelude.h" -fvisibility=hidden
