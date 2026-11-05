#!/usr/bin/env python3
"""Keep source/kernel/hot_functions.txt naming the same functions after the code moved.

Zig's C backend numbers generic instances and anonymous structs inside a name
(`mem_eql__func_281`, `FatFs__struct_1324_read`). Any edit moves those numbers, and so
does building for another board, and --ram-text silently leaves what it cannot find in
flash. The numbers cannot simply be ignored: `interface_gen_vcall__struct_1897_call`
is one interface method of hundreds.

So a listed function is looked up in the kernel the list was made on, and found again
in each kernel given: same name but for the numbers, and then the same bytes, or the
same size, or the nearest size. Names found in none of them are kept.

  scripts/hot_functions_refresh.py OLD_ELF NEW_ELF [NEW_ELF...]        rewrite the list
  scripts/hot_functions_refresh.py --check NEW_ELF [NEW_ELF...]        how much of it matches
"""
import argparse
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIST = REPO / "source/kernel/hot_functions.txt"
# Instances of one generic name that look alike; past this it is a guess anyway.
MAX_CANDIDATES = 2


def unnumbered(name):
    return re.sub(r"(__func_|struct_)\d+", r"\1#", name)


class Kernel:
    def __init__(self, path):
        self.path = path
        out = subprocess.check_output(["arm-none-eabi-nm", "-S", str(path)], text=True)
        self.functions = {}
        for line in out.splitlines():
            fields = line.split()
            if len(fields) == 4 and fields[2] in "tT":
                name = re.sub(r"__\d+$", "", fields[3])
                self.functions.setdefault(name, (int(fields[0], 16) & ~1, int(fields[1], 16)))
        self.by_generic = {}
        for name in self.functions:
            self.by_generic.setdefault(unnumbered(name), []).append(name)
        self.sections = []
        for line in subprocess.check_output(["arm-none-eabi-readelf", "-SW", str(path)], text=True).splitlines():
            m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)", line)
            if m and int(m.group(2), 16):
                self.sections.append((int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16)))
        self.image = path.read_bytes()

    def body(self, name):
        address, size = self.functions[name]
        for start, offset, length in self.sections:
            if start <= address < start + length:
                return self.image[offset + address - start:offset + address - start + size]
        return b""


def find_again(name, old, new):
    if name in new.functions and name not in old.functions:
        return [name]
    candidates = new.by_generic.get(unnumbered(name), [])
    if name not in old.functions or not candidates:
        return []
    body = old.body(name)
    same = [c for c in candidates if new.body(c) == body]
    if not same:
        same = [c for c in candidates if new.functions[c][1] == len(body)]
    if not same:
        same = sorted(candidates, key=lambda c: abs(new.functions[c][1] - len(body)))[:1]
    # The same number, when it is still among them, is most likely the same one.
    same.sort(key=lambda c: c != name)
    return same[:MAX_CANDIDATES]


def read_list(path):
    header, names = [], []
    for line in path.read_text().splitlines():
        (header if line.startswith("#") else names).append(line.strip())
    return header, [n for n in names if n]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--list", type=Path, default=LIST, help="the list to refresh or check (default: the kernel's)")
    parser.add_argument("--output", type=Path, help="write here instead of over the list")
    parser.add_argument("kernels", nargs="+", type=Path)
    args = parser.parse_args()
    header, names = read_list(args.list)
    if args.check:
        for path in args.kernels:
            kernel = Kernel(path)
            found = [n for n in names if n in kernel.functions]
            size = sum(kernel.functions[n][1] for n in found)
            print(f"{path}: {len(found)} of {len(names)} listed functions, {size} bytes")
        return
    old = Kernel(args.kernels[0])
    new = [Kernel(path) for path in args.kernels[1:]]
    refreshed = set()
    for name in names:
        hits = {hit for kernel in new for hit in find_again(name, old, kernel)}
        refreshed |= hits or {name}
    (args.output or args.list).write_text("\n".join(header + sorted(refreshed)) + "\n")
    print(f"{len(names)} names -> {len(refreshed)}")


if __name__ == "__main__":
    main()
