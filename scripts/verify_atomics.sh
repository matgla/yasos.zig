#!/usr/bin/env bash
#
# Assert that the kernel's atomics really are atomic on the target.
#
# The failure this guards against is silent by construction. Cortex-M33 has no
# LDREXD, so a 64-bit `@atomicRmw` does not fail to compile -- it lowers to an
# `__atomic_*` libcall out of compiler-rt that takes a global lock table. That
# is not lock-free and not safe from an exception handler, and nothing in the
# build says so. `kernel.sync.Atomic` refuses those widths at comptime; this is
# the belt to that pair of braces, because a `std.atomic.Value` used directly,
# or a wide RMW introduced inside a dependency, bypasses the comptime check
# entirely.
#
# It also proves the *positive* half, which matters just as much: that the
# atomics we do have lowered to real exclusives rather than to something the
# optimiser folded away. This Zig is known to mishandle direct volatile field
# access (see hal/.../uart.zig), so "it compiled" is not evidence.
#
# Usage: scripts/verify_atomics.sh [path/to/yasos_kernel]

set -euo pipefail

ELF="${1:-zig-out/bin/yasos_kernel}"
OBJDUMP="${OBJDUMP:-arm-none-eabi-objdump}"
NM="${NM:-arm-none-eabi-nm}"

if [ ! -f "$ELF" ]; then
    echo "::error::$ELF missing - did the kernel build fail?"
    exit 1
fi

if ! command -v "$OBJDUMP" >/dev/null 2>&1; then
    echo "::error::$OBJDUMP not found"
    exit 1
fi

fail=0

DISASM="$(mktemp)"
trap 'rm -f "$DISASM"' EXIT
"$OBJDUMP" -d "$ELF" > "$DISASM"

count_insn() {
    # The trailing alternation matters: operand-less mnemonics (clrex, sev, wfe)
    # end the line, so a pattern requiring trailing whitespace silently counts
    # zero of them and the gate passes for the wrong reason.
    grep -cE "[[:space:]]$1(\.[nw])?([[:space:]]|\$)" "$DISASM" || true
}

# --- The atomics lowered to exclusives -------------------------------------
#
# `SpinLock.lock` is a `@cmpxchgWeak(.acquire, .monotonic)`: load-acquire
# exclusive, then a plain store-exclusive (the acquire is already on the load,
# so LLVM has no reason to emit the release form here).
ldaex=$(count_insn ldaex)
ldrex=$(count_insn ldrex)
strex=$(count_insn strex)
stlex=$(count_insn stlex)

if [ $((ldaex + ldrex)) -eq 0 ]; then
    echo "::error::no exclusive loads in $ELF - the kernel's atomics did not lower to LDAEX/LDREX"
    fail=1
fi
if [ $((strex + stlex)) -eq 0 ]; then
    echo "::error::no exclusive stores in $ELF - the kernel's atomics did not lower to STREX/STLEX"
    fail=1
fi

# --- The release store ------------------------------------------------------
#
# `SpinLock.unlock` is an `@atomicStore(.release)`, which must be STL. A plain
# STR here would let writes made under the lock become visible to the next
# holder after the release.
stl=$(count_insn stl)
if [ "$stl" -eq 0 ]; then
    echo "::error::no store-release (STL) in $ELF - SpinLock.unlock lost its release ordering"
    fail=1
fi

# --- The reservation is dropped on a context switch -------------------------
clrex=$(count_insn clrex)
if [ "$clrex" -eq 0 ]; then
    echo "::error::no CLREX in $ELF - the context-switch store path is not clearing the exclusive monitor"
    fail=1
fi

# --- Nothing fell back to a libcall -----------------------------------------
if command -v "$NM" >/dev/null 2>&1; then
    if libcalls=$("$NM" "$ELF" | grep -E '__atomic_|__sync_' || true); [ -n "$libcalls" ]; then
        echo "::error::non-lock-free atomic libcalls linked into $ELF:"
        echo "$libcalls"
        fail=1
    fi
fi

echo "atomics: ldaex=$ldaex ldrex=$ldrex strex=$strex stlex=$stlex stl=$stl clrex=$clrex, no __atomic_/__sync_ libcalls"

exit "$fail"
