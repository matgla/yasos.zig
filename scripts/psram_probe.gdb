set pagination off
set confirm off
set width 0
set height 0
python
import re, gdb
text = open("/tmp/yasos-gdb-debug-uart.log","rb").read().decode("utf-8","replace")
def grab(p):
    m=re.search(p,text); return int(m.group(1),16) if m else None
psp=grab(r"PSP=0x([0-9A-Fa-f]+)"); pc=grab(r"stacked_pc=0x([0-9A-Fa-f]+)"); r0=grab(r"stacked r0=0x([0-9A-Fa-f]+)")
inf=gdb.selected_inferior()
def rd(a):
    try: return int.from_bytes(inf.read_memory(a&0xffffffff,4).tobytes(),"little")
    except gdb.MemoryError: return None
print("\n===== PSRAM READABILITY PROBE =====")
print("log: PSP=0x%08x stacked_pc=0x%08x stacked_r0=0x%08x"%(psp or 0,pc or 0,r0 or 0))
print("exception frame at PSP (should be r0,r1,r2,r3,r12,lr,pc,xpsr):")
for i in range(8):
    v=rd(psp+i*4); names=["r0","r1","r2","r3","r12","lr","pc","xpsr"]
    print("  PSP+0x%02x (%-4s) = %s"%(i*4, names[i], "0x%08x"%v if v is not None else "<unreadable>"))
print("does PSP+0x18 == logged stacked_pc? -> %s" % (rd(psp+0x18)==pc))
print("--- live registers (panic handler) ---")
for r in ("sp","psp","msp","pc","lr"):
    try: print("  $%s = %s"%(r, gdb.execute("p/x $%s"%r,to_string=True).strip()))
    except Exception as e: print("  $%s err %s"%(r,e))
# scan a window of PSRAM for ANY nonzero (is the QSPI window alive at all?)
nz=0
for i in range(256):
    v=rd(psp+i*4)
    if v: nz+=1
print("nonzero words in PSP..PSP+1KB: %d/256"%nz)
print("===================================\n")
end
quit
