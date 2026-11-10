#!/usr/bin/env python3
"""The Zig half of the kernel on YasOS itself: the device zig renders the kernel to C.

    scripts/kernel_tcc/zig_device.py prepare    # host: capture, ship tree, host reference
    scripts/kernel_tcc/zig_device.py qemu       # the device zig in QEMU (an524), compared
    scripts/kernel_tcc/zig_device.py tcc        # then the tcc half on its output (device.py)
    scripts/kernel_tcc/zig_device.py full       # all of it in one boot, no host step between
    scripts/kernel_tcc/zig_device.py full --board [--flash]   # the same on the rig's board
    scripts/kernel_tcc/zig_device.py full --package DIR       # host reference + a package for:
    scripts/kernel_tcc/zig_device.py board-run --package DIR  # the board at this machine's probe (CI)

prepare runs `zig build --verbose kernel-tcc-plan` in a fresh cache and takes its two C
backend compiles -- the kernel (yasos_kernel) and Zig's compiler-rt -- with every path
rewritten for a tree the device can read: repository files at their relative paths,
generated .zig files (translate-c, build options) under gen/<hash>/, the Zig lib as lib/
(build_zig.sh's device lib, sdcard/var/lib/zig).  The tree holds every .zig file of the
directories the modules come from, and run.sh, which times each compile and reads
/proc/mempeak.  The same commands then run on the host with the fork's single-threaded
host compiler (.cache/zig-build/host-st/bin/zig, built by build_zig.sh), -j1: the device's
output must be byte-identical to it (stock zig, or more threads, number and order
differently).

prepare also slims the translate-c modules (slim_translated): each keeps only the
declarations the tree's other .zig files name, and what those need in turn.  translate-c
writes every declaration of every header, and the compiler loads a file's ZIR whole: on the
board the six HAL modules alone were 543 KB of source, their ZIR pinned at the render's
peak and re-read from the card at each reload.  The C is the same less unused constants;
--no-slim keeps the modules whole.

The outputs are Zig's raw C; scripts/kernel_tcc/tool.py fix-cbe and
apps/zig/strip_naked_asm.py turn them into what build/kernel_tcc.zig compiles.  tcc
applies those to the device's output and runs scripts/kernel_tcc/device.py with a copy
of the plan (zig-out/kernel_tcc_plan.json, written by the capture) that compiles them
in place of the host's stock-zig C: the kernel ELF ends up in .cache/zig_device/tcc.

full does it all on the device in one QEMU boot (--board: on the rig's board): the two
renders, tcc building scripts/kernel_tcc/zigfix.c (the Python fix-ups in C), the fix-ups -- the symbols the
archives provide included, made from the archives the boot itself built -- and every
command of the plan through the link.  The same script runs on the host first, with the
fork's single-threaded host compiler as zig and the cross as tcc: every output of the boot,
the kernel ELF included, must be identical to that.  build_all.sh prints every output's
sha256, so a board run is compared without pulling anything back.
"""
import argparse
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WORK = REPO / ".cache/zig_device"
# Single-threaded like the device compiler, so its output is the device's (build_zig.sh).
FORK_ZIG = REPO / ".cache/zig-build/host-st/bin/zig"
DEVICE_LIB = REPO / "sdcard/var/lib/zig"
NAMES = ("yasos_kernel", "compiler_rt")


def log(msg):
    print(f">> {msg}", flush=True)


def host_zig_lib():
    out = subprocess.run(["zig", "env"], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if '"lib_dir"' in line or line.strip().startswith(".lib_dir"):
            return Path(line.split('"')[-2]).resolve()
    sys.exit("zig env: no lib_dir")


def capture(cache):
    shutil.rmtree(cache, ignore_errors=True)
    log("zig build --verbose kernel-tcc-plan (fresh cache)")
    r = subprocess.run(["zig", "build", "--verbose", "--cache-dir", str(cache), "kernel-tcc-plan"],
                       cwd=REPO, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr[-3000:])
    found = {}
    for line in r.stderr.splitlines():
        if " build-obj " not in line or "-ofmt=c" not in line:
            continue
        argv = shlex.split(line)
        argv = argv[argv.index("build-obj") - 1:]  # after the "info(verbose): " prefix
        if "--name" in argv:
            name = argv[argv.index("--name") + 1]
            if name in NAMES:
                found[name] = argv
    missing = [n for n in NAMES if n not in found]
    if missing:
        sys.exit(f"no C backend compile of {missing} in the verbose output")
    return found


class Rewriter:
    def __init__(self, tree, cache, zig_lib):
        self.tree, self.cache, self.zig_lib = tree, cache.resolve(), zig_lib
        self.gen_roots = [self.cache / "o", (REPO / ".zig-cache/o").resolve()]
        self.repo_dirs = set()

    def path(self, p):
        p = Path(p)
        if not p.is_absolute():
            p = (REPO / p)
        rp = Path(os.path.abspath(p))
        for root in self.gen_roots:
            if rp.is_relative_to(root):
                rel = rp.relative_to(root)
                dst = self.tree / "gen" / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(rp, dst)
                return str(Path("gen") / rel)
        if rp.is_relative_to(self.zig_lib):
            return str(Path("lib") / rp.relative_to(self.zig_lib))
        if rp.is_relative_to(REPO):
            rel = rp.relative_to(REPO)
            parts = rel.parts
            self.repo_dirs.add(Path(*parts[:2]) if parts[0] in ("libs", "dynamic_loader") else Path(parts[0]))
            # keep the spelling (hal/../config/...): relative to the tree it means the same
            s = str(p)
            return s[len(str(REPO)) + 1:] if s.startswith(str(REPO) + "/") else str(rel)
        sys.exit(f"a path outside the repository, the cache and the Zig lib: {p}")

    def command(self, argv, name, out_dir, cache_dir):
        out, i = ["zig"], 1
        while i < len(argv):
            a = argv[i]
            if a in ("--cache-dir", "--global-cache-dir", "--zig-lib-dir", "--build-root"):
                i += 2
                continue
            if a.startswith("--listen") or a.startswith("-femit-bin=") or a.startswith("--verbose"):
                i += 1
                continue
            # What the C backend does not read: include paths, and the assembly and
            # archives that only the object's link would take.
            if a in ("-I", "-isystem"):
                i += 2
                continue
            if a.endswith((".a", ".S", ".s", ".c", ".o")):
                i += 1
                continue
            if a.startswith("-M") and "=" in a:
                mod, _, p = a.partition("=")
                out.append(f"{mod}={self.path(p)}")
            elif a.startswith("/"):
                out.append(self.path(a))
            else:
                out.append(a)
            i += 1
        out += ["--zig-lib-dir", "lib", "--cache-dir", cache_dir, "--global-cache-dir", f"{cache_dir}/g",
                f"-femit-bin={out_dir}/{name}.c"]
        return out

    def copy_sources(self):
        n = 0
        for d in sorted(self.repo_dirs):
            for dirpath, dirnames, filenames in os.walk(REPO / d):
                dirnames[:] = [x for x in dirnames if x not in (".zig-cache", "zig-out", ".git")]
                for f in filenames:
                    if f.endswith(".zig") or f.endswith(".zon"):
                        src = Path(dirpath) / f
                        dst = self.tree / src.relative_to(REPO)
                        dst.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(src, dst)
                        n += 1
        return n


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


WORD = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
# A top-level declaration of translate-c output starts at column 0; what follows it up to
# the next one (indented bodies, a closing brace, comptime asserts) belongs to it.
DECL = re.compile(r"(?:pub )?(?:extern |export |inline )*(?:const|var|fn) ([A-Za-z_][A-Za-z_0-9]*)"
                  r"|(?:pub )?extern \"c\" (?:const|var|fn) ([A-Za-z_][A-Za-z_0-9]*)")
# A function translate-c also offers as a method of its first parameter's type.
METHOD = re.compile(r"^\s+pub const [A-Za-z_][A-Za-z_0-9]* = __root\.([A-Za-z_][A-Za-z_0-9]*);\n", re.M)
TRANSLATED = '@import("std").zig.c_translation'


def slim_module(text, used):
    """text less the declarations nothing in `used` reaches, directly or through others."""
    decls, cur = [], None
    for line in text.splitlines(keepends=True):
        m = DECL.match(line) if line[:1] not in (" ", "\t", "}", ")", "]") else None
        if m:
            cur = [m.group(1) or m.group(2), line]
            decls.append(cur)
        elif cur is None:
            cur = [None, line]
            decls.append(cur)
        else:
            cur[1] += line
    byname = {}
    for d in decls:
        if d[0]:
            byname.setdefault(d[0], []).append(d[1])
    # A type's method aliases do not keep their functions: they go with them instead.
    keep, todo = set(), [w for w in used | {"__root"} if w in byname]
    while todo:
        n = todo.pop()
        if n not in keep:
            keep.add(n)
            for body in byname[n]:
                todo += [w for w in set(WORD.findall(METHOD.sub("", body))) if w in byname and w not in keep]
    out = "".join(d[1] for d in decls if d[0] is None or d[0] in keep)
    return METHOD.sub(lambda m: m.group(0) if m.group(1) in keep else "", out)


def slim_translated(tree):
    """Slim every translate-c module of the tree to what the rest of it uses (see the docstring)."""
    modules, used = [], set()
    for p in sorted(tree.rglob("*.zig")):
        if p.relative_to(tree).parts[0] == "lib":
            continue
        text = p.read_text(errors="replace")
        if TRANSLATED in text:
            modules.append((p, text))
        else:
            used |= set(WORD.findall(text))
    before = after = 0
    for p, text in modules:
        slim = slim_module(text, used)
        p.write_text(slim)
        r = subprocess.run([str(FORK_ZIG), "ast-check", str(p)], capture_output=True, text=True)
        if r.returncode:
            print(f"warning: {p.relative_to(tree)} slimmed fails ast-check, kept whole:\n{r.stderr[:2000]}",
                  file=sys.stderr)
            p.write_text(text)
            slim = text
        before += len(text)
        after += len(slim)
    log(f"translate-c modules: {len(modules)}, {before} -> {after} bytes")


def prepare(args):
    tree = WORK / "tree"
    shutil.rmtree(tree, ignore_errors=True)
    tree.mkdir(parents=True)
    zig_lib = host_zig_lib()
    found = capture(WORK / "zcache")
    rw = Rewriter(tree, WORK / "zcache", zig_lib)
    dev = {n: rw.command(found[n], n, "/mnt/out", "/tmp/zc") for n in NAMES}
    host_out = WORK / "host_out"
    shutil.rmtree(host_out, ignore_errors=True)
    host_out.mkdir()
    host = {n: rw.command(found[n], n, str(host_out), str(WORK / "host_zc")) for n in NAMES}
    files = rw.copy_sources()
    log(f"{files} .zig files from {', '.join(map(str, sorted(rw.repo_dirs)))}; gen/ {sum(1 for _ in (tree / 'gen').rglob('*.zig'))} files")
    if not args.no_slim:
        slim_translated(tree)
    shutil.copytree(DEVICE_LIB, tree / "lib")
    # The C backend's rendered functions wait on the card (QEMU: the FAT drive), not in memory.
    spill = 'export ZIG_C_SPILL_DIR="${ZIG_C_SPILL_DIR:-$PWD/.zspill}"; mkdir -p "$ZIG_C_SPILL_DIR"'
    lines = ["cd /mnt || exit 1", "mkdir -p /mnt/out /tmp/zc /tmp/zighome", "export HOME=/tmp/zighome", spill,
             "zig version"]
    # The InternPool's sizes from the last compile: allocated once up front, they cannot be
    # left without a long enough run of free memory on a board (no MMU); see ip_hints().
    for n in NAMES:
        lines += ["cat /proc/mempeak > /dev/null", "s=$(date +%s)",
                  f"ZIG_IP_HINTS=$PWD/ip-hints-{n} " + " ".join(shlex.quote(x) for x in dev[n]) + "; r=$?; e=$(date +%s)",
                  f'echo "@@{n} rc=$r secs=$((e-s))"; cat /proc/mempeak']
    lines.append("sha256sum " + " ".join(f"/mnt/out/{n}.c" for n in NAMES))
    (tree / "run.sh").write_text("\n".join(lines) + "\n")
    log(f"host reference with the fork compiler ({FORK_ZIG})")
    shutil.rmtree(WORK / "host_zc", ignore_errors=True)
    for n in NAMES:
        # -j1: the device compiler is single-threaded, and a multi-threaded one
        # numbers and orders its output by which thread interned what.
        r = subprocess.run([str(FORK_ZIG)] + host[n][1:] + ["-j1"], cwd=tree)
        if r.returncode:
            sys.exit(f"host fork compile of {n} failed")
        log(f"  {n}.c {(host_out / f'{n}.c').stat().st_size} bytes {sha(host_out / f'{n}.c')[:16]}")
    shutil.rmtree(tree / "out", ignore_errors=True)
    for f in (WORK / "ip_hints").glob("ip-hints-*"):
        shutil.copy(f, tree / f.name)
    size = sum(f.stat().st_size for f in tree.rglob("*") if f.is_file())
    log(f"tree {tree}: {size / 1048576:.1f} MiB")
    return 0


def qemu(args):
    tree, pulled = WORK / "tree", WORK / "device_out"
    shutil.rmtree(pulled, ignore_errors=True)
    r = subprocess.run([sys.executable, "scripts/qemu_mount.py", str(tree), "--silence", str(args.silence),
                        "-c", "sh /mnt/run.sh", "--pull", str(pulled)], cwd=REPO, capture_output=True, text=True)
    out = r.stdout + r.stderr
    for line in out.splitlines():
        t = line.strip()
        if t.startswith("@@") or t.startswith("process_peak") or t[:1].isdigit() and "." in t[:6] or \
                "error" in t or "panic" in t:
            print(line)
    ip_hints(pulled)
    ok = True
    for n in NAMES:
        dev, host = pulled / "out" / f"{n}.c", WORK / "host_out" / f"{n}.c"
        same = dev.exists() and sha(dev) == sha(host)
        ok &= same
        print(f"{n}.c: {'IDENTICAL to the host fork' if same else 'DIFFERS' if dev.exists() else 'MISSING'}")
    return 0 if ok and r.returncode == 0 else 1


def ip_hints(pulled):
    """Keeps the InternPool size hints a device run wrote (ZIG_IP_HINTS) for the next tree and the board."""
    keep = WORK / "ip_hints"
    keep.mkdir(exist_ok=True)
    for f in pulled.glob("ip-hints-*"):
        shutil.copy(f, keep / f.name)
        shutil.copy(f, WORK / "tree" / f.name)


def tcc(args):
    import json
    sys.path.insert(0, str(REPO / "scripts/kernel_tcc"))
    import tool
    dev, fixed = WORK / "device_out/out", WORK / "fixed"
    shutil.rmtree(fixed, ignore_errors=True)
    fixed.mkdir(parents=True)
    plan = json.loads((REPO / "zig-out/kernel_tcc_plan.json").read_text())
    swap = {"kernel.c": fixed / "kernel.c", "compiler_rt_tcc.c": fixed / "compiler_rt_tcc.c"}
    olds = {}
    for cmd in plan["commands"]:
        for it in cmd:
            if isinstance(it, dict) and it["kind"] == "in" and Path(it["path"]).name in swap:
                olds[Path(it["path"]).name] = Path(it["path"])
                it["path"] = str(swap[Path(it["path"]).name])
    if set(olds) != set(swap):
        sys.exit(f"the plan compiles {sorted(olds)}, not {sorted(swap)}")
    tool.fix_cbe(str(dev / "yasos_kernel.c"), str(swap["kernel.c"]))
    provided = sorted((WORK / "zcache/o").glob("*/provided.txt"), key=lambda p: p.stat().st_mtime)
    if not provided:
        sys.exit("no provided.txt in the capture's cache")
    needed = sorted((WORK / "zcache/o").glob("*/needed.txt"), key=lambda p: p.stat().st_mtime)
    if not needed:
        sys.exit("no needed.txt in the capture's cache")
    subprocess.run([sys.executable, "apps/zig/strip_naked_asm.py", str(dev / "compiler_rt.c"),
                    str(fixed / "compiler_rt_strip.c"), str(provided[-1])], cwd=REPO, check=True)
    tool.prune_crt(str(swap["compiler_rt_tcc.c"]), str(fixed / "compiler_rt_strip.c"), str(needed[-1]))
    for name, path in swap.items():
        log(f"{name}: device {sha(path)[:16]}, host stock-zig {sha(olds[name])[:16]}")
    (WORK / "plan_device.json").write_text(json.dumps(plan))
    return subprocess.run([sys.executable, "scripts/kernel_tcc/device.py", "--plan", str(WORK / "plan_device.json"),
                           "--work", str(WORK / "tcc"), "--qemu"], cwd=REPO).returncode


def full(args):
    import json
    sys.path.insert(0, str(REPO / "scripts/kernel_tcc"))
    import device
    plan = device.Plan(REPO / "zig-out/kernel_tcc_plan.json")
    cmds = plan.commands
    by_name = lambda name: [i for i, c in enumerate(cmds) for p in c["inputs"] if Path(p).name == name]
    k_i, c_i = by_name("kernel.c"), by_name("compiler_rt_tcc.c")
    if len(k_i) != 1 or len(c_i) != 1:
        sys.exit("the plan does not compile kernel.c and compiler_rt_tcc.c once each")
    kernel_c = next(p for p in cmds[k_i[0]]["inputs"] if Path(p).name == "kernel.c")
    crt_c = next(p for p in cmds[c_i[0]]["inputs"] if Path(p).name == "compiler_rt_tcc.c")
    made = {o for c in cmds for o in c["outputs"]}
    link = cmds[-1]
    archives = [p for p in link["inputs"] if p.endswith(".a") and Path(p).name != "libkcrt.a"]
    provided = str(Path(crt_c).with_name("provided.txt"))
    crt_strip, needed = str(Path(crt_c).with_name("compiler_rt_strip.c")), str(Path(crt_c).with_name("needed.txt"))
    # What compiler-rt must supply: every other input of the link (all made before it).
    link_rest = [p for p in link["inputs"] if p.endswith((".o", ".a")) and Path(p).name != "libkcrt.a"]
    extra = [provided, crt_strip, needed]

    tree = WORK / "full"
    shutil.rmtree(tree, ignore_errors=True)
    shutil.copytree(WORK / "tree", tree, ignore=shutil.ignore_patterns("run.sh", "out"))
    shipped = 0
    for c in cmds:
        for p in c["inputs"]:
            if p in made or p in (kernel_c, crt_c):
                continue
            dst = tree / plan.dev(p)
            if not dst.exists():
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, dst)
                shipped += 1
    shutil.copy2(REPO / "scripts/kernel_tcc/zigfix.c", tree / "zigfix.c")
    run = (WORK / "tree/run.sh").read_text().splitlines()
    # run.sh sets ZIG_IP_HINTS before each compile; build_all.sh sets its own.
    zig_lines = ["zig build-obj" + l.split("zig build-obj", 1)[1] for l in run if "zig build-obj" in l]
    if len(zig_lines) != len(NAMES):
        sys.exit(f"run.sh: {len(zig_lines)} zig compiles, expected {len(NAMES)}")
    q = shlex.quote
    L = ['ROOT=${ROOT:-/mnt}; ZC=${ZC:-/tmp/zc}; cd "$ROOT" || exit 1; ZIGFIX=${ZIGFIX:-out/zigfix}',
         # A tree pushed to a board leaves the lib out: the card's (scripts/zig_board.py push).
         '[ -e lib ] || ln -s "${ZIG_LIB:-/var/lib/zig}" lib',
         'mkdir -p out "$ZC" "$ZC/home"; export HOME="$ZC/home"',
         'export ZIG_C_SPILL_DIR="${ZIG_C_SPILL_DIR:-$ROOT/.zspill}"; mkdir -p "$ZIG_C_SPILL_DIR"', "zig version",
         "step() { echo \"@@$1 rc=$2 secs=$(( $(date +%s) - $3 ))\"; cat /proc/mempeak 2>/dev/null; [ $2 = 0 ] || exit 1; }"]
    for line, name in zip(zig_lines, NAMES):
        # The arguments go in a response file: the RP2350 kernel's 5 KB command line is more
        # than YasOS passes to a program (E2BIG).
        line = line.split("; r=$?")[0]
        line = line.replace("--cache-dir /tmp/zc --global-cache-dir /tmp/zc/g", "")
        line = line.replace(f"-femit-bin=/mnt/out/{name}.c", "")
        argv = shlex.split(line)
        if argv[:2] != ["zig", "build-obj"] or any("/tmp/zc" in a or "-femit-bin" in a for a in argv):
            sys.exit(f"run.sh: unexpected {name} compile line")
        (tree / f"{name}.rsp").write_text("".join(a + "\n" for a in argv[2:]))
        L += ["cat /proc/mempeak > /dev/null 2>&1; s=$(date +%s)",
              f'ZIG_IP_HINTS="$ROOT/ip-hints-{name}" zig build-obj @{name}.rsp --cache-dir "$ZC" '
              f'--global-cache-dir "$ZC/g" -femit-bin=out/{name}.c -j1; step {name} $? $s']
    dirs = sorted({os.path.dirname(plan.dev(o)) for c in cmds for o in c["outputs"]} |
                  {os.path.dirname(plan.dev(kernel_c)), os.path.dirname(plan.dev(crt_c))})
    # YasOS's execve takes at most 256 arguments: long lists go in several commands.
    chunks = lambda xs: [xs[i:i + 100] for i in range(0, len(xs), 100)]
    L += ["mkdir -p " + " ".join(q(d) for d in part) for part in chunks([d for d in dirs if d])]
    L += ["s=$(date +%s); tcc -O2 zigfix.c -o out/zigfix; step zigfix-build $? $s",
          f"s=$(date +%s); \"$ZIGFIX\" fix-cbe out/yasos_kernel.c {q(plan.dev(kernel_c))}; step fix-cbe $? $s"]
    for k, c in enumerate(cmds):
        if k == c_i[0]:
            L.append(f"s=$(date +%s); \"$ZIGFIX\" provided {q(plan.dev(provided))} " +
                     " ".join(q(plan.dev(a)) for a in archives) + "; step provided $? $s")
            L.append(f"s=$(date +%s); \"$ZIGFIX\" strip-naked out/compiler_rt.c {q(plan.dev(crt_strip))} "
                     f"{q(plan.dev(provided))}; step strip-naked $? $s")
            L.append(f"s=$(date +%s); \"$ZIGFIX\" needed {q(plan.dev(needed))} " +
                     " ".join(q(plan.dev(a)) for a in link_rest) + "; step needed $? $s")
            L.append(f"s=$(date +%s); \"$ZIGFIX\" prune-crt {q(plan.dev(crt_c))} {q(plan.dev(crt_strip))} "
                     f"{q(plan.dev(needed))}; step prune-crt $? $s")
        what = plan.dev(c["outputs"][0]) if c["outputs"] else "?"
        quiet = "" if k in (k_i[0], len(cmds) - 1) else "> /dev/null 2>&1"
        timed = k in (k_i[0], c_i[0], len(cmds) - 1)
        L.append(f"echo '[{k + 1}/{len(cmds)}] {what}'")
        if timed:
            L.append("cat /proc/mempeak > /dev/null 2>&1; s=$(date +%s)")
        L.append(" ".join(q(a) for a in c["argv"]) + f" {quiet}; " +
                 (f"step {Path(what).name} $? $s" if timed else "[ $? = 0 ] || exit 1"))
    outs = [plan.dev(o) for o in made]
    # Every output's hash, so a run nothing is pulled back from can be compared too (--board).
    # YasOS's sha256sum hashes one file and prints the hash alone: a loop names each.
    (tree / "hash_outputs.sh").write_text(
        'for f in ' + " ".join(q(o) for o in compared_outputs(outs, plan, kernel_c, crt_c, extra)) +
        '; do set -- $(sha256sum "$f"); echo "$1  $f"; done\n')
    L.append("sh hash_outputs.sh")
    L.append("echo @@FULL_DONE")
    (tree / "build_all.sh").write_text("\n".join(L) + "\n")
    log(f"tree {tree}: sources, lib, {shipped} plan inputs; build_all.sh, {len(cmds)} plan commands")

    # Host reference: the same script, zig = the fork (-j1 in the script), tcc = the cross.
    host = WORK / "full_host"
    shutil.rmtree(host, ignore_errors=True)
    shutil.copytree(tree, host)
    bin_dir = WORK / "hostbin"
    bin_dir.mkdir(exist_ok=True)
    (bin_dir / "zig").write_text(f'#!/bin/sh\nexec {FORK_ZIG} "$@"\n')
    (bin_dir / "tcc").write_text(f'#!/bin/sh\nexec {REPO}/libs/tinycc/bin/armv8m-tcc "$@"\n')
    for f in ("zig", "tcc"):
        (bin_dir / f).chmod(0o755)
    subprocess.run(["gcc", "-O2", "-o", str(bin_dir / "zigfix"), str(REPO / "scripts/kernel_tcc/zigfix.c")], check=True)
    env = dict(os.environ, ROOT=str(host), ZC=str(WORK / "full_host_zc"), PATH=f"{bin_dir}:{os.environ['PATH']}",
               ZIGFIX=str(bin_dir / "zigfix"))
    shutil.rmtree(WORK / "full_host_zc", ignore_errors=True)
    log("host reference run")
    r = subprocess.run(["sh", str(host / "build_all.sh")], env=env, capture_output=True, text=True)
    if "@@FULL_DONE" not in r.stdout:
        print(r.stdout[-3000:], r.stderr[-3000:])
        sys.exit("the host reference run failed")
    # The device starts from the host run's InternPool sizes (single-threaded, as the device's):
    # a 64-bit host keeps a few more integers in limbs, a little less in extra, well inside
    # reserveFromHints' margin.  Without sizes, a board's memory fragments as the lists grow.
    for f in host.glob("ip-hints-*"):
        shutil.copy(f, tree / f.name)
    if args.host_only:
        return 0
    if args.package:
        return package(tree, host, compared_outputs(outs, plan, kernel_c, crt_c, extra), Path(args.package))
    if args.board:
        return full_board(tree, host, compared_outputs(outs, plan, kernel_c, crt_c, extra), args)
    pulled = WORK / "full_out"
    shutil.rmtree(pulled, ignore_errors=True)
    log("QEMU: everything on the device")
    r = subprocess.run([sys.executable, "scripts/qemu_mount.py", str(tree), "--silence", str(args.silence),
                        "-c", "sh /mnt/build_all.sh", "--pull", str(pulled)], cwd=REPO, capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        t = line.strip()
        if t.startswith(("@@", "process_peak", "0.")) or "error" in t:
            print(line)
    ip_hints(pulled)
    same, differ, missing = 0, [], []
    for o in compared_outputs(outs, plan, kernel_c, crt_c, extra):
        a, b = host / o, pulled / o
        if not b.exists():
            missing.append(o)
        elif sha(a) == sha(b):
            same += 1
        else:
            differ.append(o)
    print(f"device outputs identical to the host reference: {same}, differ: {len(differ)}, missing: {len(missing)}")
    for d in differ + missing:
        print(f"  {'differs' if d in differ else 'missing'}: {d}")
    elf = pulled / plan.dev(link["outputs"][0])
    if elf.exists():
        shutil.copy2(elf, WORK / "yasos_kernel.device")
        log(f"the device-built kernel: {WORK / 'yasos_kernel.device'}")
    return 0 if not differ and not missing and r.returncode == 0 else 1


def compared_outputs(outs, plan, kernel_c, crt_c, extra):
    """The files a device run must produce byte for byte as the host reference does."""
    return sorted(set(outs) | {"out/yasos_kernel.c", "out/compiler_rt.c", plan.dev(kernel_c), plan.dev(crt_c)} |
                  {plan.dev(p) for p in extra})


def tar_tree(src, tgz, exclude=()):
    import tarfile
    names = sorted(str(p.relative_to(src)) for p in src.rglob("*")
                   if p.is_file() and p.relative_to(src).parts[0] not in exclude)
    with tarfile.open(tgz, "w:gz", compresslevel=6, format=tarfile.USTAR_FORMAT) as tar:
        for n in names:
            tar.add(src / n, arcname=n, recursive=False)
    return len(names)


def package(tree, host, compared, out):
    """What a board needs for `board-run`, without this checkout: the tree (lib left out), the zig
    lib for the card, and the host reference's hash of every output."""
    shutil.rmtree(out, ignore_errors=True)
    (out / "tree").mkdir(parents=True)
    (out / "lib").mkdir()
    n = tar_tree(tree, out / "tree/src.tar.gz", exclude=("lib",))
    m = tar_tree(DEVICE_LIB, out / "lib/src.tar.gz")
    (out / "expected.sha256").write_text("".join(f"{sha(host / o)}  {o}\n" for o in compared))
    log(f"package {out}: tree {n} files, zig lib {m} files, {len(compared)} expected outputs")
    return 0


def compare(lines, expected):
    """build_all.sh's output against `{path: sha}`: (identical, differing, missing, finished)."""
    got = {}
    for t in (l.strip() for l in lines):
        parts = t.split()
        if len(parts) == 2 and len(parts[0]) == 64 and all(c in "0123456789abcdef" for c in parts[0]):
            got[parts[1]] = parts[0]
    same = [o for o in expected if got.get(o) == expected[o]]
    differ = [o for o in expected if o in got and got[o] != expected[o]]
    missing = [o for o in expected if o not in got]
    return same, differ, missing, any("@@FULL_DONE" in l for l in lines)


def rehash_command(src, paths):
    """Hash `paths` again on the device: a byte the UART drops turns a matching line into a
    "missing" or "differing" one, so those are asked for once more before a run fails."""
    q = shlex.quote
    return (f"cd {src} && for f in " + " ".join(q(p) for p in paths) +
            '; do set -- $(sha256sum "$f"); echo "$1  $f"; done')


def recheck(result, expected, run_lines, tries=2):
    """`result` of compare() with what is not identical hashed again by `run_lines(paths)`."""
    same, differ, missing, done = result
    for _ in range(tries):
        bad = differ + missing
        if not done or not bad:
            break
        log(f"board: {len(bad)} output(s) not matched, hashing them again")
        s2, differ, missing, _ = compare(run_lines(bad), {o: expected[o] for o in bad})
        same = same + s2
    return same, differ, missing, done


def report(same, differ, missing, done):
    print(f"board outputs identical to the host reference: {len(same)}, differ: {len(differ)}, "
          f"missing: {len(missing)}{'' if done else ' (build_all.sh did not finish)'}", flush=True)
    for d in differ + missing:
        print(f"  {'differs' if d in differ else 'missing'}: {d}")
    return 0 if done and not differ and not missing else 1


def board_run(args):
    """A `package` on the board at this machine's debug probe (the CI runner): the zig lib and the
    tree over the UART, build_all.sh, every output's hash against the host reference's."""
    sys.path.insert(0, str(REPO / "scripts"))
    import time
    import yasos_device as device
    pkg = Path(args.package).resolve()
    expected = {}
    for line in (pkg / "expected.sha256").read_text().splitlines():
        h, o = line.split(None, 1)
        expected[o.strip()] = h
    s = device.uart_session(args.serial)
    lines = []
    try:
        device.run(s, f"date -s @{int(time.time())} > /dev/null", silence=30, echo=False)
        log("board: the zig lib")
        device.uart_send_manifest(s, pkg / "lib", "/var/lib/zigm", timeout=1800.0)
        if device.run(s, "ln -sfn /var/lib/zigm/tree/src /var/lib/zig", silence=60, echo=False):
            sys.exit("board: cannot point /var/lib/zig at the lib")
        log(f"board: the tree to {args.board_dir}")
        device.uart_send_manifest(s, pkg / "tree", args.board_dir, timeout=1800.0)
        src = f"{args.board_dir}/tree/src"
        log("board: build_all.sh")
        device.run(s, f"ROOT={src} ZC={args.board_cache} sh {src}/build_all.sh", silence=args.silence,
                   kernel_log=True, on_line=lines.append)

        def run_lines(paths):
            got = []
            device.run(s, rehash_command(src, paths), silence=600, echo=False, on_line=got.append)
            return got
        result = recheck(compare(lines, expected), expected, run_lines)
    finally:
        s.close()
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "board_run.log").write_text("\n".join(lines) + "\n")
    for l in lines:
        if l.strip().startswith(("@@", "process_peak", "[")) or "error" in l:
            print(l)
    return report(*result)


def full_board(tree, host, compared, args):
    """`full` on the rig's board: the tree to the card, build_all.sh there, its hashes against the host's.

    The board runs the images flashed last (scripts/zig_board.py --flash, or --flash here): a rootfs
    built with `build_rootfs.sh --zig` and the zig lib pushed with `zig_board.py push`."""
    zb = [sys.executable, str(REPO / "scripts/zig_board.py")]
    if args.flash:
        log("board: flash this checkout's images, push the zig lib")
        if subprocess.run(zb + ["--flash", "push"], cwd=REPO).returncode:
            sys.exit("board: flash/push of the zig lib failed")
    dest = args.board_dir
    log(f"board: tree to {dest}/tree/src")
    if subprocess.run(zb + ["push", "--src", str(tree), "--exclude", "lib", "--dest", dest], cwd=REPO).returncode:
        sys.exit("board: pushing the tree failed")
    src = f"{dest}/tree/src"
    if args.hash_only:
        log("board: hash the outputs already there")
        command = f"cd {src} && sh hash_outputs.sh && echo @@FULL_DONE"
    else:
        log("board: build_all.sh (both renders, zigfix, every plan command)")
        command = f"ROOT={src} ZC={args.board_cache} sh {src}/build_all.sh"
    r = subprocess.run(zb + ["run", command,
                             "--silence", str(args.silence)], cwd=REPO, capture_output=True, text=True)
    out = r.stdout + r.stderr
    (WORK / "full_board.log").write_text(out)
    for line in out.splitlines():
        t = line.strip()
        if t.startswith(("@@", "process_peak", "[")) or "error" in t:
            print(line, flush=True)
    expected = {o: sha(host / o) for o in compared}

    def run_lines(paths):
        r2 = subprocess.run(zb + ["run", rehash_command(src, paths), "--silence", "600"], cwd=REPO,
                            capture_output=True, text=True)
        return (r2.stdout + r2.stderr).splitlines()
    return report(*recheck(compare(out.splitlines(), expected), expected, run_lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["prepare", "qemu", "tcc", "full", "board-run"])
    ap.add_argument("--host-only", action="store_true", help="full: only the host reference run")
    ap.add_argument("--no-slim", action="store_true", help="prepare: keep the translate-c modules whole")
    ap.add_argument("--silence", type=int, default=3000, help="seconds the device may print nothing")
    ap.add_argument("--board", action="store_true", help="full: on the rig's board instead of QEMU")
    ap.add_argument("--package", help="full: write a package for board-run here (after the host reference); "
                    "board-run: the package to run")
    ap.add_argument("--serial", help="board-run: the probe's serial device (default: auto-detect)")
    ap.add_argument("--flash", action="store_true", help="--board: flash this checkout's images and push the zig lib")
    ap.add_argument("--hash-only", action="store_true", help="--board: only hash the outputs of the last run")
    ap.add_argument("--board-dir", default="/root/kfull", help="--board: where the tree goes on the card")
    ap.add_argument("--board-cache", default="/root/zc", help="--board: the zig cache on the card")
    args = ap.parse_args()
    if args.action == "board-run" and not args.package:
        ap.error("board-run needs --package")
    return {"prepare": prepare, "qemu": qemu, "tcc": tcc, "full": full, "board-run": board_run}[args.action](args)


if __name__ == "__main__":
    sys.exit(main())
