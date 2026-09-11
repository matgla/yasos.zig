#!/bin/sh
# Per-call instruction profile of one soft-float routine, two compilers, no board.
#
# Builds lib/fp/soft twice — once with the cross tcc, once with arm-none-eabi-gcc
# at the flags lib/fp/soft/Makefile uses — then links the same bare-metal driver
# three ways (all gcc / gcc with one object swapped / all tcc) and traces every
# executed instruction under qemu-system-arm.  See
# tinycc-closing-gap-to-tcc.md, scene 17's Notes, for what it measured.
#
#   sh run.sh [TCC] [OUT]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TCC=${1:-/home/mateusz/repos/tcc-fpo0/armv8m-tcc}
OUT=${2:-$HERE/build}
FP=$HERE/../../libs/tinycc/lib/fp/soft
ITERS=${ITERS:-200}
GF="-mcpu=cortex-m33 -mthumb -mfloat-abi=soft"
CF="-O2 -I$FP/../.. -I$FP/../../../include"

mkdir -p "$OUT/gccobj" "$OUT/tccobj"
for f in fadd fmul fdiv fcmp dadd dmul ddiv dconv dcmp conv conv64; do
    arm-none-eabi-gcc $GF $CF -Wall -Wextra -c "$FP/$f.c" -o "$OUT/gccobj/$f.o"
    "$TCC" $CF -c "$FP/$f.c" -o "$OUT/tccobj/$f.o"
done
for f in f2d_stub fcmp_asm dcmp_asm; do
    arm-none-eabi-gcc $GF $CF -c "$FP/$f.S" -o "$OUT/gccobj/$f.o"
    cp "$OUT/gccobj/$f.o" "$OUT/tccobj/$f.o"
done

# libgcc supplies __aeabi_llsl/llsr, which conv64.c needs and neither
# soft-float build provides.  Identical in every arm.
LG=$(arm-none-eabi-gcc $GF -print-libgcc-file-name)
arm-none-eabi-gcc $GF -O2 -DITERS=$ITERS -c "$HERE/drv.c" -o "$OUT/drv.o"
arm-none-eabi-gcc $GF -c "$HERE/boot.S" -o "$OUT/boot.o"

link() {   # link <name> <dir-for-dadd.o> <dir-for-the-rest>
    OTHERS=$(ls "$3"/*.o | grep -v '/dadd\.o$')
    arm-none-eabi-ld -T "$HERE/link.ld" -o "$OUT/$1.elf" \
        "$OUT/boot.o" "$OUT/drv.o" "$2/dadd.o" $OTHERS "$LG"
}
link gcc    "$OUT/gccobj" "$OUT/gccobj"
link tcc    "$OUT/tccobj" "$OUT/gccobj"    # one object file swapped
link alltcc "$OUT/tccobj" "$OUT/tccobj"

for a in gcc tcc alltcc; do
    qemu-system-arm -machine mps2-an505 -cpu cortex-m33 -kernel "$OUT/$a.elf" \
        -nographic -semihosting -monitor none -serial null \
        -d exec -accel tcg,one-insn-per-tb=on -D "$OUT/exec_$a.log"
    printf '%-8s %s instructions\n' "$a" "$(wc -l < "$OUT/exec_$a.log")"
done

cd "$OUT"
python3 "$HERE/fpcount.py" .
python3 "$HERE/hist.py"   tcc.elf exec_tcc.log
python3 "$HERE/decomp.py" tcc.elf exec_tcc.log "__aeabi_dadd,sfp_round_pack_double" $((ITERS * 5))
python3 "$HERE/decomp.py" gcc.elf exec_gcc.log "__aeabi_dadd" $((ITERS * 5))
