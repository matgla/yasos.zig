# Postmortem of the 02_printf LICM crash (tcc_ir_opt_licm_ex).
# Board halted (NO reset) in the panic loop so PSRAM heap is live. Symbols
# loaded by yasld_gdb.py at runtime addresses. Frame layout (stage2, from the
# crash-site disasm of the is_invariant[ii] loop):
#   cfg = *(PSP+124)   blocks = *cfg   num_blocks = *(cfg+4)
#   bi  = *(PSP+72)    ii = *(PSP+68)  is_invariant = *(PSP+76)
# Goal: is num_blocks corrupted (bi OOB) or is the blocks[] array smashed?
set pagination off
set confirm off
set width 0
set height 0

python
import re, gdb

LOG = "/tmp/yasos-gdb-debug-uart.log"
try:
    text = open(LOG, "rb").read().decode("utf-8", "replace")
except OSError:
    text = ""

def grab(pat):
    m = re.search(pat, text)
    return int(m.group(1), 16) if m else None

psp = grab(r"PSP=0x([0-9A-Fa-f]+)")
pc  = grab(r"stacked_pc=0x([0-9A-Fa-f]+)")
r0  = grab(r"stacked r0=0x([0-9A-Fa-f]+)")
excret = grab(r"EXC_RETURN=0x([0-9A-Fa-f]+)")
inf = gdb.selected_inferior()

def rd(a):
    return int.from_bytes(inf.read_memory(a & 0xffffffff, 4).tobytes(), "little")

# The reported PSP points at the stacked exception frame, NOT the faulting
# function's sp. Frame size: standard=0x20, FP-extended (EXC_RETURN bit4==0)=0x68;
# +4 if xPSR bit9 (stack-align) was set. function_sp = PSP + frame_size.
fp_frame = (excret is not None) and ((excret & 0x10) == 0)
xpsr = grab(r"psr=0x([0-9A-Fa-f]+)")
pad = 4 if (xpsr is not None and (xpsr & 0x200)) else 0
base_fsize = 0x68 if fp_frame else 0x20
# Confirm by locating the stacked PC (at frame off +0x18) just below PSP.
fsize = base_fsize
try:
    for cand in (0x20, 0x68):
        if pc is not None and (rd(psp + 0x18) == pc):
            break
except Exception:
    pass
fsp = psp + fsize + pad
print("  EXC_RETURN=0x%08x fp_frame=%s frame_size=0x%x pad=%d -> function_sp=0x%08x"
      % (excret or 0, fp_frame, fsize, pad, fsp))

print("\n================= LICM POSTMORTEM =================")
print("  PSP=0x%08x  stacked_pc=0x%08x  r0=0x%08x" % (psp or 0, pc or 0, r0 or 0))
try:
    print("  pc symbol: " + gdb.execute("info symbol 0x%x" % (pc & ~1), to_string=True).strip())
except Exception as e:
    print("  pc symbol: (%s)" % e)

if not psp:
    print("  !! no PSP in log");
else:
    # Cross-check: ii should be the garbage (r0=is_invariant+ii, BFAR=r0).
    for probe in (fsp, psp+0x20, psp+0x68, psp):
        c = rd(probe+124)
        if 0x11000000 <= c < 0x11800000:
            fsp = probe; break
    print("  (using function_sp=0x%08x: cfg looks like heap)" % fsp)
    cfg = rd(fsp+124)
    bi  = rd(fsp+72)
    ii  = rd(fsp+68)
    isinv = rd(fsp+76)
    print("\n  --- frame locals (sp=function_sp) ---")
    print("  cfg          = 0x%08x   [PSP+124]" % cfg)
    print("  bi           = 0x%08x (%d) [PSP+72]" % (bi, bi if bi < 0x80000000 else bi-(1<<32)))
    print("  ii           = 0x%08x (%d) [PSP+68]" % (ii, ii if ii < 0x80000000 else ii-(1<<32)))
    print("  is_invariant = 0x%08x   [PSP+76]" % isinv)
    try:
        blocks = rd(cfg)
        nb     = rd(cfg+4)
        cap    = rd(cfg+8)
        print("\n  --- *cfg (IRCFG) ---")
        print("  cfg->blocks      = 0x%08x" % blocks)
        print("  cfg->num_blocks  = 0x%08x (%d)" % (nb, nb if nb<0x80000000 else nb-(1<<32)))
        print("  cfg->capacity    = 0x%08x (%d)" % (cap, cap if cap<0x80000000 else cap-(1<<32)))
        oob = (bi >= nb) if nb < 0x80000000 else True
        print("  >> bi (%d) %s num_blocks (%d)" % (bi, ">= (OOB!)" if oob else "<", nb if nb<0x80000000 else -1))
        # IRBasicBlock = 64 bytes; start_idx@0 end_idx@4.
        print("\n  --- blocks[] entries (start_idx,end_idx) ---")
        n_show = min(nb, 24) if nb < 0x80000000 else 8
        for k in range(n_show):
            ba = blocks + k*64
            try:
                s = rd(ba); e = rd(ba+4)
                tag = "  <== blocks[bi]" if k == bi else ""
                print("   blocks[%2d] @0x%08x  start=0x%08x end=0x%08x%s" % (k, ba, s, e, tag))
            except gdb.MemoryError:
                print("   blocks[%2d] @0x%08x  <unreadable>" % (k, ba)); break
        # If bi is OOB, dump what blocks[bi] actually points at (the garbage source).
        if oob and bi < 0x40000:
            ba = blocks + bi*64
            print("\n  --- blocks[bi=%d] @0x%08x (OOB read source of garbage ii=0x%08x) ---" % (bi, ba, ii))
            for off in range(0, 32, 4):
                try: print("    +0x%02x: 0x%08x" % (off, rd(ba+off)))
                except gdb.MemoryError: print("    +0x%02x: <unreadable>" % off); break
        # Heap neighborhood around the blocks allocation header (libc mhdr is 8 bytes before).
        print("\n  --- heap words around blocks alloc (0x%08x) ---" % blocks)
        for off in range(-16, 48, 4):
            try:
                v = rd(blocks+off)
                print("    [blocks%+d] 0x%08x = 0x%08x" % (off, blocks+off, v))
            except gdb.MemoryError:
                print("    [blocks%+d] <unreadable>" % off)
    except gdb.MemoryError as e:
        print("  !! cfg unreadable (cfg itself smashed?): %s" % e)
print("==================================================\n")
end
quit
