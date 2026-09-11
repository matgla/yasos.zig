#!/bin/sh
# Per-instruction profile of mibench's sha_transform, two compilers, no board.
#
# The rig's mibench_sha workload (tests/ir_tests/mibench_sha.c: 50 x SHA-1 over
# 256 bytes) linked bare-metal with scripts/dadd_prof's boot.S/link.ld, once
# with sha.c compiled by the cross tcc and once by arm-none-eabi-gcc, traced
# under qemu with -d exec, and histogrammed per function and per PC.
#
# stdio is kept out of both arms on purpose: sha.h only needs the name FILE for
# one unused prototype (-DFILE=void), and newlib's <stdio.h> plants inline
# functions that tcc emits as real symbols (_getchar_unlocked -> __srget_r,
# _impure_ptr ...), which then cannot link without a libc.  memcpy/memset are
# the driver's own byte loops, identical in both arms -- count sha_transform,
# not the whole program, for the same reason dadd_prof counts the library.
#
#   sh run.sh [TCC] [OUT]          (2026-09-04: tcc 684,000 vs gcc 494,000 = 1.38x)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TCC=${1:-/home/mateusz/repos/tcc-dadd/armv8m-tcc}
OUT=${2:-$HERE/build}
TROOT=$(cd "$(dirname "$TCC")" && pwd)
SHA=$TROOT/tests/benchmarks/mibench/security/sha
P=$HERE/../dadd_prof
GF="-mcpu=cortex-m33 -mthumb -mfloat-abi=soft"
NLINC="-I$TROOT/tests/ir_tests/libc_includes -I$TROOT/tests/ir_tests/libc_imports -I$TROOT/tests/ir_tests/libc_includes/newlib -I$TROOT/include"
mkdir -p "$OUT"
# sha.c minus its two stdio users (sha_stream, sha_print); nothing else changes
python3 - "$SHA/sha.c" "$OUT/sha_nostdio.c" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
for fn in ("sha_stream","sha_print"):
    m=re.search(r"\n[^\n]*\b%s\s*\([^)]*\)\s*\n\{.*?\n\}\n"%fn, s, re.S); assert m, fn
    s=s[:m.start()]+"\n"+s[m.end():]
open(sys.argv[2],"w").write(s.replace("#include <stdio.h>",""))
PY
LG=$(arm-none-eabi-gcc $GF -print-libgcc-file-name)
arm-none-eabi-gcc $GF -O2 -DLITTLE_ENDIAN -I"$SHA" -fno-builtin -c "$HERE/drv.c" -o "$OUT/drv.o"
arm-none-eabi-gcc $GF -c "$P/boot.S" -o "$OUT/boot.o"
arm-none-eabi-gcc $GF -O2 -DLITTLE_ENDIAN -DFILE=void -I"$SHA" -c "$OUT/sha_nostdio.c" -o "$OUT/sha_gcc.o"
"$TCC" -O2 $GF -DLITTLE_ENDIAN -DFILE=void -I"$SHA" $NLINC -c "$OUT/sha_nostdio.c" -o "$OUT/sha_tcc.o"
for a in gcc tcc; do
    arm-none-eabi-ld -T "$P/link.ld" -o "$OUT/$a.elf" "$OUT/boot.o" "$OUT/drv.o" "$OUT/sha_$a.o" "$LG"
    qemu-system-arm -machine mps2-an505 -cpu cortex-m33 -kernel "$OUT/$a.elf" \
        -nographic -semihosting -monitor none -serial null \
        -d exec -accel tcg,one-insn-per-tb=on -D "$OUT/exec_$a.log"
    printf '%-4s %s instructions\n' "$a" "$(wc -l < "$OUT/exec_$a.log")"
done
cd "$OUT" && python3 "$HERE/prof.py"
