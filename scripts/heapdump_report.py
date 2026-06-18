#!/usr/bin/env python3
"""Render a YASOS kernel heap-composition dump into a readable per-allocator report.

The kernel emits, when its tracked heap first crosses a threshold (boot peak), a
parseable snapshot of every live allocation as serial log lines:

    [ERR][heapprof] begin total=<bytes> live=<count>
    [ERR][heapprof] a <size> <pid> <a1> <a2> <a3> <a4> <a5> <a6>   (one per alloc)
    [ERR][heapprof] end

where a1..a6 are raw caller-first return addresses (0 = no frame). The kernel can't
symbolize, so this tool does it offline with arm-none-eabi-addr2line against the
kernel ELF, then aggregates allocations by call-stack so it's obvious which call
sites own the kernel heap.

Fetch: the [ERR][heapprof] block lands in the serial capture that
`scripts/remote_smoke_tui.py --run-cached --profile` syncs into
.cache/remote_smoke_logs/. This tool reads the newest such log by default, or pass
--log; pass --fetch to trigger a fresh remote run first.

Usage:
    scripts/heapdump_report.py [--log FILE] [--elf FILE] [--top N]
                               [--by {stack,caller}] [--depth N] [--fetch]
"""
import argparse
import collections
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ELF = os.path.join(REPO, "zig-out", "bin", "yasos_kernel")
LOG_GLOB = os.path.join(REPO, ".cache", "remote_smoke_logs", "**", "*.txt")
ADDR2LINE = os.environ.get("ADDR2LINE", "arm-none-eabi-addr2line")

BEGIN_RE = re.compile(r"\[heapprof\]\s+begin\s+total=(\d+)\s+live=(\d+)")
ALLOC_RE = re.compile(r"\[heapprof\]\s+a\s+(\d+)\s+(-?\d+)\s+(.+?)\s*$")
END_RE = re.compile(r"\[heapprof\]\s+end")


def newest_log():
    files = glob.glob(LOG_GLOB, recursive=True)
    return max(files, key=os.path.getmtime) if files else None


def parse_dump(path):
    """Return (allocs, total, live) for the LAST complete heapprof block in path.

    allocs = list of (size, pid, [addrs]) with zero-padding frames stripped.
    """
    allocs, total, live = [], None, None
    cur = cur_total = cur_live = None
    with open(path, errors="ignore") as fh:
        for line in fh:
            m = BEGIN_RE.search(line)
            if m:
                cur, cur_total, cur_live = [], int(m.group(1)), int(m.group(2))
                continue
            if cur is None:
                continue
            m = ALLOC_RE.search(line)
            if m:
                addrs = [int(a, 16) for a in m.group(3).split() if int(a, 16) != 0]
                cur.append((int(m.group(1)), int(m.group(2)), addrs))
                continue
            if END_RE.search(line):
                allocs, total, live = cur, cur_total, cur_live
                cur = None
    return allocs, total, live


def symbolize(addrs, elf):
    """addr -> (func, file:line). Queries addr-1 so a return address maps to the
    call site rather than the line after it."""
    uniq = sorted({a for a in addrs if a})
    if not uniq:
        return {}
    args = [ADDR2LINE, "-f", "-e", elf] + ["0x%x" % (a - 1) for a in uniq]
    try:
        out = subprocess.run(args, capture_output=True, text=True, check=False).stdout.splitlines()
    except FileNotFoundError:
        sys.exit("error: %s not found (set ADDR2LINE=...)" % ADDR2LINE)
    sym = {}
    for i, a in enumerate(uniq):
        func = out[2 * i].strip() if 2 * i < len(out) else "??"
        loc = out[2 * i + 1].strip() if 2 * i + 1 < len(out) else "??"
        sym[a] = (func, loc.replace(REPO + "/", ""))
    return sym


def fmt(n):
    return f"{n/1024:.1f}K" if n >= 1024 else f"{n}B"


def fetch():
    cmd = [
        sys.executable, os.path.join(REPO, "scripts", "remote_smoke_tui.py"),
        "--run-cached", "--profile",
        "--pytest-args", "tests/smoke/tcc_suite_test.py", "-k", "129_scopes",
    ]
    print("# fetching fresh dump: " + " ".join(cmd), file=sys.stderr)
    subprocess.run(cmd, cwd=REPO, check=False)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", help="serial log to parse (default: newest in .cache/remote_smoke_logs)")
    ap.add_argument("--elf", default=DEFAULT_ELF, help="kernel ELF for symbolization")
    ap.add_argument("--top", type=int, default=25, help="show top N allocation groups")
    ap.add_argument("--by", choices=["stack", "caller"], default="stack",
                    help="group by full stack signature or immediate caller")
    ap.add_argument("--depth", type=int, default=6, help="frames in the stack signature")
    ap.add_argument("--fetch", action="store_true", help="run a remote boot first to get a fresh dump")
    args = ap.parse_args()

    if args.fetch:
        fetch()
    log = args.log or newest_log()
    if not log or not os.path.exists(log):
        sys.exit("error: no log found (pass --log or --fetch)")
    if not os.path.exists(args.elf):
        sys.exit(f"error: kernel ELF not found: {args.elf}")

    allocs, total, live = parse_dump(log)
    if not allocs:
        sys.exit(f"error: no [heapprof] block in {log} (boot didn't cross the dump threshold?)")

    sym = symbolize([a for _, _, ad in allocs for a in ad], args.elf)
    groups = collections.defaultdict(lambda: [0, 0])  # key -> [bytes, count]
    for size, _pid, addrs in allocs:
        key = (addrs[0] if addrs else 0,) if args.by == "caller" else tuple(addrs[:args.depth])
        groups[key][0] += size
        groups[key][1] += 1
    rows = sorted(groups.items(), key=lambda kv: -kv[1][0])
    grand = sum(s for s, _, _ in allocs)

    print(f"# heap dump: {os.path.relpath(log, REPO)}")
    print(f"# parsed live={len(allocs)} bytes={grand} ({fmt(grand)})"
          f"   kernel-reported total={total} live={live}")
    print(f"# grouped by {args.by}, top {args.top}\n")
    for key, (b, cnt) in rows[:args.top]:
        frames = [sym.get(a, ("0x%x" % a, "?")) for a in key]
        f0, l0 = frames[0] if frames else ("?", "?")
        print(f"{fmt(b):>8} ({b:>7}B) x{cnt:<4} {f0}  ({l0})")
        for f, l in frames[1:]:
            print(f"{'':>21}<- {f}  ({l})")
        print()
    shown = sum(b for _, (b, _) in rows[:args.top])
    print(f"# shown {fmt(shown)} of {fmt(grand)} across {len(rows)} groups")


if __name__ == "__main__":
    main()
