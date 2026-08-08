# Post-mortem read of the PCH auto entries from retained PSRAM.
# s1 (TCCState*) is a deterministic large/mmap alloc at 0x1106e000;
# auto_pch_entries is at s1+0x2534, nb_auto_pch_entries at s1+0x2538.
set pagination off
set confirm off
python
import gdb
inf = gdb.selected_inferior()
def rd(a):
    try:
        return int.from_bytes(inf.read_memory(a, 4).tobytes(), "little")
    except gdb.MemoryError:
        return None
s1 = 0x1106e000
arr = rd(s1 + 0x2534)
nb  = rd(s1 + 0x2538)
print("[PCHREAD] s1=0x%08x auto_pch_entries=%s nb=%s" % (
    s1, ("0x%08x" % arr) if arr is not None else "?", nb))
if arr and 0 <= (nb or -1) < 16:
    for i in range(nb):
        base = arr + i*12
        hp = rd(base); pn = rd(base+4); dis = rd(base+8)
        print("[PCHREAD]  [%d] @0x%08x hp=0x%08x pn=0x%08x dis=%s" % (
            i, base, hp or 0, pn or 0, dis))
    print("[PCHREAD] WATCH addresses: entry[0].pch_name=0x%08x entry[0].header_path=0x%08x" % (arr+4, arr))
end
quit
source