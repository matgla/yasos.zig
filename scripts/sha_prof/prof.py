"""Per-function totals, sha_transform's dynamic mnemonic mix, and every PC in
sha_transform executed >= 1000 times (the loop bodies), for gcc.elf and tcc.elf
+ exec_*.log in the current directory."""
import re, subprocess, collections
def prof(a):
    dis = subprocess.run(["arm-none-eabi-objdump", "-d", f"{a}.elf"], capture_output=True, text=True).stdout
    cur = None; text = {}
    for ln in dis.splitlines():
        m = re.match(r"^([0-9a-f]{8}) <(.+)>:", ln)
        if m: cur = m.group(2); continue
        m = re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f ]+?)\s\s+(\S+)\s*([^;@]*)", ln)
        if m and cur: text[int(m.group(1), 16)] = (cur, m.group(3), m.group(4).strip())
    pcs = collections.Counter(); rx = re.compile(r"\[[0-9a-f]+/([0-9a-f]{16})/")
    for ln in open(f"exec_{a}.log"):
        m = rx.search(ln)
        if m: pcs[int(m.group(1), 16)] += 1
    fn = collections.Counter()
    for pc, c in pcs.items():
        if pc in text: fn[text[pc][0]] += c
    return text, pcs, fn
res = {a: prof(a) for a in ("gcc", "tcc")}
print("\nper function (instructions executed):")
for n in sorted(set(res["gcc"][2]) | set(res["tcc"][2]), key=lambda n: -(res["tcc"][2][n] + res["gcc"][2][n]))[:8]:
    g = res["gcc"][2][n]; t = res["tcc"][2][n]
    print("  %-22s tcc %9d  gcc %9d  %s" % (n, t, g, ("%.2fx" % (t / g)) if g else "-"))
mix = {}
for a in ("gcc", "tcc"):
    text, pcs, _ = res[a]; c = collections.Counter()
    for pc, n in pcs.items():
        if pc in text and text[pc][0] == "sha_transform": c[text[pc][1]] += n
    mix[a] = c
print("\nsha_transform mnemonic mix, dynamic (tcc | gcc):")
for k in sorted(set(mix["tcc"]) | set(mix["gcc"]), key=lambda k: -(mix["tcc"][k] + mix["gcc"][k]))[:20]:
    print("  %-10s tcc %8d   gcc %8d   %+d" % (k, mix["tcc"][k], mix["gcc"][k], mix["tcc"][k] - mix["gcc"][k]))
for a in ("tcc", "gcc"):
    print("\n%s sha_transform, PCs executed >= 1000 times, in address order:" % a)
    text, pcs, _ = res[a]
    for pc in sorted(p for p in pcs if p in text and text[p][0] == "sha_transform" and pcs[p] >= 1000):
        print("  %6x %7d  %-8s %s" % (pc, pcs[pc], text[pc][1], text[pc][2]))
