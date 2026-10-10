#!/usr/bin/env python3
"""Compare the kernel built by the cross tcc (-O2) against the Zig/LLVM build,
counting guest instructions in QEMU rather than wall time.

    scripts/kernel_compare.py --store            # build both, run, save baseline
    scripts/kernel_compare.py                    # build both, run, diff vs baseline
    scripts/kernel_compare.py --skip-build       # reuse the ELFs of the last build
    scripts/kernel_compare.py --variants llvm    # only one arm of the comparison
    scripts/kernel_compare.py --list             # show the workload battery

For each variant the kernel is built with the same rootfs and optimize mode
(`zig build -Doptimize=<mode> -Dkernel_cc=<variant> --prefix <work>/<variant>`;
the tcc build compiles its units at -O2), then put through a battery of
workloads: userland apps, tcc compiling and running programs, and the on-board
Zig compiler rendering a program to C for tcc to compile (the device zig build
has no ELF linker; see docs/kernel_bench_insn_2026-10-08.md).

Every workload runs in its own fresh boot and is counted with the gated icount
TCG plugin (the docs/kernel_bench_insn_2026-10-08.md methodology): the plugin
counts guest instructions between @@PROFILE_BEGIN@@ / @@PROFILE_END@@ UART
markers printed by a workload script, under `-icount shift=0,align=off,
sleep=off` on the board_model QEMU.  Counts are deterministic, so a comparison
is exact: no repetitions, no noise margins.  Each workload records its exit
status, its instruction count (the per-PC CSV is kept under <work>/insns/ for
hotspot analysis) and the sha256 of its output.  A `noop` workload measures the
marker harness itself.

`--store PATH` (default .cache/kernel_compare/baseline.json) saves the run as
the baseline.  Without it the run is compared against the stored baseline:
exit statuses and output hashes must match (a mismatch is a failure), and
instruction deltas are reported exactly (a warning beyond --count-warn, a
failure only with --fail-on-count).  The tcc-vs-llvm table of the current run
is always printed; a workload whose output differs between the two kernels is
a failure there too -- that is a kernel miscompile until proven otherwise.

Workloads run in parallel worker processes (--jobs), one QEMU boot each.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))

DEFAULT_BASELINE = REPO / ".cache/kernel_compare/baseline.json"
# The board_model QEMU is built with --enable-plugins; the stock qemu-system-arm
# is not (board_model.md).
PLUGIN_QEMU = REPO / ".cache/board_model/qemu/qemu-system-arm"
PLUGIN_SO = REPO / ".cache/kernel_compare/icount.so"
# Where the gated plugin has been kept so far (kernel_bench_insn_2026-10-08.md).
BENCH_PLUGIN_SO = REPO / ".cache/bench_insn_20261008/icount.so"

# Files shipped to the guest on /mnt and compiled there.  Deterministic on
# purpose: their build products and run output are compared byte-for-byte
# between kernels.
PAYLOAD = {
    "hello.c": """\
#include <stdio.h>
int main(void) {
    printf("Hello, World!\\n");
    printf("six by seven is %d\\n", 6 * 7);
    return 0;
}
""",
    "bench.c": """\
/* Deterministic compute mix for kernel A/B runs: qsort, matrix multiply,
 * recursion and integer mixing, one checksum per stage on stdout. */
#include <stdio.h>
#include <string.h>

static unsigned stage = 0;

static void report(unsigned long long sum) {
    printf("stage %u checksum %llu\\n", stage++, sum);
}

static int cmp_int(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}

static void sort_stage(void) {
    static int v[512];
    unsigned long long h = 0;
    unsigned x = 12345;
    for (int i = 0; i < 512; i++) {
        x = x * 1103515245u + 12345u;
        v[i] = (int)(x >> 8);
    }
    /* insertion sort through qsort's shape: the libc call is part of the mix */
    for (int i = 1; i < 512; i++) {
        int key = v[i], j = i - 1;
        while (j >= 0 && cmp_int(&v[j], &key) > 0) { v[j + 1] = v[j]; j--; }
        v[j + 1] = key;
    }
    for (int i = 0; i < 512; i++) h = h * 31 + (unsigned)v[i];
    report(h);
}

static void matrix_stage(void) {
    static int a[24][24], b[24][24], c[24][24];
    unsigned long long h = 0;
    for (int i = 0; i < 24; i++)
        for (int j = 0; j < 24; j++) {
            a[i][j] = i * 24 + j;
            b[i][j] = (i == j) ? 2 : (i + j) % 3;
        }
    for (int i = 0; i < 24; i++)
        for (int j = 0; j < 24; j++) {
            int s = 0;
            for (int k = 0; k < 24; k++) s += a[i][k] * b[k][j];
            c[i][j] = s;
        }
    for (int i = 0; i < 24; i++)
        for (int j = 0; j < 24; j++) h = h * 131 + (unsigned)c[i][j];
    report(h);
}

static unsigned long long fib(int n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

static void fib_stage(void) {
    unsigned long long h = 0;
    for (int n = 1; n <= 24; n++) h += fib(n);
    report(h);
}

static void mix_stage(void) {
    unsigned long long h = 1469598103934665603ull;
    for (int i = 0; i < 20000; i++) {
        h ^= (unsigned)i;
        h *= 1099511628211ull;
        h ^= h >> 29;
    }
    report(h);
}

int main(void) {
    sort_stage();
    matrix_stage();
    fib_stage();
    mix_stage();
    printf("bench done\\n");
    return 0;
}
""",
    "hello.zig": """\
const std = @import("std");

export fn yasos_zig_workload() u32 {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Hello, World!", .{}) catch return 0;
    return @intCast(s.len);
}

comptime {
    _ = yasos_zig_workload;
}
""",
}

CORPUS_LINES = 2000


def write_corpus(path):
    """A deterministic pseudo-random corpus for the coreutils workloads."""
    x = 12345
    words = ["the", "yasos", "kernel", "tcc", "zig", "boot", "qemu", "arm",
             "thumb", "romfs", "heap", "pipe", "sort", "grep", "line"]
    with open(path, "w") as f:
        for i in range(CORPUS_LINES):
            line = []
            for _ in range(6):
                x = (x * 1103515245 + 12345) % (1 << 31)
                line.append(words[x % len(words)])
            f.write(f"{i} " + " ".join(line) + "\n")


# The device Zig compiler is a "development environment" build: it has no
# ELF linker and no version/env/fmt commands (those panic), so the working
# on-board invocation is the one docs/kernel_bench_insn_2026-10-08.md used:
# render a .zig to C with build-obj -ofmt=c, then let tcc compile that C.
# One chain, because every workload boots fresh and cannot see another's files.
ZIG_CHAIN = ("mkdir -p /tmp/zig-cache /tmp/zighome"
             " && HOME=/tmp/zighome zig build-obj -ofmt=c"
             " -target thumb-freestanding -mcpu=cortex_m33 -OReleaseSmall"
             " /tmp/work/hello.zig --zig-lib-dir /usr/lib/zig"
             " --cache-dir /tmp/zig-cache -femit-bin=/tmp/work/hello_zig.c"
             " && sha256sum /tmp/work/hello_zig.c"
             " && tcc -c -I/usr/lib/zig -include /usr/lib/zig/zig_c_prelude.h"
             " /tmp/work/hello_zig.c -o /tmp/work/hello_zig.o")

# The battery, run against every kernel.  Fields:
#   cmd       the workload command, run inside the instruction-count window
#   rc_only   record the status but not the output hash (nondeterministic text)
#   needs     skip unless this program exists on the image (checked per boot)
#   silence   override the between-lines silence timeout for this command
#
# Every workload is one fresh boot, so a workload cannot use another's output:
# compile-only tcc steps use -c, and the one end-to-end workload compiles and
# runs hello in a single chain.
WORKLOADS = [
    {"name": "noop", "cmd": "true"},
    {"name": "uname", "cmd": "uname -a"},
    {"name": "ls-bin", "cmd": "ls /bin"},
    {"name": "echo", "cmd": "echo hello-from-yasos"},
    {"name": "true-launch", "cmd": "/bin/true"},
    {"name": "sha256sum", "cmd": "sha256sum /tmp/work/hello.c"},
    {"name": "ps", "cmd": "ps", "rc_only": True},
    {"name": "core-sort", "cmd": "sort /tmp/work/corpus.txt > /tmp/work/sorted.txt"},
    {"name": "core-grep", "cmd": "grep -c the /tmp/work/corpus.txt"},
    {"name": "tcc-hello-c-O0", "cmd": "tcc -c -O0 /tmp/work/hello.c -o /tmp/work/hello0.o"},
    {"name": "tcc-hello-c-O2", "cmd": "tcc -c -O2 /tmp/work/hello.c -o /tmp/work/hello2.o"},
    {"name": "tcc-bench-c-O2", "cmd": "tcc -c -O2 /tmp/work/bench.c -o /tmp/work/bench.o"},
    {"name": "tcc-hello-run", "cmd": "tcc /tmp/work/hello.c -o /tmp/work/hello && /tmp/work/hello"},
    {"name": "zig-version", "cmd": "zig version", "needs": "zig", "silence": 60},
    {"name": "zig-obj-tcc", "cmd": ZIG_CHAIN, "needs": "zig", "silence": 1800},
]

# The window script: the trailing wlrc echo reports the workload's own exit
# status (the END echo would otherwise overwrite $?), from outside the window.
WINDOW_SCRIPT = ("echo '@@PROFILE_BEGIN@@'\n"
                 "{cmd}\n"
                 "r=$?\n"
                 "echo '@@PROFILE_END@@'\n"
                 'echo "@@yasos-wlrc=$r"\n')


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_rev():
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=REPO,
                              check=True, capture_output=True, text=True).stdout.strip()
    except subprocess.CalledProcessError:
        return "unknown"


def ensure_smoke_venv():
    """The guest session imports pyserial (and friends) from the smoke venv;
    re-exec under it, creating the venv the way run_qemu_smoke.sh does."""
    try:
        import serial  # noqa: F401
        return
    except ImportError:
        pass
    venv_python = REPO / ".qemu_smoke_venv/bin/python"
    if not venv_python.is_file():
        print("kernel_compare.py: creating the smoke venv (.qemu_smoke_venv)", file=sys.stderr)
        subprocess.run([sys.executable, "-m", "venv", str(REPO / ".qemu_smoke_venv")], check=True)
        subprocess.run([str(venv_python), "-m", "pip", "install", "--quiet",
                        "--disable-pip-version-check",
                        "-r", str(REPO / "tests/smoke/requirements.txt")], check=True)
    os.execv(str(venv_python), [str(venv_python), str(Path(__file__).resolve()), *sys.argv[1:]])


def ensure_plugin():
    """The gated icount plugin, copied out of the bench_insn cache on first use."""
    if PLUGIN_SO.is_file():
        return
    if BENCH_PLUGIN_SO.is_file():
        PLUGIN_SO.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(BENCH_PLUGIN_SO, PLUGIN_SO)
        source = BENCH_PLUGIN_SO.with_suffix(".c")
        if source.is_file():
            shutil.copy2(source, PLUGIN_SO.with_suffix(".c"))
        return
    sys.exit(f"kernel_compare.py: the icount plugin is missing (looked at {PLUGIN_SO} "
             f"and {BENCH_PLUGIN_SO}); it is built alongside the kernel_bench_insn "
             "capture -- see docs/kernel_bench_insn_2026-10-08.md")


def check_prereqs(variants):
    if not (REPO / "config/target/config.json").is_file():
        sys.exit("kernel_compare.py: config/target/config.json is missing; "
                 "run `zig build defconfig -Ddefconfig_file=configs/qemu_mps3_an524_defconfig` first")
    if not (REPO / "rootfs.img").is_file():
        sys.exit("kernel_compare.py: rootfs.img is missing; build it with ./build_rootfs.sh -o rootfs.img "
                 "(both kernels embed the same image; add --zig <zig-src> there for the on-board compiler tests)")
    if not PLUGIN_QEMU.is_file():
        sys.exit(f"kernel_compare.py: the plugin-enabled QEMU is missing at {PLUGIN_QEMU}; "
                 "run `scripts/board_model.py setup` first")
    ensure_plugin()
    for v in variants:
        if v == "tcc" and not (REPO / "libs/tinycc/bin/armv8m-tcc").is_file():
            sys.exit("kernel_compare.py: the tcc kernel needs the cross at libs/tinycc/bin/armv8m-tcc; "
                     "run ./build_rootfs.sh first, or drop the 'tcc' variant with --variants llvm")


def build_variant(variant, args):
    prefix = args.work / variant
    elf = prefix / "bin" / "yasos_kernel"
    if args.skip_build:
        if not elf.is_file():
            sys.exit(f"kernel_compare.py: --skip-build but {elf} does not exist; build without --skip-build once")
        return elf
    cmd = ["zig", "build", f"-Doptimize={args.optimize}", f"-Dkernel_cc={variant}",
           "--prefix", str(prefix)]
    print(f"--- building {variant} kernel: {' '.join(cmd)}", flush=True)
    subprocess.run(cmd, cwd=REPO, check=True)
    return elf


def prepare_payload(args):
    payload = args.work / "payload"
    payload.mkdir(parents=True, exist_ok=True)
    for name, text in PAYLOAD.items():
        (payload / name).write_text(text)
    write_corpus(payload / "corpus.txt")
    return payload


def sum_csv(path):
    """Total instructions: sum the per-PC cpu0+cpu1 counts of the window CSV."""
    total = 0
    with open(path) as f:
        next(f)
        for line in f:
            fields = line.split(",")
            if len(fields) >= 3:
                total += int(fields[1]) + int(fields[2])
    return total


def output_hash(lines, rc_only):
    if rc_only:
        return None, None
    kept = [ln for ln in lines
            if "@@PROFILE_" not in ln and "@@yasos-" not in ln]
    digest = hashlib.sha256(("\n".join(kept) + "\n").encode()).hexdigest()
    return digest, kept


def run_workload(variant, wl, elf, payload, args):
    """One fresh boot: copy the payload to /tmp/work, run the workload inside
    the @@PROFILE@@ window, return its result dict."""
    result = {"variant": variant, "name": wl["name"], "rc": None, "insns": None,
              "out_sha256": None, "out": None, "skipped": None, "error": None}
    ensure_plugin()
    boot = args.work / "boot" / f"{variant}-{wl['name']}"
    csv = args.work / "insns" / f"{variant}-{wl['name']}.csv"
    try:
        if boot.exists():
            shutil.rmtree(boot)
        boot.mkdir(parents=True)
        for name in os.listdir(payload):
            src = payload / name
            if src.is_file():
                shutil.copy2(src, boot / name)
        (boot / "wl.sh").write_text(WINDOW_SCRIPT.format(cmd=wl["cmd"]))
        csv.parent.mkdir(parents=True, exist_ok=True)
        if csv.exists():
            csv.unlink()

        # The plugin-enabled QEMU with the counting window armed: board FPU/DSP
        # plus -icount, exactly as docs/kernel_bench_insn_2026-10-08.md ran it.
        # QemuMount reads these from os.environ (this worker is its own process).
        os.environ["YASOS_QEMU_BIN"] = str(PLUGIN_QEMU)
        os.environ["YASOS_QEMU_EXTRA_ARGS"] = (
            "-global sse-200.CPU0_FPU=on -global sse-200.CPU1_FPU=on "
            "-global sse-200.CPU0_DSP=on -global sse-200.CPU1_DSP=on "
            "-icount shift=0,align=off,sleep=off -d plugin "
            f"-plugin {PLUGIN_SO},out={csv}")

        from yasos_device import DeviceError, QemuMount, run

        lines = []
        with QemuMount([(boot, "")], kernel=elf, keep_work=args.keep) as guest:
            rc = run(guest.session, "mkdir -p /tmp/work && cp -r /mnt/* /tmp/work/",
                     silence=args.silence, echo=False)
            if rc:
                result["error"] = f"payload copy failed (rc={rc})"
                return result
            if wl.get("needs") and run(guest.session, f"test -x /usr/bin/{wl['needs']}",
                                       silence=args.silence, echo=False):
                result["skipped"] = f"{wl['needs']} not found on this image"
                return result
            try:
                guest.session.file.flush()
                log_start = Path(guest.session.log_path).stat().st_size
                rc = run(guest.session, "sh /tmp/work/wl.sh",
                         silence=wl.get("silence", args.silence),
                         echo=False, on_line=lines.append)
            except (DeviceError, RuntimeError, AssertionError, OSError) as exc:
                result["error"] = f"guest lost during the workload: {exc}"
                return result
            # User-visible output filters tprof lines. Read the raw transcript
            # as the smoke harness does, preserving cache traffic in the JSON.
            guest.session.file.flush()
            sys.path.insert(0, str(REPO / "tests"))
            from smoke.kernel_profile import parse_lines
            with open(guest.session.log_path, encoding="utf-8", errors="ignore") as log:
                log.seek(log_start)
                result["profile"] = parse_lines(log).to_dict()
            # The workload's own exit status rides out of the window on a
            # @@yasos-wlrc= line; run()'s status is sh's (always 0 here).
            for ln in lines:
                m = re.search(r"@@yasos-wlrc=(-?\d+)", ln)
                if m:
                    result["rc"] = int(m.group(1))
                    break
            else:
                result["rc"] = rc
        if not csv.is_file():
            result["error"] = "the instruction window never closed (no plugin CSV)"
            return result
        result["insns"] = sum_csv(csv)
        result["out_sha256"], result["out"] = output_hash(lines, wl.get("rc_only"))
    except (DeviceError, RuntimeError, AssertionError, OSError, ValueError) as exc:
        result["error"] = str(exc)
    finally:
        if not args.keep and boot.exists():
            shutil.rmtree(boot, ignore_errors=True)
    return result


def worker_main(argv):
    """One (variant, workload) boot in a worker process; writes a result JSON."""
    import argparse as ap
    parser = ap.ArgumentParser()
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--silence", type=float, default=900.0)
    parser.add_argument("--keep", action="store_true")
    opts = parser.parse_args(argv)
    wl = next(w for w in WORKLOADS if w["name"] == opts.name)
    result = run_workload(opts.variant, wl, opts.kernel, opts.work / "payload", opts)
    out = opts.work / "results" / f"{opts.variant}-{opts.name}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n")
    return 0


def dispatch_workers(runs, elfs, payload, args):
    jobs = max(1, args.jobs)

    def spawn(cmd, log, timeout):
        with open(log, "w") as fh:
            return subprocess.run(cmd, cwd=REPO, stdout=fh, stderr=subprocess.STDOUT,
                                  timeout=timeout)

    tasks = [(variant, wl) for variant in runs for wl in WORKLOADS]
    print(f"--- running {len(tasks)} workloads ({jobs} at a time, one boot each)", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {}
        for variant, wl in tasks:
            log = args.work / "results" / f"{variant}-{wl['name']}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            cmd = [sys.executable, str(Path(__file__).resolve()), "--_worker",
                   "--work", str(args.work), "--kernel", str(elfs[variant]),
                   "--variant", variant, "--name", wl["name"],
                   "--silence", str(wl.get("silence", args.silence))]
            if args.keep:
                cmd.append("--keep")
            futures[pool.submit(spawn, cmd, log,
                                wl.get("silence", args.silence) * 3 + 600)] = (variant, wl, log)
        for future in concurrent.futures.as_completed(futures):
            variant, wl, log = futures[future]
            name = wl["name"]
            result_path = args.work / "results" / f"{variant}-{name}.json"
            try:
                future.result()
            except subprocess.TimeoutExpired:
                runs[variant]["tests"][name] = {
                    "rc": None, "insns": None, "skipped": None,
                    "error": f"worker exceeded its timeout; transcript: {log}"}
                print(f"    [{variant}] {name}: TIMEOUT (transcript: {log})", flush=True)
                continue
            if result_path.is_file():
                result = json.loads(result_path.read_text())
            else:
                result = {"rc": None, "insns": None, "skipped": None,
                          "error": f"worker produced no result; transcript: {log}"}
            runs[variant]["tests"][name] = result
            detail = result.get("error") or result.get("skipped") or \
                (f"{result['insns']:,} insns" if result.get("insns") is not None else "?")
            print(f"    [{variant}] {name}: rc={result.get('rc')}, {detail}", flush=True)


def print_ab_table(results):
    print("\n== tcc -O2 vs zig/llvm kernel (guest instructions in QEMU) ==")
    header = f"{'workload':<18} {'tcc insns':>14} {'llvm insns':>14} {'tcc/llvm':>9} {'outputs':>9} {'rcs':>8}"
    print(header)
    for wl in WORKLOADS:
        name = wl["name"]
        a = results["runs"].get("tcc", {}).get("tests", {}).get(name)
        b = results["runs"].get("llvm", {}).get("tests", {}).get(name)
        if a is None and b is None:
            continue
        ia = a.get("insns") if a else None
        ib = b.get("insns") if b else None
        ratio = f"{ia / ib:.2f}x" if ia and ib else "-"
        if a is None or b is None:
            outs, rcs = "one-sided", "-"
        elif a.get("error") or b.get("error"):
            outs = "error"
            rcs = f"{a.get('rc')}/{b.get('rc')}"
        elif a.get("skipped") or b.get("skipped"):
            outs = "skipped"
            rcs = f"{a.get('rc')}/{b.get('rc')}"
        else:
            ha, hb = a.get("out_sha256"), b.get("out_sha256")
            outs = "same" if (ha is None and hb is None) or ha == hb else "DIFFER"
            rcs = f"{a.get('rc')}/{b.get('rc')}"
        print(f"{name:<18} "
              f"{f'{ia:,}' if ia is not None else '-':>14} "
              f"{f'{ib:,}' if ib is not None else '-':>14} "
              f"{ratio:>9} {outs:>9} {rcs:>8}")


def compare_with_baseline(results, baseline, args):
    failures, warnings = [], []
    print(f"\n== vs baseline {args.baseline} (stored {baseline.get('meta', {}).get('date', '?')}) ==")
    if baseline.get("schema") != results["schema"]:
        sys.exit(f"kernel_compare.py: baseline schema {baseline.get('schema')} != "
                 f"{results['schema']}; re-store it with --store")
    base_rootfs = baseline.get("meta", {}).get("rootfs_sha256")
    now_rootfs = results["meta"]["rootfs_sha256"]
    if base_rootfs and base_rootfs != now_rootfs:
        warnings.append("the rootfs image changed since the baseline; "
                        "output and instruction comparisons span different images")
    for variant, run_data in results["runs"].items():
        base_run = baseline.get("runs", {}).get(variant)
        if base_run is None:
            warnings.append(f"[{variant}] no stored run for this variant")
            continue
        base_tests = base_run.get("tests", {})
        for name in base_tests:
            if name not in run_data["tests"]:
                warnings.append(f"[{variant}] {name}: in the baseline but not run now "
                                "(dropped from the battery, or the guest was lost)")
        for name, now in run_data["tests"].items():
            before = base_tests.get(name)
            if before is None:
                warnings.append(f"[{variant}] {name}: new (not in baseline)")
                continue
            if now.get("rc") != before.get("rc"):
                failures.append(f"[{variant}] {name}: exit status {now.get('rc')} "
                                f"!= stored {before.get('rc')}")
                continue
            if now.get("skipped") or now.get("error"):
                print(f"[{variant}] {name}: {now.get('skipped') or now.get('error')}")
                continue
            ha, hb = now.get("out_sha256"), before.get("out_sha256")
            if ha is not None and hb is not None and ha != hb:
                failures.append(f"[{variant}] {name}: output changed since the baseline")
                continue
            ia, ib = now.get("insns"), before.get("insns")
            if ia is None or ib is None:
                failures.append(f"[{variant}] {name}: no instruction count "
                                f"(stored: {ib})")
                continue
            delta = (ia - ib) / ib if ib else 0.0
            mark = ""
            if abs(delta) > args.count_warn:
                mark = f"  (warning: beyond --count-warn {args.count_warn:.0%})"
                warnings.append(f"[{variant}] {name}: {ia:,} vs {ib:,} stored insns ({delta:+.2%})")
                if args.fail_on_count:
                    failures.append(f"[{variant}] {name}: instructions {ia:,} vs {ib:,} "
                                    f"stored ({delta:+.2%}) and --fail-on-count is set")
            print(f"[{variant}] {name}: {ia:,} insns vs {ib:,} stored ({delta:+.2%}){mark}")
    for line in warnings:
        print(f"WARNING: {line}")
    print(f"baseline comparison: {len(failures)} failure(s), {len(warnings)} warning(s)")
    return failures


def main(argv=None):
    argv = list(argv) if argv is not None else None
    if argv and "--_worker" in argv:
        return worker_main([a for a in argv[1:] if a != "--_worker"])
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--store", nargs="?", const="default", metavar="PATH",
                        help="save the run as the baseline (default: %(default)s)")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE,
                        help="baseline to compare against (default: %(default)s)")
    parser.add_argument("--variants", default="tcc,llvm",
                        help="comma-separated kernel builds to test (default: %(default)s)")
    parser.add_argument("--optimize", default="ReleaseFast",
                        help="zig optimize mode for both kernels (default: %(default)s; tcc compiles at -O2)")
    parser.add_argument("--skip-build", action="store_true",
                        help="reuse <work>/<variant>/bin/yasos_kernel from the last build")
    parser.add_argument("--jobs", type=int, default=min(8, max(1, (os.cpu_count() or 2) // 2)),
                        help="parallel workload boots (default: %(default)s)")
    parser.add_argument("--silence", type=float, default=900.0, metavar="SEC",
                        help="seconds a workload may print nothing (default: %(default)s)")
    parser.add_argument("--count-warn", type=float, default=0.05,
                        help="instruction delta vs baseline that warns (default: %(default)s)")
    parser.add_argument("--fail-on-count", action="store_true",
                        help="an instruction delta beyond --count-warn fails the comparison")
    parser.add_argument("--work", type=Path, default=REPO / ".cache/kernel_compare",
                        help="build prefixes, payloads and results live here (default: %(default)s)")
    parser.add_argument("--keep", action="store_true",
                        help="keep each guest's work directory (qemu log, images)")
    parser.add_argument("--list", action="store_true", help="show the workload battery and stop")
    args = parser.parse_args(argv[1:] if argv else None)

    if args.list:
        for wl in WORKLOADS:
            flags = ", ".join(k for k in ("rc_only", "needs") if wl.get(k))
            print(f"{wl['name']:<18} {wl['cmd']}" + (f"  [{flags}]" if flags else ""))
        return 0

    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    unknown = [v for v in variants if v not in ("tcc", "llvm")]
    if unknown:
        parser.error(f"unknown variants: {', '.join(unknown)} (known: tcc, llvm)")
    args.work = args.work.resolve()
    args.work.mkdir(parents=True, exist_ok=True)
    check_prereqs(variants)
    payload = prepare_payload(args)

    results = {
        "schema": 2,
        "meta": {
            "date": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "git_rev": git_rev(),
            "optimize": args.optimize,
            "rootfs_sha256": sha256_file(REPO / "rootfs.img"),
            "qemu": "mps3-an524",
            "counter": "gated icount plugin (guest instructions, @@PROFILE@@ window)",
        },
        "runs": {},
    }
    elfs = {}
    for variant in variants:
        elfs[variant] = build_variant(variant, args)
        results["runs"][variant] = {
            "kernel": str(elfs[variant]),
            "kernel_sha256": sha256_file(elfs[variant]),
            "kernel_bytes": elfs[variant].stat().st_size,
            "tests": {},
        }

    dispatch_workers(results["runs"], elfs, payload, args)

    print_ab_table(results)
    for variant, run_data in results["runs"].items():
        size_kb = run_data["kernel_bytes"] / 1024
        print(f"[{variant}] kernel {size_kb:.0f} KiB, sha256 {run_data['kernel_sha256'][:16]}…")

    failures = []
    if args.store:
        baseline_path = Path(args.store) if args.store != "default" else DEFAULT_BASELINE
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(json.dumps(results, indent=2) + "\n")
        print(f"\nbaseline stored: {baseline_path}")
    elif args.baseline.is_file():
        baseline = json.loads(args.baseline.read_text())
        failures = compare_with_baseline(results, baseline, args)
    else:
        print(f"\nno baseline at {args.baseline}; run with --store to record one")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out = args.work / f"results-{stamp}.json"
    out.write_text(json.dumps(results, indent=2) + "\n")
    print(f"results: {out}")
    return 1 if failures else 0


if __name__ == "__main__":
    ensure_smoke_venv()  # no-op under the smoke venv; otherwise re-exec under it
    sys.exit(main(sys.argv))
