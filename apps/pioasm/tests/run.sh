#!/bin/sh
# Regression test: run pioasm over tests/*.pio and compare with what the Pico
# SDK's C++ pioasm (hal/libs/pico-sdk/tools/pioasm) wrote for the same input:
#
#   NAME.h       pioasm -o c-sdk NAME.pio
#   NAME.hex     pioasm -o hex NAME.pio
#   NAME.v1.h    pioasm -o c-sdk -v 1 NAME.pio
#   NAME.v1.hex  pioasm -o hex -v 1 NAME.pio
#   err_*.pio    must fail and write nothing to stdout
#
# usage: tests/run.sh [pioasm]   (default: build/host/pioasm)

cd "$(dirname "$0")" || exit 1
PIOASM=${1:-../build/host/pioasm}
case $PIOASM in /*) ;; *) PIOASM=$PWD/$PIOASM ;; esac
out=${TMPDIR:-/tmp}/pioasm-test.$$
pass=0
fail=0

check() { # expected-file args...
    exp=$1
    shift
    if "$PIOASM" "$@" > "$out" 2>/dev/null && cmp -s "$exp" "$out"; then
        pass=$((pass + 1))
    else
        echo "FAIL: pioasm $* (expected $exp)"
        diff "$exp" "$out" | head -20
        fail=$((fail + 1))
    fi
}

for exp in *.h *.hex; do
    case $exp in
    *.v1.h) check "$exp" -o c-sdk -v 1 "${exp%.v1.h}.pio" ;;
    *.v1.hex) check "$exp" -o hex -v 1 "${exp%.v1.hex}.pio" ;;
    *.h) check "$exp" -o c-sdk "${exp%.h}.pio" ;;
    *.hex) check "$exp" -o hex "${exp%.hex}.pio" ;;
    esac
done

for src in err_*.pio; do
    if "$PIOASM" "$src" > "$out" 2>/dev/null || [ -s "$out" ]; then
        echo "FAIL: pioasm $src should fail with no output"
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done

rm -f "$out"
echo "pioasm tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
