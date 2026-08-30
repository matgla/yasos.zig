#!/usr/bin/env python3
"""Disassemble the binary that a board hexdump carries.

`hexdump FILE` on the target (apps/hexdump/main.c) is how a program the board
itself wrote gets off the board during a take: a 7-digit offset, then up to
eight little-endian halfwords for the 16 bytes it read.  The recorded terminal
keeps that, so the transcript *is* the binary.  This turns it back into the file
and disassembles it -- pair it with the `sha256sum` the same take printed and
the frame carries its own proof that the disassembly is of the board's bytes and
not of a host cross-compile of the same source.

    scripts/dump_disasm.py dump.txt
    scripts/demo_shot.sh full && scripts/dump_disasm.py TAKE.raw --save demo.bin

The input can be the raw transcript: escape sequences, the prompt and the typed
command around the dump are ignored, and a take holding two dumps is split into
two rather than spliced together (`--dump` picks one; the longest wins).

YAFF modules (libs/tinycc/source/obj/tccyaff.h) are decoded.  The header says
where each region lives, so the disassembly covers exactly the executable ones
(code + init + plt) at module-relative addresses -- the same numbers the
branches in the code already use, so `bl 0x130` lands on a plt entry you can see
-- and walking the section table doubles as a completeness check on the
transcript: if the regions add up to the reconstructed length, no line was lost.
Anything that is not a YAFF module is disassembled whole (as with `--raw`).
"""

from __future__ import annotations

import argparse
import re
import struct
import subprocess
import sys
import tempfile


OBJDUMP = "arm-none-eabi-objdump"

# apps/hexdump/main.c writes "%07x " then "%04x " per halfword.  Widened here to
# also take `hexdump -C` / `od -t x1`: 6-10 digit offsets, an optional colon,
# 2-hex byte columns, and a trailing |ascii| gutter.  A column's own width says
# how to read it -- 2 digits is a byte, 4 is a little-endian halfword -- so the
# two formats can even be mixed.  `xxd` is deliberately NOT accepted: its 4-hex
# columns are byte *pairs*, not halfwords, and nothing in the line says which
# convention is in force.  Pipe through `xxd -c 16 -g 1` if you have to.
_LINE = re.compile(
    r"^([0-9a-f]{6,10}):?"
    r"((?:\s+(?:[0-9a-f]{2}|[0-9a-f]{4}))*)"
    r"(?:\s*\|[^|]*\||\s\s+\S.*)?$",
    re.IGNORECASE,
)

# CSI/OSC and the two-byte escapes; a transcript is full of them.
_ANSI = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-_]")


def parse_dumps(text):
    """Split a transcript into every hexdump it holds, newest offset order kept.

    A rewind (an offset not following the previous one) starts a *new* dump
    rather than being merged: two dumps of two different files in one take must
    not be spliced into one blob that disassembles as neither.
    """
    dumps = []
    cur = None
    for raw in text.splitlines():
        line = raw.strip()
        if line == "*":                       # hexdump(1) run marker
            if cur:
                cur["repeat"] = True
            continue
        m = _LINE.match(line)
        if not m:
            continue
        off = int(m.group(1), 16)
        toks = m.group(2).split()
        if cur is None or off < cur["next"]:
            if not toks:
                continue                      # a lone offset is not a dump start
            cur = {"blob": bytearray(), "next": 0, "rows": 0, "eof": None,
                   "gap": None, "last": None, "repeat": False}
            dumps.append(cur)
        if not toks:
            # hexdump prints the offset it *would* have read next, so this is
            # the length rounded up to 16 -- an end marker, not data.
            cur["eof"] = off
            continue
        if cur["gap"]:
            continue                          # this dump is already broken
        row = bytearray()
        for t in toks:
            row += bytes([int(t, 16)]) if len(t) == 2 else int(t, 16).to_bytes(2, "little")
        if off > cur["next"]:
            if cur["repeat"] and cur["last"]:
                while cur["next"] + len(cur["last"]) <= off:
                    cur["blob"] += cur["last"]
                    cur["next"] += len(cur["last"])
            if off != cur["next"]:
                cur["gap"] = (cur["next"], off)
                continue
        cur["blob"] += row
        cur["next"] = off + len(row)
        cur["rows"] += 1
        cur["last"] = row
        cur["repeat"] = False
    return dumps


# YaffHeader, libs/tinycc/source/obj/tccyaff.h -- packed, so these are plain
# byte offsets into the file the board wrote.
def parse_yaff(data):
    if len(data) < 92 or data[:4] != b"YAFF":
        return None
    u32 = lambda o: struct.unpack_from("<I", data, o)[0]
    u16 = lambda o: struct.unpack_from("<H", data, o)[0]
    h = {
        "module_type": data[4], "arch": u16(5), "version": data[7],
        "code_length": u32(8), "init_length": u32(12), "data_length": u32(16),
        "bss_length": u32(20), "entry": u32(24),
        "got_length": u32(48), "got_plt_length": u32(52), "plt_length": u32(56),
        "text_offset": u16(70),
        "stack_size": u32(80), "heap_size": u32(84), "const_rodata_length": u32(88),
    }
    # Module offset space, exactly as dynamic_loader/source/loader.zig
    # get_section_address_for_offset() walks it: code | init | plt | data | bss |
    # got, with the shared rodata as a prefix *inside* the data region.  bss is
    # the one region the file does not store, so from bss on the module offset
    # and the file offset drift apart by bss_length -- both are tracked.
    code, init = 0, h["code_length"]
    plt = init + h["init_length"]
    dat = plt + h["plt_length"]
    bss = dat + h["data_length"]
    got = bss + h["bss_length"]
    ro = h["const_rodata_length"]
    #        name      module      file (None = not stored)   bytes
    h["regions"] = [
        ("code", code, code, h["code_length"]),
        ("init", init, init, h["init_length"]),
        ("plt", plt, plt, h["plt_length"]),
        ("rodata", dat, dat, ro),
        ("data", dat + ro, dat + ro, h["data_length"] - ro),
        ("bss", bss, None, h["bss_length"]),
        ("got", got, bss, h["got_length"]),
    ]
    h["exec_end"] = dat                       # code+init+plt: everything is_code
    h["file_end"] = h["text_offset"] + bss + h["got_length"]
    return h


def render(text, vma, labels):
    """Put the labels we know about into objdump's output.

    Raw-binary objdump has no symbol table, so branch targets are bare numbers.
    Naming the entry point and each plt stub is the difference between reading
    the listing and decoding it.
    """
    addr_re = re.compile(r"^\s*([0-9a-f]+):\t")
    tail_re = re.compile(r"0x([0-9a-f]+)$")
    # objdump's preamble names the temp file it was handed and invents a
    # `.data` section for a raw blob.  Both are noise, and the filename is not
    # reproducible between runs, so neither belongs in a recorded frame.
    noise = re.compile(r"^(\S*:\s+file format |Disassembly of section |[0-9a-f]+ <\.data>:)")
    out = []
    for line in text.splitlines():
        if noise.match(line):
            continue
        if not line.strip() and not out:
            continue
        m = addr_re.match(line)
        if m and int(m.group(1), 16) in labels:
            out.append("")
            out.append(f"{int(m.group(1), 16):08x} <{labels[int(m.group(1), 16)]}>:")
        t = tail_re.search(line)
        if t and int(t.group(1), 16) in labels:
            line += f" <{labels[int(t.group(1), 16)]}>"
        out.append(line)
    return "\n".join(out) + "\n"


def objdump(blob, vma, args):
    # -b binary makes objdump seek, so this has to be a real file, not a pipe.
    with tempfile.NamedTemporaryFile(suffix=".bin") as f:
        f.write(blob)
        f.flush()
        p = subprocess.run(
            [args.objdump, "-D", "-b", "binary", "-m", "arm", "-M", "force-thumb",
             f"--adjust-vma={vma}", f.name],
            stdout=subprocess.PIPE, check=False)
    return p.stdout.decode("utf-8", errors="replace"), p.returncode


def ascii_of(b):
    return "".join(chr(c) if 0x20 <= c < 0x7f else "." for c in b)


def main():
    p = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("dump", nargs="?", default="-",
                   help="hexdump transcript, or - for stdin")
    p.add_argument("--save", metavar="BIN", help="also keep the reconstructed file")
    p.add_argument("--raw", action="store_true",
                   help="disassemble the whole blob, do not read a YAFF header")
    p.add_argument("--dump", type=int, metavar="N", dest="which",
                   help="pick the Nth hexdump in the transcript (default: longest)")
    p.add_argument("--vma", default="0", help="base address for the listing")
    p.add_argument("--objdump", default=OBJDUMP)
    p.add_argument("--bytes-only", action="store_true",
                   help="rebuild and report, do not disassemble")
    args = p.parse_args()

    src = sys.stdin.buffer.read() if args.dump == "-" else open(args.dump, "rb").read()
    dumps = parse_dumps(_ANSI.sub("", src.decode("utf-8", errors="replace")))
    if not dumps:
        print("no hexdump lines in the input -- the board's `hexdump`, "
              "`hexdump -C` and `od -t x1` are understood, `xxd` is not "
              "(see the note on column width; `xxd -g 1` is)", file=sys.stderr)
        return 1

    for i, d in enumerate(dumps):
        note = f" -- GAP at 0x{d['gap'][1]:x}, missing from 0x{d['gap'][0]:x}" if d["gap"] else ""
        print(f"dump {i}: {len(d['blob'])} bytes from {d['rows']} lines{note}", file=sys.stderr)
    d = dumps[args.which] if args.which is not None else max(dumps, key=lambda x: len(x["blob"]))
    if len(dumps) > 1 and args.which is None:
        print(f"using the longest ({len(d['blob'])} bytes); --dump N picks another",
              file=sys.stderr)
    if d["gap"]:
        print("transcript is missing lines -- the binary is incomplete", file=sys.stderr)
        return 1
    blob = bytes(d["blob"])
    if args.save:
        open(args.save, "wb").write(blob)
        print(f"wrote {args.save}", file=sys.stderr)

    vma = int(args.vma, 0)
    h = None if args.raw else parse_yaff(blob)
    if h is None:
        print(f"{len(blob)} bytes, no YAFF header -- disassembling all of it\n")
        if args.bytes_only:
            return 0
        text, rc = objdump(blob, vma, args)
        sys.stdout.write(render(text, vma, {}))
        return rc

    kind = {1: "executable", 2: "shared library"}.get(h["module_type"], "unknown")
    arch = {1: "armv6-m", 2: "armv7-m", 3: "armv7e-m", 4: "armv8-m"}.get(h["arch"], "?")
    print(f"YAFF v{h['version']}  {kind}  {arch}  entry 0x{h['entry'] & ~1:x}"
          f"{'  (thumb)' if h['entry'] & 1 else ''}")
    print(f"{len(blob)} bytes, text at file offset 0x{h['text_offset']:x}\n")
    print(f"  {'region':<8} {'module':>10} {'file':>10} {'bytes':>8}")
    for name, moff, foff, length in h["regions"]:
        if not length:
            continue
        where = "-  (bss)" if foff is None else "0x%x" % (h["text_offset"] + foff)
        print(f"  {name:<8} {'0x%x' % moff:>10} {where:>10} {length:>8}")

    # The section walk has to land exactly on the end of the file.  If it does,
    # every line of the dump arrived; if it does not, one did not.
    if h["file_end"] != len(blob):
        print(f"\nWARNING: sections end at 0x{h['file_end']:x} but the blob is "
              f"0x{len(blob):x} -- the transcript is short or the header is off",
              file=sys.stderr)
    else:
        print("\nsections account for every byte -- the transcript is complete")

    ro = next((r for r in h["regions"] if r[0] == "rodata" and r[3]), None)
    if ro:
        start = h["text_offset"] + ro[2]
        raw = blob[start:start + ro[3]]
        print(f"\nrodata (module 0x{ro[1]:x}, what pc-relative literals index into):")
        for i in range(0, len(raw), 16):
            print(f"  +0x{i:04x}  {raw[i:i+16].hex(' '):<47}  |{ascii_of(raw[i:i+16])}|")

    if args.bytes_only:
        return 0

    code = blob[h["text_offset"]:h["text_offset"] + h["exec_end"]]
    print(f"\n{len(code)} bytes of executable image (code + init + plt)\n")
    text, rc = objdump(code, vma, args)

    # Name what the listing can prove: the entry point, and every plt stub the
    # code actually calls (their addresses come out of the disassembly itself,
    # so no guess at a stub size is needed).
    labels = {vma + (h["entry"] & ~1): "entry"}
    plt_lo = vma + h["code_length"] + h["init_length"]
    plt_hi = plt_lo + h["plt_length"]
    calls = re.findall(r"\b(?:blx|bl|b\.w|b\.n|b)\s+0x([0-9a-f]+)", text)
    targets = sorted({int(x, 16) for x in calls if plt_lo <= int(x, 16) < plt_hi})
    for i, t in enumerate(targets):
        labels[t] = f"plt.{i}"
    if h["init_length"]:
        labels.setdefault(vma + h["code_length"], "init")
    if h["plt_length"]:
        labels.setdefault(plt_lo, "plt")
    sys.stdout.write(render(text, vma, labels))
    return rc


if __name__ == "__main__":
    sys.exit(main())
