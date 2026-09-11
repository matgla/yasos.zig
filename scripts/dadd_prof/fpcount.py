"""Instructions executed inside the floating-point routines, per arm.

The whole-program count is not the number to quote: the boot code's `.data`
copy loop runs a different number of times in each arm because `.data` differs
with what got linked, which moves the total by a few instructions and moves the
gap by the same few.  Everything the comparison is about is inside libsoftfp,
so count that and the three arms are exactly comparable.

    python3 fpcount.py build
"""
import collections
import re
import subprocess
import sys

NOT_FP = {"Reset_Handler", "Default_Handler", "main", "bench_double_add"}
ARMS = [("all gcc's", "gcc"), ("one file swapped", "tcc"), ("all tcc's", "alltcc")]
TRACE = re.compile(r"^Trace .*\[[0-9a-f]+/([0-9a-f]{16})/")


def symbols(elf):
    out = subprocess.run(["arm-none-eabi-nm", "-nS", elf],
                         capture_output=True, text=True).stdout
    return [(int(p[0], 16), int(p[1], 16), p[3])
            for p in (line.split() for line in out.splitlines()) if len(p) == 4]


def fp_instructions(elf, log):
    syms = symbols(elf)
    pcs = collections.Counter()
    for line in open(log):
        m = TRACE.match(line)
        if m:
            pcs[int(m.group(1), 16)] += 1
    total = 0
    for pc, n in pcs.items():
        name = next((s for a, size, s in syms if a <= pc < a + size), None)
        if name and name not in NOT_FP:
            total += n
    return total


out = sys.argv[1] if len(sys.argv) > 1 else "build"
counts = {}
for label, arm in ARMS:
    counts[arm] = fp_instructions(f"{out}/{arm}.elf", f"{out}/exec_{arm}.log")
    print(f"{label:20s} {counts[arm]:9,d}")

dadd = counts["tcc"] - counts["gcc"]
whole = counts["alltcc"] - counts["gcc"]
print(f"\ndadd alone      +{dadd:,}\nwhole library   +{whole:,}"
      f"\ndadd's share    {100 * dadd / whole:.1f}%")
