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

  tool.py needed OUT.txt FILE...
      Write the global symbols the objects and archives leave undefined: what
      compiler-rt has to supply to the kernel link.

  tool.py prune-crt OUT.c IN.c NEEDED.txt
      Compiler-rt's C less the functions nothing in NEEDED.txt reaches (see
      prune_crt): the kernel link keeps 7 of its 554 functions.

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


def elf_undefined(data):
    """Undefined global/weak symbol names of one ELF32 little-endian relocatable."""
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
            if (info >> 4) in (1, 2) and shndx == 0 and name:
                end = data.index(b'\0', stroff + name)
                names.add(data[stroff + name:end].decode())
    return names


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


def needed(out, files):
    """The symbols the link's other inputs leave undefined: what compiler-rt must supply."""
    names = set()
    for f in files:
        for member in archive_members(f):
            names |= elf_undefined(member)
    open(out, 'w').write(''.join(n + '\n' for n in sorted(names)))


CRT_WORD = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')


def crt_def_name(header):
    """The function a definition's header line (ending in ') {') defines."""
    end = header.rindex(')')
    depth, i = 0, end
    while i >= 0:
        depth += {')': 1, '(': -1}.get(header[i], 0)
        if depth == 0:
            break
        i -= 1
    m = re.search(r'([A-Za-z_][A-Za-z0-9_]*)\s*$', header[:i])
    return m.group(1) if m else None


def prune_crt(out, src, needed_file):
    """compiler-rt less the functions nothing in the link reaches.

    The C backend renders all of compiler-rt -- 554 functions -- and the kernel link keeps
    seven; tcc took 9 of the board build's 28 minutes on the rest.  Roots: the symbols the
    other inputs leave undefined (`needed`), by assembler name, and what the file's data
    refers to.  A definition is a line at column 0 ending in ') {' through the next '}' at
    column 0; prototypes and everything else stay."""
    lines = open(src).read().splitlines(keepends=True)
    defs, i = [], 0               # (name, first line, last line)
    while i < len(lines):
        l = lines[i]
        if l[:1] not in ' \t#}' and l.rstrip().endswith(') {'):
            j = i + 1
            while j < len(lines) and lines[j].rstrip('\n') != '}':
                j += 1
            defs.append((crt_def_name(l), i, j))
            i = j + 1
        else:
            i += 1
    in_def = [False] * len(lines)
    for _, a, b in defs:
        for k in range(a, b + 1):
            in_def[k] = True
    # assembler name -> C names: `#define cident zig_e_x` + `zig_mangled(zig_e_x, "asm")`,
    # and `__asm__("asm")` on forwarders and other renamed definitions.
    to_c = {}
    define = {}
    for l in lines:
        m = re.match(r'#define (\w+) (zig_e_\w+)$', l.rstrip())
        if m:
            define.setdefault(m.group(2), []).append(m.group(1))
    for l in lines:
        for ident, asm in re.findall(r'zig_mangled\((\w+), "([^"]+)"\)', l):
            to_c.setdefault(asm, set()).update([ident] + define.get(ident, []))
        m = re.search(r'\s*__asm__\("([^"]+)"\);$', l.rstrip())
        if m and l[:m.start()].rstrip().endswith(')'):
            name = crt_def_name(l[:m.start()])
            if name:
                to_c.setdefault(m.group(1), set()).add(name)
    bodies = {}
    for name, a, b in defs:
        bodies.setdefault(name, []).append((a, b))
    roots = set()
    for n in (l.strip() for l in open(needed_file)):
        roots |= to_c.get(n, set())
        roots.add(n)
    proto = re.compile(r'.*\)\s*;$')  # a declaration: `...)` [zig_mangled(...)] [__asm__("...")] `;`
    for k, l in enumerate(lines):
        if not in_def[k] and not l.startswith('#') and not proto.match(l.rstrip()):
            roots.update(CRT_WORD.findall(l))
    keep, todo = set(), [r for r in roots if r in bodies]
    while todo:
        n = todo.pop()
        if n in keep:
            continue
        keep.add(n)
        for a, b in bodies[n]:
            for w in set(CRT_WORD.findall(''.join(lines[a:b + 1]))):
                for c in (w, *to_c.get(w, ())):
                    if c in bodies and c not in keep:
                        todo.append(c)
    drop = [False] * len(lines)
    for name, a, b in defs:
        if name not in keep:
            for k in range(a, b + 1):
                drop[k] = True
    open(out, 'w').writelines(l for k, l in enumerate(lines) if not drop[k])
    print(f"prune-crt: {len(defs)} definitions, {sum(1 for n, _, _ in defs if n in keep)} kept")


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
    elif sys.argv[1] == 'needed':
        needed(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == 'prune-crt':
        prune_crt(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == 'plan':
        plan(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(__doc__)
