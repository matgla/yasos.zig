#!/usr/bin/env bash
#
# Guard against `block_context_switch` coming back.
#
# It was a global `bool` plus a global `i32`, used at 37 sites as if it were
# mutual exclusion. It never was: it stops *this* core rescheduling and does
# nothing whatsoever about another one. Every site is now either a named lock,
# a per-CPU preempt window (`preempt_disable`), or gone because what it guarded
# guards itself.
#
# The plan (docs/smp_plan.md, phase 3) names this grep as the completion test:
# once the last site is converted, delete the alias and stop it being
# reintroduced. Reaching for it again almost always means "I want a lock" --
# see the rank table for which one.
set -euo pipefail

cd "$(dirname "$0")/.."

# Prose may discuss it; code may not call it.
if hits=$(grep -rn --include=*.zig --include=*.S \
        -E '(block|unblock)_context_switch *\(' source/ \
        | grep -v '^source/kernel/interrupts/system_call.zig:.*//' \
        | grep -vE '^[^:]+:[0-9]+: *//' \
        | grep -v 'process_unblock_context_switch' \
    ); then
    echo "::error::block_context_switch is back -- it is not a lock, see docs/smp_plan.md phase 3"
    echo "$hits"
    exit 1
fi

echo "no block_context_switch call sites"
