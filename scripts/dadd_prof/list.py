import re,subprocess,sys,collections
elf,log,fn=sys.argv[1],sys.argv[2],sys.argv[3]
dis=subprocess.run(["arm-none-eabi-objdump","-d",elf],capture_output=True,text=True).stdout
pcs=collections.Counter(); rx=re.compile(r"\[[0-9a-f]+/([0-9a-f]{16})/")
for ln in open(log):
    m=rx.search(ln)
    if m: pcs[int(m.group(1),16)]+=1
cur=None; out=[]
for ln in dis.splitlines():
    m=re.match(r"^([0-9a-f]{8}) <(.+)>:",ln)
    if m: cur=m.group(2); continue
    if cur!=fn: continue
    m=re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f ]+?)\s\s+(.*)$",ln)
    if not m: continue
    pc=int(m.group(1),16); c=pcs.get(pc,0)
    out.append(f"{c:6d}  {m.group(1)}: {m.group(2):<12s} {m.group(3)}")
print(f"--- {fn} in {elf}: {len(out)} instructions, {sum(pcs.get(int(l[8:16],16),0) for l in out)} executed")
for l in out: print(l)
