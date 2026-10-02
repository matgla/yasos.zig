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

"""Check that the device's tcc compiles tinycc itself: the self-host test.

    scripts/tcc_selfhost.py --qemu                      # an524 guest, sources on /mnt
    scripts/tcc_selfhost.py --uart --dest /sd/selfhost  # a board on the debug probe
    scripts/tcc_selfhost.py --prepare-only              # just build the payload
    scripts/tcc_selfhost.py --qemu --tu 'unity/ir_'    # a few TUs, no link: quick

Host side (prepare): tinycc is copied to a private tree, configured the way
build_rootfs.sh configures the native (stage 2) compiler, and built there with
the cross. That build's log gives every compile command; the payload carries
the sources those commands read (from the cross's own -MD dependency lists), a
listfile of flags per command, the host-cross objects as a reference, and two
shell scripts.

Device side (selfhost.sh):
  stage 2   the rootfs tcc compiles every TU and links a new tcc; each object is
            compared with the host cross's (differences are reported but are
            not a failure: host and device may break ties differently), and the
            new tcc must compile and run a hello world.
  stage 3   the NEW tcc compiles everything again and links itself; every object
            and the linked compiler must be byte-identical to stage 2. That
            fixpoint is the pass criterion.

The run is long: one stage is roughly 45 minutes under QEMU.
"""

import argparse
import io
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

TINYCC = REPO_ROOT / "libs" / "tinycc"
ROOTFS_INCLUDE = REPO_ROOT / "rootfs" / "usr" / "include"
HOST_LIBTCC1 = TINYCC / "lib" / "tcc" / "armv8m-libtcc1.a"
DEVICE_LIBTCC1 = "/usr/lib/armv8m-libtcc1.a"
# tcc writes an executable's own file name into it, so every compiler this
# test links is called what make calls it; only then can two of them compare.
EXE = "armv8m-tcc"

# What the private copy of tinycc leaves out: build outputs, and trees the
# native compiler build never reads.
TREE_EXCLUDES = [".git", "/tests", "/venv", "/metrics", "/docs", "/win32", "/examples",
                 "/rp2350_examples", "*.o", "*.a", "*.d", "/armv8m-*", "/bin"]

# FP defaults of build_rootfs.sh, keyed by .yasos-build/fp-mode's first half.
FP_DEFINES = {
    "soft": "-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_NONE",
    "rp2350": "-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_RP2350",
    "rp2350-dcp": "-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_RP2350",
    "fpv5-sp-d16": "-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_FPV5_SP_D16",
    "fpv5-d16": "-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_FPV5_D16",
    "fpv4-sp-d16": "-DCONFIG_TCC_DEFAULT_FPU=ARM_FPU_FPV4_SP_D16",
}


class SelfhostError(Exception):
    pass


def sh(cmd, cwd=None, log=None, env=None):
    with open(log, "w") if log else open(os.devnull, "w") as out:
        rc = subprocess.run(cmd, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, env=env,
                            shell=isinstance(cmd, str)).returncode
    if rc:
        raise SelfhostError(f"failed ({rc}): {cmd if isinstance(cmd, str) else ' '.join(cmd)}"
                            + (f"; see {log}" if log else ""))


# ---- configure and build the native compiler with the cross ----

def fp_define(tinycc: Path) -> str:
    """build_rootfs.sh's FP flags for the mode the rootfs was last built with."""
    stamp = tinycc / ".yasos-build" / "fp-mode"
    mode, linkage = (stamp.read_text().strip().split("/") + ["static"])[:2] if stamp.is_file() else ("soft", "static")
    if mode not in FP_DEFINES:
        raise SelfhostError(f"unknown FP mode '{mode}' in {stamp}")
    define = FP_DEFINES[mode]
    if linkage == "shared":
        define += " -DCONFIG_TCC_DEFAULT_FP_LIB=ARM_FP_LIB_SHARED"
    return define


def configure_and_build(tinycc: Path, tree: Path, opt: str, work: Path) -> Path:
    """The stage-2 native build of build_rootfs.sh, with the cross, in *tree*.

    Keep the configure line in step with build_rootfs.sh (build_c_compiler,
    "Second stage")."""
    tree.mkdir(parents=True, exist_ok=True)
    sh(["rsync", "-a", "--delete"] + [f"--exclude={e}" for e in TREE_EXCLUDES] + [f"{tinycc}/", f"{tree}/"])
    env = dict(os.environ, PATH=f"{tinycc / 'bin'}:{os.environ['PATH']}")
    defines = f"-DTCC_DEBUG=0 -DCONFIG_TCC_DEBUG -DCONFIG_TCC_DEBUG_ENV=0 {fp_define(tinycc)}"
    cflags = (f"-Wall -Werror {defines} {opt} -DTCC_ARM_VFP -DTCC_ARM_EABI=1 -DCONFIG_TCC_BCHECK=0 "
              "-DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M -DTARGETOS_YasOS=1 -DTCC_TARGET_ARM_THUMB "
              f"-DTCC_TARGET_ARM -DTCC_IS_NATIVE -I{ROOTFS_INCLUDE} -fpie -fPIE -mcpu=cortex-m33 "
              "-fvisibility=hidden -ffunction-sections")
    ldflags = ("-fpie -fPIE -fvisibility=hidden -Wl,--gc-sections -Wl,-Ttext=0x0 -Wl,-section-alignment=0x4 "
               "-DTCC_ARM_VFP -DTCC_TARGET_ARM -DTCC_ARM_EABI -DTCC_ARM_HARDFLOAT -DTCC_TARGET_ARM_ARCHV8M "
               "-DTCC_TARGET_ARM_THUMB")
    sh(["./configure", "--cc=tcc", "--cpu=armv8m", f"--extra-cflags={cflags}", f"--extra-ldflags={ldflags}",
        "--enable-cross", "--config-asm=yes", "--config-bcheck=no", "--config-pie=yes", "--config-pic=yes",
        "--config-ldl=no", "--config-pthread=no", "--disable-asan", "--prefix=/usr",
        "--libpaths=/usr/lib:{B}:/lib", "--crtprefix=/usr/lib", "--sysincludepaths=/usr/include:{B}/include",
        "--cross-prefix=armv8m-", "--sysroot=/"], cwd=tree, log=work / "configure.log", env=env)
    # Stale objects would make this an incremental build; start clean, as
    # build_rootfs.sh does before its native stages.
    sh("rm -rf armv8m-arch armv8m-ir armv8m-source armv8m-*.o *.o armv8m-tcc", cwd=tree)
    log = work / "build.log"
    sh(["make", "armv8m-tcc", f"-j{os.cpu_count() or 4}", "VERBOSE=1", "AR=ar",
        f"LIBS={HOST_LIBTCC1} -lpthread -ldl -lc -lm", "INC-armv8m=/usr/include:{B}/include"],
       cwd=tree, log=log, env=env)
    return log


# ---- turn the build log into a plan ----

class Unit:
    def __init__(self, source, flags, obj, cwd):
        self.source, self.flags, self.obj, self.cwd = source, flags, obj, cwd


def _to_tree(path: str, cwd: Path, tree: Path) -> str:
    full = Path(path) if os.path.isabs(path) else cwd / path
    return os.path.relpath(os.path.normpath(full), tree)


def parse_log(log: Path, tree: Path):
    compiles, archives, link = [], {}, None
    for line in log.read_text().splitlines():
        if not line.startswith("armv8m-tcc ") and not line.startswith("ar rcs "):
            continue
        argv = shlex.split(line)
        if argv[0] == "ar":
            archives[os.path.normpath(argv[2])] = argv[3:]
        elif "-c" in argv:
            compiles.append(argv)
        elif "-o" in argv and argv[argv.index("-o") + 1] == "armv8m-tcc":
            link = argv
    if not compiles or link is None:
        raise SelfhostError(f"no compiles or no final link in {log}")

    units = []
    for argv in compiles:
        source = argv[argv.index("-c") + 1]
        out = argv[argv.index("-o") + 1]
        cwd = tree
        if not os.path.isabs(source) and not (tree / source).is_file():
            # A sub-make ran it in the source's own directory.
            hits = [Path(r) for r, _, files in os.walk(tree / "source") if source in files]
            if len(hits) != 1:
                raise SelfhostError(f"cannot place {source}: {hits}")
            cwd = hits[0]
        flags, skip = [], False
        for i, arg in enumerate(argv[1:], 1):
            if skip:
                skip = False
                continue
            if arg in ("-o", "-c"):
                skip = True
                continue
            if arg.startswith("-I"):
                path = arg[2:]
                if os.path.normpath(path) == str(ROOTFS_INCLUDE):
                    flags.append("-I/usr/include")
                else:
                    flags.append("-I" + _to_tree(path, cwd, tree))
                continue
            flags.append(arg)
        leak = [f for f in flags if str(REPO_ROOT) in f]
        if leak:
            raise SelfhostError(f"host path left in the flags of {source}: {leak}")
        units.append(Unit(_to_tree(source, cwd, tree), flags,
                          os.path.normpath(out if os.path.isabs(out) else cwd / out), cwd))
    names = [os.path.basename(u.obj) for u in units]
    if len(set(names)) != len(names):
        raise SelfhostError("two objects share a name; the flat layout cannot hold them")
    return units, archives, link


def link_plan(link, tree: Path):
    """(first object, whole-archive members in order, libarm members, tail args).

    --whole-archive archives become their members listed in place; libarm.a
    stays an archive, rebuilt on the device (its members come from ar t, since
    make assembled it with an MRI script tcc -ar does not speak)."""
    def members(archive):
        out = subprocess.run(["ar", "t", str(tree / archive)], capture_output=True, text=True, check=True).stdout
        return out.split()

    args = link[link.index("-o") + 2:]
    first = os.path.basename(args[0])
    whole, arm, tail, in_whole = [], [], [], False
    for arg in args[1:]:
        if arg == "-Wl,--whole-archive":
            in_whole = True
        elif arg == "-Wl,--no-whole-archive":
            in_whole = False
        elif arg.endswith(".a") and "libtcc1" not in arg:
            if in_whole:
                whole += members(arg)
            else:
                if os.path.basename(arg) != "libarm.a":
                    raise SelfhostError(f"unexpected archive {arg} in the link")
                arm = members(arg)
        elif "libtcc1" in arg:
            tail.append("@LIBTCC1@")
        else:
            tail.append(arg)
    return first, whole, arm, tail


def dependencies(units, tree: Path, env) -> set:
    """Every file under *tree* a compile reads, from the cross's -MD output."""
    files = set()
    deps = tree / ".selfhost-deps"
    deps.mkdir(exist_ok=True)
    for n, u in enumerate(units):
        dep = deps / f"{n}.d"
        cmd = ["armv8m-tcc", "-o", str(deps / f"{n}.o"), "-c", u.source, "-MD", "-MF", str(dep)]
        cmd += [f if not f.startswith("-I") or f == "-I/usr/include" else "-I" + str(tree / f[2:]) for f in u.flags]
        cmd = [c if c != "-I/usr/include" else f"-I{ROOTFS_INCLUDE}" for c in cmd]
        sh(cmd, cwd=tree, env=env)
        text = dep.read_text().replace("\\\n", " ")
        for token in re.split(r"(?<!\\)\s+", text.split(":", 1)[1]):
            token = token.replace("\\ ", " ").strip()
            if not token:
                continue
            path = Path(token) if os.path.isabs(token) else tree / token
            path = Path(os.path.normpath(path))
            if str(path).startswith(str(tree) + "/"):
                files.add(os.path.relpath(path, tree))
    shutil.rmtree(deps)
    return files


# ---- the payload ----

def _quote(arg: str) -> str:
    """One argument as tcc's @listfile parser reads it back."""
    if re.search(r'[\s"\\]', arg):
        return '"' + arg.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return arg


def build_script(units, first, whole, arm, tail, link: bool) -> str:
    lines = [
        "# generated by scripts/tcc_selfhost.py: sh build.sh <source dir> <tcc> <output dir>",
        "S=$1; CC=$2; O=$3",
        'cd "$S" || exit 1',
        "t0=$(date +%s)",
    ]
    for n, u in enumerate(units):
        obj = os.path.basename(u.obj)
        lines.append(f'$CC @rsp/{n:03d}.rsp -o "$O/{obj}" -c {u.source}; r=$?; '
                     f'echo "SELFHOST cc {obj} rc=$r t=$(( $(date +%s) - t0 ))s"; [ $r = 0 ] || exit 1')
    if link:
        lines.append(f'rm -f "$O/libarm.a"; $CC -ar rcs "$O/libarm.a" '
                     + " ".join(f'"$O/{m}"' for m in arm) + '; r=$?; echo "SELFHOST ar libarm.a rc=$r"; '
                     "[ $r = 0 ] || exit 1")
        objs = " ".join(f'"$O/{m}"' for m in [first] + whole)
        rest = " ".join(_quote(t) if t != "@LIBTCC1@" else DEVICE_LIBTCC1 for t in tail)
        lines.append(f'$CC -o "$O/{EXE}" {objs} "$O/libarm.a" {rest}; r=$?; '
                     'echo "SELFHOST link rc=$r t=$(( $(date +%s) - t0 ))s"; [ $r = 0 ] || exit 1')
    return "\n".join(lines) + "\n"


SELFHOST_SH = r'''# generated by scripts/tcc_selfhost.py: sh selfhost.sh <payload dir> <work dir> <stages 2|3> <link 0|1>
P=$1; W=$2; STAGES=$3; LINK=$4
ulimit -s 256
fail() { echo "SELFHOST RESULT FAIL $*"; exit 1; }
rm -rf "$W"; mkdir -p "$W/src" "$W/ref" "$W/s2" "$W/s3" || fail "mkdir $W"
cd "$W/src" && tar xf "$P/src.tar" || fail "unpacking src.tar"
cd "$W/ref" && tar xf "$P/ref.tar" || fail "unpacking ref.tar"
cd /
echo "SELFHOST stage 2: $(command -v tcc || echo tcc) compiles $(wc -l < $W/src/objects.txt) TUs"
sh "$W/src/build.sh" "$W/src" tcc "$W/s2" || fail "stage 2 build"
same=0; differ=0
for o in $(cat "$W/src/objects.txt"); do
  if cmp -s "$W/s2/$o" "$W/ref/$o"; then same=$((same+1)); else differ=$((differ+1)); echo "SELFHOST host-vs-device differs $o"; fi
done
echo "SELFHOST stage 2 vs host cross: $same identical, $differ differ"
if [ "$LINK" = 0 ]; then echo "SELFHOST RESULT PASS compile-only"; exit 0; fi
if cmp -s "$W/s2/armv8m-tcc" "$W/ref/armv8m-tcc"; then echo "SELFHOST stage 2 tcc identical to the host-cross link"; else echo "SELFHOST stage 2 tcc differs from the host-cross link"; fi
echo '#include <stdio.h>' > "$W/hello.c"
echo 'int main(void) { printf("selfhost hello %d\n", 6 * 7); return 0; }' >> "$W/hello.c"
"$W/s2/armv8m-tcc" "$W/hello.c" -o "$W/hello" || fail "new tcc cannot compile hello.c"
out=$("$W/hello")
[ "$out" = "selfhost hello 42" ] || fail "hello printed '$out'"
echo "SELFHOST new tcc builds a working hello"
if [ "$STAGES" = 2 ]; then echo "SELFHOST RESULT PASS stage 2"; exit 0; fi
echo "SELFHOST stage 3: the new tcc compiles itself"
sh "$W/src/build.sh" "$W/src" "$W/s2/armv8m-tcc" "$W/s3" || fail "stage 3 build"
same=0; differ=0
for o in $(cat "$W/src/objects.txt") armv8m-tcc; do
  if cmp -s "$W/s2/$o" "$W/s3/$o"; then same=$((same+1)); else differ=$((differ+1)); echo "SELFHOST fixpoint differs $o"; fi
done
echo "SELFHOST fixpoint: $same identical, $differ differ"
# The stage-3 compiler is the current sources, as the host cross is; the rootfs
# tcc that ran stage 2 may be older. This says which the stage-2 differences were.
hsame=0; hdiffer=0
for o in $(cat "$W/src/objects.txt"); do
  if cmp -s "$W/s3/$o" "$W/ref/$o"; then hsame=$((hsame+1)); else hdiffer=$((hdiffer+1)); fi
done
echo "SELFHOST stage 3 vs host cross: $hsame identical, $hdiffer differ"
[ $differ = 0 ] || fail "stage 3 is not a fixpoint"
echo "SELFHOST RESULT PASS fixpoint"
'''


def prepare(args) -> Path:
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    tree = work / "tree"
    print(f"prepare: native tinycc from {args.tinycc} in {tree}", file=sys.stderr)
    log = configure_and_build(args.tinycc.resolve(), tree, args.opt, work)
    units, _archives, link = parse_log(log, tree)
    first, whole, arm, tail = link_plan(link, tree)
    compiled = {os.path.basename(u.obj) for u in units}
    missing = [m for m in [first] + whole + arm if m not in compiled]
    if missing:
        raise SelfhostError(f"link members nobody compiled: {missing}")

    payload = work / "payload"
    ref = work / "ref"
    shutil.rmtree(payload, ignore_errors=True)
    shutil.rmtree(ref, ignore_errors=True)
    payload.mkdir()
    ref.mkdir()
    for u in units:
        shutil.copy2(u.obj, ref / os.path.basename(u.obj))
    shutil.copy2(tree / EXE, ref / EXE)

    # Prove the device's link recipe on the host first: the same objects, the
    # same archive step and link line through the cross must give the very
    # binary make produced.
    env = dict(os.environ, PATH=f"{args.tinycc.resolve() / 'bin'}:{os.environ['PATH']}")
    check = work / "linkcheck"
    shutil.rmtree(check, ignore_errors=True)
    check.mkdir()
    sh(["armv8m-tcc", "-ar", "rcs", str(check / "libarm.a")] + [str(ref / m) for m in arm], env=env)
    sh(["armv8m-tcc", "-o", str(check / EXE)] + [str(ref / m) for m in [first] + whole]
       + [str(check / "libarm.a")] + [t if t != "@LIBTCC1@" else str(HOST_LIBTCC1) for t in tail], env=env)
    if (check / EXE).read_bytes() != (ref / EXE).read_bytes():
        raise SelfhostError(f"the device link recipe does not reproduce make's armv8m-tcc ({check})")
    shutil.rmtree(check)

    selected = units
    link = True
    if args.tu:
        selected = [u for u in units if re.search(args.tu, u.source)]
        if not selected:
            raise SelfhostError(f"--tu {args.tu!r} matches no TU")
        link = False

    files = dependencies(units, tree, env)
    with tarfile.open(payload / "src.tar", "w", format=tarfile.USTAR_FORMAT) as tar:
        def add_bytes(name, data):
            info = tarfile.TarInfo(name)
            info.size, info.mode, info.mtime = len(data), 0o644, 0
            tar.addfile(info, io.BytesIO(data))
        for name in sorted(files):
            info = tar.gettarinfo(tree / name, arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            with open(tree / name, "rb") as fh:
                tar.addfile(info, fh)
        for n, u in enumerate(units):
            add_bytes(f"rsp/{n:03d}.rsp", (" ".join(_quote(f) for f in u.flags) + "\n").encode())
        add_bytes("build.sh", build_script(selected, first, whole, arm, tail, link).encode())
        add_bytes("objects.txt", "".join(os.path.basename(u.obj) + "\n" for u in selected).encode())
    with tarfile.open(payload / "ref.tar", "w", format=tarfile.USTAR_FORMAT) as tar:
        for name in sorted(os.listdir(ref)):
            tar.add(ref / name, arcname=name)
    (payload / "selfhost.sh").write_text(SELFHOST_SH)
    (payload / "mode").write_text("link\n" if link else "compile-only\n")

    size = sum(f.stat().st_size for f in payload.iterdir())
    print(f"prepare: {len(units)} TUs ({len(selected)} to run), {len(files)} source files, "
          f"payload {size / 1048576:.1f} MiB in {payload}", file=sys.stderr)
    return payload


# ---- running it ----

def summarise(lines, log_path: Path) -> int:
    log_path.write_text("\n".join(lines) + "\n")
    result = [l for l in lines if l.startswith("SELFHOST RESULT")]
    for l in lines:
        if l.startswith(("SELFHOST stage", "SELFHOST fixpoint", "SELFHOST new tcc", "SELFHOST RESULT")):
            print(l)
    print(f"log: {log_path}")
    return 0 if result and " PASS" in result[-1] else 1


def run_on_target(args, payload: Path) -> int:
    from yasos_device import QemuMount, run, uart_send, uart_session
    stages = "2" if args.stages == 2 else "3"
    link = "1" if (payload / "mode").read_text().strip() == "link" else "0"
    lines = []
    started = time.monotonic()

    def on_line(text):
        lines.append(text)

    log_path = args.work.resolve() / f"run_{time.strftime('%Y%m%d_%H%M%S')}.log"
    if args.qemu:
        with QemuMount([(payload, "selfhost")], kernel=args.kernel) as guest:
            try:
                run(guest.session, f"sh /mnt/selfhost/selfhost.sh /mnt/selfhost {args.device_work} {stages} {link}",
                    silence=args.silence, on_line=on_line)
            finally:
                guest.stop()
    else:
        session = uart_session(args.serial)
        try:
            uart_send(session, payload, args.dest)
            work = args.device_work if args.device_work_set else f"{args.dest.rstrip('/')}/work"
            run(session, f"sh {args.dest}/selfhost.sh {args.dest} {work} {stages} {link}",
                silence=args.silence, on_line=on_line)
        finally:
            session.close()
    print(f"target time: {time.monotonic() - started:.0f} s", file=sys.stderr)
    return summarise(lines, log_path)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Self-compile tinycc on a YasOS target.")
    where = parser.add_mutually_exclusive_group()
    where.add_argument("--qemu", action="store_true", help="run on an mps3-an524 guest, payload on /mnt")
    where.add_argument("--uart", action="store_true", help="send the payload over the debug-probe UART")
    where.add_argument("--prepare-only", action="store_true", help="build the payload and stop")
    parser.add_argument("--dest", default="/root/selfhost", help="--uart: absolute directory on the board")
    parser.add_argument("--serial", help="--uart: serial device (default: auto-detect the probe)")
    parser.add_argument("--device-work", help="directory the target builds in "
                        "(default: /tmp/tcc_selfhost under QEMU, <dest>/work over UART)")
    parser.add_argument("--kernel", type=Path, help="--qemu: an mps3-an524 kernel (default: zig-out/bin/yasos_kernel)")
    parser.add_argument("--tinycc", type=Path, default=TINYCC, help="tinycc source tree (default: %(default)s)")
    parser.add_argument("--work", type=Path, default=REPO_ROOT / ".cache" / "tcc_selfhost",
                        help="host work directory (default: %(default)s)")
    parser.add_argument("--opt", default=os.environ.get("NATIVE_TCC_OPT_OVERRIDE", "-O2"),
                        help="optimisation of the compiler being built (default: build_rootfs.sh's, %(default)s)")
    parser.add_argument("--stages", type=int, choices=(2, 3), default=3,
                        help="2: device builds tcc; 3: and that tcc rebuilds itself to a fixpoint (default)")
    parser.add_argument("--tu", metavar="REGEX", help="only the TUs whose source matches; compiles only, no link")
    parser.add_argument("--silence", type=float, default=3600.0, metavar="SEC",
                        help="give up after this long without output (default: %(default)s)")
    args = parser.parse_args(argv)
    args.device_work_set = args.device_work is not None
    if args.device_work is None:
        args.device_work = "/tmp/tcc_selfhost"
    if not (args.qemu or args.uart or args.prepare_only):
        parser.error("choose --qemu, --uart or --prepare-only")

    try:
        payload = prepare(args)
        if args.prepare_only:
            return 0
        return run_on_target(args, payload)
    except SelfhostError as error:
        print(f"tcc_selfhost: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
