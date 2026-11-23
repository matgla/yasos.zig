#!/usr/bin/env python3
"""Count what tcc's safe default says about our C, per directory, and fail
when a count grows.

Every build passes -ccompat for now (regular C); our code moves to the safe
default directory by directory.  This keeps the way there one-directional:
each listed directory's tracked .c files go through

    armv8m-tcc -fsyntax-only -fmax-errors=0 -I<the file's dir> -I<the directory> [-I<dir>/include] [flags]

in the safe default (the yasc dialect, -Wall, -Wlifetime, -W[maybe-]
uninitialized, unsafe C as errors), and the warnings and errors are counted
per directory.  The counts live in scripts/safe_mode_ratchet.json; a count
above it fails, a count below it asks for --update so that the new floor is
kept.  tcc keeps parsing after an error (-fmax-errors=0 here: no cap), so a
count is every diagnostic, not only each file's first.

  scripts/safe_mode_ratchet.py                 # check against the baseline
  scripts/safe_mode_ratchet.py --update        # write the current counts
  scripts/safe_mode_ratchet.py --add apps/foo  # start counting a directory
  scripts/safe_mode_ratchet.py --report out.txt  # every diagnostic, by file

The compiler is libs/tinycc/bin/armv8m-tcc as build_rootfs.sh leaves it (its
system headers are rootfs/usr/include), or --tcc.  A directory's extra
compiler options (defines, include paths) go in the JSON under "flags".
"""

import argparse
import concurrent.futures
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "scripts" / "safe_mode_ratchet.json"
DEFAULT_TCC = ROOT / "libs" / "tinycc" / "bin" / "armv8m-tcc"


# Files that exist to draw diagnostics (libc's checks of its own header
# annotations, tests/annotations/check.sh): not code to clean up.
NOT_COUNTED = ("/tests/annotations/",)


def tracked_c_files(directory):
    """The .c files git tracks under DIRECTORY, a submodule's too."""
    path = ROOT / directory
    if (path / ".git").exists():
        out = subprocess.run(["git", "-C", str(path), "ls-files", "*.c"], capture_output=True, text=True, check=True)
        files = [f"{directory}/{f}" for f in out.stdout.split()]
    else:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "--", f"{directory}/*.c", f"{directory}/**/*.c"],
            capture_output=True,
            text=True,
            check=True,
        )
        files = out.stdout.split()
    return sorted({f for f in files if not any(n in f"/{f}" for n in NOT_COUNTED)})


def check_file(tcc, directory, rel, flags):
    path = ROOT / rel
    # -fmax-errors=0: tcc keeps parsing after an error; count every one, not
    # the default cap of 8 per file
    cmd = [str(tcc), "-fsyntax-only", "-fmax-errors=0", f"-I{path.parent}", f"-I{ROOT / directory}"]
    if (ROOT / directory / "include").is_dir():
        cmd.append(f"-I{ROOT / directory / 'include'}")
    cmd += flags + [str(path)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120, cwd=ROOT)
    except subprocess.TimeoutExpired:
        return rel, 0, 1, [f"{rel}: error: tcc timed out"]
    lines = [line for line in proc.stderr.splitlines() if ": warning: " in line or ": error: " in line]
    warnings = sum(": warning: " in line for line in lines)
    errors = sum(": error: " in line for line in lines)
    if proc.returncode != 0 and errors == 0:
        errors = 1  # a crash, or an error tcc printed some other way
        lines.append(f"{rel}: error: tcc exited {proc.returncode}: {proc.stderr.strip()[-200:]}")
    return rel, warnings, errors, [line.replace(str(ROOT) + "/", "") for line in lines]


def measure(tcc, dirs, flags_by_dir, jobs):
    counts = {d: {"warnings": 0, "errors": 0, "files": 0} for d in dirs}
    report = {}
    work = [(d, f) for d in dirs for f in tracked_c_files(d)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(check_file, tcc, d, f, flags_by_dir.get(d, [])): d for d, f in work}
        for fut in concurrent.futures.as_completed(futures):
            d = futures[fut]
            rel, w, e, lines = fut.result()
            counts[d]["warnings"] += w
            counts[d]["errors"] += e
            counts[d]["files"] += 1
            if lines:
                report[rel] = lines
    return counts, report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tcc", default=str(DEFAULT_TCC), help="the cross compiler (default: %(default)s)")
    ap.add_argument("--baseline", default=str(BASELINE), help="the counts file (default: %(default)s)")
    ap.add_argument("--update", action="store_true", help="write the current counts as the baseline")
    ap.add_argument("--add", nargs="+", metavar="DIR", help="start counting these directories (implies --update)")
    ap.add_argument("--report", metavar="FILE", help="write every diagnostic, by file")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    args = ap.parse_args()

    tcc = Path(args.tcc)
    if not tcc.exists():
        print(f"safe_mode_ratchet: {tcc} not found -- run build_rootfs.sh first", file=sys.stderr)
        return 2
    baseline_path = Path(args.baseline)
    baseline = json.loads(baseline_path.read_text()) if baseline_path.exists() else {"dirs": {}}
    dirs = dict(baseline.get("dirs", {}))
    for d in args.add or []:
        d = d.rstrip("/")
        if not (ROOT / d).is_dir():
            print(f"safe_mode_ratchet: no directory {d}", file=sys.stderr)
            return 2
        dirs.setdefault(d, {"warnings": 0, "errors": 0})
    flags_by_dir = baseline.get("flags", {})
    missing = [d for d in dirs if not (ROOT / d).is_dir()]
    if missing:
        print(f"safe_mode_ratchet: listed but missing: {', '.join(missing)}", file=sys.stderr)
        return 2

    counts, report = measure(tcc, sorted(dirs), flags_by_dir, args.jobs)
    if args.report:
        with open(args.report, "w") as out:
            for rel in sorted(report):
                out.write("\n".join(report[rel]) + "\n")

    if args.update or args.add:
        baseline["dirs"] = {d: {"warnings": c["warnings"], "errors": c["errors"]} for d, c in sorted(counts.items())}
        baseline.setdefault("flags", {})
        baseline_path.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
        total_w = sum(c["warnings"] for c in counts.values())
        total_e = sum(c["errors"] for c in counts.values())
        print(f"safe_mode_ratchet: baseline written: {len(counts)} directories, {total_w} warnings, {total_e} errors")
        return 0

    grew, shrank = [], []
    width = max((len(d) for d in counts), default=10)
    for d, c in sorted(counts.items()):
        base = dirs[d]
        for kind in ("warnings", "errors"):
            if c[kind] > base.get(kind, 0):
                grew.append(f"{d}: {kind} {base.get(kind, 0)} -> {c[kind]}")
            elif c[kind] < base.get(kind, 0):
                shrank.append(f"{d}: {kind} {base.get(kind, 0)} -> {c[kind]}")
        print(f"{d:<{width}}  {c['files']:4d} files  {c['warnings']:5d} warnings  {c['errors']:4d} errors")
    if grew:
        print("\nsafe_mode_ratchet: counts grew (the safe default says more about them than before):")
        for line in grew:
            print(f"  {line}")
        print("Fix the new diagnostics (scripts/safe_mode_ratchet.py --report FILE lists them all).")
        return 1
    if shrank:
        print("\nsafe_mode_ratchet: counts went down -- keep the new floor with --update:")
        for line in shrank:
            print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
