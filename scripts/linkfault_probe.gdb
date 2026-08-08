# Linker section-corruption fault probe.
#
# Crash class: CFSR=0x00008200 (PRECISERR+BFARVALID), wild BFAR/MMFAR (e.g.
# 0x3F6D865C), stacked_pc inside armv8m-tcc .text. Suspected section_ptr_add /
# section_realloc returning `sec->data + off` with sec->data already corrupted
# upstream (section setup). This probe: (1) symbolizes + disassembles the
# faulting PC, (2) walks the faulting thread's PSP stack to recover the caller
# chain that reached the bad memory access.
#
# Use with the board halted after the fault and per-module symbols already added
# at runtime load addresses (the --gdb-debug flow does this).
set pagination off
set confirm off
set width 0

python
import re, gdb

LOG = "/tmp/yasos-gdb-debug-uart.log"
try:
    text = open(LOG, "rb").read().decode("utf-8", "replace")
except OSError as e:
    print("linkfault_probe: cannot read %s: %s" % (LOG, e))
    text = ""

def grab(name):
    m = re.search(name + r"=0x([0-9A-Fa-f]+)", text)
    return int(m.group(1), 16) if m else None

print("\n=============== LINK-FAULT PROBE ===============")
for label in ("CFSR", "HFSR", "MMFAR", "BFAR", "stacked_pc", "stacked_lr", "PSP", "PSPLIM", "r4", "r5", "r6", "r7"):
    v = grab(label)
    if v is not None:
        print("  %-11s = 0x%08x" % (label, v))

cfsr = grab("CFSR")
if cfsr is not None:
    bits = []
    names = {0:"IACCVIOL",1:"DACCVIOL",3:"MUNSTKERR",4:"MSTKERR",7:"MMARVALID",
             8:"IBUSERR",9:"PRECISERR",10:"IMPRECISERR",11:"UNSTKERR",12:"STKERR",
             15:"BFARVALID",16:"UNDEFINSTR",17:"INVSTATE",18:"INVPC",19:"NOCP",
             20:"STKOF",24:"UNALIGNED",25:"DIVBYZERO"}
    for b,n in names.items():
        if cfsr & (1<<b): bits.append(n)
    print("  CFSR bits   = %s" % (", ".join(bits) or "(none)"))

# Runtime .text ranges from the yasld load lines.
ranges = []
for m in re.finditer(r"\.text\s+loaded at 0x([0-9A-Fa-f]+),\s*size:\s*([0-9A-Fa-f]+)\s+for:\s*(\S+)", text):
    lo = int(m.group(1), 16); sz = int(m.group(2), 16)
    if sz:
        ranges.append((lo, lo + sz, m.group(3)))
print("\n  module .text ranges from log:")
for lo, hi, nm in ranges:
    print("    0x%08x..0x%08x  %s" % (lo, hi, nm))

def in_code(v):
    return any(lo <= v < hi for lo, hi, _ in ranges)

def resolve(name, addr):
    if addr is None:
        return
    a = addr & ~1
    print("\n--- %s = 0x%08x ---" % (name, addr))
    try:
        gdb.execute("info symbol 0x%x" % a)
    except gdb.error as e:
        print("  (%s)" % e)
    try:
        gdb.execute("disassemble 0x%x" % a)
    except gdb.error as e:
        print("  disas function: (%s)" % e)
        try:
            gdb.execute("x/24i 0x%x" % (a - 48))
        except gdb.error as e2:
            print("  disas window: (%s)" % e2)

resolve("stacked_pc", grab("stacked_pc"))
resolve("stacked_lr", grab("stacked_lr"))

# Stack walk for the caller chain.
psp = grab("PSP")
if not psp:
    try:
        psp = int(gdb.parse_and_eval("$psp")) & 0xffffffff
    except gdb.error:
        psp = None
print("\n=============== PSP STACK WALK ===============")
print("  PSP = 0x%08x" % (psp or 0))
if psp:
    inf = gdb.selected_inferior()
    shown = 0
    for i in range(768):
        a = psp + i*4
        try:
            raw = inf.read_memory(a, 4)
        except gdb.MemoryError:
            break
        v = int.from_bytes(raw.tobytes(), "little")
        if (v & 1) and in_code(v & ~1):
            try:
                sym = gdb.execute("info symbol 0x%x" % (v & ~1), to_string=True).strip()
            except gdb.error as e:
                sym = "(%s)" % e
            print("  [sp+0x%04x] 0x%08x  %s" % (i*4, v, sym))
            shown += 1
            if shown >= 50:
                print("  ... (stopping after 50 frames)")
                break
    if not shown:
        print("  no code pointers found above PSP")
print("=============== END PROBE ===============\n")
end
quit
