#!/bin/sh
# Per-function instruction profile of bench_memcpy, two compilers, no board.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TCC=${1:-/home/mateusz/repos/tcc-dadd/armv8m-tcc}
OUT=${2:-$HERE/build}
TROOT=$(cd "$(dirname "$TCC")" && pwd)
BS=$TROOT/tests/benchmarks/bench_string.c
P=$HERE/../sha_prof/../dadd_prof
GF="-mcpu=cortex-m33 -mthumb -mfloat-abi=soft"
NLINC="-I$TROOT/tests/ir_tests/libc_includes -I$TROOT/tests/ir_tests/libc_imports -I$TROOT/tests/ir_tests/libc_includes/newlib -I$TROOT/include"
NL=$TROOT/tests/ir_tests/qemu/mps2-an505/newlib_build/arm-none-eabi/newlib/libc.a
mkdir -p "$OUT"
LG=$(arm-none-eabi-gcc $GF -print-libgcc-file-name)
arm-none-eabi-gcc $GF -O2 -c "$HERE/drv.c" -o "$OUT/drv.o"
arm-none-eabi-gcc $GF -c "$P/boot.S" -o "$OUT/boot.o"
arm-none-eabi-gcc $GF -O2 -I$TROOT/include -c "$BS" -o "$OUT/bs_gcc.o"
"$TCC" -O2 $GF $NLINC -c "$BS" -o "$OUT/bs_tcc.o"
for a in gcc tcc; do
  arm-none-eabi-ld -T "$P/link.ld" -o "$OUT/$a.elf" "$OUT/boot.o" "$OUT/drv.o" "$OUT/bs_$a.o" "$NL" "$LG" 2>&1 | grep -v warning || true
  qemu-system-arm -machine mps2-an505 -cpu cortex-m33 -kernel "$OUT/$a.elf" -nographic -semihosting -monitor none -serial null -d exec -accel tcg,one-insn-per-tb=on -D "$OUT/exec_$a.log"
  printf '%-4s %s instructions\n' "$a" "$(wc -l < "$OUT/exec_$a.log")"
done
cd "$OUT" && python3 "$HERE/../sha_prof/prof.py" 2>/dev/null | sed -n '/per function/,/mnemonic/p' | head -14
