#!/usr/bin/env python3
"""
 Copyright (c) 2026 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 """

"""Build the plain-text man pages YasOS reads with usr/bin/man.

    scripts/man/build_man.py rootfs/usr/share/man --rootfs rootfs \\
        [--zig-source ~/repos/zig] [--zig .cache/zig-build/host-st/bin/zig]

Pages are ASCII text in man layout.  By default they are packed into xz
blocks of about 64 KB (OUT/bNN.xz) with OUT/index ("name block offset
length"); usr/bin/man unpacks the one block, cuts the page out into /tmp
and shows it with `more` (apps/more).  --compress gzip writes NAME.txt.gz,
--compress none plain NAME.txt.  OUT/whatis is the `man -k` index (one
"name - description" per page) and OUT/aliases maps other names to a page
("fprintf printf"), so `man fprintf` opens printf.txt.

Pages, all generated on the PC (nothing is converted on the board):

  man/*.txt (in-tree)   hand-written: pio, pioasm, rp2350-pio, ...
  libc                  one page per header (what yasos libc declares,
                        and which of it is really implemented), and the
                        Linux man-pages section 3 page of every function
                        the yasos libraries implement, with a YasOS note
                        on top; yasos-libc(7) summarises
  tcc                   tinycc's tcc-doc.texi (makeinfo --plain), the
                        cross's -h/-hh option summary, and the pages
                        tinycc keeps beside its features
                        (libs/tinycc/docs/man/*.txt: yasc-modules, ...)
  zig                   the language reference (doc/langref.html.in of
                        --zig-source, one page per chapter) and the CLI
                        help of --zig; skipped without them
  fatfs                 FatFs's HTML documentation (libs/zfat vendor)

Missing tools or sources skip their part with a message; the build goes on.
"""

import argparse
import gzip
import html
import os
import re
import shutil
import subprocess
import sys
import textwrap
from html.parser import HTMLParser
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WIDTH = 78
XZ_BLOCK = 64 * 1024  # uncompressed bytes per xz block, see pack_xz_blocks
BODY = 7  # nroff's body indent

# The libraries a YasOS program can link, and how.
LIBRARIES = [
    ("libc", "libs/libc/build/libc.a", "linked by default"),
    ("libm", "libs/libm/build/libm.a", "-lm"),
    ("libpthread", "libs/pthread/build/libpthread.a", "-lpthread"),
    ("libdl", "libs/libdl/build/libdl.a", "-ldl"),
    ("libtermcap", "libs/termcap/build/libtermcap.a", "-ltermcap"),
    ("libncurses", "libs/yasos_curses/build/libncurses.a", "-lncurses"),
    ("libtcc1", "rootfs/usr/lib/armv8m-libtcc1.a", "tcc's runtime, linked by default"),
]

# Headers that belong to the compiler, not to the C library.
SKIP_HEADERS = {"stdatomic.h", "tccdefs.h", "tccdecls.h", "tcclib.h", "tcc_stdint.h", "libtcc.h", "varargs.h"}

MAN3 = Path("/usr/share/man/man3")


def log(msg):
    print(f"build_man: {msg}", file=sys.stderr)


def ascii_only(text):
    return text.encode("ascii", "replace").decode("ascii").replace("\t", "        ")


def header_line(name, section, middle="YasOS Manual"):
    left = f"{name.upper()}({section})"
    gap = WIDTH - 2 * len(left) - len(middle)
    if gap < 2:
        return f"{left}  {middle}"
    return left + " " * (gap // 2) + middle + " " * (gap - gap // 2) + left


def wrap(text, indent=BODY, hang=0):
    return textwrap.wrap(text, WIDTH, initial_indent=" " * indent,
                         subsequent_indent=" " * (indent + hang),
                         break_long_words=False, break_on_hyphens=False) or [""]


class Pages:
    """The output directory, the whatis index and the aliases."""

    def __init__(self, out):
        self.out = out
        self.whatis = {}
        self.aliases = {}

    def add(self, name, text, desc=None):
        text = ascii_only(text).rstrip() + "\n"
        (self.out / f"{name}.txt").write_text(text)
        if desc is None:
            desc = name_line(text)
        self.whatis[name] = desc or name

    def alias(self, other, name):
        if other != name and other not in self.whatis:
            self.aliases.setdefault(other, name)

    def finish(self, compress):
        if compress == "gzip":
            # One gzip per page: 2.7x smaller, a page inflates on its own.
            for path in sorted(self.out.glob("*.txt")):
                data = path.read_bytes()
                with open(str(path) + ".gz", "wb") as f:
                    f.write(gzip.compress(data, compresslevel=9, mtime=0))
                path.unlink()
        elif compress == "xz":
            self.pack_xz_blocks()
        with open(self.out / "whatis", "w") as f:
            for name in sorted(self.whatis):
                f.write(f"{name} - {self.whatis[name]}\n")
        with open(self.out / "aliases", "w") as f:
            for other in sorted(self.aliases):
                if other not in self.whatis:
                    f.write(f"{other} {self.aliases[other]}\n")


    def pack_xz_blocks(self):
        """Pages of one topic concatenated into ~64 KB blocks, each an xz
        file (bNN.xz); OUT/index has "name block offset length" per page.

        Measured on the Pico Plus 2 (toybox xzcat): a 64 KB block unpacks
        in 0.09 s, 128 KB in 0.6 s, 318 KB in 1.8 s -- so blocks stay small
        and a page costs one block.  All pages: 2.1 MB plain, 0.77 MB as
        gzip per page, 0.52 MB like this."""
        import lzma
        pages = sorted(self.out.glob("*.txt"), key=lambda p: (page_topic(p), p.name))
        filters = [{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME,
                    "dict_size": XZ_BLOCK}]
        index, block, number, topic = [], bytearray(), 0, None

        def flush():
            nonlocal block, number
            if block:
                data = lzma.compress(bytes(block), format=lzma.FORMAT_XZ,
                                     check=lzma.CHECK_CRC32, filters=filters)
                (self.out / f"b{number:02d}.xz").write_bytes(data)
                number += 1
                block = bytearray()

        for path in pages:
            text = path.read_bytes()
            t = page_topic(path)
            if block and (len(block) + len(text) > XZ_BLOCK or t != topic):
                flush()
            topic = t
            index.append(f"{path.name[:-4]} b{number:02d}.xz {len(block)} {len(text)}")
            block += text
            path.unlink()
        flush()
        (self.out / "index").write_text("\n".join(index) + "\n")


def page_topic(path):
    """Which pages share blocks: similar text packs tighter."""
    name = path.name[:-4]
    head = path.read_text(errors="replace").split("\n", 1)[0]
    if name.startswith("zig"):
        return "zig"
    if "FatFs" in head:
        return "fatfs"
    if name.endswith(".h"):
        return "headers"
    if "Linux Programmer" in head or "Library Functions" in head or "System Calls" in head:
        return "libc"
    return "other"


def name_line(text):
    """The description after "name - " in the NAME section."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "NAME":
            body = []
            for nxt in lines[i + 1:]:
                if not nxt.strip():
                    if body:
                        break
                    continue
                if not nxt.startswith(" "):
                    break
                body.append(nxt.strip())
            joined = " ".join(body)
            if " - " in joined:
                return joined.split(" - ", 1)[1].strip()
            return joined
    return ""


# ----------------------------------------------------------------- hand-written

def handwritten(pages, src):
    if not src.is_dir():
        return
    count = 0
    for path in sorted(src.glob("*.txt")):
        text = path.read_text()
        pages.add(path.stem, text)
        # "reboot, halt, poweroff - ..." on the NAME line: `man halt` finds it.
        for other in page_names(text):
            pages.alias(other, path.stem)
        count += 1
    log(f"{count} hand-written page(s) from {src}")


# ------------------------------------------------------------------------- libc

def archive_symbols(path):
    """Global symbols defined in an ar archive, from its "/" symbol index."""
    data = path.read_bytes()
    if not data.startswith(b"!<arch>\n"):
        return set()
    syms = set()
    pos = 8
    while pos + 60 <= len(data):
        name = data[pos:pos + 16].decode("latin-1").strip()
        size = int(data[pos + 48:pos + 58].decode("latin-1").strip() or 0)
        body = data[pos + 60:pos + 60 + size]
        if name == "/":
            count = int.from_bytes(body[:4], "big")
            names = body[4 + 4 * count:].split(b"\0")
            syms |= {n.decode("latin-1") for n in names[:count] if n}
        elif body.startswith(b"\x7fELF"):
            syms |= elf_symbols(body)
        else:
            # libc's Makefile archives arm/*.S as source text; their symbols
            # are still in libc.so, so take them from the .global lines.
            syms |= set(re.findall(r"^\s*\.glob(?:a)?l\s+(\w+)", body.decode("latin-1"), re.M))
        pos += 60 + size + (size & 1)
    return syms


def elf_symbols(obj):
    """Defined global and weak symbols of an ELF32 little-endian object."""
    u16 = lambda o: int.from_bytes(obj[o:o + 2], "little")
    u32 = lambda o: int.from_bytes(obj[o:o + 4], "little")
    if len(obj) < 52 or obj[4] != 1 or obj[5] != 1:
        return set()
    shoff, shentsize, shnum = u32(0x20), u16(0x2E), u16(0x30)
    sections = [shoff + i * shentsize for i in range(shnum)]
    out = set()
    for sh in sections:
        if u32(sh + 4) != 2:  # SHT_SYMTAB
            continue
        off, size = u32(sh + 0x10), u32(sh + 0x14)
        strtab = u32(sections[u32(sh + 0x18)] + 0x10)
        for sym in range(off + 16, off + size, 16):
            bind, shndx = obj[sym + 12] >> 4, u16(sym + 14)
            if bind in (1, 2) and shndx != 0:
                start = strtab + u32(sym)
                out.add(obj[start:obj.index(b"\0", start)].decode("latin-1"))
    return out


def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    src = src.replace("\\\n", " ")
    return "\n".join(line for line in src.splitlines() if not line.lstrip().startswith("#"))


def remove_balanced(text, word):
    """Drop `word(...)` with balanced parentheses (attributes, asm labels)."""
    out = []
    i = 0
    while True:
        j = text.find(word, i)
        if j < 0:
            out.append(text[i:])
            return "".join(out)
        out.append(text[i:j])
        k = text.find("(", j)
        if k < 0 or text[j + len(word):k].strip():
            out.append(word)
            i = j + len(word)
            continue
        depth = 0
        while k < len(text):
            if text[k] == "(":
                depth += 1
            elif text[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        i = k + 1


def declarations(src):
    """Top-level statements of a header, with bodies of braces skipped."""
    src = strip_comments(src)
    stmts, cur, depth = [], [], 0
    for ch in src:
        if depth:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            continue
        if ch == "{":
            text = "".join(cur).strip()
            if text in ('extern "C"', "extern 'C'"):
                cur = []
                continue
            if text.endswith(")"):
                stmts.append((text, True))  # an inline function: defined here
                cur = []
            depth = 1
            continue
        if ch == "}":
            cur = []  # the end of an extern "C" block
            continue
        if ch == ";":
            stmts.append(("".join(cur).strip(), False))
            cur = []
            continue
        cur.append(ch)
    return stmts


def function_name(stmt):
    s = " ".join(stmt.split())
    if not s or s.startswith("typedef") or "(" not in s:
        return None, None
    for word in ("__attribute__", "__asm__", "__asm", "asm", "__declspec"):
        s = remove_balanced(s, word)
    s = " ".join(s.split())
    m = re.search(r"\(\s*\*\s*(\w+)\s*\(", s)  # void (*signal(int, ...))(int)
    if m and s.index("(") == m.start():
        return m.group(1), s
    m = re.match(r"(.*?)\b(\w+)\s*\(", s)
    if not m or not m.group(1).strip():
        return None, None
    name = m.group(2)
    if name in ("if", "while", "for", "return", "sizeof", "defined"):
        return None, None
    return name, s


def header_name(path, root):
    rel = path.relative_to(root).as_posix()
    return rel, rel.replace("/", "-")


def render_man3(path):
    raw = gzip.decompress(path.read_bytes()) if path.suffix == ".gz" else path.read_bytes()
    proc = subprocess.run(
        ["groff", "-t", "-e", "-mandoc", "-Tascii", "-P-cbu", f"-rLL={WIDTH}n", "-rcR=1", "-rHY=0"],
        input=raw, capture_output=True, cwd="/usr/share/man")
    if proc.returncode != 0 or not proc.stdout:
        return None
    col = subprocess.run(["col", "-bx"], input=proc.stdout, capture_output=True)
    return col.stdout.decode("ascii", "replace")


def find_man3(name):
    """Section 3, else section 2 (the system-call wrappers: close, chdir)."""
    for d, sec in ((MAN3, "3"), (MAN3.parent / "man2", "2")):
        for cand in (f"{name}.{sec}.gz", f"{name}.{sec}", f"{name}.{sec}x.gz", f"{name}.{sec}x"):
            path = d / cand
            if path.exists():
                return resolve_so(path)
    return None


def resolve_so(path, depth=0):
    """Follow `.so man3/other.3` redirections to the real page."""
    raw = gzip.decompress(path.read_bytes()) if path.suffix == ".gz" else path.read_bytes()
    first = raw.split(b"\n", 1)[0].decode("latin-1").strip()
    if first.startswith(".so ") and depth < 4:
        target = Path("/usr/share/man") / first[4:].strip()
        for cand in (target, Path(str(target) + ".gz")):
            if cand.exists():
                return resolve_so(cand, depth + 1)
        return None
    return path


def page_names(text):
    """The function names a man3 page's NAME section lists."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == "NAME":
            body = []
            for nxt in lines[i + 1:]:
                if not nxt.strip() and body:
                    break
                body.append(nxt.strip())
            joined = " ".join(body).split(" - ", 1)[0]
            return [n.strip() for n in joined.replace(",", " ").split() if re.match(r"^\w+$", n.strip())]
    return []


def libc_pages(pages, rootfs):
    include = rootfs / "usr/include"
    if not include.is_dir():
        log(f"no {include}: skipping the libc pages")
        return
    have_archives = False
    impl = {}  # function -> library
    for lib, rel, _ in LIBRARIES:
        path = REPO / rel
        if path.exists():
            have_archives = True
            for sym in archive_symbols(path):
                impl.setdefault(sym, lib)
    if not have_archives:
        log("no built libraries under libs/*/build: every declared function counts as implemented")
    flags = {lib: how for lib, _, how in LIBRARIES}

    declared = {}  # header -> [(name, prototype)]
    inline = set()     # functions defined in a header (static inline)
    mentioned = set()  # every identifier in the headers
    where = {}     # function -> header
    for path in sorted(include.rglob("*.h")):
        if path.name in SKIP_HEADERS:
            continue
        rel, _ = header_name(path, include)
        seen = set()
        src = path.read_text(errors="replace")
        mentioned.update(re.findall(r"\b[A-Za-z_]\w*\b", strip_comments(src)))
        for stmt, body in declarations(src):
            name, proto = function_name(stmt)
            if name and body:
                inline.add(name)
            if name and name not in seen:
                seen.add(name)
                declared.setdefault(rel, []).append((name, proto + ";"))
                where.setdefault(name, rel)

    def implemented(name):
        return name in impl or name in inline or not have_archives

    # One page per header.
    for rel, funcs in sorted(declared.items()):
        _, page = header_name(include / rel, include)
        yes = [(n, p) for n, p in funcs if implemented(n)]
        no = [(n, p) for n, p in funcs if not implemented(n)]
        out = [header_line(page, 3), "", "NAME", f"{' ' * BODY}{rel} - what yasos libc declares in <{rel}>",
               "", "SYNOPSIS", f"{' ' * BODY}#include <{rel}>", "",
               "DESCRIPTION"]
        out += wrap(f"The functions <{rel}> declares, as written in /usr/include/{rel}. "
                    "Each name with a page opens with man NAME. Macros, types and "
                    "constants are in the header itself.")
        if yes:
            out += ["", "FUNCTIONS"]
            for name, proto in yes:
                lib = impl.get(name, "libc")
                note = "" if lib == "libc" else f"   ({flags[lib]})"
                out += wrap(proto + note, hang=4)
        if no:
            out += ["", "DECLARED BUT NOT IMPLEMENTED"]
            out += wrap("Declared here but defined in no yasos library: a program "
                        "that calls one compiles and then fails to link.")
            out.append("")
            for name, proto in no:
                out += wrap(proto, hang=4)
        out += ["", "SEE ALSO", f"{' ' * BODY}yasos-libc(7)"]
        pages.add(page, "\n".join(out))
        if page != rel:
            pages.alias(rel, page)

    # The Linux man-pages page of each implemented function.
    have_groff = shutil.which("groff") and shutil.which("col")
    if not have_groff or not MAN3.is_dir():
        log("no groff/col or /usr/share/man/man3: skipping the function pages")
    rendered = {}  # page file -> page name
    nopage = []
    for name in sorted(where):
        if not implemented(name):
            continue
        src = find_man3(name) if have_groff and MAN3.is_dir() else None
        if src is None:
            nopage.append(name)
            continue
        if src in rendered:
            pages.alias(name, rendered[src])
            continue
        text = render_man3(src)
        if not text:
            nopage.append(name)
            continue
        page = re.sub(r"\.[23]\w*(\.gz)?$", "", src.name)
        if page in pages.whatis and page not in rendered.values():
            page = f"{page}.3"
        rendered[src] = page
        listed = [n for n in page_names(text) if n in where] or [name]
        here = sorted({where[n] for n in listed if n in where})
        libs = sorted({impl.get(n, "libc") for n in listed if implemented(n)})
        missing = [n for n in page_names(text) if not implemented(n)]
        note = ["YASOS"]
        note += wrap(f"Declared in {', '.join('<' + h + '>' for h in here)}; in "
                     + ", ".join(f"{lib} ({flags[lib]})" for lib in libs) + ".", indent=5)
        if missing:
            note += wrap("Not in yasos libc: " + ", ".join(missing) + ".", indent=5)
        note += wrap("This page is from Linux man-pages and describes glibc and POSIX; "
                     "yasos libc may differ. See yasos-libc(7).", indent=5)
        lines = text.rstrip().splitlines()
        body = lines[:1] + [""] + note + lines[1:]
        pages.add(page, "\n".join(body))
        for n in listed:
            if implemented(n):
                pages.alias(n, page)
        pages.alias(name, page)

    # The summary.
    undeclared = sorted(s for s in impl if impl[s] == "libc" and s not in mentioned
                        and not s.startswith("_") and re.match(r"^[a-z]\w*$", s))
    unimpl = sorted(n for n in where if not implemented(n))
    out = [header_line("yasos-libc", 7), "", "NAME",
           f"{' ' * BODY}yasos-libc - the C library and other libraries of YasOS", "",
           "DESCRIPTION"]
    out += wrap("YasOS programs are compiled with tcc on the board (or armv8m-tcc on a PC) "
                "against the headers in /usr/include and the libraries in /usr/lib. "
                "The C library is a small libc of its own (parts from musl and neatlibc), "
                "not glibc: the function pages here come from Linux man-pages and say "
                "what POSIX and glibc do, so read them with that in mind.")
    out += ["", "LIBRARIES"]
    for lib, rel, how in LIBRARIES:
        n = sum(1 for s in impl if impl[s] == lib)
        if n == 0:
            how += "; empty, its functions are in libc"
        out += wrap(f"{lib:<12} {n:>4} symbols   {how}", hang=24)
    out += ["", "HEADERS"]
    for rel in sorted(declared):
        _, page = header_name(include / rel, include)
        yes = sum(1 for n, _ in declared[rel] if implemented(n))
        out += wrap(f"{rel:<22} {yes:>3} of {len(declared[rel]):>3} functions   man {page}")
    if unimpl:
        out += ["", "DECLARED BUT NOT IMPLEMENTED"]
        out += wrap("A program that calls one of these compiles and then fails to link:")
        out.append("")
        out += wrap(" ".join(unimpl))
    if undeclared:
        out += ["", "IMPLEMENTED BUT NOT DECLARED"]
        out += wrap("In libc but declared in no header: declare it yourself (with the "
                    "POSIX prototype) to use it, or add it to the header:")
        out.append("")
        out += wrap(" ".join(undeclared))
    if nopage:
        out += ["", "FUNCTIONS WITHOUT A PAGE"]
        out += wrap(" ".join(sorted(n for n in nopage if not n.startswith("_"))))
    out += ["", "SEE ALSO", f"{' ' * BODY}tcc(1), tcc-options(1), man(1)"]
    pages.add("yasos-libc", "\n".join(out))
    log(f"libc: {len(declared)} headers, {len(rendered)} function pages, "
        f"{len(unimpl)} declared-not-implemented, {len(nopage)} without a page")


# -------------------------------------------------------------------------- tcc

def tcc_pages(pages):
    tinycc = REPO / "libs/tinycc"
    texi = tinycc / "tcc-doc.texi"
    if texi.exists() and shutil.which("makeinfo"):
        proc = subprocess.run(["makeinfo", "--plain", "--no-split", "--fill-column=76", texi.name],
                              cwd=tinycc, capture_output=True, text=True)
        if proc.returncode == 0 and proc.stdout:
            out = [header_line("tcc", 1), "", "NAME",
                   f"{' ' * BODY}tcc - Tiny C Compiler, the compiler of YasOS", "", "NOTES"]
            out += wrap("YasOS runs a fork of TinyCC (libs/tinycc in yasos.zig) that targets "
                        "ARMv8-M Thumb-2 through its own IR and optimiser; -O0, -O1 and -O2 "
                        "work. The reference below is upstream's; the x86, PE and Windows "
                        "parts do not apply. Options: tcc-options(1). Libraries: "
                        "yasos-libc(7).")
            out += ["", "REFERENCE", ""] + proc.stdout.splitlines()
            pages.add("tcc", "\n".join(out))
        else:
            log(f"makeinfo failed on {texi}: {proc.stderr.strip()[:200]}")
    else:
        log("no tcc-doc.texi or makeinfo: skipping tcc(1)")

    cross = tinycc / "bin/armv8m-tcc"
    if cross.exists():
        helps = []
        for flag in ("-h", "-hh"):
            proc = subprocess.run([str(cross), flag], capture_output=True, text=True)
            helps.append((proc.stdout + proc.stderr).rstrip())
        out = [header_line("tcc-options", 1), "", "NAME",
               f"{' ' * BODY}tcc-options - tcc's command-line options (-h and -hh)", "",
               "DESCRIPTION"]
        out += wrap("What tcc -h and tcc -hh print. Taken from the cross compiler, which is "
                    "built from the same source as the board's tcc.")
        out += ["", "TCC -H", ""] + [" " * BODY + l if l else "" for l in helps[0].splitlines()]
        out += ["", "TCC -HH", ""] + [" " * BODY + l if l else "" for l in helps[1].splitlines()]
        out += ["", "SEE ALSO", f"{' ' * BODY}tcc(1), yasos-libc(7)"]
        pages.add("tcc-options", "\n".join(out))
    else:
        log("no libs/tinycc/bin/armv8m-tcc: skipping tcc-options(1)")

    # hand-written pages that live with the tinycc features they describe
    handwritten(pages, tinycc / "docs/man")


# ------------------------------------------------------------------ HTML -> text

class Html2Text(HTMLParser):
    """Enough HTML for FatFs's docs and Zig's langref: headings, paragraphs,
    pre, lists, definition lists and tables."""

    SKIP = {"head", "script", "style", "title"}

    def __init__(self, base=BODY):
        super().__init__(convert_charrefs=True)
        self.lines = []
        self.base = base
        self.indent = base
        self.inline = []
        self.pre = None
        self.skip = 0
        self.heading = None
        self.bullets = []
        self.bullet = ""
        self.table = None
        self.cell = None

    # helpers
    def blank(self):
        if self.lines and self.lines[-1] != "":
            self.lines.append("")

    def flush(self):
        text = " ".join("".join(self.inline).split())
        self.inline = []
        if self.cell is not None:
            self.cell.append(text)
            return
        if not text:
            return
        self.lines += wrap(self.bullet + text, indent=self.indent, hang=len(self.bullet))
        self.bullet = ""

    # parser callbacks
    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
            return
        if self.skip:
            return
        if self.pre is not None:
            return
        if tag in ("p", "div"):
            self.flush()
            if self.table is None:
                self.blank()
        elif re.match(r"h[1-6]$", tag):
            self.flush()
            self.blank()
            self.heading = int(tag[1])
        elif tag == "pre":
            self.flush()
            self.pre = []
        elif tag in ("ul", "ol"):
            self.flush()
            self.bullets.append(self.indent)
            self.indent += 2
        elif tag == "li":
            self.flush()
            self.bullet = "- "
        elif tag == "dt":
            self.flush()
            self.blank()
        elif tag == "dd":
            self.flush()
            self.indent += 4
        elif tag == "br":
            self.flush()
        elif tag == "table":
            self.flush()
            self.table = []
        elif tag == "tr" and self.table is not None:
            self.end_cell()
            self.table.append([])
        elif tag in ("td", "th") and self.table is not None:
            self.end_cell()
            self.cell = []
        elif tag == "img":
            self.inline.append("[figure]")

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip = max(0, self.skip - 1)
            return
        if self.skip:
            return
        if tag == "pre" and self.pre is not None:
            raw = "".join(self.pre).strip("\n")
            self.pre = None
            self.blank()
            for line in raw.expandtabs(4).splitlines():
                self.lines.append((" " * (self.indent + 4) + line).rstrip())
            self.blank()
            return
        if self.pre is not None:
            return
        if re.match(r"h[1-6]$", tag) and self.heading:
            title = " ".join("".join(self.inline).split())
            self.inline = []
            level, self.heading = self.heading, None
            if level <= 2:
                self.lines.append(title.upper())
            else:
                self.lines.append(" " * 3 + title)
            self.indent = self.base
            return
        if tag in ("p", "div"):
            self.flush()
        elif tag in ("ul", "ol"):
            self.flush()
            if self.bullets:
                self.indent = self.bullets.pop()
            self.blank()
        elif tag == "li":
            self.flush()
        elif tag == "dd":
            self.flush()
            self.indent = max(self.base, self.indent - 4)
        elif tag == "dt":
            self.flush()
        elif tag in ("td", "th", "tr"):
            self.end_cell()
        elif tag == "table" and self.table is not None:
            self.end_cell()
            rows = [r for r in self.table if r]
            self.table = None
            self.emit_table(rows)

    def handle_data(self, data):
        if self.skip:
            return
        if self.pre is not None:
            self.pre.append(data)
        else:
            self.inline.append(data)

    def end_cell(self):
        """Close a cell; FatFs's HTML leaves some </td> out."""
        if self.cell is None:
            return
        self.flush()
        if self.table:
            self.table[-1].append(" ".join(self.cell))
        self.cell = None

    def emit_table(self, rows):
        if not rows:
            return
        ncol = max(len(r) for r in rows)
        rows = [r + [""] * (ncol - len(r)) for r in rows]
        widths = [max(len(r[c]) for r in rows) for c in range(ncol)]
        self.blank()
        if self.indent + sum(widths) + 2 * (ncol - 1) <= WIDTH:
            for r in rows:
                line = "  ".join(r[c].ljust(widths[c]) for c in range(ncol))
                self.lines.append((" " * self.indent + line).rstrip())
        else:
            for r in rows:
                first = True
                for c in range(ncol):
                    if not r[c]:
                        continue
                    self.lines += wrap(r[c], indent=self.indent + (0 if first else 4), hang=0)
                    first = False
        self.blank()

    def text(self):
        self.flush()
        out = []
        for line in self.lines:
            if line == "" and out and out[-1] == "":
                continue
            out.append(line)
        return "\n".join(out).strip("\n")


def html_to_text(src, base=BODY):
    parser = Html2Text(base)
    parser.feed(src)
    parser.close()
    return parser.text()


# ------------------------------------------------------------------------ fatfs

def fatfs_pages(pages):
    docs = REPO / "libs/zfat/vendor/fatfs/documents"
    if not docs.is_dir():
        log(f"no {docs}: skipping the FatFs pages")
        return
    ff_h = REPO / "libs/zfat/vendor/fatfs/source/ff.h"
    m = re.search(r"FatFs - Generic FAT Filesystem module\s+(R[\w.]+)", ff_h.read_text(errors="replace")) if ff_h.exists() else None
    version = f"FatFs {m.group(1)}" if m else "FatFs"
    names = []
    for path in sorted((docs / "doc").glob("*.html")):
        src = path.read_text(errors="replace")
        h2 = re.search(r"<h2>(.*?)</h2>", src, re.S)
        title = html.unescape(re.sub(r"<[^>]+>", "", h2.group(1))).strip() if h2 else path.stem
        first_p = re.search(r"</h2>\s*<p>(.*?)</p>", src, re.S)
        desc = html.unescape(re.sub(r"<[^>]+>", "", first_p.group(1))) if first_p else title
        desc = " ".join(desc.split())
        if re.match(r"^(f_|disk_|get_fattime|ff_)\w*$", title):
            name, section = title, 3
        else:
            name, section = f"fatfs-{path.stem}", 7
        body = html_to_text(src)
        lines = body.splitlines()
        # The <h2> became the first line: replace it with a NAME section.
        if lines and lines[0].strip().upper() == title.upper():
            lines = lines[1:]
        while lines and not lines[0].strip():
            lines = lines[1:]
        if lines and " ".join(lines[0].split()) == desc:
            lines = lines[1:]
        short = desc if len(desc) < 70 else desc[:67].rsplit(" ", 1)[0] + "..."
        out = [header_line(name, section, version), "", "NAME", f"{' ' * BODY}{name} - {short}", ""]
        out += lines
        out += ["", "SEE ALSO", f"{' ' * BODY}fatfs(7)"]
        pages.add(name, "\n".join(out), short)
        names.append((name, short))

    index = docs / "00index_e.html"
    out = [header_line("fatfs", 7, version), "", "NAME",
           f"{' ' * BODY}fatfs - ChaN's FatFs, a FAT/exFAT filesystem module in C", ""]
    out += ["YASOS"]
    out += wrap("The kernel's FAT driver is built on this FatFs (libs/zfat in yasos.zig). "
                f"Its source, {version}, can be compiled into a program with tcc: ff.c, "
                "ffunicode.c, ffsystem.c and your own diskio.c (disk_initialize, "
                "disk_status, disk_read, disk_write, disk_ioctl). ffconf.h selects the "
                "features (fatfs-config).", indent=5)
    if index.exists():
        out += ["", ""] + html_to_text(index.read_text(errors="replace")).splitlines()
    out += ["", "PAGES"]
    for name, short in names:
        out += wrap(f"{name:<18} {short}", hang=19)
    pages.add("fatfs", "\n".join(out))
    log(f"fatfs: {len(names) + 1} pages")


# -------------------------------------------------------------------------- zig

def langref_pages(pages, zig_source, version):
    tmpl_path = zig_source / "doc/langref.html.in"
    if not tmpl_path.exists():
        log(f"no {tmpl_path}: skipping the Zig language reference")
        return
    tmpl = tmpl_path.read_text(errors="replace")
    code_dir = zig_source / "doc/langref"
    start = tmpl.find("{#header_open|")
    tmpl = tmpl[start:]
    end = tmpl.rfind("{#header_close#}")
    tmpl = tmpl[:end + len("{#header_close#}")]

    def code_file(name):
        path = code_dir / name
        if not path.exists():
            return f"<pre>[{html.escape(name)} not found]</pre>"
        lines = path.read_text(errors="replace").rstrip().splitlines()
        while lines and re.match(r"^// [\w-]+(=.*)?$", lines[-1].strip()):
            lines.pop()
        while lines and not lines[-1].strip():
            lines.pop()
        return f"<pre>{html.escape(chr(10).join(lines))}</pre>"

    def directive(m):
        parts = m.group(1).split("|")
        kind = parts[0]
        if kind == "code":
            return code_file(parts[1])
        if kind in ("syntax", "endsyntax"):
            return ""
        if kind == "link":
            return html.escape(parts[1])
        if kind == "see_also":
            return "<p>See also: " + html.escape(", ".join(parts[1:])) + ".</p>"
        if kind == "syntax_block":
            return "<pre>"
        if kind == "end_syntax_block":
            return "</pre>"
        if kind == "shell_samp":
            return "<pre>"
        if kind == "end_shell_samp":
            return "</pre>"
        return ""

    # Headings: numbered by nesting, turned into split markers and <hN>.
    level = 0
    chunks = []
    pos = 0
    for m in re.finditer(r"\{#(header_open\|[^#]*|header_close)#\}", tmpl):
        chunks.append(("text", tmpl[pos:m.start()]))
        pos = m.end()
        if m.group(1).startswith("header_open"):
            level += 1
            chunks.append(("open", level, m.group(1).split("|")[1]))
        else:
            level -= 1
    chunks.append(("text", tmpl[pos:]))

    chapters = []  # [title, [html parts], [subtitles]]
    for chunk in chunks:
        if chunk[0] == "open":
            _, lvl, title = chunk
            if lvl == 1:
                chapters.append([title, [], []])
                continue
            if not chapters:
                continue
            chapters[-1][1].append(f"<h{min(lvl, 4)}>{html.escape(title)}</h{min(lvl, 4)}>")
            if lvl == 2:
                chapters[-1][2].append(title)
        elif chapters:
            chapters[-1][1].append(chunk[1])

    def slug(title):
        return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", title.lower())).strip("-")

    names = []
    for title, parts, subs in chapters:
        src = re.sub(r"\{#([^#]*)#\}", directive, "".join(parts))
        body = html_to_text(src)
        name = f"zig-{slug(title)}"
        out = [header_line(name, 7, f"Zig {version}"), "", "NAME",
               f"{' ' * BODY}{name} - Zig language reference: {title}", "", "DESCRIPTION", ""]
        out += body.splitlines()
        out += ["", "SEE ALSO", f"{' ' * BODY}zig-lang(7), zig(1)"]
        pages.add(name, "\n".join(out), f"Zig language reference: {title}")
        names.append((name, title, subs))

    out = [header_line("zig-lang", 7, f"Zig {version}"), "", "NAME",
           f"{' ' * BODY}zig-lang - the Zig language reference, one page per chapter", "",
           "DESCRIPTION"]
    out += wrap(f"The language reference of Zig {version} (doc/langref.html.in of the "
                "compiler the board runs), as plain text. Each chapter is a page; the "
                "examples are the reference's own. For the standard library, read its "
                "source in /var/lib/zig/std (ctags -R /var/lib/zig/std, then jump with vi).")
    out += ["", "CHAPTERS"]
    for name, title, subs in names:
        out += wrap(f"{name:<32} {title}", hang=33)
    pages.add("zig-lang", "\n".join(out))
    log(f"zig: {len(names) + 1} language reference pages")


def zig_cli_page(pages, zig, version):
    helps = []
    for args in (["help"], ["build-obj", "--help"], ["test", "--help"]):
        proc = subprocess.run([str(zig)] + args, capture_output=True, text=True)
        helps.append((" ".join(["zig"] + args), (proc.stdout + proc.stderr).rstrip()))
    out = [header_line("zig", 1, f"Zig {version}"), "", "NAME",
           f"{' ' * BODY}zig - the Zig compiler", "", "YASOS"]
    out += wrap("The board's zig is the device build of the yasos Zig fork. It has no "
                "ELF linker: build objects as C (zig build-obj -ofmt=c) and compile and "
                "link them with tcc. Its lib is on the card at /var/lib/zig; pass "
                "--zig-lib-dir /var/lib/zig, since zig env panics on the device build. "
                "zig wants a writable HOME (export HOME=/tmp), and its cache is best in "
                "/tmp.", indent=5)
    for title, text in helps:
        out += ["", title.upper(), ""] + [" " * BODY + l if l else "" for l in text.splitlines()]
    out += ["", "SEE ALSO", f"{' ' * BODY}zig-lang(7), tcc(1)"]
    pages.add("zig", "\n".join(out))


def zig_pages(pages, zig_source, zig):
    version = None
    if zig and Path(zig).exists():
        proc = subprocess.run([str(zig), "version"], capture_output=True, text=True)
        version = proc.stdout.strip() or None
    if zig_source and not version:
        proc = subprocess.run(["git", "-C", str(zig_source), "describe", "--tags"],
                              capture_output=True, text=True)
        version = proc.stdout.strip() or None
    version = version or "(unknown version)"
    if zig and Path(zig).exists():
        zig_cli_page(pages, zig, version)
    else:
        log("no --zig: skipping zig(1)")
    if zig_source:
        langref_pages(pages, Path(zig_source), version)
    else:
        log("no --zig-source: skipping the Zig language reference")


# ------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1].strip())
    ap.add_argument("out", type=Path, help="output directory (rootfs/usr/share/man)")
    ap.add_argument("--rootfs", type=Path, default=REPO / "rootfs")
    ap.add_argument("--handwritten", type=Path, default=REPO / "man")
    ap.add_argument("--zig-source", type=Path, help="Zig source tree (doc/langref.html.in)")
    ap.add_argument("--zig", type=Path, help="a host zig of the board's version, for zig(1)")
    ap.add_argument("--compress", choices=("xz", "gzip", "none"), default="xz",
                    help="xz: 64 KB blocks + index (default); gzip: NAME.txt.gz; "
                         "none: NAME.txt")
    args = ap.parse_args()

    if args.out.exists():
        shutil.rmtree(args.out)
    args.out.mkdir(parents=True)
    pages = Pages(args.out)
    libc_pages(pages, args.rootfs)
    tcc_pages(pages)
    fatfs_pages(pages)
    zig_pages(pages, args.zig_source, args.zig)
    handwritten(pages, args.handwritten)  # last: a hand-written page wins
    pages.finish(compress=args.compress)
    size = sum(p.stat().st_size for p in args.out.iterdir())
    log(f"{len(pages.whatis)} pages, {len(pages.aliases)} aliases, {size // 1024} KB in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
