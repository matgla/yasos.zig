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

"""Where the device zig's time goes, at board speed: the kernel render under the board
model (scripts/board_model.py's RP2350 timing plugin on a board-shaped an524 kernel).

    scripts/zig_profile.py image NAME --zig ZIG_SRC   # an524 board model + the device zig in romfs
    scripts/zig_profile.py run NAME OUT [--warm] [--copy] [--env K=V] [--plugin ARGS] [--no-io]
                                                       # the kernel render of .cache/zig_device/tree
    scripts/zig_profile.py funcs NAME OUT [--top N]    # modeled time per function: zig, libc, kernel

image builds in this checkout (it is left configured for qemu_mps3_an524) and keeps the
kernel, rootfs.img, the build log and zig.elf -- the device zig relinked with symbols, the
same link as the YAFF executable, so its text is where the romfs copy runs -- under
.cache/board_model/images/NAME.  run mounts the tree (zig_device.py prepare) at /mnt and runs
its kernel compile with the plugin's per-PC and per-data-access profiles; the zig cache starts
empty unless --warm (a second run then measures what a board with a filled cache does).
--copy renders a private copy of the tree in OUT (runs side by side); --env sets the compiler's
environment (ZIG_ZIR_BUDGET=..., ZIG_ZIR_STICKY=...); --plugin appends plugin arguments.
/mnt costs the Pico Plus 2's SD card time unless --no-io (IO_ARGS: the fatdisk window as the
plugin's io= region, its defaults measured on the board 2026-11-09) -- without it the ZIR reloads
are free.  WB: dirty PSRAM writebacks, measured 2026-11-09 (memset 16.6 MB/s on the board,
18.3 modeled; the plugin's wb=0 default models 49).
funcs folds the PCs into functions like scripts/selfhost_profile.py funcs.
"""
import argparse
import bisect
import collections
import csv
import importlib.util
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TREE = REPO / ".cache/zig_device/tree"
IO_ARGS = "io=0x82000000:0x92000000"
WB = "wb=160"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bm = load("board_model", REPO / "scripts/board_model.py")
sp = load("selfhost_profile", REPO / "scripts/selfhost_profile.py")


def log(msg):
    print(f">> {msg}", flush=True)


def sh(cmd, logfile=None, **kw):
    out = open(logfile, "w") if logfile else None
    r = subprocess.run(cmd, shell=True, cwd=REPO, stdout=out, stderr=subprocess.STDOUT if out else None, **kw)
    if r.returncode:
        sys.exit(f"failed ({r.returncode}): {cmd}" + (f" -- see {logfile}" if logfile else ""))


def cmd_image(args):
    d = bm.ROOT / "images" / args.name
    if d.exists() and not args.force:
        sys.exit(f"{d} exists (--force)")
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    ld = REPO / "hal/source/arm/qemu_mps3/linker_script.ld"
    sh("zig build defconfig -Ddefconfig_file=configs/qemu_mps3_an524_defconfig", d / "defconfig.log")
    bm.board_shape(ld)
    try:
        log("rootfs with the device zig (build_rootfs.sh --zig)")
        sh(f"./build_rootfs.sh -c -o rootfs.img --zig {args.zig}", d / "board_model_rootfs.log")
        log("board-shaped an524 kernel")
        sh("rm -rf .zig-cache && zig build -Doptimize=ReleaseFast", d / "kernel.log")
    finally:
        subprocess.run(["git", "checkout", str(ld)], cwd=REPO)
    (d / "zig-out/bin").mkdir(parents=True)
    shutil.copy2(REPO / "zig-out/bin/yasos_kernel", d / "zig-out/bin/yasos_kernel")
    shutil.copy2(REPO / "rootfs.img", d / "rootfs.img")
    w = REPO / ".cache/zig-build"
    cross = REPO / "libs/tinycc/bin/armv8m-tcc"
    # build_zig.sh's link, as an ELF with symbols: same objects, same order, same layout.
    sh(f"{cross} -g -fvisibility=hidden -stack-size=196608 -Wl,--hot-text={REPO}/apps/zig/hot_functions.txt {w}/zig.o {w}/compat.o {w}/compiler_rt.o -lm "
       f"-Wl,-oformat=elf32-littlearm -o {d}/zig.elf")
    shutil.copy2(w / "zig", d / "zig.yaff")
    libc_lines = [l for l in (d / "board_model_rootfs.log").read_text(errors="replace").splitlines()
                  if l.startswith("armv8m-tcc ") and "-o build/libc.so.elf" in l]
    if libc_lines:
        line = libc_lines[-1].replace("armv8m-tcc ", f"{cross} -g ", 1).replace("-o build/libc.so.elf", f"-o {d}/libc.elf")
        subprocess.run(line, shell=True, cwd=REPO / "libs/libc", capture_output=True)
    shutil.copy2(REPO / "libs/libc/build/libc.so.elf", d / "libc.so.elf")
    (d / "board_model_image.json").write_text('{"zig": "%s"}\n' % args.zig)
    log(f"image {d}")
    return 0


def kernel_line():
    run = (TREE / "run.sh").read_text().splitlines()
    for line in run:
        if "zig build-obj" in line and "--name yasos_kernel " in line:
            return line.split("; r=$?")[0]
    sys.exit(f"{TREE}/run.sh: no kernel compile (zig_device.py prepare)")


def cmd_run(args):
    image = bm.image_dir(args.name)
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    tree = TREE
    if args.copy:
        tree = out / "tree"
        if not args.warm:
            shutil.rmtree(tree, ignore_errors=True)
        if not tree.exists():
            shutil.copytree(TREE, tree, symlinks=True, ignore=shutil.ignore_patterns("zc", ".zspill", "out"))
    if not args.warm:
        shutil.rmtree(tree / "zc", ignore_errors=True)
        shutil.rmtree(tree / ".zspill", ignore_errors=True)
    (tree / "poolmap.txt").unlink(missing_ok=True)
    # The InternPool hints of the last full host run (zig_device.py full) are what a board
    # render gets; prepare's are smaller, and a pool that grows mid-render fragments PSRAM
    # until the model runs out of memory where the board does not.
    full_hints = REPO / ".cache/zig_device/full/ip-hints-yasos_kernel"
    if full_hints.exists():
        shutil.copy2(full_hints, tree / "ip-hints-yasos_kernel")
    import shlex
    line = kernel_line().replace("/tmp/zc", "/mnt/zc")
    hints, _, compile_ = line.partition(" zig build-obj ")
    # In a response file: YasOS's execve takes at most 256 arguments.
    (tree / "zig_profile.rsp").write_text("".join(a + "\n" for a in shlex.split(compile_)))
    cmd = ("cd /mnt && mkdir -p /mnt/out /mnt/zc/g /tmp/zighome && export HOME=/tmp/zighome && "
           "export ZIG_C_SPILL_DIR=/mnt/.zspill && mkdir -p /mnt/.zspill && cat /proc/mempeak > /dev/null && "
           + (f"touch /mnt/.sampling && (while [ -e /mnt/.sampling ]; do sleep {args.poolmap}; "
              "echo POOLMAP_AT $(date +%s) >> /mnt/poolmap.txt; cat /proc/poolmap /proc/meminfo >> /mnt/poolmap.txt; done) & "
              if args.poolmap else "") +
           "".join(f"s=$(date +%s); {hints} {' '.join(args.env)} zig build-obj @zig_profile.rsp; "
                     f"echo RENDER{k} rc=$? modeled_secs=$(( $(date +%s) - s )); " for k in range(args.repeat - 1)) +
           f"s=$(date +%s); {hints} {' '.join(args.env)} zig build-obj @zig_profile.rsp; echo RC=$? modeled_secs=$(( $(date +%s) - s )); rm -f /mnt/.sampling; [ -e /mnt/poolmap.txt ] && cat /mnt/poolmap.txt; cat /proc/mempeak; sha256sum /mnt/out/yasos_kernel.c")
    extra = f",pcprof={out}/zig.pc.csv,dprof={out}/zig.data.csv"
    if not args.no_io:
        extra += f",{IO_ARGS},{WB}"
    if args.plugin:
        extra += f",{args.plugin}"
    env = bm.qemu_env(image, f"{extra} -d plugin -D {out}/plugin.log")
    env["YASOS_QEMU_EXTRA_ARGS"] = bm.AN524_ARGS + " " + env.pop("YASOS_QEMU_EXTRA_ARGS_APPEND")
    log(f"QEMU + board model: the kernel render ({'warm' if args.warm else 'empty'} zig cache)")
    t0 = time.time()
    r = subprocess.run([sys.executable, str(REPO / "scripts/qemu_mount.py"), "--kernel",
                        str(image / "zig-out/bin/yasos_kernel"), str(tree), "--silence", "7200", "-c", cmd],
                       env=env, capture_output=True, text=True, cwd=REPO)
    (out / "run.txt").write_text(r.stdout + "\n--- stderr\n" + r.stderr)
    for l in r.stdout.splitlines():
        if l.startswith(("RC=", "RENDER", "process_peak")) or re.match(r"[0-9a-f]{64}\b", l) or "error" in l:
            print(l)
    for l in (out / "plugin.log").read_text(errors="replace").splitlines():
        if "modeled_ms" in l or "rp2350_timing: io" in l:
            print(l)
    log(f"host {time.time() - t0:.0f} s; {out}")
    return 0 if "RC=0" in r.stdout else 1


class CodeMap:
    """Guest PC -> (module, function): zig and libc where their romfs copies run, the kernel."""

    def __init__(self, image):
        data = (image / "rootfs.img").read_bytes()
        self.mods = []
        for name, stripped, sym in (("zig", image / "zig.elf", image / "zig.elf"),
                                    ("libc", image / "libc.so.elf", image / "libc.elf")):
            if not sym.exists():
                continue
            a, o, n = sp.text_of(stripped)
            pos = data.find(stripped.read_bytes()[o + 64:o + 576])
            if pos < 0:
                print(f"warning: {name} text not found in rootfs.img", file=sys.stderr)
                continue
            self.mods.append((name, 0x60000000 + pos - 64 - a, n, *sp.symbols(sym)))
        self.kA, self.kN = sp.symbols(image / "zig-out/bin/yasos_kernel")

    def name(self, pc):
        for name, base, n, A, N in self.mods:
            if base <= pc < base + n:
                i = bisect.bisect_right(A, pc - base) - 1
                return name, N[i] if i >= 0 else "?"
        i = bisect.bisect_right(self.kA, pc) - 1
        if i >= 0 and not 0x60000000 <= pc < 0x64000000 and not sp.PROCESS_RAM[0] <= pc < sp.PROCESS_RAM[1]:
            return "kernel", self.kN[i]
        return "other", "?"


def cmd_funcs(args):
    image = bm.image_dir(args.name)
    code = CodeMap(image)
    insns, stalls, fetch = collections.Counter(), collections.Counter(), collections.Counter()
    for r in csv.DictReader(open(Path(args.out) / "zig.pc.csv")):
        k = code.name(int(r["pc"], 16))
        insns[k] += int(r["insns"])
        stalls[k] += int(r["extra_cycles"])
        fetch[k] += int(r["fetch_cycles"])
    cyc = {k: insns[k] * sp.CPI + stalls[k] for k in insns}
    total = sum(cyc.values())
    print(f"total {total / sp.HZ:.1f} s modeled; {sum(insns.values()) / 1e9:.2f} G insns; "
          f"stalls {100 * sum(stalls.values()) / total:.0f}%")
    mod = collections.Counter()
    for k, v in cyc.items():
        mod[k[0]] += v
    print("by module:", {k: f"{v / sp.HZ:.0f} s {100 * v / total:.1f}%" for k, v in mod.most_common()})
    print(f"instructions {sum(insns.values()) * sp.CPI / sp.HZ:.1f} s, fetch {sum(fetch.values()) / sp.HZ:.1f} s, "
          f"data {(sum(stalls.values()) - sum(fetch.values())) / sp.HZ:.1f} s")
    print(f"{'%':>5} {'cum':>6} {'stall%':>6} {'fetch%':>6} {'Minsn':>8}  function")
    c = 0
    for k, v in sorted(cyc.items(), key=lambda x: -x[1])[:args.top]:
        c += v
        print(f"{100 * v / total:5.1f} {100 * c / total:6.1f} {100 * stalls[k] / v:6.0f} {100 * fetch[k] / v:6.0f} "
              f"{insns[k] / 1e6:8.1f}  {k[0]}:{k[1]}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("image")
    s.add_argument("name")
    s.add_argument("--zig", required=True, help="the zig fork's source tree")
    s.add_argument("--force", action="store_true")
    s = sub.add_parser("run")
    s.add_argument("name")
    s.add_argument("out")
    s.add_argument("--warm", action="store_true", help="keep the tree's zig cache from the last run")
    s.add_argument("--copy", action="store_true", help="render a private copy of the tree in OUT/tree")
    s.add_argument("--env", action="append", default=[], help="KEY=VALUE for the compiler (repeatable)")
    s.add_argument("--plugin", default="", help="extra plugin arguments, comma-separated")
    s.add_argument("--no-io", action="store_true", help="free /mnt and wb=0, as before 2026-11-09")
    s.add_argument("--repeat", type=int, default=1, help="render N times in one boot (the guest's /mnt does "
                   "not survive a boot, so --warm alone starts cold): RENDERk/RC lines give modeled seconds each")
    s.add_argument("--poolmap", type=int, default=0, metavar="SECS",
                   help="append /proc/poolmap and /proc/meminfo to TREE/poolmap.txt every SECS (guest time)")
    s = sub.add_parser("funcs")
    s.add_argument("name")
    s.add_argument("out")
    s.add_argument("--top", type=int, default=50)
    args = ap.parse_args()
    return {"image": cmd_image, "run": cmd_run, "funcs": cmd_funcs}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
