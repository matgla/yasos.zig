import re, subprocess, sys, collections

def syms(elf):
    out = subprocess.run(["arm-none-eabi-nm","-nS",elf],capture_output=True,text=True).stdout
    s=[]
    for ln in out.splitlines():
        p=ln.split()
        if len(p)==4:
            s.append((int(p[0],16),int(p[1],16),p[3]))
    return s

def lookup(s,pc):
    lo,hi=0,len(s)-1; best=None
    for a,sz,n in s:
        if a<=pc<a+sz: return n
    return None

def load(log):
    pcs=collections.Counter()
    rx=re.compile(r"\[[0-9a-f]+/([0-9a-f]{16})/")
    for ln in open(log):
        m=rx.search(ln)
        if m: pcs[int(m.group(1),16)]+=1
    return pcs

elf,log=sys.argv[1],sys.argv[2]
s=syms(elf); pcs=load(log)
per=collections.Counter(); entries=collections.Counter()
starts={a:n for a,sz,n in s}
total=0
for pc,c in pcs.items():
    n=lookup(s,pc) or "??"
    per[n]+=c; total+=c
    if pc in starts: entries[starts[pc]]+=c
print(f"total instructions {total}")
print(f"{'function':32s} {'instr':>9s} {'calls':>7s} {'i/call':>8s}  {'%':>5s}")
for n,c in per.most_common(14):
    e=entries.get(n,0)
    print(f"{n:32s} {c:9d} {e:7d} {c/e if e else 0:8.1f}  {100*c/total:5.1f}")
