#!/usr/bin/env python3
"""AREA 4: empirical YAFF relocation inventory.

Data segment layout (from tccyaff.c): [rodata | data | bss], rodata at offset 0.
A data relocation's `.to` field is the byte offset (within the data segment)
that gets PATCHED. If .to < rodata_size it lands in rodata -> NOT shareable.
"""
import struct, sys

# --- current 88-byte YaffHeader field offsets (verified against tccyaff.h) ---
H = {
    'code_length': 8, 'init_length': 12, 'data_length': 16, 'bss_length': 20,
    'symbol_table_relocations_amount': 36, 'local_relocations_amount': 38,
    'data_relocations_amount': 40, 'copy_relocations_amount': 42,
    'got_length': 48, 'got_plt_length': 52, 'plt_length': 56,
    'relocations_offset': 64,
}
SEC = ["CODE", "DATA", "INIT", "UNK"]

def u32(d, o): return struct.unpack_from("<I", d, o)[0]
def u16(d, o): return struct.unpack_from("<H", d, o)[0]

def analyze(path, rodata_size):
    d = open(path, "rb").read()
    code_length = u32(d, H['code_length'])
    data_length = u32(d, H['data_length'])
    bss_length  = u32(d, H['bss_length'])
    got_length  = u32(d, H['got_length'])
    plt_length  = u32(d, H['plt_length'])
    sym_amt   = u16(d, H['symbol_table_relocations_amount'])
    local_amt = u16(d, H['local_relocations_amount'])
    data_amt  = u16(d, H['data_relocations_amount'])
    copy_amt  = u16(d, H['copy_relocations_amount'])
    reloc_off = u16(d, H['relocations_offset'])

    print(f"=== {path} ===")
    print(f"file_size           = {len(d)}")
    print(f"code_length         = {code_length} (0x{code_length:x})")
    print(f"data_length(YAFF)   = {data_length} (0x{data_length:x})  [= rodata+data]")
    print(f"bss_length          = {bss_length} (0x{bss_length:x})")
    print(f"got_length          = {got_length}  plt_length={plt_length}")
    print(f"rodata_size(ELF)    = {rodata_size} (0x{rodata_size:x})")
    print(f"-> data(.data) part = {data_length - rodata_size} (0x{data_length - rodata_size:x})")
    print(f"sym_relocs={sym_amt} local_relocs={local_amt} data_relocs={data_amt} copy_relocs={copy_amt}")
    print(f"relocations_offset  = 0x{reloc_off:x}")

    # ordering on disk: sym_table | local | data | copy  (each 8 bytes, copy=12)
    sym_start   = reloc_off
    local_start = sym_start + sym_amt * 8
    data_start  = local_start + local_amt * 8
    copy_start  = data_start + data_amt * 8

    # ---- DATA RELOCATIONS: .to = patched byte offset within data segment ----
    to_rodata = []   # offsets that get patched, landing INSIDE rodata
    to_data   = 0
    to_bss    = 0
    to_other  = 0
    target_sec = {0:0,1:0,2:0,3:0}  # which section the .from points TO
    pos = data_start
    for i in range(data_amt):
        to_val = u32(d, pos)
        w1 = u32(d, pos + 4)
        section = w1 & 0x3
        pos += 8
        target_sec[section] += 1
        if to_val < rodata_size:
            to_rodata.append(to_val)
        elif to_val < data_length:
            to_data += 1
        elif to_val < data_length + bss_length:
            to_bss += 1
        else:
            to_other += 1

    print(f"\n--- DATA RELOCATIONS ({data_amt}) classified by PATCH location (.to) ---")
    print(f"  patch lands in RODATA [0,{rodata_size}) : {len(to_rodata)}")
    print(f"  patch lands in DATA   [{rodata_size},{data_length}): {to_data}")
    print(f"  patch lands in BSS    [{data_length},{data_length+bss_length}): {to_bss}")
    print(f"  patch lands OTHER (>=data+bss, e.g GOT) : {to_other}")
    print(f"  (.from TARGET section: CODE={target_sec[0]} DATA={target_sec[1]} "
          f"INIT={target_sec[2]} UNK/GOT-indirect={target_sec[3]})")

    # ---- clustering analysis of rodata-targeting patch offsets ----
    if to_rodata:
        ro = sorted(to_rodata)
        lo, hi = ro[0], ro[-1]
        span = hi - lo + 4  # each patch is a 4-byte word
        print(f"\n--- RODATA patch-offset CLUSTERING ({len(ro)} relocs) ---")
        print(f"  min offset = 0x{lo:x}  max offset = 0x{hi:x}")
        print(f"  span       = {span} bytes (0x{span:x}) over rodata size {rodata_size}")
        print(f"  span as %% of rodata = {100.0*span/rodata_size:.1f}%")
        # contiguity: how many distinct 'gaps' and is it head/tail clustered?
        # tail-clustered = all relocs in last X% ; head = first X%
        frac_lo = lo / rodata_size
        frac_hi = hi / rodata_size
        print(f"  first patch at {100*frac_lo:.1f}%% of rodata, last at {100*frac_hi:.1f}%%")
        # gap histogram
        gaps = [ro[i+1]-ro[i] for i in range(len(ro)-1)]
        big_gaps = [g for g in gaps if g > 64]
        print(f"  consecutive gaps: count={len(gaps)} max={max(gaps) if gaps else 0} "
              f"gaps>64B={len(big_gaps)}")
        # Estimate const-shareable bytes if we DON'T reorder: bytes BELOW the
        # first reloc + bytes ABOVE the last reloc are pure-const contiguous.
        const_below = lo
        const_above = rodata_size - (hi + 4)
        print(f"  contiguous pure-const BELOW first reloc = {const_below} bytes")
        print(f"  contiguous pure-const ABOVE last reloc  = {const_above} bytes")
        # If we could reorder: total const = rodata - 4*nrelocs (distinct words)
        distinct = len(set(ro))
        reorder_const = rodata_size - 4 * distinct
        print(f"  distinct patched words = {distinct} -> reorderable const = "
              f"{reorder_const} bytes ({100.0*reorder_const/rodata_size:.1f}%%)")
        # show distribution in deciles
        buckets = [0]*10
        for o in ro:
            b = min(9, int(10 * o / rodata_size))
            buckets[b] += 1
        print(f"  decile histogram (0=start..9=end of rodata): {buckets}")
        sample = ro[:8] + (['...'] if len(ro) > 16 else []) + (ro[-8:] if len(ro) > 16 else [])
        print(f"  sample offsets: {[hex(x) if isinstance(x,int) else x for x in sample]}")
    else:
        print("\n  NO data relocations patch into rodata.")

    # ---- LOCAL (GOT) relocations: these patch the GOT, not rodata ----
    # but report how many GOT slots resolve to rodata-range targets (those
    # GOT words are per-process, but they live in .got not rodata)
    pos = local_start
    got_to_rodata = 0
    got_to_code = 0
    for i in range(local_amt):
        w0 = u32(d, pos); tgt = u32(d, pos+4); pos += 8
        sect = w0 & 0x3
        if sect == 0:
            got_to_code += 1
        elif tgt < rodata_size:
            got_to_rodata += 1
    print(f"\n--- LOCAL/GOT relocations ({local_amt}) ---")
    print(f"  GOT slots -> CODE: {got_to_code}, GOT slots -> rodata-range: {got_to_rodata}")
    print(f"  (these patch the per-process .got, not rodata bytes)")

    return {
        'data_length': data_length, 'rodata_size': rodata_size,
        'relocs_into_rodata': len(to_rodata), 'relocs_into_data': to_data,
        'relocs_into_bss': to_bss, 'relocs_into_got': to_other,
        'data_amt': data_amt, 'local_amt': local_amt,
        'const_below': (sorted(to_rodata)[0] if to_rodata else rodata_size),
        'const_above': (rodata_size - (sorted(to_rodata)[-1]+4) if to_rodata else rodata_size),
        'distinct': len(set(to_rodata)),
    }

if __name__ == "__main__":
    print("########## TOYBOX ##########")
    tb = analyze("rootfs/usr/bin/toybox", 0x7120)
    print("\n########## LIBC ##########")
    lc = analyze("rootfs/usr/lib/libc.so", 0x2158)
