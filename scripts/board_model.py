#!/usr/bin/env python3
"""RP2350 board model: profile on-device tcc compiles on QEMU at board speed.

QEMU's mps3-an524 runs the same kernel and userspace as the Pico Plus 2, but
weighs every byte the same, so its profiles put the time in the wrong places:
on the board, code and read-only data are fetched from flash and process heaps
spill into PSRAM, both behind a 16 KB XIP cache whose misses cost a QSPI
transaction.  The board model adds that back:

  * tools/board_model/rp2350_timing.c, a QEMU TCG plugin, charges the board's
    costs (core at 532 MHz, the XIP cache in front of flash and PSRAM, the
    uncached page clear) and keeps the guest's clock on modeled board time --
    so tcc's own -bench and PASS_TIME tables read board time, unchanged;
  * an image is an an524 tree whose memory map is the board's (336 KB of
    process SRAM, 8 MB of PSRAM), so the kernel's tiering spills tcc's heap
    exactly where the board does;
  * the costs are fitted to board measurements (`calibrate`); against the
    2026-10-07 board run the model is within ~3-7% per compile.

Workflow:
  board_model.py setup                         build QEMU with plugins + the plugin
  board_model.py image base                    image from this tree's tinycc
  board_model.py image new --tinycc ~/repos/yasos-tcc-cj-perf   (a checkout or a git rev)
  board_model.py run base -k strlen            smoke tcc suites on the image (-O2 default), profiled
  board_model.py report RUN                    slowest compiles, suite-wide pass totals
  board_model.py compare RUN_A RUN_B           per-compile and per-pass deltas
  board_model.py calibrate BOARD_RUN_DIR IMAGE refit the costs to a board run

Everything lives under .cache/board_model/ (qemu/, plugin/, images/, runs/).
"""
import argparse
import datetime
import glob
import itertools
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def _main_checkout():
    """The repository's main checkout (differs from REPO in a git worktree)."""
    r = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                       capture_output=True, text=True)
    return Path(r.stdout.strip()).parent if r.returncode == 0 else REPO


MAIN = _main_checkout()
ROOT = Path(os.environ.get("BOARD_MODEL_HOME", MAIN / ".cache" / "board_model"))
# helpers that live outside git: a static glib prefix + QEMU source, the venvs
HELPER_ROOTS = [REPO, MAIN]
QEMU_DIR = ROOT / "qemu"
PLUGIN = ROOT / "plugin" / "librp2350_timing.so"
PLUGIN_SRC = REPO / "tools" / "board_model" / "rp2350_timing.c"
PARAMS = ROOT / "params.json"
QEMU_VERSION = "11.1.2"

AN524_ARGS = ("-global sse-200.CPU0_FPU=on -global sse-200.CPU1_FPU=on "
              "-global sse-200.CPU0_DSP=on -global sse-200.CPU1_DSP=on")
# an524 addresses that stand for the board's XIP regions: kernel flash and the
# romfs (programs execute in place from it, as from the board's flash).
REGIONS = "flash=0x10000000:0x10080000,flash=0x60000000:0x64000000"
# The board's memory, applied to an image's an524 linker script.
BOARD_LENGTHS = {"process_ram": "336K", "psram": "8M"}

# Image trees are copies of a checkout without these.
COPY_EXCLUDE = {".git", ".cache", ".zig-cache", "zig-out", ".claude", ".qemu_smoke_venv", "yasos_venv"}


def log(msg):
    print(f">> {msg}", flush=True)


def sh(cmd, cwd=None, env=None, logfile=None):
    log(f"{cmd}" + (f"   (log: {logfile})" if logfile else ""))
    if logfile:
        with open(logfile, "w") as fh:
            r = subprocess.run(cmd, shell=True, cwd=cwd, env=env, stdout=fh, stderr=subprocess.STDOUT)
    else:
        r = subprocess.run(cmd, shell=True, cwd=cwd, env=env)
    if r.returncode:
        sys.exit(f"failed ({r.returncode}): {cmd}" + (f"\n  see {logfile}" if logfile else ""))


# --------------------------------------------------------------------------- setup

def glib_pkgconfig():
    """A PKG_CONFIG_PATH that finds glib-2.0, or None."""
    candidates = [r / ".cache/qemu_plugin/prefix" / lib / "pkgconfig" for r in HELPER_ROOTS for lib in ("lib", "lib64")]
    paths = [str(p) for p in candidates if p.is_dir()]
    env = dict(os.environ, PKG_CONFIG_PATH=":".join(paths + [os.environ.get("PKG_CONFIG_PATH", "")]))
    ok = subprocess.run(["pkg-config", "--exists", "glib-2.0"], env=env).returncode == 0
    return env["PKG_CONFIG_PATH"] if ok else None


def cmd_setup(args):
    pc = glib_pkgconfig()
    if pc is None:
        sys.exit("glib-2.0 development files not found: install glib2-devel (and meson), or build the static "
                 "prefix in .cache/qemu_plugin")
    env = dict(os.environ, PKG_CONFIG_PATH=pc)
    venv_bin = next((r / ".cache/qemu_plugin/venv/bin" for r in HELPER_ROOTS if (r / ".cache/qemu_plugin/venv/bin").is_dir()),
                    REPO / ".cache/qemu_plugin/venv/bin")
    if venv_bin.is_dir():
        env["PATH"] = f"{venv_bin}:{env['PATH']}"
    qemu = QEMU_DIR / "qemu-system-arm"
    if not qemu.exists() or args.rebuild_qemu:
        src = next((r / f".cache/qemu_plugin/src/qemu-{QEMU_VERSION}" for r in HELPER_ROOTS
                    if (r / f".cache/qemu_plugin/src/qemu-{QEMU_VERSION}").is_dir()), ROOT / f"src/qemu-{QEMU_VERSION}")
        if not src.is_dir():
            dl = ROOT / "src"
            dl.mkdir(parents=True, exist_ok=True)
            tar = dl / f"qemu-{QEMU_VERSION}.tar.xz"
            if not tar.exists():
                sh(f"curl -fL -o {tar} https://download.qemu.org/qemu-{QEMU_VERSION}.tar.xz")
            sh(f"tar -xf {tar} -C {dl}")
            src = dl / f"qemu-{QEMU_VERSION}"
        QEMU_DIR.mkdir(parents=True, exist_ok=True)
        python = venv_bin / "python3" if venv_bin.is_dir() else Path(sys.executable)
        sh(f"{src}/configure --target-list=arm-softmmu --enable-plugins --disable-docs --disable-tools "
           f"--disable-werror --disable-gtk --disable-sdl --disable-vnc --disable-opengl --disable-spice "
           f"--disable-libusb --disable-usb-redir --python={python}",
           cwd=QEMU_DIR, env=env, logfile=QEMU_DIR / "configure.log")
        sh(f"ninja -j{os.cpu_count()} qemu-system-arm", cwd=QEMU_DIR, env=env, logfile=QEMU_DIR / "ninja.log")
    inc = None
    for cand in [r / f".cache/qemu_plugin/src/qemu-{QEMU_VERSION}/include/plugins" for r in HELPER_ROOTS] + [
            ROOT / f"src/qemu-{QEMU_VERSION}/include/plugins"]:
        if (cand / "qemu-plugin.h").exists():
            inc = cand
    if inc is None:
        sys.exit("qemu-plugin.h not found (QEMU source tree missing)")
    PLUGIN.parent.mkdir(parents=True, exist_ok=True)
    glib_cflags = subprocess.run(["pkg-config", "--cflags", "glib-2.0"], env=env, capture_output=True,
                                 text=True).stdout.strip()
    sh(f"gcc -O2 -shared -fPIC -Wall -I{inc} {glib_cflags} -o {PLUGIN} {PLUGIN_SRC}")
    log(f"ready: {qemu}, {PLUGIN}")


# --------------------------------------------------------------------------- images

def copy_tree(src, dst):
    dst.mkdir(parents=True)
    for entry in src.iterdir():
        if entry.name in COPY_EXCLUDE:
            continue
        sh(f"cp -a --reflink=auto {entry} {dst}/")


def put_tinycc(spec, tcc_dst, patch):
    """Replace the image's tinycc sources with a git revision of this tree's
    tinycc, or with another checkout's working tree (uncommitted changes and
    all)."""
    if Path(spec).expanduser().is_dir():
        src = Path(spec).expanduser().resolve()
        # every tracked file as it is in the working tree (local edits
        # included); --no-recursion keeps gitlinks (test submodules) out
        shutil.rmtree(tcc_dst / "source")
        staged = subprocess.run(["git", "-C", str(src), "ls-files", "-c", "-s", "-z"], capture_output=True,
                                text=True, check=True).stdout.split("\0")
        files = [e.split("\t", 1)[1] for e in staged if e and not e.startswith("160000 ")
                 and (src / e.split("\t", 1)[1]).exists()]  # no gitlinks or working-tree deletions
        listing = tcc_dst / ".board_model_files"
        listing.write_text("\0".join(files))
        sh(f"tar -C {src} --null --no-recursion -T {listing} -cf - | tar -x -C {tcc_dst}")
        listing.unlink()
        head = subprocess.run(["git", "-C", str(src), "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
        dirty = subprocess.run(["git", "-C", str(src), "status", "--porcelain", "-uno"], capture_output=True, text=True)
        desc = f"checkout {src} at {head.stdout.strip()}" + (" + local edits" if dirty.stdout.strip() else "")
    else:
        rev = subprocess.run(["git", "-C", str(MAIN / "libs/tinycc"), "rev-parse", "--verify", spec + "^{commit}"],
                             capture_output=True, text=True)
        if rev.returncode:
            sys.exit(f"--tinycc {spec}: neither a directory nor a revision of libs/tinycc")
        shutil.rmtree(tcc_dst / "source")
        sh(f"git -C {MAIN / 'libs/tinycc'} archive {rev.stdout.strip()} | tar -x -C {tcc_dst}")
        desc = f"rev {rev.stdout.strip()}"
    if patch:
        sh(f"patch -p1 -s -d {tcc_dst} < {Path(patch).resolve()}")
        desc += f" + {patch}"
    return desc


def board_shape(linker_script):
    s = linker_script.read_text()
    for region, length in BOARD_LENGTHS.items():
        s, n = re.subn(rf"(^\s*{region}\s*\([^)]*\)\s*:\s*ORIGIN\s*=\s*0x[0-9A-Fa-f]+\s*,\s*LENGTH\s*=\s*)\S+",
                       rf"\g<1>{length} /* board model */", s, flags=re.M)
        if n != 1:
            sys.exit(f"could not resize {region} in {linker_script}")
    linker_script.write_text(s)


def cmd_image(args):
    dst = ROOT / "images" / args.name
    src = Path(args.source).resolve() if args.source else REPO
    if dst.exists():
        if not args.force:
            sys.exit(f"{dst} exists (--force to rebuild it from scratch)")
        shutil.rmtree(dst)
    copy_tree(src, dst)
    meta = {"name": args.name, "source": str(src), "created": datetime.datetime.now().isoformat(timespec="seconds"),
            "tinycc": "as in source tree"}
    tcc = dst / "libs/tinycc"
    if args.tinycc:
        meta["tinycc"] = put_tinycc(args.tinycc, tcc, args.tinycc_patch)
    # the copied tree's tinycc build state is the source tree's: drop it
    for f in glob.glob(str(tcc / ".yasos-build/*.stamp")):
        os.remove(f)
    for pat in ("armv8m-arch", "armv8m-ir", "armv8m-source", "armv8m-*.o", "*.o"):
        for f in glob.glob(str(tcc / pat)):
            shutil.rmtree(f) if os.path.isdir(f) else os.remove(f)
    for venv in (".qemu_smoke_venv", "yasos_venv"):
        have = next((r / venv for r in HELPER_ROOTS if (r / venv).is_dir()), None)
        if have:  # a copy, not a link: the build re-runs `python3 -m venv` on it
            sh(f"cp -a --reflink=auto {have} {dst / venv}")
    sh("zig build defconfig -Ddefconfig_file=configs/qemu_mps3_an524_defconfig", cwd=dst,
       logfile=dst / "board_model_defconfig.log")
    board_shape(dst / "hal/source/arm/qemu_mps3/linker_script.ld")
    rootfs_env = dict(os.environ)
    rootfs_env.pop("DEBUG", None)  # Toybox treats DEBUG as a command prefix.
    sh("./build_rootfs.sh -c -o rootfs.img --no-kernel", cwd=dst, env=rootfs_env,
       logfile=dst / "board_model_rootfs.log")
    sh("zig build -Doptimize=ReleaseSafe", cwd=dst, logfile=dst / "board_model_kernel.log")
    (dst / "board_model_image.json").write_text(json.dumps(meta, indent=1))
    log(f"image {args.name}: {dst} ({meta['tinycc']})")


def image_dir(name):
    d = ROOT / "images" / name
    if not (d / "zig-out/bin/yasos_kernel").exists():
        sys.exit(f"no image {name} (board_model.py image {name})")
    return d


def plugin_args(kernel, params=None):
    nm = subprocess.run(["arm-none-eabi-nm", "-S", str(kernel)], capture_output=True, text=True).stdout
    clk = re.search(r"^([0-9a-f]+) [0-9a-f]+ \w yasos_modeled_clock_ns$", nm, re.M)
    uz = re.search(r"^([0-9a-f]+) ([0-9a-f]+) \w yasos_uncached_zero$", nm, re.M)
    ps = re.search(r"^([0-9a-f]+) \w __psram_start__$", nm, re.M)
    pe = re.search(r"^([0-9a-f]+) \w __psram_end__$", nm, re.M)
    if not (clk and uz and ps and pe):
        sys.exit(f"{kernel} has no board-model symbols (an an524 kernel from this tree?)")
    lo = int(uz.group(1), 16)
    a = (f"clock=0x{clk.group(1)},{REGIONS},psram=0x{ps.group(1)}:0x{pe.group(1)},"
         f"nocache={lo:#x}:{lo + int(uz.group(2), 16):#x}")
    params = params if params is not None else (json.loads(PARAMS.read_text()) if PARAMS.exists() else {})
    for k, v in params.items():
        a += f",{k}={v}"
    return a


def qemu_env(image, extra=""):
    kernel = image / "zig-out/bin/yasos_kernel"
    qemu = QEMU_DIR / "qemu-system-arm"
    if not qemu.exists() or not PLUGIN.exists():
        sys.exit("run `board_model.py setup` first")
    env = dict(os.environ)
    env["YASOS_QEMU_BIN"] = str(qemu)
    env["YASOS_QEMU_EXTRA_ARGS_APPEND"] = f"-d plugin -plugin {PLUGIN},{plugin_args(kernel)}{extra}"
    return env


# --------------------------------------------------------------------------- runs

def cmd_run(args):
    image = image_dir(args.image)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = ROOT / "runs" / (args.name or f"{args.image}-{stamp}")
    run_dir.mkdir(parents=True, exist_ok=bool(args.name))
    env = qemu_env(image)
    env["YASOS_TCC_PROFILE"] = "1"              # tcc -bench: phases + PASS_TIME, on the modeled clock
    env["YASOS_SMOKE_RESULTS_DIR"] = str(run_dir / "results")
    env["YASOS_SMOKE_ENABLE_GCC_TORTURE"] = "1"
    cmd = [str(image / "scripts/run_qemu_smoke.sh"), "--no-build", "--opt-levels", args.opt_levels,
           *(args.tests or ["tcc_suite_test.py"]), "-n", str(args.jobs)]
    if args.k:
        cmd += ["-k", args.k]
    cmd += args.pytest_args
    meta = {"image": args.image, "image_meta": json.loads((image / "board_model_image.json").read_text()),
            "cmd": cmd, "plugin": env["YASOS_QEMU_EXTRA_ARGS_APPEND"], "started": stamp}
    (run_dir / "run.json").write_text(json.dumps(meta, indent=1))
    log(f"run {run_dir.name}: {' '.join(cmd)}")
    with open(run_dir / "pytest.log", "w", buffering=1) as fh:
        p = subprocess.Popen(cmd, cwd=image, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in p.stdout:
            fh.write(line)
            if re.search(r"PASSED|FAILED|ERROR|passed|failed", line):
                sys.stdout.write(line)
        rc = p.wait()
    logs = image / ".cache/qemu_smoke_logs"
    if logs.is_dir():
        shutil.copytree(logs, run_dir / "smoke_logs", dirs_exist_ok=True)
    meta["pytest_rc"] = rc
    (run_dir / "run.json").write_text(json.dumps(meta, indent=1))
    log(f"results in {run_dir} (pytest rc {rc}); board_model.py report {run_dir.name}")
    if rc:
        sys.exit(rc)


BENCH_TOTAL = re.compile(r"^# init total\s+(\d+)")
BENCH_PHASE = re.compile(r"^# bench total (\S+)\s+(\d+) us")
PASS_ROW = re.compile(r"^PASS_TIME (\S+)\s+(\d+)\s+(\d+)\s+(\d+)")


def load_run(name):
    d = Path(name) if Path(name).is_dir() else ROOT / "runs" / name
    res = {}
    for f in sorted((d / "results").glob("*.jsonl")):
        for line in f.read_text().splitlines():
            r = json.loads(line)
            t = {"status": r["status"], "host_ms": r["host_compile_ms"], "phases": {}, "passes": {}}
            for b in r["bench"]:
                m = BENCH_TOTAL.match(b)
                if m:
                    t["ms"] = int(m.group(1)) / 1000
                m = BENCH_PHASE.match(b)
                if m:
                    t["phases"][m.group(1)] = int(m.group(2)) / 1000
            for p in r["passes"]:
                m = PASS_ROW.match(p)
                if m:
                    t["passes"][m.group(1)] = t["passes"].get(m.group(1), 0) + int(m.group(2)) / 1000
            if "ms" in t:
                res[r["test_id"]] = t   # a rerun (retry) replaces the earlier record
    if not res:
        sys.exit(f"no results in {d}/results")
    return res


def pass_totals(res):
    tot = {}
    for t in res.values():
        for p, ms in t["passes"].items():
            tot[p] = tot.get(p, 0) + ms
    return tot


def cmd_report(args):
    res = load_run(args.run)
    total = sum(t["ms"] for t in res.values())
    print(f"{len(res)} compiles, modeled board time {total / 1000:.1f} s")
    print(f"\nslowest {args.top} compiles (modeled board ms):")
    for tid, t in sorted(res.items(), key=lambda kv: -kv[1]["ms"])[:args.top]:
        ph = t["phases"]
        print(f"  {t['ms']:9.0f}  opt {ph.get('func-opt', 0):7.0f}  alloc {ph.get('func-alloc', 0):7.0f}  "
              f"cg {ph.get('func-codegen', 0):6.0f}  {tid}")
    pt = pass_totals(res)
    ptotal = sum(pt.values())
    print(f"\npasses, summed over the suite ({ptotal / 1000:.1f} s of {total / 1000:.1f} s in timed passes):")
    for p, ms in sorted(pt.items(), key=lambda kv: -kv[1])[:args.top]:
        worst = max(res.items(), key=lambda kv: kv[1]["passes"].get(p, 0))
        print(f"  {ms / 1000:8.2f} s  {100 * ms / ptotal:5.1f}%  {p:28s} worst: {worst[1]['passes'][p]:.0f} ms {worst[0]}")


def cmd_compare(args):
    a, b = load_run(args.a), load_run(args.b)
    common = sorted(set(a) & set(b))
    ta, tb = sum(a[t]["ms"] for t in common), sum(b[t]["ms"] for t in common)
    print(f"{len(common)} compiles in both: {ta / 1000:.1f} s -> {tb / 1000:.1f} s ({100 * (tb - ta) / ta:+.1f}%)")
    rows = sorted(common, key=lambda t: b[t]["ms"] - a[t]["ms"])
    wins = [t for t in rows if b[t]["ms"] < a[t]["ms"]][:args.top]
    losses = [t for t in reversed(rows) if b[t]["ms"] > a[t]["ms"]][:args.top]
    for title, sel in (("largest wins", wins), ("largest losses", losses)):
        print(f"\n{title}:" + ("" if sel else " none"))
        for t in sel:
            print(f"  {a[t]['ms']:9.0f} -> {b[t]['ms']:9.0f} ms  {100 * (b[t]['ms'] - a[t]['ms']) / a[t]['ms']:+6.1f}%  {t}")
    pa = pass_totals({t: a[t] for t in common})
    pb = pass_totals({t: b[t] for t in common})
    print(f"\npasses (suite totals), largest changes:")
    for p in sorted(set(pa) | set(pb), key=lambda p: -abs(pb.get(p, 0) - pa.get(p, 0)))[:args.top]:
        print(f"  {pa.get(p, 0) / 1000:8.2f} -> {pb.get(p, 0) / 1000:8.2f} s  {(pb.get(p, 0) - pa.get(p, 0)) / 1000:+7.2f} s  {p}")
    print("\nnote: small moves in passes a change did not touch are usually code layout -- the 16 KB XIP\n"
          "cache sees a different tcc text layout -- which is real on the board too.")


# --------------------------------------------------------------------------- calibration

GUEST_ROOT = "/root/ci/sources/v2/"
TESTS = REPO / "libs/tinycc/tests"
LOCAL = [("gcc_torture/compile/", TESTS / "gcctestsuite/gcc-testsuite/gcc/testsuite/gcc.c-torture/compile"),
         ("gcc_torture/execute/", TESTS / "gcctestsuite/gcc-testsuite/gcc/testsuite/gcc.c-torture/execute"),
         ("ir_tests/", TESTS / "ir_tests"), ("tests2/", TESTS / "tests2")]
COUNTERS = re.compile(r"insns (\d+) .*\n.*ifetch hit (\d+) miss (\d+) \| dread hit (\d+) miss (\d+) \| dwrite hit (\d+) "
                      r"miss (\d+) \| writebacks (\d+).*uncached_w (\d+)")
TERMS = ["cpi", "hit", "imiss", "dmiss", "wb", "ucw", "const_ms"]


def board_commands(run_dir):
    """test id -> (board compile_ms, tcc command) from a board remote_smoke_logs run."""
    rep = json.loads((run_dir / "tcc_timing_report.json").read_text())
    tests = rep["tests"].values() if isinstance(rep["tests"], dict) else rep["tests"]
    logs = sorted(run_dir.glob("test_run_*.txt"))
    out = {}
    for t in tests:
        norm = re.sub(r"[/\[\]]", "_", t["test_id"])
        f = next((f for f in logs if ("suite_" + norm + "__") in f.name), None)
        if not f:
            continue
        line = next((l for l in f.read_text(errors="replace").replace("\r", "").splitlines()
                     if l.startswith("$ ") and " tcc " in f" {l[2:]}"), None)
        if line:
            out[t["test_id"]] = (t["compile_ms"], line[2:])
    return out


def replay_plan(cmd):
    """Files to put on /mnt and the guest command for one board compile."""
    cmd = re.sub(r";\s*compile_status=.*?echo __COMPILE_STATUS__:\$compile_status", "", cmd)
    cmd = re.sub(r";\s*ulimit -s 32\s*$", "", cmd).strip()
    srcs = re.findall(re.escape(GUEST_ROOT) + r"(\S+)", cmd)
    if len(srcs) != 1:
        return None
    rel = srcs[0]
    local = next((d / Path(rel).name for p, d in LOCAL if rel.startswith(p)), None)
    if not local or not local.is_file():
        return None
    files = [(local, "src/" + rel)]
    for m in re.finditer(r'^\s*#\s*include\s*"([^"]+)"', local.read_text(errors="replace"), re.M):
        inc = local.parent / m.group(1)
        if ".." in m.group(1) or not inc.is_file():
            return None
        if re.search(r'^\s*#\s*include\s*"', inc.read_text(errors="replace"), re.M):
            return None
        files.append((inc, str(Path("src/" + rel).parent / m.group(1))))
    cmd = cmd.replace(GUEST_ROOT + rel, "/mnt/src/" + rel)
    cmd = re.sub(r"-o /tmp/(\S+)", r"-o /mnt/out/\1", cmd)
    return files, f"mkdir -p /mnt/out && cd /mnt && {cmd} > /mnt/out/log.txt 2>&1"


def counters_of(plog):
    m = COUNTERS.search(plog.read_text()) if plog.exists() else None
    if not m:
        return None
    insns, ih, im, rh, rm, wh, wm, wb, ucw = map(int, m.groups())
    return [insns, ih + rh + wh, im, rm + wm, wb, ucw]


def replay(image, label, files, cmd, out):
    work = Path(tempfile.mkdtemp(prefix=f"{label}_", dir=out))
    for src, rel in files:
        (work / "mnt" / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, work / "mnt" / rel)
    (work / "mnt").mkdir(exist_ok=True)
    plog = out / f"{label}.plugin.log"
    env = qemu_env(image, f" -d plugin -D {plog}")
    env["YASOS_QEMU_EXTRA_ARGS"] = AN524_ARGS + " " + env.pop("YASOS_QEMU_EXTRA_ARGS_APPEND")
    py = next((r / "libs/tinycc/venv/bin/python3" for r in HELPER_ROOTS if (r / "libs/tinycc/venv/bin/python3").exists()),
              REPO / ".qemu_smoke_venv/bin/python3")
    r = subprocess.run([str(py if py.exists() else sys.executable), str(REPO / "scripts/qemu_mount.py"),
                        "--kernel", str(image / "zig-out/bin/yasos_kernel"), str(work / "mnt"), "--silence", "1800",
                        "-c", cmd], env=env, capture_output=True, text=True, cwd=REPO)
    shutil.rmtree(work, ignore_errors=True)
    return label, r.returncode, counters_of(plog)


def nnls(A, b):
    import numpy as np
    best, best_r = np.zeros(A.shape[1]), float(b @ b)
    for k in range(1, A.shape[1] + 1):
        for cols in itertools.combinations(range(A.shape[1]), k):
            x, *_ = np.linalg.lstsq(A[:, cols], b, rcond=None)
            if (x >= 0).all():
                r = float(((A[:, cols] @ x - b) ** 2).sum())
                if r < best_r:
                    best_r, best = r, np.zeros(A.shape[1])
                    best[list(cols)] = x
    return best


def cmd_calibrate(args):
    import math
    import numpy as np
    image = image_dir(args.image)
    run_dir = Path(args.board_run).resolve()
    cmds = board_commands(run_dir)
    cands = []
    for tid, (ms, cmd) in cmds.items():
        if ms >= 150 and re.match(r"(gcc_compile|gcc_execute)/", tid):
            plan = replay_plan(cmd)
            if plan:
                cands.append((ms, tid, plan))
    cands.sort()
    lo, hi = math.log(cands[0][0]), math.log(cands[-1][0])
    chosen, seen = [], set()
    for k in range(args.n):
        target = lo + (hi - lo) * k / max(args.n - 1, 1)
        c = min((c for c in cands if c[1] not in seen), key=lambda c: abs(math.log(c[0]) - target))
        seen.add(c[1])
        chosen.append(c)
    out = ROOT / "calibration" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True)
    tasks = [("baseline", [], "true", None, None)] + [(f"t{i}", c[2][0], c[2][1], c[0], c[1])
                                                       for i, c in enumerate(chosen)]
    with ThreadPoolExecutor(args.jobs) as ex:
        done = list(ex.map(lambda t: replay(image, t[0], t[1], t[2], out) + (t[3], t[4]), tasks))
    base = done[0][2]
    rows, ys, ids = [], [], []
    for label, rc, k, ms, tid in done[1:]:
        if rc or not k:
            log(f"skipped {tid} (rc {rc})")
            continue
        rows.append([x - y for x, y in zip(k, base)] + [1.0])
        ys.append(ms * 532e3)
        ids.append(tid)
    A, y = np.array(rows, float), np.array(ys, float)
    A[:, -1] = 532e3                       # the constant term in ms
    w = 1 / y
    train = np.arange(len(y)) % 2 == 0
    p = nnls(A[train] * w[train, None], y[train] * w[train])
    err = (A @ p - y) / y
    for i in np.argsort(y):
        print(f"  {y[i] / 532e3:9.0f} board  {(A @ p)[i] / 532e3:9.0f} model  {100 * err[i]:+6.1f}%  {ids[i]}"
              + ("" if train[i] else "   [held out]"))
    print("fit:      mean |err| %.1f%%  max %.1f%%" % (100 * abs(err[train]).mean(), 100 * abs(err[train]).max()))
    print("held out: mean |err| %.1f%%  max %.1f%%" % (100 * abs(err[~train]).mean(), 100 * abs(err[~train]).max()))
    params = {"cpi_milli": round(p[0] * 1000), "hit": round(p[1]), "imiss": round(p[2]), "dmiss": round(p[3]),
              "wb": round(p[4]), "ucw": round(p[5])}
    print("params:", params, f"(+{p[6]:.0f} ms per compile outside the model)")
    (out / "fit.json").write_text(json.dumps({"params": params, "const_ms": p[6], "tests": ids}, indent=1))
    if args.write:
        PARAMS.write_text(json.dumps(params, indent=1))
        log(f"wrote {PARAMS}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup", help="build QEMU with plugins and the rp2350_timing plugin")
    s.add_argument("--rebuild-qemu", action="store_true")
    s = sub.add_parser("image", help="build a board-model image (an524, board memory map)")
    s.add_argument("name")
    s.add_argument("--tinycc", help="a libs/tinycc git revision, or a tinycc checkout directory")
    s.add_argument("--tinycc-patch", help="patch applied to the image's tinycc (-p1)")
    s.add_argument("--source", help="yasos tree to copy (default: this one)")
    s.add_argument("--force", action="store_true")
    s = sub.add_parser("run", help="run the smoke tcc suites on an image under the model")
    s.add_argument("image")
    s.add_argument("-O", "--opt-levels", default="-O2")
    s.add_argument("-k", help="pytest -k expression")
    s.add_argument("-n", "--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    s.add_argument("--name", help="run name (default IMAGE-STAMP)")
    s.add_argument("--tests", nargs="*", help="pytest paths (default tcc_suite_test.py)")
    s.add_argument("pytest_args", nargs="*")
    s = sub.add_parser("report", help="slowest compiles and suite-wide pass totals of a run")
    s.add_argument("run")
    s.add_argument("--top", type=int, default=30)
    s = sub.add_parser("compare", help="per-compile and per-pass deltas between two runs")
    s.add_argument("a")
    s.add_argument("b")
    s.add_argument("--top", type=int, default=20)
    s = sub.add_parser("calibrate", help="fit the plugin's costs to a board run")
    s.add_argument("board_run", help="a .cache/remote_smoke_logs/<host>/<n> directory")
    s.add_argument("image", help="an image whose tinycc is the board's")
    s.add_argument("-n", type=int, default=40)
    s.add_argument("-j", "--jobs", type=int, default=8)
    s.add_argument("--write", action="store_true", help=f"save the fit to {PARAMS}")
    args = ap.parse_args()
    {"setup": cmd_setup, "image": cmd_image, "run": cmd_run, "report": cmd_report, "compare": cmd_compare,
     "calibrate": cmd_calibrate}[args.cmd](args)


if __name__ == "__main__":
    main()
