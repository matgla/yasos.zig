#!/usr/bin/env python3
"""Where a self-compile's board time goes: per function and per allocation site.

Compiles units of the tinycc self-host payload (scripts/tcc_selfhost.py
--prepare-only) on a board-model image (scripts/board_model.py image), one QEMU
per unit, under the rp2350_timing plugin.  Host profiles cannot answer this: on
the board a miss costs 84 cycles and the host cross inlines what the device does
not.

  selfhost_profile.py run IMAGE OUT [--ulimit KB] [--env K=V ...] [-j N] [--allocprof] [--opt -On]
                                    [--fast MODULE:FILE ...] [UNIT...]
                                                    --fast: what if these functions cost no XIP fetch
  selfhost_profile.py funcs IMAGE OUT [--top N]     cycles per function, tcc + libc + kernel
  selfhost_profile.py hotlist IMAGE OUT --kb N [--module tcc|libc|kernel] [--marks LIST]
                                                    the functions to run from SRAM, from a run on an image
                                                    without a list: fetch stall per byte
  selfhost_profile.py callers IMAGE BASE OUT FN... [--unit U] [--attr ENTRY,ZERO,LOOP]
                                                    who calls these on the device, where the host's
                                                    inlining cannot mislead
  selfhost_profile.py ab IMAGE_A IMAGE_B [--opt -On ...]
                                                    run both at each level, compare time and objects
  selfhost_profile.py allocs OUT [--top N]          misses per allocation site, and what SRAM could hold
  selfhost_profile.py compare OUT_A OUT_B           per-unit times and counters
  selfhost_profile.py poolmap OUT UNIT              who owned SRAM when tcc started
  selfhost_profile.py identity IMAGE_A IMAGE_B      do two images' crosses produce the same objects?

allocs needs an image whose native tcc declares its allocations, and the knobs
(--env TCC_TIER=N, TCC_ARENA_KB=N, TCC_POOLMAP=1) come with it; libs/tinycc/source/driver/libtcc.c
says what they do:

  TCC_NATIVE_EXTRA_CFLAGS=-DTCC_ALLOC_PROFILE scripts/board_model.py image prof
  selfhost_profile.py run prof OUT --allocprof --env TCC_ALLOCPROF=1 --env TCC_TIER=3 codegen tccpp
  selfhost_profile.py allocs OUT
"""
import argparse
import bisect
import collections
import csv
import hashlib
import importlib.util
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("board_model", REPO / "scripts/board_model.py")
bm = importlib.util.module_from_spec(spec)
sys.modules["board_model"] = bm
spec.loader.exec_module(bm)

CPI = 2.203
HZ = 532e6
DMISS = 84


def payload_src():
    """The payload frozen on first use: comparisons need one input, not the tree's."""
    src = bm.ROOT / "selfhost_src"
    if not (src / "build.sh").exists():
        tar = REPO / ".cache/tcc_selfhost/payload/src.tar.gz"
        if not tar.exists():
            sys.exit("no payload: scripts/tcc_selfhost.py --prepare-only --stages 2")
        src.mkdir(parents=True, exist_ok=True)
        subprocess.run(["tar", "xf", str(tar), "-C", str(src)], check=True)
    return src


def units_of(src):
    jobs = {}
    for line in (src / "build.sh").read_text().splitlines():
        m = re.match(r'\$CC (@rsp/\d+\.rsp) -o "\$O/([^"]+)\.o" -c (\S+?);', line)
        if m:
            jobs[m[2]] = (m[1], m[3])
    return jobs


def image_stamp(image):
    h = hashlib.sha256()
    for f in ("rootfs.img", "zig-out/bin/yasos_kernel"):
        h.update((image / f).read_bytes())
    return h.hexdigest()


def stamp_run(out, image):
    """A run keeps the units it finished, so a rebuilt image must not reuse them."""
    stamp, want = out / "image.sha256", image_stamp(image)
    if stamp.exists() and stamp.read_text().strip() != want:
        sys.exit(f"{out} holds results of another build of {image.name}: use a new directory")
    stamp.write_text(want + "\n")


def fast_ranges(image, specs, out):
    """--fast MODULE:FILE: the listed functions' flash ranges, for the plugin's fast=."""
    code = CodeMap(image)
    ranges = []
    for spec in specs:
        module, _, path = spec.partition(":")
        names = {re.sub(r"^=", "", l.strip()) for l in Path(path).read_text().splitlines()
                 if l.strip() and not l.startswith("#")}
        found = set()
        for lo, hi, name in code.spans(module):
            short = re.sub(r"__\d+$", "", name) if module == "kernel" else name
            if short in names:
                ranges.append((lo, hi))
                found.add(short)
        print(f"--fast {module}: {len(found)} of {len(names)} functions, "
              f"{sum(h - l for l, h in ranges)} bytes so far", flush=True)
    merged = []
    for lo, hi in sorted(ranges):
        if merged and lo <= merged[-1][1]:
            merged[-1][1] = max(hi, merged[-1][1])
        else:
            merged.append([lo, hi])
    path = out / "fast.txt"
    path.write_text("".join(f"{lo:x} {hi:x}\n" for lo, hi in merged))
    return path


def cmd_run(args):
    image = bm.image_dir(args.image)
    src = payload_src()
    jobs = units_of(src)
    names = args.units or list(jobs)
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    stamp_run(out, image)
    fast = fast_ranges(image, args.fast, out) if getattr(args, "fast", None) else None
    unit_extra = getattr(args, "unit_extra", None)
    py = next((r / "libs/tinycc/venv/bin/python3" for r in bm.HELPER_ROOTS if (r / "libs/tinycc/venv/bin/python3").exists()),
              Path(sys.executable))
    prefix = " ".join(args.env)
    opt = getattr(args, "opt", None)

    def one(unit):
        rsp, source = jobs[unit]
        txt, log = out / f"{unit}.txt", out / f"{unit}.plugin.log"
        if txt.exists() and "RC=0" in txt.read_text(errors="replace"):
            return unit, 0
        extra = f",pcprof={out}/{unit}.pc.csv,dprof={out}/{unit}.data.csv"
        if fast:
            extra += f",fast={fast}"
        if unit_extra:
            extra += unit_extra(unit)
        if getattr(args, "allocprof", False):
            extra += f",allocprof={out}/{unit}.alloc.csv"
        work = Path(tempfile.mkdtemp(prefix=f"{unit}_", dir=out))
        subprocess.run(["cp", "-a", "--reflink=auto", f"{src}/.", str(work)], check=True)
        if opt:  # in the response file: "-O2 ... -O0" is not the code "-O0" gives
            path = work / rsp[1:]
            text, n = re.subn(r"(?<!\S)-O\S*", opt, path.read_text())
            if n != 1:
                sys.exit(f"{path}: {n} optimisation flags")
            path.unlink()  # reflinked or not, the payload stays as it was
            path.write_text(text)
        env = bm.qemu_env(image, f"{extra} -d plugin -D {log}")
        env["YASOS_QEMU_EXTRA_ARGS"] = bm.AN524_ARGS + " " + env.pop("YASOS_QEMU_EXTRA_ARGS_APPEND")
        cmd = (f"cd /mnt && cat /proc/mempeak >/dev/null; ulimit -s {args.ulimit} && {prefix} tcc {rsp} -bench -o /tmp/o.o -c {source}; "
               "echo RC=$?; sha256sum /tmp/o.o; cat /proc/mempeak")
        # The real build runs under shells, which hold memory the whole time.
        for depth in range(args.nest):
            script = f"/tmp/n{depth}.sh"
            cmd = f"echo '{cmd}' > {script}; sh {script}; true" if "'" not in cmd else cmd
        t0 = time.time()
        r = subprocess.run([str(py), str(REPO / "scripts/qemu_mount.py"), "--kernel", str(image / "zig-out/bin/yasos_kernel"),
                            str(work), "--silence", "3000", "-c", cmd], env=env, capture_output=True, text=True, cwd=REPO)
        shutil.rmtree(work, ignore_errors=True)
        txt.write_text(r.stdout + "\n--- stderr\n" + r.stderr)
        print(f"{unit}: rc={r.returncode} host={time.time() - t0:.0f}s", flush=True)
        return unit, r.returncode

    with ThreadPoolExecutor(args.j) as pool:
        res = list(pool.map(one, names))
    failed = [u for u, rc in res if rc]
    if failed:
        print("failed:", failed)


def unit_stats(out, unit):
    x = (out / f"{unit}.txt").read_text(errors="replace")
    s = {"rc": (re.search(r"^RC=(\d+)", x, re.M) or [None, "?"])[1]}
    m = re.search(r"# ([\d.]+) s, \d+ lines/s", x)
    s["time"] = float(m[1]) if m else None
    h = re.search(r"([0-9a-f]{64})\s+/tmp/o\.o", x)
    s["obj"] = h[1][:12] if h else "-"
    m = re.search(r"process_peak_bytes (\d+)", x)
    s["peak"] = int(m[1]) / 1024 if m else 0
    log = (out / f"{unit}.plugin.log")
    t = log.read_text(errors="replace") if log.exists() else ""
    m = re.search(r"insns (\d+) base_cycles (\d+) extra_cycles (\d+)", t)
    if m:
        s["insn"], s["stall"] = int(m[1]) / 1e9, int(m[3]) / 1e9
    m = re.search(r"ifetch hit \d+ miss (\d+) \| dread hit \d+ miss (\d+) \| dwrite hit \d+ miss (\d+)", t)
    if m:
        s["imiss"], s["dread"], s["dwrite"] = [int(m[i]) / 1e6 for i in (1, 2, 3)]
    return s


def cmd_compare(args):
    a, b = args.a, args.b
    ta = tb = 0.0
    names = sorted(p.stem for p in a.glob("*.txt") if (b / p.name).exists())
    print(f"{'unit':26}{'A s':>9}{'B s':>9}{'change':>9}  {'stall A':>8}{'B':>8}  {'dread A':>8}{'B':>7}  {'peak KB':>8}{'B':>7}  {'same obj'}")
    rows = []
    for u in names:
        x, y = unit_stats(a, u), unit_stats(b, u)
        if not x["time"] or not y["time"] or x["rc"] != "0" or y["rc"] != "0":
            print(f"{u:26} A rc={x['rc']} B rc={y['rc']}")
            continue
        ta += x["time"]
        tb += y["time"]
        rows.append((x["time"], u, x, y))
    for _, u, x, y in sorted(rows, key=lambda r: -r[0])[:args.top]:
        same = "yes" if x["obj"] == y["obj"] else ("-" if "-" in (x["obj"], y["obj"]) else "NO")
        print(f"{u:26}{x['time']:9.1f}{y['time']:9.1f}{100 * (y['time'] - x['time']) / x['time']:+8.1f}%  "
              f"{x.get('stall', 0):8.1f}{y.get('stall', 0):8.1f}  {x.get('dread', 0):8.0f}{y.get('dread', 0):7.0f}  "
              f"{x['peak']:8.0f}{y['peak']:7.0f}  {same}")
    if ta:
        print(f"{'TOTAL':26}{ta:9.1f}{tb:9.1f}{100 * (tb - ta) / ta:+8.1f}%   over {len(rows)} units")
    differ = [u for _, u, x, y in rows if x["obj"] != y["obj"]]
    print(f"objects differ: {len(differ)} of {len(rows)}{' ' + ' '.join(differ[:6]) if differ else ''}")


def relinked(image):
    """tcc and libc ELFs with symbols: the installed ones are stripped.  Same link,
    plus -g; .text stays the same size, so the addresses hold."""
    d = image / "selfhost_profile"
    d.mkdir(exist_ok=True)
    log = (image / "board_model_rootfs.log").read_text(errors="replace").splitlines()
    tcc_lines = [l for l in log if l.startswith("armv8m-tcc -o armv8m-tcc armv8m-source/driver/tcc.o")]
    libc_lines = [l for l in log if l.startswith("armv8m-tcc ") and "-o build/libc.so.elf" in l]
    cross = image / "libs/tinycc/bin/armv8m-tcc"
    if not (d / "tcc.elf").exists():
        line = tcc_lines[-1].replace("armv8m-tcc -o armv8m-tcc ", f"{cross} -g -Wl,-oformat=elf32-littlearm -o {d}/tcc.elf ", 1)
        subprocess.run(line, shell=True, cwd=image / "libs/tinycc", check=True, capture_output=True,
                       env={**os.environ, "PATH": f"{cross.parent}:{os.environ['PATH']}"})
    if not (d / "libc.elf").exists():
        line = libc_lines[-1].replace("armv8m-tcc ", f"{cross} -g ", 1).replace("-o build/libc.so.elf", f"-o {d}/libc.elf")
        subprocess.run(line, shell=True, cwd=image / "libs/libc", check=True, capture_output=True)
    return d / "tcc.elf", d / "libc.elf"


def symbols(elf):
    out = subprocess.run(["arm-none-eabi-nm", "-n", "--defined-only", str(elf)], capture_output=True, text=True).stdout
    syms = set()
    for l in out.splitlines():
        q = l.split()
        if len(q) == 3 and q[1] in "tTwWvV" and not q[2].startswith("$"):
            syms.add((int(q[0], 16) & ~1, q[2]))
    syms = sorted(syms)
    return [s[0] for s in syms], [s[1] for s in syms]


def text_of(elf):
    out = subprocess.run(["arm-none-eabi-readelf", "-SW", str(elf)], capture_output=True, text=True).stdout
    m = re.search(r"\]\s+\.text\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)", out)
    return [int(m[i], 16) for i in (1, 2, 3)]


def hot_block(yaff_path, sym):
    """(offset, length, offsets of its instructions) of an image's --hot-text block, or None."""
    yaff = yaff_path.read_bytes()
    arch = int.from_bytes(yaff[72:76], "little")
    if int.from_bytes(yaff[arch:arch + 2], "little") < 20:
        return None
    off = int.from_bytes(yaff[arch + 12:arch + 16], "little")
    length = int.from_bytes(yaff[arch + 16:arch + 20], "little")
    out = subprocess.run(["arm-none-eabi-objdump", "-d", "--no-show-raw-insn", f"--start-address={off}",
                          f"--stop-address={off + length}", str(sym)], capture_output=True, text=True).stdout
    return off, length, {int(m[1], 16) for m in re.finditer(r"^\s*([0-9a-f]+):", out, re.M)}


# The an524's process memory, where the copies are, and the kernel pool's page.
PROCESS_RAM = (0x66000000, 0x6C000000)
POOL_PAGE = 256


def hot_base(pcs, hot, hint=None):
    """Where a run's copy of the block was: nothing records it.  A wrong base still puts most
    PCs on some instruction, Thumb being 2 or 4 bytes, so only every one of them will do.
    *pcs* most executed first.  *hint*: where it was in the last run."""
    off, length, insns = hot
    ram = [pc for pc in pcs if PROCESS_RAM[0] <= pc < PROCESS_RAM[1]][:2000]

    def exact(base):
        inside = [pc for pc in ram if base <= pc < base + length]
        return len(inside) if inside and all(pc - base + off in insns for pc in inside) else 0

    if hint is not None and exact(hint):
        return hint
    best, most = None, 0
    if not ram:
        return None
    for base in range((min(ram) - length) & ~(POOL_PAGE - 1), max(ram) + 1, POOL_PAGE):
        n = exact(base)
        if n > most:
            best, most = base, n
    return best


class CodeMap:
    """Names for an image's guest PCs and back: tcc and libc in romfs, their SRAM copies, the kernel."""

    def __init__(self, image):
        tcc_sym, libc_sym = relinked(image)
        data = (image / "rootfs.img").read_bytes()
        self.mods = []
        for name, stripped, sym in (("tcc", image / "libs/tinycc/bin/armv8m-tcc.elf", tcc_sym),
                                    ("libc", image / "libs/libc/build/libc.so.elf", libc_sym)):
            a, o, n = text_of(stripped)
            pos = data.find(stripped.read_bytes()[o + 64:o + 576])
            if pos < 0:
                sys.exit(f"{name} text not found in rootfs.img")
            self.mods.append((name, 0x60000000 + pos - 64 - a, n, *symbols(sym)))
        self.kernel = image / "zig-out/bin/yasos_kernel"
        self.kA, self.kN = symbols(self.kernel)
        blocks = [(self.mods[0], hot_block(image / "rootfs/usr/bin/tcc", tcc_sym)),
                  (self.mods[1], hot_block(image / "rootfs/usr/lib/libc.so", libc_sym))]
        self.blocks = [(m, hot) for m, hot in blocks if hot]

    def copies(self, rows, hints=None):
        """Where this run's profile rows put the SRAM copies."""
        by_use = [int(r["pc"], 16) for r in sorted(rows, key=lambda r: -int(r["insns"]))]
        return [(m, hot, hot_base(by_use, hot, (hints or {}).get(m[0]))) for m, hot in self.blocks]

    def name(self, pc, copies):
        for name, base, n, A, N in self.mods:
            if base <= pc < base + n:
                i = bisect.bisect_right(A, pc - base) - 1
                return name, N[i] if i >= 0 else "?"
        for m, hot, hb in copies:
            if hb is not None and hb <= pc < hb + hot[1]:
                return m[0], m[4][bisect.bisect_right(m[3], pc - hb + hot[0]) - 1]
        i = bisect.bisect_right(self.kA, pc) - 1
        if i >= 0 and not 0x60000000 <= pc < 0x64000000 and not PROCESS_RAM[0] <= pc < PROCESS_RAM[1]:
            return "kernel", self.kN[i]
        return "other", "?"

    def entries(self, fn, copies):
        """Every PC a function starts at, its SRAM copy first.  A hot function has two: a
        =marked one really runs from flash too.  FN may be name+OFFSET, for a block inside."""
        name, _, plus = fn.partition("+")
        off = int(plus, 0) if plus else 0
        pcs = []
        for m, hot, hb in copies:
            pcs += [hb + a - hot[0] + off for a, x in zip(m[3], m[4]) if x == name and hb is not None and hot[0] <= a < hot[0] + hot[1]]
        for _, base, n, A, N in self.mods:
            pcs += [base + a + off for a, x in zip(A, N) if x == name and a < n]
        pcs += [a + off for a, x in zip(self.kA, self.kN) if re.sub(r"__\d+$", "", x) == name]
        return pcs

    def spans(self, module):
        """(lo, hi, name) of each function of a module where its flash copy runs."""
        if module == "kernel":  # its sections are far apart, so the next symbol ends a sized one only
            out = subprocess.run(["arm-none-eabi-nm", "-n", "-S", "--defined-only", str(self.kernel)],
                                 capture_output=True, text=True).stdout
            size = {q[3]: int(q[1], 16) for q in map(str.split, out.splitlines()) if len(q) == 4}
            for i, name in enumerate(self.kN):
                lo = self.kA[i]
                next_lo = self.kA[i + 1] if i + 1 < len(self.kA) else lo + 4
                yield lo, lo + (size[name] if name in size else min(next_lo - lo, 4096)), name  # assembly has no size
            return
        _, base, n, A, N = next(m for m in self.mods if m[0] == module)
        for i, name in enumerate(N):
            end = A[i + 1] if i + 1 < len(A) else min(n, A[i] + 4)
            if end > A[i] and A[i] < n:
                yield base + A[i], base + end, name


def cmd_funcs(args):
    image = bm.image_dir(args.image)
    code = CodeMap(image)
    insns, stalls, fetch = collections.Counter(), collections.Counter(), collections.Counter()
    hints = {}
    for f in args.out.glob("*.pc.csv"):
        rows = list(csv.DictReader(open(f)))
        copies = code.copies(rows, hints)
        hints = {c[0][0]: c[2] for c in copies}
        for r in rows:
            k = code.name(int(r["pc"], 16), copies)
            insns[k] += int(r["insns"])
            stalls[k] += int(r["extra_cycles"])
            fetch[k] += int(r["fetch_cycles"])
    cyc = {k: insns[k] * CPI + stalls[k] for k in insns}
    total = sum(cyc.values())
    print(f"total {total / HZ:.1f} s modeled; {sum(insns.values()) / 1e9:.2f} G insns; stalls {100 * sum(stalls.values()) / total:.0f}%")
    mod = collections.Counter()
    for k, v in cyc.items():
        mod[k[0]] += v
    print("by module:", {k: f"{100 * v / total:.1f}%" for k, v in mod.most_common()})
    print(f"instructions {sum(insns.values()) * CPI / HZ:.1f} s, fetch {sum(fetch.values()) / HZ:.1f} s, "
          f"data {(sum(stalls.values()) - sum(fetch.values())) / HZ:.1f} s")
    print(f"{'%':>5} {'cum':>6} {'stall%':>6} {'fetch%':>6} {'Minsn':>8}  function")
    c = 0
    for k, v in sorted(cyc.items(), key=lambda x: -x[1])[:args.top]:
        c += v
        print(f"{100 * v / total:5.1f} {100 * c / total:6.1f} {100 * stalls[k] / v:6.0f} {100 * fetch[k] / v:6.0f} {insns[k] / 1e6:8.1f}  {k[0]}:{k[1]}")


# What the boot runs before it has copied .data, where .time_critical comes from.
KERNEL_NOT_HOT = {"memcpy", "memset", "memmove"}


def cmd_callers(args):
    """Who calls these functions, per the base run's placement of the SRAM copies.  --attr
    ENTRY,ZERO,LOOP: runs of a block inside ENTRY, by who called ENTRY and who called ZERO."""
    image = bm.image_dir(args.image)
    code = CodeMap(image)
    if (args.base / "image.sha256").exists() and (args.base / "image.sha256").read_text().strip() != image_stamp(image):
        sys.exit(f"{args.base} is a run of another build of {image.name}: its addresses do not apply")
    src = payload_src()
    units = args.unit or [u for u in units_of(src) if (args.base / f"{u}.pc.csv").exists()]
    if not units:
        sys.exit(f"no profiled units in {args.base}")
    args.out.mkdir(parents=True, exist_ok=True)
    attr = args.attr.split(",") if args.attr else None
    if attr and len(attr) != 3:
        sys.exit("--attr ENTRY,ZERO,LOOP")
    placed = {}

    def extra(unit):
        if unit not in placed:
            placed[unit] = code.copies(list(csv.DictReader(open(args.base / f"{unit}.pc.csv"))))
        copies = placed[unit]
        pcs = []
        for fn in (attr or []) + args.functions:
            found = code.entries(fn, copies)
            if not found:
                sys.exit(f"{fn}: no such function")
            pcs += found[:1] if attr and fn in attr else found
        watch = args.out / f"{unit}.watch"
        watch.write_text("".join(f"{pc:x}\n" for pc in dict.fromkeys(pcs)))
        a = f",callers={watch},callers_out={args.out}/{unit}.callers.csv"
        if attr:
            a += ",attr=" + ":".join(f"{code.entries(fn, copies)[0]:x}" for fn in attr)
        return a

    for unit in units:
        extra(unit)  # a typo should fail now, not in QEMU
    run = argparse.Namespace(image=args.image, out=args.out, units=units, env=[], ulimit=32, nest=args.nest,
                             j=args.j, opt=args.opt, unit_extra=extra)
    cmd_run(run)
    calls = collections.defaultdict(collections.Counter)
    for unit in units:
        path = args.out / f"{unit}.callers.csv"
        if not path.exists():
            print(f"{unit}: no call graph")
            continue
        for line in path.read_text().splitlines():
            callee, a, b, n = line.split(",")
            callee, a, b = (code.name(int(x, 16), placed[unit]) for x in (callee, a, b))
            calls[callee][(a, b) if attr else a] += int(n)
    for callee, by in sorted(calls.items(), key=lambda kv: -sum(kv[1].values())):
        total = sum(by.values())
        print(f"{callee[0]}:{callee[1]}: {total / 1e6:.2f} M")
        for who, n in by.most_common(args.top):
            label = f"{who[0][1]}  <- zero by {who[1][1]}" if attr else f"{who[0]}:{who[1]}"
            print(f"   {n / 1e6:8.2f} M {100 * n / total:4.0f}%  {label}")


def cmd_ab(args):
    """Image A against image B at each optimisation level: board-model time, and the objects
    must match unless the code generator was meant to change."""
    for opt in args.opt or ["-O0", "-O2"]:
        outs = []
        for name in (args.a, args.b):
            out = bm.ROOT / "selfhost_runs" / f"{name}{opt}"
            print(f"--- {name} {opt}: {out}", flush=True)
            cmd_run(argparse.Namespace(image=name, out=out, units=args.unit or [], env=[], ulimit=32, nest=2, j=args.j, opt=opt))
            outs.append(out)
        print(f"=== {args.a} -> {args.b} {opt}")
        cmd_compare(argparse.Namespace(a=outs[0], b=outs[1], top=args.top))


def cmd_hotlist(args):
    """The list for one module, from a run on an image without one: fetch stall per byte.
    tcc: libs/tinycc/source/driver/hot_functions.txt, libc: libs/libc/hot_functions.txt, kernel:
    source/kernel/hot_functions.txt.  In tcc and libc only a function in a section of its own
    can move; libtcc1's local labels cannot."""
    image = bm.image_dir(args.image)
    tcc_sym, libc_sym = relinked(image)
    data = (image / "rootfs.img").read_bytes()
    if args.module == "kernel":
        A, N = symbols(image / "zig-out/bin/yasos_kernel")
        base, n = 0, 1 << 32
        movable = {x for x in N if x not in KERNEL_NOT_HOT and not x.startswith(("L..", "."))}
    else:
        stripped, sym, objects = ((image / "libs/tinycc/bin/armv8m-tcc.elf", tcc_sym, image / "libs/tinycc/armv8m-source")
                                  if args.module == "tcc" else
                                  (image / "libs/libc/build/libc.so.elf", libc_sym, image / "libs/libc/build"))
        a, o, n = text_of(stripped)
        pos = data.find(stripped.read_bytes()[o + 64:o + 576])
        if pos < 0:
            sys.exit(f"{args.module} text not found in rootfs.img")
        base = 0x60000000 + pos - 64 - a
        A, N = symbols(sym)
        movable = set()
        for obj in objects.rglob("*.o"):
            out = subprocess.run(["arm-none-eabi-objdump", "-h", str(obj)], capture_output=True, text=True).stdout
            for line in out.splitlines():
                m = re.search(r"\s\.text\.(\S+)\s", line)
                if m and not m[1].startswith("."):
                    movable.add(m[1])
    size = {}
    for i, name in enumerate(N):
        end = A[i + 1] if i + 1 < len(A) else min(n, A[i] + 4)
        if end > A[i] and A[i] < n and name in movable:
            size[name] = size.get(name, 0) + end - A[i]
    fetch = collections.Counter()
    for spec in args.out:  # RUN or RUN:WEIGHT, to weigh -O0 against -O2
        run, _, weight = spec.partition(":")
        for f in Path(run).glob("*.pc.csv"):
            for r in csv.DictReader(open(f)):
                pc = int(r["pc"], 16)
                if args.module == "kernel" and 0x60000000 <= pc:
                    continue
                if base <= pc < base + n:
                    i = bisect.bisect_right(A, pc - base) - 1
                    if i >= 0:
                        fetch[N[i]] += float(weight or 1) * int(r["fetch_cycles"])
    picked, used = [], 0
    for name in sorted((k for k in fetch if k in size), key=lambda k: -fetch[k] / size[k]):
        if used + size[name] <= args.kb * 1024:
            used += size[name]
            picked.append(name)
    runs = " ".join(Path(spec).name for spec in args.out)
    print(f"# {len(picked)} functions, {used} bytes: selfhost_profile.py hotlist {args.image} {runs} "
          f"--module {args.module} --kb {args.kb}")
    if args.module == "kernel":  # Zig's numbers change on every edit; --ram-text ignores them
        picked = [re.sub(r"__\d+$", "", name) for name in picked]
    marks = set()
    if args.marks:  # =name: a judgement from the call graph, which a fetch profile cannot make
        marks = {l[1:].strip() for l in args.marks.read_text().splitlines() if l.startswith("=")}
    print("\n".join(("=" if name in marks else "") + name for name in sorted(set(picked))))


def cmd_allocs(args):
    sites = collections.defaultdict(lambda: collections.Counter())
    names = {4095: "<sram: not declared>", 4094: "<psram: not declared>"}
    maxpeak = collections.Counter()
    units = 0
    for f in args.out.glob("*.alloc.csv"):
        units += 1
        unit = f.name[:-len(".alloc.csv")]
        local = {}
        for m in re.finditer(r"^ALLOCSITE (\d+) (\S+) (\d+)", (args.out / f"{unit}.txt").read_text(errors="replace"), re.M):
            local[int(m[1])] = f"{m[2].replace('source/', '')}:{m[3]}"
        for r in csv.DictReader(open(f)):
            sid = int(r["site"])
            name = names.get(sid) or local.get(sid, f"site{sid}")
            s = sites[name]
            for k in ("fast_accesses", "slow_reads", "slow_writes", "read_miss", "write_miss", "allocs", "bytes"):
                s[k] += int(r[k])
            maxpeak[name] = max(maxpeak[name], int(r["peak_live"]))
            s["maxsize"] = max(s["maxsize"], int(r["max_size"]))
    tm = sum(s["read_miss"] + s["write_miss"] for s in sites.values())
    ta = sum(s["slow_reads"] + s["slow_writes"] + s["fast_accesses"] for s in sites.values())
    print(f"{units} units; {tm / 1e6:.0f} M data misses, {ta / 1e6:.0f} M accesses")
    print(f"{'miss M':>8}{'%':>6}{'cum':>6}{'peak KB':>9}{'miss/KB':>9}{'acc M':>8}{'allocs':>9}  site")
    order = sorted(sites, key=lambda n: -(sites[n]["read_miss"] + sites[n]["write_miss"]))
    c = 0
    for n in order[:args.top]:
        s = sites[n]
        m = s["read_miss"] + s["write_miss"]
        c += m
        pk = maxpeak[n] / 1024
        print(f"{m / 1e6:8.1f}{100 * m / tm:6.1f}{100 * c / tm:6.1f}{pk:9.1f}{m / 1e3 / max(pk, 1):9.1f}"
              f"{(s['slow_reads'] + s['slow_writes'] + s['fast_accesses']) / 1e6:8.1f}{s['allocs']:9}  {n}")
    print("\nsites by misses per KB of worst-unit peak: what fits, greedily")
    used = covered = 0
    marks = [64, 128, 192, 256, 336, 512, 1024]
    declared = [n for n in sites if not n.startswith("<") and sites[n]["read_miss"] + sites[n]["write_miss"] > 0]
    for n in sorted(declared, key=lambda n: -(sites[n]["read_miss"] + sites[n]["write_miss"]) / max(maxpeak[n], 256)):
        used += maxpeak[n]
        covered += sites[n]["read_miss"] + sites[n]["write_miss"]
        while marks and used >= marks[0] * 1024:
            print(f"  {marks.pop(0):5} KB: {100 * covered / tm:5.1f}% of misses (last site {n}, peak {maxpeak[n] // 1024} KB)")


def cmd_poolmap(args):
    x = (args.out / f"{args.unit}.txt").read_text(errors="replace")
    for when in ("start", "exit"):
        rows = re.findall(rf"^POOLMAP {when} (\d+) (\d+) (0x[0-9a-f]+) (\d+) (\w+)", x, re.M)
        print(f"--- {when}")
        tier = collections.Counter()
        for pid, t, addr, n, src in sorted(rows, key=lambda r: int(r[2], 16)):
            tier[t] += int(n)
            if t == "0" or args.all:
                print(f"  pid {pid:>3} tier {t} {addr} {int(n) / 1024:8.1f} KB {src}")
        print("  totals KB:", {t: round(v / 1024, 1) for t, v in tier.items()})


def cmd_identity(args):
    a, b = bm.image_dir(args.a), bm.image_dir(args.b)
    src = payload_src()
    jobs = units_of(src)
    tmp = Path(tempfile.mkdtemp(prefix="identity_"))

    def one(unit):
        rsp, source = jobs[unit]
        flags = [f"-I{a}/rootfs/usr/include" if x == "-I/usr/include" else x
                 for x in shlex.split((src / rsp[1:]).read_text().replace("\n", " "))]
        objs = []
        for tag, image in (("a", a), ("b", b)):
            # tcc embeds the output's basename: same name, different directory
            (tmp / tag).mkdir(exist_ok=True)
            o = tmp / tag / f"{unit}.o"
            r = subprocess.run([str(image / "libs/tinycc/bin/armv8m-tcc"), *flags, "-c", "-o", str(o), source], cwd=src,
                               capture_output=True, text=True)
            objs.append((r.returncode, o.read_bytes() if o.exists() else b"", r.stderr[:200]))
        return unit, objs

    with ThreadPoolExecutor(14) as pool:
        res = list(pool.map(one, jobs))
    shutil.rmtree(tmp, ignore_errors=True)
    bad = [(u, o[0][0], o[1][0], o[0][2], o[1][2]) for u, o in res if o[0][0] or o[1][0] or o[0][1] != o[1][1]]
    print(f"compared {len(res)}, differ {len(bad)}")
    for row in bad[:12]:
        print(" ", row[0], "rc", row[1], row[2], (row[3] or row[4]).strip()[:120])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("run")
    s.add_argument("image")
    s.add_argument("out", type=Path)
    s.add_argument("units", nargs="*")
    s.add_argument("--ulimit", type=int, default=32)
    s.add_argument("--env", action="append", default=[])
    s.add_argument("--allocprof", action="store_true")
    s.add_argument("--opt", help="optimisation level, in place of the payload's")
    s.add_argument("--fast", action="append", metavar="MODULE:FILE",
                   help="what if: these functions (tcc, libc, kernel) cost no XIP fetch")
    s.add_argument("--nest", type=int, default=0, help="run the compile under this many shell scripts")
    s.add_argument("-j", type=int, default=8)
    s.set_defaults(fn=cmd_run)
    s = sub.add_parser("funcs")
    s.add_argument("image")
    s.add_argument("out", type=Path)
    s.add_argument("--top", type=int, default=50)
    s.set_defaults(fn=cmd_funcs)
    s = sub.add_parser("hotlist")
    s.add_argument("image")
    s.add_argument("out", nargs="+", help="runs to rank by: RUN or RUN:WEIGHT")
    s.add_argument("--kb", type=int, required=True)
    s.add_argument("--module", choices=("tcc", "libc", "kernel"), default="tcc")
    s.set_defaults(fn=cmd_hotlist)
    s.add_argument("--marks", type=Path, help="keep the = marks of this list")
    s = sub.add_parser("callers", help="who calls these functions, on the base run's placement")
    s.add_argument("image")
    s.add_argument("base", type=Path, help="a run of this image: where its SRAM copies are")
    s.add_argument("out", type=Path)
    s.add_argument("functions", nargs="*", help="function, or function+OFFSET for a block inside it")
    s.add_argument("--unit", action="append", help="default: every unit the base run has")
    s.add_argument("--attr", help="ENTRY,ZERO,LOOP: count runs of LOOP by who called ENTRY and ZERO")
    s.add_argument("--opt", help="optimisation level, in place of the payload's")
    s.add_argument("--nest", type=int, default=2)
    s.add_argument("--top", type=int, default=8)
    s.add_argument("-j", type=int, default=8)
    s.set_defaults(fn=cmd_callers)
    s = sub.add_parser("ab", help="two images at each level: time and object identity")
    s.add_argument("a")
    s.add_argument("b")
    s.add_argument("--opt", action="append", help="default: -O0 and -O2")
    s.add_argument("--unit", action="append")
    s.add_argument("--top", type=int, default=12)
    s.add_argument("-j", type=int, default=8)
    s.set_defaults(fn=cmd_ab)
    s = sub.add_parser("allocs")
    s.add_argument("out", type=Path)
    s.add_argument("--top", type=int, default=40)
    s.set_defaults(fn=cmd_allocs)
    s = sub.add_parser("compare")
    s.add_argument("a", type=Path)
    s.add_argument("b", type=Path)
    s.add_argument("--top", type=int, default=30)
    s.set_defaults(fn=cmd_compare)
    s = sub.add_parser("poolmap")
    s.add_argument("out", type=Path)
    s.add_argument("unit")
    s.add_argument("--all", action="store_true")
    s.set_defaults(fn=cmd_poolmap)
    s = sub.add_parser("identity")
    s.add_argument("a")
    s.add_argument("b")
    s.set_defaults(fn=cmd_identity)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
