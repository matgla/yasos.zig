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

"""The device zig on the rig's board (build_rootfs.sh --zig keeps it in an rp2350 image).

    scripts/zig_board.py --flash run 'ls -l /usr/bin/zig'  # this checkout's images first
    scripts/zig_board.py push                        # the zig lib onto the card
    scripts/zig_board.py push --src .cache/zig_device/tree --exclude lib --dest /root/ktree
                                                     # any tree: lands in DEST/tree/src
    scripts/zig_board.py run 'cd /root/w && zig build-obj -ofmt=c ... && tcc ...'
    scripts/zig_board.py pull '/root/kfull/tree/src/out/a.o /root/x.c' --out DIR   # files back (sz)

push sends sdcard/var/lib/zig (build_zig.sh's staging tree) to /var/lib/zigm/tree/src
as a manifest delta (only what changed; 822 files, 4 MiB compressed, ~2.5 min the first
time) and points /var/lib/zig, where the compiler looks, at it.  Everything on the rig
runs under the board lock, through scripts/rig/tinycc_board.sh's flash-and-run wrapper:
images are checked by sha256 before and after the flash.  Reads the rig from
.cache/remote_smoke_runner.json (remote_smoke_tui.py --reconfigure).
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import tarfile
import time
import hashlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), os.getcwd()]
REPO = HERE.parent
LIBDEST = "/var/lib/zigm"
D = "zig_board/yasos.zig"


def serve(a):
    import yasos_device as device
    s = device.uart_session(None)
    try:
        device.run(s, f"date -s @{int(time.time())} > /dev/null", silence=30, echo=False)
        if a.action == "push":
            device.uart_send_manifest(s, Path(a.payload), a.dest, full=a.full, timeout=1800.0)
            if a.dest != LIBDEST:
                return 0
            return device.run(s, f"ln -sfn {LIBDEST}/tree/src /var/lib/zig", silence=60, echo=False)
        if a.action == "pull":
            from tests.smoke.framework import file_transfer
            out = Path(a.payload)
            out.mkdir(parents=True, exist_ok=True)
            got = file_transfer.receive_files(s, f"sz {a.command}", lambda name: out / Path(name).name,
                                              timeout=600.0)
            print(f"pulled {len(got)} file(s)")
            return 0 if got else 1
        return device.run(s, a.command, silence=a.silence, kernel_log=True)
    finally:
        s.close()


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["push", "run", "pull"])
    ap.add_argument("command", nargs="?")
    ap.add_argument("--flash", action="store_true")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--payload")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--src", help="push this tree instead of the zig lib (sdcard/var/lib/zig)")
    ap.add_argument("--dest", default=LIBDEST, help="board directory; the files land in DEST/tree/src")
    ap.add_argument("--exclude", action="append", default=[], help="top-level entry of --src to leave out")
    ap.add_argument("--silence", type=float, default=3600)
    ap.add_argument("--out", help="pull: host directory the files land in")
    a = ap.parse_args()
    if a.serve:
        return serve(a)

    cfg = json.loads((REPO / ".cache/remote_smoke_runner.json").read_text())
    target, port = cfg["ssh_target"], str(cfg.get("ssh_port", 22))
    remote = cfg.get("remote_repo_path", "~/yasos_remote_smoke")

    def ssh(c):
        return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-p", port, target, c],
                              stdin=subprocess.DEVNULL, text=True).returncode

    def scp(srcs, dst):
        subprocess.run(["scp", "-q", "-P", port, *map(str, srcs), f"{target}:{dst}"], check=True)

    ssh(f"mkdir -p {D}/py {D}/rig {D}/img {D}/payload")
    scp([Path(__file__), REPO / "scripts/yasos_device.py"], f"{D}/py/")
    wrap = (REPO / "scripts/rig/tinycc_board.sh").read_text().replace('"$D/py/tinycc_board.py"', '"$D/py/zig_board.py"')
    w = REPO / ".cache/zig_board/zig_board.sh"
    w.parent.mkdir(parents=True, exist_ok=True)
    w.write_text(wrap)
    scp([REPO / "scripts/rig/reflash.sh", REPO / "scripts/rig/boot_check.py", w], f"{D}/rig/")
    flash = ["NOFLASH", "-", "-"]
    if a.flash:
        rootfs, kernel = REPO / "rootfs.img", REPO / "zig-out/bin/yasos_kernel"
        print(">> sending images", flush=True)
        scp([rootfs, kernel], f"{D}/img/")
        flash = ["FLASH", sha(rootfs), sha(kernel)]
    extra = []
    if a.action == "push":
        lib = Path(a.src).resolve() if a.src else REPO / "sdcard/var/lib/zig"
        payload = REPO / ".cache/zig_board/payload"
        payload.mkdir(parents=True, exist_ok=True)
        tgz = payload / "src.tar.gz"
        names = sorted(str(p.relative_to(lib)) for p in lib.rglob("*")
                       if p.is_file() and p.relative_to(lib).parts[0] not in a.exclude)
        with tarfile.open(tgz, "w:gz", compresslevel=6, format=tarfile.USTAR_FORMAT) as tar:
            for n in names:
                tar.add(lib / n, arcname=n, recursive=False)
        print(f">> {lib.name}: {len(names)} files, {tgz.stat().st_size / 1048576:.1f} MiB compressed", flush=True)
        ssh(f"rm -f {D}/payload/*")
        scp([tgz], f"{D}/payload/")
        extra = ["--payload", f"$HOME/{D}/payload", "--dest", a.dest] + (["--full"] if a.full else [])
    elif a.action == "pull":
        if not a.command or not a.out:
            ap.error("pull needs the board paths and --out")
        ssh(f"rm -rf {D}/pulled")
        extra = [a.command, "--payload", f"$HOME/{D}/pulled"]
    else:
        extra = [a.command, "--silence", str(a.silence)]
    words = ["bash", f"$HOME/{D}/rig/zig_board.sh", f"$HOME/{D}", "3000", *flash, "--serve", a.action, *extra]
    quoted = " ".join(x if x.startswith("$HOME") else shlex.quote(x) for x in words)
    rc = ssh(f"YASOS_RIG_REMOTE={remote} {quoted}")
    if a.action == "pull" and rc == 0:
        Path(a.out).mkdir(parents=True, exist_ok=True)
        subprocess.run(["scp", "-q", "-P", port, f"{target}:{D}/pulled/*", str(a.out)], check=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
