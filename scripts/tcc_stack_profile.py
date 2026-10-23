#!/usr/bin/env python3
"""Weight explicit ARM SP accesses by a saved per-PC execution profile.

Accepts the pc,cpu0,cpu1 CSV produced by the launch-profile QEMU plugin.
Disassembles the matching ELF and resolves functions with nm. This measures
executed instructions and transfer bytes, not peak stack depth or spill counts.
Accesses through pointers derived from SP are deliberately outside this census.
"""

import argparse
import bisect
import collections
import csv
import hashlib
import json
import re
import subprocess
from pathlib import Path


def classify(mnemonic, operands):
    """Return (category, bytes transferred) for an explicit SP operation."""
    op = mnemonic.split(".")[0]
    operands = operands.lower()
    memory_sp = re.search(r"\[sp(?:\s*[,\]])", operands)
    multiple_sp = re.match(r"sp\s*!?\s*,", operands)
    if op in ("push", "pop", "vpush", "vpop") or (
        op.startswith(("ldm", "stm", "vldm", "vstm")) and multiple_sp
    ):
        registers = re.search(r"\{([^}]+)\}", operands)
        if not registers:
            raise ValueError(f"missing register list: {mnemonic} {operands}")
        size = 0
        for register in registers[1].split(","):
            register = register.strip()
            match = re.fullmatch(r"([rds])(\d+)-\1(\d+)", register)
            count = int(match[3]) - int(match[2]) + 1 if match else 1
            size += count * (8 if register.startswith("d") else 4)
        load = op in ("pop", "vpop") or op.startswith(("ldm", "vldm"))
        return ("multiple_load" if load else "multiple_store", size)
    if memory_sp and op.startswith(("ldr", "str", "vldr", "vstr")):
        if op.startswith(("vldr", "vstr")):
            size = 8 if operands.startswith("d") else 4
        elif op.startswith(("ldrd", "strd")):
            size = 8
        elif op.startswith(("ldrb", "ldrsb", "strb")):
            size = 1
        elif op.startswith(("ldrh", "ldrsh", "strh")):
            size = 2
        else:
            size = 4
        return ("load" if "ldr" in op else "store", size)
    if op in ("add", "adds", "sub", "subs", "mov", "movs"):
        args = [arg.strip() for arg in operands.split(",")]
        if args[0] != "sp" and "sp" in args[1:]:
            return ("address", 0)
    return (None, 0)


def analyze(elf, profile, repetitions, start=None, end=None):
    symbols = subprocess.check_output(
        ["arm-none-eabi-nm", "-S", "-n", str(elf)], text=True
    )
    entries = []
    for line in symbols.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4 and fields[2] in ("t", "T", "w", "W"):
            address, size = int(fields[0], 16) & ~1, int(fields[1], 16)
            if size and not fields[3].startswith(("$", "L.")):
                entries.append((address, size, fields[3]))
    entries.sort()
    starts = [entry[0] for entry in entries]
    assembly = subprocess.check_output(
        ["arm-none-eabi-objdump", "-d", str(elf)], text=True
    )
    instructions = {}
    pattern = re.compile(r"^\s*([0-9a-f]+):\s+(?:[0-9a-f]{4}(?:\s+[0-9a-f]{4})?)\s+([\w.]+)\s*(.*)$")
    for line in assembly.splitlines():
        match = pattern.match(line)
        if match:
            address = int(match[1], 16)
            mnemonic, operands = match[2], match[3].split("@")[0].strip()
            if not mnemonic.startswith("."):
                instructions[address] = (mnemonic, operands)

    totals = collections.Counter()
    functions = collections.defaultdict(collections.Counter)
    sites = []
    for row in csv.DictReader(profile.open()):
        pc = int(row["pc"], 16)
        if (start is not None and pc < start) or (end is not None and pc >= end):
            continue
        count = int(row["cpu0"]) + int(row["cpu1"])
        index = bisect.bisect_right(starts, pc) - 1
        name = "unmapped"
        if index >= 0 and pc < entries[index][0] + entries[index][1]:
            name = entries[index][2]
        function = functions[name]
        for counter in (totals, function):
            counter["instructions"] += count
        if pc not in instructions:
            totals["undisassembled_instructions"] += count
            continue
        mnemonic, operands = instructions[pc]
        category, width = classify(mnemonic, operands)
        if category:
            for counter in (totals, function):
                counter[category] += count
                counter["transfer_bytes"] += count * width
            sites.append(dict(pc=hex(pc), function=name, category=category,
                              instruction=f"{mnemonic} {operands}",
                              executions=count / repetitions,
                              transfer_bytes=count * width / repetitions))

    def normalized(counter):
        return {key: value / repetitions for key, value in counter.items()}

    return dict(elf=str(elf.resolve()), profile=str(profile.resolve()),
                elf_sha256=hashlib.sha256(elf.read_bytes()).hexdigest(),
                profile_sha256=hashlib.sha256(profile.read_bytes()).hexdigest(),
                repetitions=repetitions, start=start, end=end,
                totals=normalized(totals),
                functions=sorted((dict(name=name, **normalized(counter))
                                  for name, counter in functions.items()),
                                 key=lambda row: -(row.get("load", 0) + row.get("store", 0))),
                sites=sorted(sites, key=lambda row: -row["executions"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", type=Path)
    parser.add_argument("profile", type=Path)
    parser.add_argument("--repetitions", type=int, required=True)
    parser.add_argument("--start", type=lambda value: int(value, 0))
    parser.add_argument("--end", type=lambda value: int(value, 0))
    parser.add_argument("--json", type=Path)
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()
    if args.repetitions <= 0:
        parser.error("--repetitions must be positive")
    result = analyze(args.elf, args.profile, args.repetitions, args.start, args.end)
    if args.json:
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    print("Per repetition (explicit SP accesses only):")
    print(json.dumps(result["totals"], indent=2))
    print("\n    SP loads    SP stores    SP addresses  function")
    for function in result["functions"][:args.top]:
        print(f"{function.get('load', 0):12.2f} {function.get('store', 0):12.2f} "
              f"{function.get('address', 0):15.2f}  {function['name']}")


if __name__ == "__main__":
    main()
