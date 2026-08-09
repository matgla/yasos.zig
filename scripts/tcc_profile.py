#!/usr/bin/env python3
"""Host-side, device-representative profiler for the YASOS armv8m tcc.

Runs the x86-64 cross compiler (libs/tinycc/bin/armv8m-tcc) under callgrind on a
test source. The cross compiler runs the SAME preprocess/parse/IR/ARM-codegen
code as the on-device tcc, so its instruction profile (Ir) is a faithful device
CPU profile -- produced in seconds instead of an ~8-minute device round-trip.

It also reports, as device-cost proxies:
  - Dr/Dw  : per-function data reads/writes (memory traffic; the slice that lands
             in PSRAM on the device pays the slow-access penalty).
  - I/O    : file open + read-byte counts (the slow-flash dimension; --io).

Why not a cache-miss (cachegrind) model of PSRAM? The Cortex-M33 has no data
cache, so every PSRAM access is slow regardless of recency; a cache model would
"cache" hot data and hide it. Ir (exact) + Dr/Dw (traffic) is the honest proxy.

Usage:
  scripts/tcc_profile.py [source.c]               # default: tests2/129_scopes.c
  scripts/tcc_profile.py foo.c -c "-O1" -n 30
  scripts/tcc_profile.py --sort data              # rank by Dr+Dw instead of Ir
  scripts/tcc_profile.py --io                     # also count file opens/reads
  scripts/tcc_profile.py --save base.json         # save totals + per-fn Ir
  scripts/tcc_profile.py --compare base.json      # diff a hotspot vs a baseline

Prereqs: valgrind (apt install valgrind) and the host cross compiler at
libs/tinycc/bin/armv8m-tcc (built by build_rootfs.sh / `make cross`).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CROSS = os.path.join(REPO, "libs", "tinycc", "bin", "armv8m-tcc")
DEFAULT_SRC = os.path.join(REPO, "libs", "tinycc", "tests", "tests2", "129_scopes.c")

# tcc's own translation units (so we drop dynamic-loader / libc startup noise).
TCC_RE = re.compile(r"(tccpp|tccgen|tccelf|tccasm|tccdbg|tccld|tccyaff|tccmachine"
                    r"|tccopt|tccrun|svalue|tccls|tccir_operand|libtcc|/tcc\.c|/ir/|arm-thumb)")
NOISE_RE = re.compile(r"ld-linux|libc\.so|/dl-|sysdeps|/malloc/|/string/|\?\?\?|ld\.so")
NUM_RE = re.compile(r"(\d[\d,]*) \(")
FN_RE = re.compile(r"\)\s+(\S+:\S+)")


def die(msg):
    sys.exit("error: " + msg)


def check_prereqs():
    if not shutil.which("valgrind"):
        die("valgrind not found (apt install valgrind)")
    if not shutil.which("callgrind_annotate"):
        die("callgrind_annotate not found (part of valgrind)")
    if not (os.path.exists(CROSS) and os.access(CROSS, os.X_OK)):
        die(f"host cross compiler not found at {os.path.relpath(CROSS, REPO)}\n"
            f"       build it: ./build_rootfs.sh   (or cd libs/tinycc && make cross)")
    # guard against the self-host overwriting it with an ARM binary
    ft = subprocess.run(["file", CROSS], capture_output=True, text=True).stdout
    if "x86-64" not in ft and "x86_64" not in ft:
        die(f"{os.path.relpath(CROSS, REPO)} is not an x86-64 host binary ({ft.split(':',1)[-1].strip()})\n"
            f"       the self-host may have overwritten it; rebuild with ./build_rootfs.sh")


def run_callgrind(src, cflags, link):
    out = tempfile.mktemp(prefix="tcc_cg_", suffix=".out")
    exe = tempfile.mktemp(prefix="tcc_out_")
    comp = [CROSS] + ([] if link else ["-c"]) + cflags.split() + [src, "-o", exe]
    cg = ["valgrind", "--tool=callgrind", f"--callgrind-out-file={out}",
          "--cache-sim=yes", "--D1=32768,8,64", "--LL=524288,8,64"]
    r = subprocess.run(cg + comp, capture_output=True, text=True)
    totals = {}
    for line in r.stderr.splitlines():
        m = re.search(r"\b([ID])\s+refs:\s+([\d,]+)", line)
        if m:
            totals[m.group(1)] = int(m.group(2).replace(",", ""))
    if r.returncode != 0 or "I" not in totals:
        die(f"compile failed (rc={r.returncode}):\n" + "\n".join(comp) + "\n" +
            r.stderr[-2000:])
    for f in (exe,):
        try:
            os.unlink(f)
        except OSError:
            pass
    return out


def parse_funcs(out):
    """Return {func: {Ir, Dr, Dw}} for tcc's own functions only."""
    txt = subprocess.run(["callgrind_annotate", "--show=Ir,Dr,Dw", "--sort=Ir",
                          "--threshold=100", out], capture_output=True, text=True).stdout
    funcs = {}
    in_table = False
    for line in txt.splitlines():
        if re.match(r"\s*Ir\b.*file:function", line):
            in_table = True
            continue
        if not in_table or line.startswith("-") or not line.strip():
            continue
        nums = [int(n.replace(",", "")) for n in NUM_RE.findall(line)]
        fn = FN_RE.search(line)
        if not fn or len(nums) < 3:
            continue
        name = fn.group(1)
        if NOISE_RE.search(line) or not TCC_RE.search(line):
            continue
        ir, dr, dw = nums[0], nums[1], nums[2]
        e = funcs.setdefault(name, {"Ir": 0, "Dr": 0, "Dw": 0})
        e["Ir"] += ir
        e["Dr"] += dr
        e["Dw"] += dw
    return funcs


# The host cross-compiler's OWN dynamic linker opens these; the device tcc
# (self-hosted) doesn't, so exclude them to count only tcc's target-file I/O.
HOST_SYS_RE = re.compile(r"/usr/lib/|/lib/x86_64|/lib64|ld\.so|/etc/|/proc/|/sys/|/dev/|/usr/share/")
OPENAT_RE = re.compile(r'openat\([^,]+,\s*"([^"]+)".*\)\s*=\s*(\d+)')
READ_RE = re.compile(r"\bread\((\d+),.*\)\s*=\s*(\d+)")


def count_io(src, cflags, link):
    if not shutil.which("strace"):
        return None
    exe = tempfile.mktemp(prefix="tcc_io_")
    comp = [CROSS] + ([] if link else ["-c"]) + cflags.split() + [src, "-o", exe]
    log = tempfile.mktemp(prefix="tcc_strace_")
    subprocess.run(["strace", "-f", "-e", "trace=openat,read", "-o", log] + comp,
                   capture_output=True, text=True)
    opens, read_bytes, target_fds = 0, 0, set()
    try:
        for line in open(log, errors="ignore"):
            m = OPENAT_RE.search(line)
            if m and not HOST_SYS_RE.search(m.group(1)):
                opens += 1
                target_fds.add(m.group(2))
                continue
            m = READ_RE.search(line)
            if m and m.group(1) in target_fds:
                read_bytes += int(m.group(2))
    except OSError:
        return None
    try:
        os.unlink(log)
    except OSError:
        pass
    return {"opens": opens, "read_bytes": read_bytes}


def short(name):
    # ".../tccpp.c:next_nomacro [/.../armv8m-tcc]" -> "tccpp.c:next_nomacro"
    name = re.sub(r"\s*\[[^\]]*\]\s*$", "", name)
    return re.sub(r"^.*/", "", name)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", nargs="?", default=DEFAULT_SRC, help="C source to compile")
    ap.add_argument("-c", "--cflags", default="-O0", help="extra tcc flags (default -O0)")
    ap.add_argument("-n", "--top", type=int, default=25, help="top N functions")
    ap.add_argument("--sort", choices=["ir", "data"], default="ir",
                    help="rank by instructions (ir) or data refs Dr+Dw (data)")
    ap.add_argument("--compile", action="store_true", help="compile-only (-c); default is full compile+link like the device")
    ap.add_argument("--io", action="store_true", help="also report file open/read counts")
    ap.add_argument("--save", metavar="JSON", help="save totals + per-function Ir for later --compare")
    ap.add_argument("--compare", metavar="JSON", help="diff this run's hotspots vs a saved baseline")
    args = ap.parse_args()

    check_prereqs()
    src = args.source if os.path.isabs(args.source) else os.path.abspath(args.source)
    if not os.path.exists(src):
        die(f"source not found: {src}")
    link = not args.compile

    out = run_callgrind(src, args.cflags, link)
    funcs = parse_funcs(out)
    tot_ir = sum(f["Ir"] for f in funcs.values())
    tot_d = sum(f["Dr"] + f["Dw"] for f in funcs.values())
    key = (lambda kv: kv[1]["Ir"]) if args.sort == "ir" else (lambda kv: kv[1]["Dr"] + kv[1]["Dw"])
    ranked = sorted(funcs.items(), key=key, reverse=True)

    print(f"# tcc profile (host cross compiler, device-representative CPU): "
          f"{os.path.relpath(src, REPO)}  [{args.cflags}{' +link' if link else ' -c'}]")
    print(f"# tcc-code totals: Ir={tot_ir:,}  Dr+Dw={tot_d:,}   (loader/libc startup excluded)")
    print(f"# ranked by {'instructions (Ir)' if args.sort=='ir' else 'data refs (Dr+Dw)'}, top {args.top}\n")
    print(f"{'Ir%':>6} {'Ir':>12} {'Dr+Dw':>11}  function")
    print("-" * 72)
    for name, e in ranked[:args.top]:
        d = e["Dr"] + e["Dw"]
        print(f"{100*e['Ir']/tot_ir:5.1f}% {e['Ir']:>12,} {d:>11,}  {short(name)}")

    if args.io:
        io = count_io(src, args.cflags, link)
        if io:
            print(f"\n# I/O (slow-flash proxy): {io['opens']} file opens, "
                  f"{io['read_bytes']:,} bytes read")
        else:
            print("\n# I/O: strace unavailable")

    if args.save:
        json.dump({"source": os.path.relpath(src, REPO), "cflags": args.cflags,
                   "total_ir": tot_ir, "total_dref": tot_d,
                   "funcs": {short(n): e["Ir"] for n, e in funcs.items()}},
                  open(args.save, "w"), indent=2)
        print(f"\n# saved baseline -> {args.save}")

    if args.compare:
        base = json.load(open(args.compare))
        b_tot = base.get("total_ir", 0)
        print(f"\n# compare vs {args.compare}: total Ir {b_tot:,} -> {tot_ir:,} "
              f"({100*(tot_ir-b_tot)/b_tot:+.1f}%)" if b_tot else "")
        bf = base.get("funcs", {})
        cur = {short(n): e["Ir"] for n, e in funcs.items()}
        deltas = sorted(((cur.get(k, 0) - bf.get(k, 0), k) for k in set(bf) | set(cur)),
                        key=lambda x: abs(x[0]), reverse=True)
        print(f"{'dIr':>12}  function (biggest changes)")
        for dv, k in deltas[:args.top]:
            if dv:
                print(f"{dv:>+12,}  {k}")

    try:
        os.unlink(out)
    except OSError:
        pass


if __name__ == "__main__":
    main()
