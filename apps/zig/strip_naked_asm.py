#!/usr/bin/env python3
"""Adapt the C backend's compiler_rt output to what tinycc can build.

Zig's compiler-rt renders through the C backend like any other Zig source, and
the Zig compiler needs it: it holds every comptime float in an f128, so it
reaches the f16/f80/f128 routines whatever the program being compiled contains.
Three things in the 2 MB of generated C are beyond tinycc, and all three are
mechanical to fix:

  1. Eight ARM EABI wrappers are naked functions whose inline asm uses *named*
     operands (`bl %[__udivmodsi4]`, constraint "X"). tcc has no named operands
     but assembles a literal symbol reference fine, and the operand is always
     the address of a function in this file -- so substitute its final
     assembler name. These wrappers are not optional: on ARM, four of them are
     the ONLY definition of __fixdfti and friends. The plain C routine beside
     each one is static, and the asm is what adapts its sret return to the
     by-value one the symbol promises.

  2. A second exported name is expressed as __attribute__((alias("__cmphf2"))),
     which names the target by its *assembler* name. tcc resolves an alias
     against C identifiers only, and its own `.globl x; x = y` form produces an
     absolute symbol, which would link to address 0. Emit real forwarding
     functions instead: a call through one is a branch, and correct.

  3. compiler-rt exports names the platform already defines (fabs, __aeabi_memcpy,
     ...) and the linker refuses the duplicate. Rename those out of the way
     rather than dropping them -- the routines have internal callers, and only
     the exported assembler name is in anyone's way.

    strip_naked_asm.py <in.c> <out.c> [provided-symbols-file]

The third argument lists symbols the platform already defines, one per line
(`nm --defined-only libtcc1.a` is the source of the set that matters here).
"""
import re, sys

src = open(sys.argv[1]).read().splitlines(keepends=True)
provided = set()
if len(sys.argv) > 3:
    provided = {l.split()[-1] for l in open(sys.argv[3]) if l.strip()}

out = src

# ---- 3. Rename exports the platform already provides. ----------------------
def rename_export(line):
    return re.sub(r'zig_mangled\((\w+), "([^"]+)"\)',
                  lambda m: m.group(0) if m.group(2) not in provided
                  else f'zig_mangled({m.group(1)}, "zigrt_{m.group(2)}")',
                  line)

out = [rename_export(l) for l in out]

# ---- 2. Second exported names, as forwarding functions. --------------------
asm_name = {}          # assembler name -> C identifier that carries it
for l in out:
    for ident, nm in re.findall(r'zig_mangled\((\w+), "([^"]+)"\)', l):
        asm_name[nm] = ident

fwd, kept = [], []
export_re = re.compile(
    r'^\s*zig_extern\s+(?P<ret>.+?)\s+(?P<name>zig_e_\w+)\((?P<params>[^)]*)\)\s+'
    r'zig_mangled_export\((?P=name),\s*"(?P<exp>[^"]+)",\s*"(?P<target>[^"]+)"\);')
for l in out:
    m = export_re.match(l)
    if not m:
        kept.append(l)
        continue
    target = asm_name.get(m.group("target"))
    if target is None:
        continue                      # aliases a name this object does not define
    args = ", ".join(re.findall(r"\b(a\d+)\b", m.group("params")))
    ident = "yz_fwd_" + m.group("exp")
    fwd.append(f'{m.group("ret")} {ident}({m.group("params")}) __asm__("{m.group("exp")}");\n')
    fwd.append(f'{m.group("ret")} {ident}({m.group("params")}) {{ return {target}({args}); }}\n')
out = kept

# ---- 1. Named asm operands -> literal symbol references. -------------------
# Done last, so the names substituted are the ones the file finally exports.
# A definition reaches its assembler name through `#define <cident> <zig_e_x>`
# and `zig_mangled(<zig_e_x>, "<asm>")`; a static function has neither and is
# its own assembler name.
define_to_zig_e, final_name = {}, {}
for l in out:
    m = re.match(r"#define (\w+) (zig_e_\w+)", l)
    if m:
        define_to_zig_e[m.group(1)] = m.group(2)
for cident, zig_e in define_to_zig_e.items():
    for l in out:
        m = re.search(rf'zig_mangled\({re.escape(zig_e)}, "([^"]+)"\)', l)
        if m:
            final_name[cident] = m.group(1)
            break

rewritten = 0
asm_only = []          # static functions now named only inside an asm string
for i, l in enumerate(out):
    if "%[" not in l:
        continue
    targets = dict(re.findall(r'\[(\w+)\]"X"\(\(&(\w+)\)\)', l))
    for name, ident in targets.items():
        l = l.replace(f"%[{name}]", final_name.get(ident, ident))
        if ident not in final_name:
            asm_only.append(ident)
    clobber = ': "memory"' in l
    l = re.sub(r'::\s*\[\w+\]"X"\(\(&\w+\)\)(?:\s*:\s*"memory")?',
               ':::"memory"' if clobber else "", l)
    out[i] = l
    rewritten += 1

# The named operand was the only C-visible reference to a static target; once
# it is a literal in the asm string, an optimising compiler (tcc -O1+, gcc)
# sees the function as unused and drops it, and the wrapper's `bl` fails to
# link. A `used` table of their addresses keeps them.
if asm_only:
    refs = ", ".join(f"(void const *)&{ident}" for ident in dict.fromkeys(asm_only))
    out.append("\n/* Static targets of the asm wrappers above. */\n")
    out.append(f"static void const *const yz_asm_targets[] __attribute__((used)) = {{ {refs} }};\n")

if fwd:
    out.append("\n/* Second exported names, as forwarding calls. */\n")
    out.extend(fwd)

open(sys.argv[2], "w").writelines(out)
print(f"rewrote {rewritten} asm wrappers, {len(fwd)//2} forwarding exports, "
      f"{sum(1 for l in out if 'zigrt_' in l)} renamed")
