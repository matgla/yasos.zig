#!/usr/bin/env python3
"""Rebuild the tcc kernel on YasOS itself, from the host build's plan.

    zig build kernel-tcc-plan                  # host: build, write the plan
    scripts/kernel_tcc/device.py --qemu        # replay it in QEMU (an524)
    scripts/kernel_tcc/device.py --list        # just show the boots

The plan (zig-out/kernel_tcc_plan.json, from build/kernel_tcc.zig) is every
tcc command of the host build: compiles, archives and the link.  The device
runs the same commands with its own tcc.  What the host does with Python --
Zig's C backend output fixed up, compiler-rt's duplicates renamed -- stays on
the host: those generated C files are shipped like any other source.

Each command needs its inputs and headers (from the host compile's depfile)
at the same paths relative to the repository; absolute paths outside it (the
Zig lib directory) go under ext/N/.  The fatdisk window holds 16 MB, which
the 12 MB kernel.c and the 4 MB romfs image do not fit into together, so the
commands are packed in order into boots that each fit, and what one boot
makes is pulled home and shipped to the boots that need it.

Every output is compared with the host's; the device's kernel ELF ends up in
WORK/yasos_kernel.
"""

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import tool  # noqa: E402

# The window is 16 MiB; leave room for the FAT itself and directory entries.
DEFAULT_LIMIT = 15 * 1024 * 1024


def parse_depfile(path):
    """Prerequisites of a make-style depfile, as written."""
    text = Path(path).read_text().replace("\\\n", " ")
    _, _, deps = text.partition(": ")
    out, cur, i = [], "", 0
    while i < len(deps):
        ch = deps[i]
        if ch == "\\" and i + 1 < len(deps):
            cur += deps[i + 1]
            i += 2
            continue
        if ch.isspace():
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += ch
        i += 1
    if cur:
        out.append(cur)
    return out


class Plan:
    def __init__(self, path):
        data = json.loads(Path(path).read_text())
        self.root = Path(data["root"])
        # Directories outside the repository handed to tcc (-I <zig lib>).
        ext = []
        for cmd in data["commands"]:
            for it in cmd:
                if isinstance(it, dict) and it["kind"] == "dir" and not self._inside(it["path"]):
                    if it["path"] not in ext:
                        ext.append(it["path"])
        self.ext = ext
        self.commands = [self._command(cmd) for cmd in data["commands"]]

    def _inside(self, p):
        return os.path.normpath(p).startswith(str(self.root) + os.sep)

    def dev(self, p):
        """Device path, relative to the build directory, of host path p."""
        p = os.path.normpath(os.path.join(self.root, p))
        if self._inside(p):
            return os.path.relpath(p, self.root)
        for i, e in enumerate(self.ext):
            if p == e or p.startswith(e + os.sep):
                return os.path.join(f"ext/{i}", os.path.relpath(p, e))
        raise SystemExit(f"device.py: {p} is outside the repository and every -I directory")

    def _command(self, items):
        argv, inputs, outputs, deps = ["tcc"], [], [], []
        for it in items:
            if isinstance(it, str):
                argv.append(it)
                continue
            kind, prefix, path = it["kind"], it["prefix"], it["path"]
            if kind == "dep":
                deps.append(path)
                continue
            argv.append(prefix + self.dev(path))
            if kind == "in":
                inputs.append(path)
            elif kind == "out":
                outputs.append(path)
        for d in deps:
            for p in parse_depfile(d):
                p = os.path.normpath(os.path.join(self.root, p))
                if p not in inputs:
                    inputs.append(p)
        return {"argv": argv, "inputs": inputs, "outputs": outputs}


def size(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


def pack(plan, limit):
    """Commands in order into boots of at most `limit` bytes shipped + made."""
    made_by = {}
    for i, c in enumerate(plan.commands):
        for o in c["outputs"]:
            made_by[o] = i
    boots, cur = [], None
    for i, c in enumerate(plan.commands):
        while True:
            if cur is None:
                cur = {"commands": [], "ship": {}, "made": {}}
            ship = {p: size(p) for p in c["inputs"] if p not in cur["made"] and p not in cur["ship"]}
            made = {o: size(o) for o in c["outputs"]}
            total = sum(cur["ship"].values()) + sum(cur["made"].values()) + sum(ship.values()) + sum(made.values())
            if total > limit and cur["commands"]:
                boots.append(cur)
                cur = None
                continue
            if total > limit:
                raise SystemExit(f"device.py: command {i} alone needs {total} bytes, over the {limit} limit")
            cur["commands"].append(i)
            cur["ship"].update(ship)
            cur["made"].update(made)
            break
    if cur and cur["commands"]:
        boots.append(cur)
    for b in boots:
        b["from_boot"] = {p for p in b["ship"] if p in made_by}
    return boots


def script(plan, boot):
    lines = ["cd /mnt || exit 1"]
    dirs = sorted({os.path.dirname(plan.dev(o)) for i in boot["commands"] for o in plan.commands[i]["outputs"]})
    if dirs:
        lines.append("mkdir -p " + " ".join(shlex.quote(d) for d in dirs if d))
    n = len(boot["commands"])
    for k, i in enumerate(boot["commands"]):
        c = plan.commands[i]
        what = plan.dev(c["outputs"][0]) if c["outputs"] else "?"
        lines.append(f"echo '[{k + 1}/{n}] {what}'")
        lines.append(" ".join(shlex.quote(a) for a in c["argv"]) + " || exit 1")
    lines.append("echo kernel-tcc-device: boot done")
    return "\n".join(lines) + "\n"


def stage(plan, boot, src_dir, pulled):
    if src_dir.exists():
        shutil.rmtree(src_dir)
    src_dir.mkdir(parents=True)
    for p in boot["ship"]:
        dst = src_dir / plan.dev(p)
        dst.parent.mkdir(parents=True, exist_ok=True)
        if p in boot["from_boot"]:
            shutil.copy2(pulled[p], dst)
        else:
            shutil.copy2(p, dst)
    (src_dir / "build.sh").write_text(script(plan, boot))


def same_archive(a, b):
    ma, mb = list(tool.archive_members(a)), list(tool.archive_members(b))
    return ma == mb


def compare(plan, pulled):
    same, differ = [], []
    for c in plan.commands:
        for o in c["outputs"]:
            dev = Path(pulled[o]).read_bytes()
            host = Path(o).read_bytes()
            ok = dev == host or (o.endswith(".a") and same_archive(pulled[o], o))
            (same if ok else differ).append(plan.dev(o))
    return same, differ


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--plan", type=Path, default=REPO / "zig-out/kernel_tcc_plan.json")
    ap.add_argument("--work", type=Path, default=REPO / ".cache/kernel_tcc_device")
    ap.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="bytes per boot, shipped + made")
    ap.add_argument("--kernel", type=Path, help="an524 kernel to run the build on (default: zig-out/bin/yasos_kernel)")
    ap.add_argument("--list", action="store_true", help="show the boots and stop")
    ap.add_argument("--qemu", action="store_true", help="run the boots in QEMU")
    ap.add_argument("--silence", type=float, default=3600.0, help="seconds a command may print nothing")
    args = ap.parse_args()

    plan = Plan(args.plan)
    boots = pack(plan, args.limit)
    for n, b in enumerate(boots):
        mb = (sum(b["ship"].values()) + sum(b["made"].values())) / 2**20
        outs = [plan.dev(o) for i in b["commands"] for o in plan.commands[i]["outputs"]]
        print(f"boot {n}: {len(b['commands'])} commands, {len(b['ship'])} files in "
              f"({len(b['from_boot'])} from earlier boots), {mb:.1f} MiB; makes {', '.join(outs[:3])}"
              + (f" ... ({len(outs)})" if len(outs) > 3 else ""))
    if args.list or not args.qemu:
        return 0

    kernel = args.kernel or REPO / "zig-out/bin/yasos_kernel"
    args.work.mkdir(parents=True, exist_ok=True)
    shutil.copy2(kernel, args.work / "runner_kernel")
    pulled = {}
    for n, b in enumerate(boots):
        src, out = args.work / f"boot{n}", args.work / f"boot{n}.out"
        stage(plan, b, src, pulled)
        if out.exists():
            shutil.rmtree(out)
        print(f"--- boot {n}", flush=True)
        rc = subprocess.call([sys.executable, str(REPO / "scripts/qemu_mount.py"), str(src),
                              "--kernel", str(args.work / "runner_kernel"), "--silence", str(args.silence),
                              "-c", "time sh /mnt/build.sh", "--pull", str(out)])
        if rc:
            print(f"device.py: boot {n} failed ({rc}); its /mnt is in {out}", file=sys.stderr)
            return 1
        for i in b["commands"]:
            for o in plan.commands[i]["outputs"]:
                pulled[o] = str(out / plan.dev(o))
                if not os.path.exists(pulled[o]):
                    print(f"device.py: boot {n} did not make {plan.dev(o)}", file=sys.stderr)
                    return 1

    same, differ = compare(plan, pulled)
    print(f"outputs identical to the host build: {len(same)}/{len(same) + len(differ)}")
    for d in differ:
        print(f"  differs: {d}")
    elf = [o for o in plan.commands[-1]["outputs"]][0]
    shutil.copy2(pulled[elf], args.work / "yasos_kernel")
    print(f"device-built kernel: {args.work / 'yasos_kernel'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
