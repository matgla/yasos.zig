# Bad-free backtrace probe.
#
# The HardFault is `free(v)` with v = a non-heap garbage value (e.g. 0x2F9),
# called from default_reallocator (libtcc.c:134, i.e. tcc_free(garbage)).
# The UART fault dump only gives stacked_pc/lr — NOT the caller chain, so we
# can't see WHICH tcc_free() passed the bad pointer. This probe recovers it.
#
# Use it with the board HALTED AT THE FAULT (in the hardfault/panic handler),
# with the per-module symbols already added at their runtime load addresses
# (same setup fault_probe.gdb relies on). It walks the faulting thread's PSP
# stack and symbolizes every word that looks like a tcc/libc return address,
# reconstructing the call chain that led to the bad free.
set pagination off
set confirm off
set width 0

python
import re, gdb

LOG = "/tmp/yasos-gdb-debug-uart.log"
try:
    text = open(LOG, "rb").read().decode("utf-8", "replace")
except OSError:
    text = ""

# Runtime .text ranges parsed from the yasld load lines in the captured UART
# log, e.g. ".text loaded at 0x101e8740, size: 1cc9b8 for: armv8m-tcc".
# These shift between builds, so always read them from this run's log.
ranges = []
for m in re.finditer(r"\.text\s+loaded at 0x([0-9A-Fa-f]+),\s*size:\s*([0-9A-Fa-f]+)\s+for:\s*(\S+)", text):
    lo = int(m.group(1), 16); sz = int(m.group(2), 16)
    if sz:
        ranges.append((lo, lo + sz, m.group(3)))
print("  module .text ranges from log:")
for lo, hi, nm in ranges:
    print("    0x%08x..0x%08x  %s" % (lo, hi, nm))

def in_code(v):
    return any(lo <= v < hi for lo, hi, _ in ranges)

# In the --gdb-debug flow the board was reset-halted after the fault, so the
# live $psp is the reset value — but PSRAM still holds the faulting thread's
# stack. Prefer the PSP captured in the UART dump; fall back to live $psp.
psp = None
m = re.search(r"PSP=0x([0-9A-Fa-f]+)", text)
if m:
    psp = int(m.group(1), 16)
if not psp:
    try:
        psp = int(gdb.parse_and_eval("$psp")) & 0xffffffff
    except gdb.error:
        pass

print("\n=============== BAD-FREE STACK WALK ===============")
print("  PSP = 0x%08x" % (psp or 0))
if not psp:
    print("  no PSP available — halt the target at the fault first")
else:
    inf = gdb.selected_inferior()
    NWORDS = 768
    shown = 0
    for i in range(NWORDS):
        a = psp + i*4
        try:
            raw = inf.read_memory(a, 4)
        except gdb.MemoryError:
            break
        v = int.from_bytes(raw.tobytes(), "little")
        # Return addresses on the stack have the thumb bit set; the call target
        # is v & ~1. Only show words that land inside known code.
        if (v & 1) and in_code(v & ~1):
            try:
                sym = gdb.execute("info symbol 0x%x" % (v & ~1), to_string=True).strip()
            except gdb.error as e:
                sym = "(%s)" % e
            print("  [sp+0x%04x] 0x%08x  %s" % (i*4, v, sym))
            shown += 1
            if shown >= 40:
                print("  ... (stopping after 40 frames)")
                break
    if not shown:
        print("  no code pointers found in %d words above PSP" % NWORDS)

print("\n--- faulting free() arg should be the freed pointer (v) ---")
print("  from the dump: r4=v, r5=v-8 (mhdr). A small value (e.g. 0x2F9) is the")
print("  miscompiled non-pointer passed to tcc_free().")
end
quit
