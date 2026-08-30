#!/usr/bin/env python3
"""Compile every userland TU with armv8m-tcc and with arm-none-eabi-gcc under
ABI-comparable flags, and sum .text (and .text+.rodata) per category.

The TU list and the exact -D/-I for each one come from each Makefile's own
`make -Bn` dry run, not from a hand-written list, so a source added to an app
shows up here without this script being touched.  Sizes are read from section
headers, never from file size.
"""
import os, re, shlex, subprocess, sys, json, collections

TOP = "/home/mateusz/repos/yasos.zig"
OUT = os.path.dirname(os.path.abspath(__file__)) + "/gccobj"
ROOTFS_INC = f"{TOP}/rootfs/usr/include"
TCC = f"{TOP}/libs/tinycc/bin/armv8m-tcc"
GCC = "arm-none-eabi-gcc"
GCC_INC = subprocess.run([GCC, "-print-file-name=include"], capture_output=True,
                         text=True).stdout.strip()

#: The ABI gcc has to be held to so the comparison is codegen and not calling
#: convention: single PIC base in r9, data addressed through it, hard FP on the
#: same FPU.  Straight from the tinycc-vs-gcc method already on file.
GCC_ABI = ("-mcpu=cortex-m33 -mthumb -mfloat-abi=hard -mfpu=fpv5-sp-d16 "
           "-fpic -msingle-pic-base -mpic-register=r9 "
           "-mno-pic-data-is-text-relative -fvisibility=hidden "
           # gcc 14 turned implicit declarations into hard errors whatever the
           # -std; three of these sources have one (realpath, qsort, strcmp) and
           # tcc compiles them. -fpermissive puts them back to warnings so the
           # same source reaches both code generators. Nothing here edits code.
           "-fpermissive "
           # tcc predefines __linux__/__unix__ for this target and bare-metal
           # gcc does not, so without these the two compilers preprocess
           # DIFFERENT source: toybox's portability.h drops <sys/statfs.h> and
           # fails to build. Checked the whole tcc-only predefine set for other
           # cases — __TINYC__ appears only in stdalign.h and test headers, and
           # __YasOS__ only in tcc's own tccdefs.h, so neither is worth handing
           # to gcc (and __TINYC__ would be a lie).
           "-D__linux__=1 -D__unix__=1 -D__unix=1 -D__linux=1").split()

#: Both sides get this, so neither is measured at a level the other did not see.
OPT = ["-O2"]

#: What the card calls each thing -> the directories that build it.
CATEGORIES = [
    ("shell & coreutils", ["apps/toybox", "apps/coreutils"]),
    ("the game",          ["apps/zork"]),
    ("filesystem tools",  ["apps/mkfs"]),
    ("the editor",        ["apps/yasvi"]),
    ("dev & benchmarks",  ["apps/hexdump", "apps/sdbench", "apps/syscallbench",
                           "apps/prun", "apps/sha", "apps/longjump_tester",
                           "apps/hello_world"]),
    ("toys & demos",      ["apps/textvaders", "apps/ascii_animations",
                           "apps/cowsay"]),
    ("file transfer",     ["apps/rzsz"]),
    ("the libraries",     ["libs/libc", "libs/libm", "libs/yasos_curses",
                           "libs/termcap"]),
    ("the compiler",      ["libs/tinycc"]),
]

#: The device compiler is not built by a plain `all` rule.
MAKE_TARGET = {"libs/tinycc": ["armv8m-tcc"]}

#: zork's Makefile takes its flags from the command line the way
#: build_zork_makefile does, not from ROOTFS_OPT_CFLAGS.
MAKE_VARS = {
    "apps/zork": ["CFLAGS=-O2 -Wl,-oformat=elf32-littlearm"],
}

def parse_compile(line):
    """(flags, source) for a tcc compile line, whatever order -c/-o came in.

    Parsed by tokens rather than by a positional regex: zork spells it
    `-c -o obj src` and every other Makefile spells it `-c src -o obj`, and a
    regex that assumes one silently drops the other's whole tree.
    """
    try:
        toks = shlex.split(line)
    except ValueError:
        return None
    for i, t in enumerate(toks):
        if t.endswith("armv8m-tcc"):
            break
    else:
        return None
    if "-c" not in toks:
        return None
    flags, src, skip = [], None, False
    for t in toks[i + 1:]:
        if skip:
            skip = False
            continue
        if t == "-o":
            skip = True
        elif t == "-c":
            pass
        elif t.endswith(".c") and src is None:
            src = t
        else:
            flags.append(t)
    return (flags, src) if src else None


def toybox_tus():
    """toybox does not go through a Makefile rule we can read.

    `scripts/make.sh` writes the whole compile out to `generated/build.sh` as
    one `$BUILD lib/*.c $FILES $LINK -o toybox` line, so that file *is* the
    dry run — ask the shell to expand it rather than re-deriving the applet
    list, which `yasos.config` curates and a defconfig would silently widen.
    """
    d = f"{TOP}/apps/toybox"
    script = ("set -e; cd %s; VERSION=''; LIBRARIES=''; "
              ". ./generated/build.sh 2>/dev/null || true; "
              "echo \"$BUILD\"; echo '---'; echo lib/*.c $FILES") % shlex.quote(d)
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    build, _, files = p.stdout.partition("\n---\n")
    toks = shlex.split(build)
    flags = [t for t in toks[1:] if not t.endswith("armv8m-tcc")]
    return [(flags, src) for src in files.split()]


def dry_run(d):
    """Every (flags, source) the Makefile in *d* would compile."""
    if d == "apps/toybox":
        return toybox_tus()
    cmd = (["make", "-Bnw", f"CC={TCC}", "ROOTFS_OPT_CFLAGS=-O2",
            "ROOTFS_DEBUG_CFLAGS="] + MAKE_VARS.get(d, [])
           + MAKE_TARGET.get(d, []))
    p = subprocess.run(cmd, cwd=f"{TOP}/{d}", capture_output=True, text=True)
    tus = [t for t in (parse_compile(l) for l in p.stdout.splitlines()) if t]
    return tus


def to_gcc(flags):
    """The same compile, expressed for gcc: keep what describes the *program*,
    replace what describes tcc's own ABI, drop what only concerns linking."""
    out, skip = [], False
    for f in flags:
        if skip:
            if skip == "keep":
                out.append(f)
            skip = False
            continue
        if f in ("-I", "-D", "-isystem", "-include"):
            # The separated spelling. toybox writes `-I .`, and dropping the
            # `.` leaves a bare `-I` that swallows the next real flag instead.
            out.append(f); skip = "keep"
        elif f.startswith(("-I", "-D", "-std=")):
            out.append(f)
        elif f == "-nostdinc":
            out.append(f)
        # everything else — -L, -share-rodata, -g, -fPIC/-fpie, -mcpu,
        # -fvisibility, -W*, -pedantic, -nostdlib — is either a link flag, a
        # tcc-only spelling, or supplied by GCC_ABI below.
    if not any(f.startswith("-std=") for f in out):
        # gcc 15 defaults to C23, where an implicit declaration is an error and
        # these sources have a few; tcc's own default is C11-with-GNU. Matching
        # the dialect is part of "the same flags", not a concession.
        out.append("-std=gnu11")
    return out


def sections(obj):
    """(.text bytes, .text+.rodata bytes) from the section headers."""
    p = subprocess.run(["arm-none-eabi-objdump", "-h", obj],
                       capture_output=True, text=True)
    text = ro = 0
    for line in p.stdout.splitlines():
        parts = line.split()
        if len(parts) > 3 and re.match(r"^\d+$", parts[0]):
            name, size = parts[1], int(parts[2], 16)
            if name.startswith(".text"):
                text += size
            elif name.startswith(".rodata"):
                ro += size
    return text, text + ro


def main():
    os.makedirs(OUT, exist_ok=True)
    rows, failures = [], []
    for cat, dirs in CATEGORIES:
        for d in dirs:
            for k, (flags, src) in enumerate(dry_run(d)):
                cwd = f"{TOP}/{d}"
                if os.path.isabs(src):
                    # the FPU sub-make spells its sources absolutely
                    cwd, src = os.path.dirname(src), os.path.basename(src)
                elif not os.path.exists(f"{cwd}/{src}"):
                    # `make -nBw` prints no "Entering directory" for the arch
                    # sub-makes, so their sources are relative to their own
                    # directory. Find the one file that matches rather than
                    # guessing the directory.
                    hits = subprocess.run(["find", cwd, "-path", f"*/{src}"],
                                          capture_output=True, text=True).stdout.split()
                    if len(hits) != 1:
                        failures.append(("resolve", d, src, f"{len(hits)} matches"))
                        continue
                    cwd, src = os.path.dirname(hits[0]), os.path.basename(hits[0])
                tag = f"{d}/{src}".replace("/", "_").replace(".", "_")
                got = {}
                gflags = to_gcc(flags) + GCC_ABI + ["-isystem", GCC_INC,
                                                    "-I", ROOTFS_INC]
                for who, cc, extra, lvl in (("tcc0", TCC, flags, ["-O0"]),
                                            ("tcc", TCC, flags, OPT),
                                            ("gcc", GCC, gflags, OPT),
                                            # tcc aliases -Os to -O2, so gcc at
                                            # -Os is the size bound tcc has no
                                            # way to ask for. Reported beside
                                            # the like-for-like -O2 column, not
                                            # instead of it.
                                            ("gccos", GCC, gflags, ["-Os"])):
                    obj = f"{OUT}/{tag}.{who}.o"
                    p = subprocess.run([cc] + extra + lvl + ["-c", src, "-o", obj],
                                       cwd=cwd, capture_output=True, text=True)
                    if p.returncode != 0 or not os.path.exists(obj):
                        failures.append((who, d, src, p.stderr.strip()[:300]))
                        break
                    got[who] = sections(obj)
                else:
                    rows.append(dict(cat=cat, dir=d, src=src,
                                     tcc0_text=got["tcc0"][0], tcc0_all=got["tcc0"][1],
                                     tcc_text=got["tcc"][0], gcc_text=got["gcc"][0],
                                     gccos_text=got["gccos"][0],
                                     tcc_all=got["tcc"][1], gcc_all=got["gcc"][1],
                                     gccos_all=got["gccos"][1]))
    json.dump(dict(rows=rows, failures=failures), open(f"{OUT}/../gcc_compare.json", "w"), indent=1)

    by = collections.defaultdict(lambda: [0, 0, 0, 0, 0])
    for r in rows:
        a = by[r["cat"]]
        a[0] += r["tcc_text"]; a[1] += r["gcc_text"]
        a[2] += r["gccos_text"]; a[3] += 1; a[4] += r["tcc0_text"]
    hdr = (f"{'category':20} {'TUs':>4} {'tcc -O0':>10} {'tcc -O2':>10} {'gcc -O2':>10}"
           f" {'x':>6} {'gcc -Os':>10} {'x':>6}")
    print(hdr); print("-" * len(hdr))
    tot = [0, 0, 0, 0, 0]
    for cat, _ in CATEGORIES:
        a = by.get(cat)
        if not a:
            continue
        for i in range(5):
            tot[i] += a[i]
        print(f"{cat:20} {a[3]:>4} {a[4]:>10,} {a[0]:>10,} {a[1]:>10,}"
              f" {a[0]/max(1,a[1]):>6.3f} {a[2]:>10,} {a[0]/max(1,a[2]):>6.3f}")
    print("-" * len(hdr))
    print(f"{'TOTAL':20} {tot[3]:>4} {tot[4]:>10,} {tot[0]:>10,} {tot[1]:>10,}"
          f" {tot[0]/max(1,tot[1]):>6.3f} {tot[2]:>10,} {tot[0]/max(1,tot[2]):>6.3f}")
    print("\nPY_LANES = [")
    for cat, _ in CATEGORIES:
        a = by.get(cat)
        if a:
            print(f'    ("{cat}", {a[4]:_}, {a[0]:_}, {a[1]:_}),')
    print("]")
    if failures:
        print(f"\n{len(failures)} TU(s) did not compile on one side:")
        seen = set()
        for who, d, src, err in failures:
            if (who, d) in seen:
                continue
            seen.add((who, d))
            print(f"  [{who}] {d}/{src}: {err.splitlines()[0] if err else '?'}")


if __name__ == "__main__":
    main()
