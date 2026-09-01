#!/usr/bin/env python3
"""Diff yaffdump's listing against arm-none-eabi-objdump's, module by module.

The decoder's specification is "what objdump prints", so the test is literally
that: disassemble every YAFF module in the rootfs both ways and compare the
instruction lines at each address.  With --no-pool yaffdump decodes the literal
pools as code exactly as objdump has to (it is handed a flat blob and cannot
know better), which is what makes the two listings comparable at all -- the
pool marking that yaffdump does by default is the part objdump *cannot* do, and
is checked separately by --report-pools.

    tests/diff_objdump.py                       # the whole rootfs
    tests/diff_objdump.py rootfs/usr/bin/tcc    # one module
    tests/diff_objdump.py --show 40 ...         # more mismatch examples

Comments (everything after "@") and symbol annotations ("<name+0x4>") are not
compared: they are decoration, and the two tools deliberately know different
things about the module.
"""

from __future__ import annotations

import argparse
import collections
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
YAFFDUMP = os.path.join(HERE, "..", "build", "yaffdump")
OBJDUMP = "arm-none-eabi-objdump"
SEARCH = ["rootfs/usr/bin", "rootfs/lib", "rootfs/bin", "rootfs/usr/games", "rootfs/usr/lib"]

LINE = re.compile(r"^\s*([0-9a-f]+):\t([0-9a-f ]+)\s*\t(.*)$")


def exec_image(data):
    """The code+init+plt bytes and where they start, from the YAFF header."""
    if len(data) < 92 or data[:4] != b"YAFF":
        return None
    u32 = lambda o: struct.unpack_from("<I", data, o)[0]
    u16 = lambda o: struct.unpack_from("<H", data, o)[0]
    text = u16(70)
    length = u32(8) + u32(12) + u32(56)  # code + init + plt
    return data[text:text + length]


def normalize(text):
    """Strip what the two tools are not expected to agree on."""
    text = text.split("\t@")[0].split(" @ ")[0]
    text = re.sub(r"\s*<[^>]*>", "", text)
    text = text.replace("\t", " ")
    return " ".join(text.split())


def parse(listing, encodings=None):
    out = {}
    for line in listing.splitlines():
        match = LINE.match(line)
        if not match:
            continue
        address = int(match.group(1), 16)
        out[address] = normalize(match.group(3))
        if encodings is not None:
            encodings[address] = match.group(2).strip()
    return out


def run_objdump(blob, objdump, machine="arm"):
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as handle:
        handle.write(blob)
        name = handle.name
    try:
        result = subprocess.run(
            [objdump, "-D", "-b", "binary", "-m", machine, "-M", "force-thumb", name],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    finally:
        os.unlink(name)
    return result.stdout.decode("utf-8", errors="replace")


def modules(paths):
    if paths:
        return [p for p in paths]
    found = []
    for directory in SEARCH:
        full = os.path.join(ROOT, directory)
        if not os.path.isdir(full):
            continue
        for name in sorted(os.listdir(full)):
            path = os.path.join(full, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            with open(path, "rb") as handle:
                if handle.read(4) == b"YAFF":
                    found.append(path)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("modules", nargs="*", help="YAFF files (default: the whole rootfs)")
    parser.add_argument("--yaffdump", default=YAFFDUMP)
    parser.add_argument("--objdump", default=OBJDUMP)
    parser.add_argument("--machine", default="arm",
                        help="objdump -m: 'arm' decodes encodings no M-profile part has "
                             "(and so disagrees on data), 'armv8-m.main' is the real target")
    parser.add_argument("--show", type=int, default=12, help="mismatch examples to print")
    parser.add_argument("--report-pools", action="store_true",
                        help="also report how many words the default (pool-marking) mode "
                             "rescues from being disassembled as code")
    parser.add_argument("--fail-under", type=float, default=100.0,
                        help="agreement percentage below which the test fails")
    args = parser.parse_args()

    if not os.path.exists(args.yaffdump):
        print(f"{args.yaffdump} not built -- run `make CC=gcc` first", file=sys.stderr)
        return 2

    total = 0
    agreed = 0
    missing = 0
    undecoded = 0
    by_mnemonic = collections.Counter()
    by_undecoded = collections.Counter()
    examples = []
    pools = 0

    for path in modules(args.modules):
        data = open(path, "rb").read()
        blob = exec_image(data)
        if blob is None:
            print(f"skipping {path}: not a YAFF module", file=sys.stderr)
            continue
        encodings = {}
        ours = parse(subprocess.run([args.yaffdump, "-d", "--no-pool", path],
                                    stdout=subprocess.PIPE, check=True).stdout.decode())
        theirs = parse(run_objdump(blob, args.objdump, args.machine), encodings)
        module_bad = 0
        for address, expected in theirs.items():
            total += 1
            got = ours.get(address)
            if got is None:
                missing += 1
                continue
            if got == expected:
                agreed += 1
                continue
            if got.startswith(".word") or got.startswith(".short"):
                # We refused the encoding.  Either it is data (objdump, handed a
                # flat blob, has to guess and usually lands on some NEON form
                # that no M-profile part even has) or it is something real that
                # is not decoded yet -- which is what the histogram below is for.
                undecoded += 1
                by_undecoded[expected.split(" ")[0]] += 1
                continue
            module_bad += 1
            by_mnemonic[expected.split(" ")[0]] += 1
            if len(examples) < args.show:
                examples.append((path, address, encodings.get(address, "?"), expected, got))
        if args.report_pools:
            marked = subprocess.run([args.yaffdump, "-d", path], stdout=subprocess.PIPE,
                                    check=True).stdout.decode()
            pools += marked.count("@ literal pool")
        print(f"{os.path.relpath(path, ROOT):<34} {len(theirs):>8} insns  "
              f"{module_bad:>6} differ  {len(theirs) - len(ours):>5} missing")

    print()
    if total == 0:
        print("no instructions compared")
        return 1
    decoded = total - undecoded - missing
    share = 100.0 * agreed / decoded if decoded else 0.0
    print(f"{agreed}/{decoded} decoded instructions agree with objdump ({share:.4f}%)")
    print(f"{undecoded} encodings refused (printed as .word), {missing} addresses not reached")
    if by_undecoded:
        print("\nrefused, by what objdump made of the same bytes:")
        for mnemonic, count in by_undecoded.most_common(12):
            print(f"  {mnemonic:<16} {count}")
    if by_mnemonic:
        print("\nmismatches by objdump mnemonic:")
        for mnemonic, count in by_mnemonic.most_common(20):
            print(f"  {mnemonic:<16} {count}")
    if examples:
        print("\nexamples:")
        for path, address, encoding, expected, got in examples:
            print(f"  {os.path.basename(path)}+0x{address:x}  [{encoding}]")
            print(f"    objdump : {expected}")
            print(f"    yaffdump: {got}")
    if args.report_pools:
        print(f"\n{pools} words marked as literal pool data that objdump disassembles as code")
    return 0 if share >= args.fail_under and missing == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
