# Non-interactive fault probe: parse the captured UART hardfault diagnostics,
# resolve the faulting PC/LR against symbols loaded at runtime addresses
# (yasld-load already ran), disassemble around the fault, then quit.
python
import re, gdb

LOG = "/tmp/yasos-gdb-debug-uart.log"
try:
    text = open(LOG, "rb").read().decode("utf-8", "replace")
except OSError as e:
    print("fault_probe: cannot read %s: %s" % (LOG, e))
    text = ""

def grab(name):
    m = re.search(name + r"=0x([0-9A-Fa-f]+)", text)
    return int(m.group(1), 16) if m else None

pc   = grab("stacked_pc")
lr   = grab("stacked_lr")
cfsr = grab("CFSR")
hfsr = grab("HFSR")

print("\n=============== FAULT PROBE ===============")
for label in ("CFSR", "HFSR", "stacked_pc", "stacked_lr", "PSP", "PSPLIM"):
    m = re.search(label + r"=0x([0-9A-Fa-f]+)", text)
    if m:
        print("  %-11s = 0x%s" % (label, m.group(1)))

if cfsr is not None:
    bits = []
    if cfsr & (1 << 0):  bits.append("IACCVIOL")
    if cfsr & (1 << 1):  bits.append("DACCVIOL")
    if cfsr & (1 << 16): bits.append("UNDEFINSTR")
    if cfsr & (1 << 17): bits.append("INVSTATE")
    if cfsr & (1 << 18): bits.append("INVPC")
    if cfsr & (1 << 19): bits.append("NOCP")
    if cfsr & (1 << 20): bits.append("STKOF")
    if cfsr & (1 << 24): bits.append("UNALIGNED")
    if cfsr & (1 << 25): bits.append("DIVBYZERO")
    print("  CFSR bits   = %s" % (", ".join(bits) or "(none)"))

def resolve(name, addr):
    if addr is None:
        return
    a = addr & ~1  # clear thumb bit
    print("\n--- %s = 0x%08x ---" % (name, addr))
    for cmd in ("info symbol 0x%x" % a,):
        try:
            gdb.execute(cmd)
        except gdb.error as e:
            print("  (%s)" % e)
    # Disassemble the ENTIRE containing function from live target memory
    # (ground truth) so we can see prologue r7/fp setup + call sequence.
    try:
        gdb.execute("disassemble 0x%x" % a)
    except gdb.error as e:
        print("  disas function: (%s)" % e)
        try:
            gdb.execute("x/24i 0x%x" % (a - 48))
        except gdb.error as e2:
            print("  disas window: (%s)" % e2)

resolve("stacked_pc", pc)
resolve("stacked_lr", lr)
print("=============== END PROBE ===============\n")
end
quit
