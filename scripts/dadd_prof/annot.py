import re,subprocess,sys,collections
elf,log=sys.argv[1],sys.argv[2]; fns=set(sys.argv[3].split(","))
dis=subprocess.run(["arm-none-eabi-objdump","-d",elf],capture_output=True,text=True).stdout
cur=None; text={}
for ln in dis.splitlines():
    m=re.match(r"^([0-9a-f]{8}) <(.+)>:",ln)
    if m: cur=m.group(2); continue
    m=re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f ]+?)\s\s+(\S+)\s*(.*)$",ln)
    if m and cur: text[int(m.group(1),16)]=(cur,m.group(3),m.group(4),len(m.group(2).replace(" ",""))//2)
pcs=collections.Counter(); rx=re.compile(r"\[[0-9a-f]+/([0-9a-f]{16})/")
for ln in open(log):
    m=rx.search(ln)
    if m: pcs[int(m.group(1),16)]+=1
CLASS=[("memory",r"^(ldr|str|ldm|stm|push|pop|vldr|vstr)"),
       ("move",r"^(mov|mvn)"),
       ("branch/cmp",r"^(b|bl|bx|blx|cmp|cmn|tst|it|cb)"),
       ("shift",r"^(lsl|lsr|asr|ror|rrx)"),
       ("arith/logic",r"^(add|adc|sub|sbc|rsb|and|orr|eor|bic|mul|umull|clz|ubfx|bfi|uxt|sxt|neg|rbit)")]
def cls(mn):
    for name,rx2 in CLASS:
        if re.match(rx2,mn): return name
    return "other"
agg=collections.Counter(); mn=collections.Counter(); tot=0
for pc,c in pcs.items():
    t=text.get(pc)
    if not t or t[0] not in fns: continue
    agg[cls(t[1])]+=c; mn[t[1]]+=c; tot+=c
print(f"executed in {','.join(sorted(fns))}: {tot}")
for k,v in agg.most_common(): print(f"  {k:14s} {v:8d}  {100*v/tot:5.1f}%")
print("  top mnemonics:", ", ".join(f"{k} {v}" for k,v in mn.most_common(12)))
