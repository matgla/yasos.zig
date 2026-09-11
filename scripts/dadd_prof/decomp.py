import re,subprocess,sys,collections
elf,log,fns,calls=sys.argv[1],sys.argv[2],set(sys.argv[3].split(",")),int(sys.argv[4])
dis=subprocess.run(["arm-none-eabi-objdump","-d",elf],capture_output=True,text=True).stdout
cur=None; text={}
for ln in dis.splitlines():
    m=re.match(r"^([0-9a-f]{8}) <(.+)>:",ln)
    if m: cur=m.group(2); continue
    m=re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f ]+?)\s\s+(\S+)\s*([^;@]*)",ln)
    if m and cur: text[int(m.group(1),16)]=(cur,m.group(3),m.group(4).strip())
pcs=collections.Counter(); rx=re.compile(r"\[[0-9a-f]+/([0-9a-f]{16})/")
for ln in open(log):
    m=rx.search(ln)
    if m: pcs[int(m.group(1),16)]+=1
def klass(mn,ops):
    if mn in("stmdb","ldmia","ldmia.w","push","pop","bx","bl","blx"): return "call linkage"
    if re.match(r"^(add|sub)",mn) and ops.startswith("sp,"): return "frame setup"
    if re.match(r"^(ldr|str)",mn) and "[sp" in ops: return "stack traffic"
    if re.match(r"^mov(s|\.w)?$",mn) and re.match(r"^\w+, *\w+$",ops) and not re.search(r"#",ops): return "register copy"
    if re.match(r"^(b|b\.n|b\.w)$",mn): return "unconditional branch"
    if re.match(r"^(cmp|cmn|tst|it|ite|itt|cb)",mn) or re.match(r"^b[a-z]{2}",mn): return "compare/branch"
    return "work"
agg=collections.Counter(); tot=0
for pc,c in pcs.items():
    t=text.get(pc)
    if not t or t[0] not in fns: continue
    agg[klass(t[1],t[2])]+=c; tot+=c
print(f"{elf} {','.join(sorted(fns))}: {tot} instr / {calls} calls = {tot/calls:.1f} per call")
for k,v in agg.most_common(): print(f"   {k:22s} {v/calls:7.2f} /call   {100*v/tot:5.1f}%")
