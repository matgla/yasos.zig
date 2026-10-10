#!/usr/bin/env python3
"""Helpers for building the YasOS kernel with tcc (build/kernel_tcc.zig).

  tool.py fix-cbe IN.c OUT.c
      Make Zig's C-backend output something gcc, clang and tcc all accept:
        * C-reserved extern *variables* get the zig_e_ prefix but no asm label
          for their real name (functions do) -- add it;
        * const data placed in a code section (linksection(".time_critical"))
          is a section type conflict for gcc/clang -- move it to
          ".time_critical.data" (the linker scripts glob .time_critical*);
        * naked functions may only contain asm: drop `(void)aN;` discards;
        * a never-inline wrapper around a naked function is not naked itself
          (its body is a C call).

  tool.py provided OUT.txt ARCHIVE...
      Write the global symbols the archives define, one per line -- the names
      apps/zig/strip_naked_asm.py renames out of Zig's compiler-rt so the link
      has one definition of each.  Reads ar + ELF32 directly (no binutils:
      this also runs where only tcc exists).

  tool.py plan OUT.json ARGS...
      The tcc commands of build/kernel_tcc.zig as JSON, for
      scripts/kernel_tcc/device.py: "@cmd" starts a command, "@in"/"@dir"/
      "@out"/"@dep" PREFIX PATH are files (made absolute), anything else is a
      literal argument.  {"root": repo, "commands": [[item, ...], ...]} with
      an item either a string or {"kind", "prefix", "path"}.
"""
import json
import os
import re
import struct
import sys


def fix_cbe(src, dst):
    s = open(src).read()
    s = re.sub(r'^(zig_extern .*\bzig_e_(\w+));$', r'\1 zig_mangled(zig_e_\2, "\2");', s, flags=re.M)
    s = re.sub(r'^(zig_linksection\("\.time_critical)("\) struct \w+ const )', r'\1.data\2', s, flags=re.M)

    def strip(m):
        return re.sub(r'\n \(void\)a\d+;', '', m.group(0))

    s = re.sub(r'^(static )?zig_naked void \w+\([^)]*\) \{.*?\n\}', strip, s, flags=re.M | re.S)
    s = re.sub(r'^(static zig_never_inline) zig_naked (void zig_never_inline_)', r'\1 \2', s, flags=re.M)
    open(dst, 'w').write(s)


def elf_globals(data):
    """Defined global/weak symbol names of one ELF32 little-endian relocatable."""
    if data[:4] != b'\x7fELF' or data[4] != 1:
        return set()
    shoff, = struct.unpack_from('<I', data, 0x20)
    shentsize, shnum = struct.unpack_from('<HH', data, 0x2e)
    secs = [struct.unpack_from('<IIIIIIIIII', data, shoff + i * shentsize) for i in range(shnum)]
    names = set()
    for sh in secs:
        if sh[1] != 2:  # SHT_SYMTAB
            continue
        off, size, link, entsize = sh[4], sh[5], sh[6], sh[9] or 16
        stroff = secs[link][4]
        for k in range(1, size // entsize):
            name, value, sz, info, other, shndx = struct.unpack_from('<IIIBBH', data, off + k * entsize)
            if (info >> 4) in (1, 2) and shndx != 0:  # GLOBAL/WEAK, defined
                end = data.index(b'\0', stroff + name)
                names.add(data[stroff + name:end].decode())
    return names


def archive_members(path):
    data = open(path, 'rb').read()
    if not data.startswith(b'!<arch>\n'):
        yield data
        return
    pos = 8
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        size = int(hdr[48:58].decode().strip())
        name = hdr[0:16].decode().strip()
        body = data[pos + 60:pos + 60 + size]
        if not name.startswith('/'):  # skip symbol/name tables
            yield body
        pos += 60 + size + (size & 1)


def provided(out, archives):
    names = set()
    for a in archives:
        for member in archive_members(a):
            names |= elf_globals(member)
    open(out, 'w').write(''.join(n + '\n' for n in sorted(names)))


def plan(out, args):
    commands = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '@cmd':
            commands.append([])
            i += 1
        elif a in ('@in', '@dir', '@out', '@dep'):
            commands[-1].append({'kind': a[1:], 'prefix': args[i + 1], 'path': os.path.abspath(args[i + 2])})
            i += 3
        else:
            commands[-1].append(a)
            i += 1
    with open(out, 'w') as f:
        json.dump({'root': os.getcwd(), 'commands': commands}, f, indent=1)


if __name__ == '__main__':
    if sys.argv[1] == 'fix-cbe':
        fix_cbe(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == 'provided':
        provided(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == 'plan':
        plan(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(__doc__)
