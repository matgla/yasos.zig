import re,subprocess,collections,sys
def prof(elf,log,fns):
    dis=subprocess.run(["arm-none-eabi-objdump","-d",elf],capture_output=True,text=True).stdout
    cur=None;text={}
    for ln in dis.splitlines():
        m=re.match(r"^([0-9a-f]{8}) <(.+)>:",ln)
        if m: cur=m.group(2);continue
        m=re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f ]+?)\s\s+(\S+)\s*([^;@]*)",ln)
        if m and cur: text[int(m.group(1),16)]=(cur,m.group(3),m.group(4).strip())
    pcs=collections.Counter();rx=re.compile(r"\[[0-9a-f]+/([0-9a-f]{16})/")
    for ln in open(log):
        m=rx.search(ln)
        if m: pcs[int(m.group(1),16)]+=1
    c=collections.Counter()
    for pc,n in pcs.items():
        t=text.get(pc)
        if t and t[0] in fns: c[re.sub(r"\.(n|w)$","",t[1])]+=n
    return c
t=prof("dadd_tcc.elf","exec_tcc.log",{"__aeabi_dadd","sfp_round_pack_double"})
g=prof("dadd_gcc.elf","exec_gcc.log",{"__aeabi_dadd"})
keys=set(t)|set(g)
rows=sorted(keys,key=lambda k:-(t[k]-g[k]))
print(f"{'mnemonic':12s} {'tcc/call':>9s} {'gcc/call':>9s} {'delta':>8s}")
for k in rows:
    d=(t[k]-g[k])/1000
    if abs(d)>=0.4: print(f"{k:12s} {t[k]/1000:9.2f} {g[k]/1000:9.2f} {d:+8.2f}")
