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

"""Work on tinycc on the board: keep the sources there, build them there.

    scripts/tinycc_board.py push                    # the whole repository to the board
    scripts/tinycc_board.py make                    # ./configure && make there
    scripts/tinycc_board.py make --configure='--enable-O0 --disable-optimizer'
    scripts/tinycc_board.py run 'cd tests && ls'    # any command, in the source directory
    scripts/tinycc_board.py pull                    # what changed on the board comes back

The sources land in DEST/tree/src (default /root/tinycc/tree/src, on the card). A push
sends only what changed since the last one, as one compressed archive, and a changed file
gets the time of its arrival, so make rebuilds what it should. It refuses to overwrite a
file edited on the board: pull first, or --force. New files in the checkout go too, as
long as git does not ignore them. Pull does the same three-way merge as target_sync.py: a
file changed on both sides comes back beside yours as <file>.target.

By default the board is the rig's (.cache/remote_smoke_runner.json), taken under its lock
so that sessions queue, and left running whatever firmware it has; --flash installs this
checkout's rootfs.img and kernel first. --serial DEV uses a probe on this PC. --qemu boots
this checkout's an524 kernel instead: nothing survives the boot, so `all` (a push and a
make in one boot) is the command that makes sense there.
"""

import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
# On the rig this file sits beside yasos_device.py, and the checkout there (the
# working directory) has tests/smoke/framework.
sys.path[:0] = [str(HERE), str(HERE.parent), os.getcwd()]

import yasos_device as device  # noqa: E402

REPO = HERE.parent
TINYCC = REPO / "libs/tinycc"
WORK = REPO / ".cache/tinycc_board"
RUNNER_CONFIG = ".cache/remote_smoke_runner.json"
# What a build on the board never reads, for --sources-only: 37 of the 52 MB is tests/.
NOT_SOURCES = ("tests/", "docs/", "win32/", "metrics/", "examples/", "rp2350_examples/", ".github/", ".vscode/")
FIND_CHANGED = "find . -type f -newer ../.complete"


def log(message):
    print(f">> {message}", flush=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ---- on this PC: what to send ----

def checkout_files(sources_only: bool) -> list:
    """Tracked files as they are now, and new ones git does not ignore."""
    out = subprocess.run(["git", "-C", str(TINYCC), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, text=True, check=True).stdout
    names = sorted({n for n in out.split("\0") if n and (TINYCC / n).is_file()})
    if sources_only:
        names = [n for n in names if not n.startswith(NOT_SOURCES)]
    return names


def make_payload(work: Path, sources_only: bool) -> Path:
    payload = work / "payload"
    shutil.rmtree(payload, ignore_errors=True)
    payload.mkdir(parents=True)
    names = checkout_files(sources_only)
    with tarfile.open(payload / "src.tar.gz", "w:gz", compresslevel=1, format=tarfile.USTAR_FORMAT) as tar:
        for name in names:
            tar.add(TINYCC / name, arcname=name, recursive=False)
    size = (payload / "src.tar.gz").stat().st_size
    log(f"{len(names)} files, {size / 1048576:.1f} MiB compressed")
    return payload


def not_ignored(paths: list) -> list:
    """The paths git would track: a build on the board leaves objects behind."""
    if not paths:
        return []
    ignored = subprocess.run(["git", "-C", str(TINYCC), "check-ignore", "--no-index", "--stdin", "-z"],
                             input="\0".join(paths), capture_output=True, text=True).stdout
    skip = set(ignored.split("\0"))
    return [p for p in paths if p not in skip]


# ---- on the machine with the UART: the board's side ----

def set_clock(session):
    # A board that was flashed has lost the time, and make needs it to be right.
    device.run(session, f"date -s @{int(time.time())} > /dev/null", silence=30, echo=False)


def board_lines(session, command: str, silence: float = 600.0) -> list:
    lines = []

    def line(text):
        lines.append(text.strip())

    rc = device.run(session, command, silence=silence, echo=False, on_line=line)
    if rc != 0:
        raise device.DeviceError(f"'{command}' failed: {rc}")
    return lines


def board_changed(session, dest: str) -> list:
    """Paths under the source directory touched since the last push finished."""
    if device.run(session, f"test -f {dest}/tree/.complete", silence=60, echo=False) != 0:
        return []
    found = board_lines(session, f"cd {dest}/tree/src && {FIND_CHANGED}; r=$?; cd /; (exit $r)")
    return sorted(p[2:] for p in found if p.startswith("./"))


def refuse_board_edits(session, payload: Path, dest: str):
    """Stop a push that would overwrite a file edited on the board."""
    entries = device._archive_entries(payload)
    manifest = {}
    if device.run(session, f"test -f {dest}/MANIFEST", silence=60, echo=False) == 0:
        for text in board_lines(session, f"cat {dest}/MANIFEST"):
            digest, sep, name = text.partition("  ")
            if sep:
                manifest[name] = digest
    conflicts = []
    for path in board_changed(session, dest):
        name = "src/" + path
        if name not in manifest or (name in entries and entries[name][2] == manifest[name]):
            continue  # not ours, or the push leaves it alone
        lines = board_lines(session, f"sha256sum {shlex.quote(f'{dest}/tree/{name}')}")
        digest = lines[-1].split()[0] if lines else ""
        if digest != manifest[name] and digest != entries.get(name, (0, 0, 0))[2]:
            conflicts.append(path)
    if conflicts:
        for path in conflicts:
            print(f"  edited on the board: {path}")
        raise device.DeviceError(f"{len(conflicts)} file(s) edited on the board would be overwritten: pull, or --force")


def board_push(session, payload: Path, dest: str, full: bool, force: bool):
    if not (full or force):
        refuse_board_edits(session, payload, dest)
    device.uart_send_manifest(session, payload, dest, full=full, timeout=120.0)


def board_make(session, dest: str, configure: str) -> int:
    source = f"{dest}/tree/src"
    return device.run(session, f"cd {source} && ./configure {configure} && make; r=$?; cd /; (exit $r)", silence=3600, kernel_log=True)


def board_fetch(session, dest: str, paths: list, out: Path):
    from tests.smoke.framework import file_transfer
    root = f"{dest}/tree/src/"
    listing = out / ".list"
    listing.write_text("".join(root + p + "\n" for p in paths))
    file_transfer.send_files(session, [(listing, "/tmp/.yasos_sz.list")])
    wanted = set(paths)
    got = file_transfer.receive_files(session, f"sz --strip {shlex.quote(root)} --list /tmp/.yasos_sz.list",
                                      lambda name: out / name if name in wanted else None)
    missing = wanted - {name for name, _, _ in got}
    if missing:
        raise device.DeviceError(f"the board did not send {sorted(missing)[:5]}")


def serve(args):
    """The internal command: everything that needs the UART, on whoever has it."""
    session = device.uart_session(args.serial)
    try:
        set_clock(session)
        return do_board(session, args)
    finally:
        session.close()


def do_board(session, args) -> int:
    dest = args.dest.rstrip("/")
    if args.action == "push":
        board_push(session, Path(args.payload), dest, args.full, args.force)
    elif args.action == "make":
        return board_make(session, dest, args.configure)
    elif args.action == "run":
        return device.run(session, f"cd {dest}/tree/src && {args.command}; r=$?; cd /; (exit $r)", silence=3600, kernel_log=True)
    elif args.action == "changed":
        print("CHANGED " + json.dumps(board_changed(session, dest)), flush=True)
    elif args.action == "fetch":
        board_fetch(session, dest, json.loads(Path(args.paths).read_text()), Path(args.out))
    return 0


# ---- getting to the board ----

class Local:
    """This process has the UART."""

    def __init__(self, args):
        self.args = args

    def call(self, action, **extra):
        return serve(argparse.Namespace(**{**vars(self.args), "action": action, **extra}))

    def changed(self):
        session = device.uart_session(self.args.serial)
        try:
            return board_changed(session, self.args.dest.rstrip("/"))
        finally:
            session.close()

    def fetch(self, paths, out):
        path = out / ".paths"
        path.write_text(json.dumps(paths))
        return self.call("fetch", paths=str(path), out=str(out))


class Rig:
    """The board hangs off the rig: run this script there, holding its lock."""

    def __init__(self, args):
        self.args = args
        path = next((r / RUNNER_CONFIG for r in (REPO, Path.home() / "repos/yasos.zig") if (r / RUNNER_CONFIG).exists()), None)
        if path is None:
            sys.exit(f"no {RUNNER_CONFIG} (scripts/remote_smoke_tui.py --reconfigure), or use --serial / --qemu")
        config = json.loads(path.read_text())
        self.target = config["ssh_target"]
        self.port = str(config.get("ssh_port", 22))
        self.remote = config.get("remote_repo_path", "~/yasos_remote_smoke")
        self.dir = f"tinycc_board/{args.label}"
        self.flashed = False

    def ssh(self, command, capture=False):
        return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
                               "-p", self.port, self.target, command],
                              stdin=subprocess.DEVNULL, capture_output=capture, text=True)

    def copy(self, sources, dest):
        subprocess.run(["scp", "-q", "-P", self.port, *map(str, sources), f"{self.target}:{dest}"], check=True)

    def prepare(self):
        d = self.dir
        if self.ssh(f"mkdir -p {d}/py {d}/rig {d}/img {d}/payload").returncode:
            sys.exit(f"cannot reach the rig {self.target}")
        self.copy([HERE / "tinycc_board.py", HERE / "yasos_device.py"], f"{d}/py/")
        self.copy([HERE / "rig/reflash.sh", HERE / "rig/boot_check.py", HERE / "rig/tinycc_board.sh"], f"{d}/rig/")

    def flash_args(self):
        if self.args.flash and not self.flashed:
            self.flashed = True
            rootfs, kernel = REPO / "rootfs.img", REPO / "zig-out/bin/yasos_kernel"
            log("sending the images")
            self.copy([rootfs, kernel], f"{self.dir}/img/")
            return ["FLASH", sha256(rootfs), sha256(kernel)]
        return ["NOFLASH", "-", "-"]

    def remote_call(self, action, capture=False, **extra):
        words = ["bash", f"$HOME/{self.dir}/rig/tinycc_board.sh", f"$HOME/{self.dir}", str(self.args.lock_wait),
                 *self.flash_args(), "--serve", action, "--dest", self.args.dest]
        for key, value in extra.items():
            if value is True:
                words.append(f"--{key}")
            elif value not in (False, None, ""):
                words.append(f"--{key}={value}")
        quoted = " ".join(w if w.startswith("$HOME") else shlex.quote(w) for w in words)
        return self.ssh(f"YASOS_RIG_REMOTE={self.remote} {quoted}", capture=capture)

    def call(self, action, **extra):
        return self.remote_call(action, **extra).returncode

    def send_payload(self, payload):
        d = self.dir
        self.ssh(f"rm -f {d}/payload/*")
        self.copy(sorted(payload.iterdir()), f"{d}/payload/")
        return f"$HOME/{d}/payload"

    def changed(self):
        result = self.remote_call("changed", capture=True)
        for text in result.stdout.splitlines():
            if text.startswith("CHANGED "):
                return json.loads(text[8:])
        sys.exit(f"the board did not answer: {result.stdout[-400:]}{result.stderr[-400:]}")

    def fetch(self, paths, out):
        d = f"{self.dir}/fetched"
        self.ssh(f"rm -rf {d}; mkdir -p {d}")
        (out / ".paths").write_text(json.dumps(paths))
        self.copy([out / ".paths"], f"{d}/.paths")
        rc = self.call("fetch", paths=f"$HOME/{d}/.paths", out=f"$HOME/{d}/files")
        if rc == 0:
            rc = subprocess.run(["scp", "-q", "-r", "-P", self.port, f"{self.target}:{d}/files/.", str(out)]).returncode
        return rc


# ---- pull ----

def state_path(label: str) -> Path:
    path = WORK / label / "pushed.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def pushed_state(label: str) -> dict:
    path = state_path(label)
    return json.loads(path.read_text()) if path.is_file() else {}


def remember_push(label: str, payload: Path):
    entries = device._archive_entries(payload)
    state_path(label).write_text(json.dumps({p[4:]: e[2] for p, e in entries.items()}, sort_keys=True))


def pull(board, args) -> int:
    base = pushed_state(args.label)
    if not base:
        sys.exit("nothing to compare with: this checkout has not pushed yet")
    changed = not_ignored(board.changed())
    if not changed:
        log("nothing changed on the board")
        return 0
    log(f"{len(changed)} file(s) changed on the board")
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        if board.fetch(changed, out):
            sys.exit("fetching from the board failed")
        target = dict(base)
        for path in changed:
            target[path] = sha256(out / path)
        report = device.merge_into_host(base, target, TINYCC, lambda paths: out)
    state_path(args.label).write_text(json.dumps(target, sort_keys=True))
    device.print_merge_report(report, TINYCC)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("action", nargs="?", choices=("push", "make", "all", "run", "pull"))
    parser.add_argument("command", nargs="?", help="for run: the command, in the source directory")
    parser.add_argument("--dest", help="directory on the board (default: /root/tinycc, on the card; "
                                       "--qemu: /tmp/tinycc, as its RAM /root holds only about 14 MB)")
    parser.add_argument("--configure", default="", help="options for ./configure")
    parser.add_argument("--sources-only", action="store_true", help="leave out tests/, docs/ and the like (13 of 52 MB)")
    parser.add_argument("--full", action="store_true", help="send everything, whatever the board says it has")
    parser.add_argument("--force", action="store_true", help="overwrite files edited on the board")
    parser.add_argument("--flash", action="store_true", help="rig: flash this checkout's images first")
    parser.add_argument("--label", default=REPO.name, help="rig and cache directory for this checkout (default: %(default)s)")
    parser.add_argument("--lock-wait", type=int, default=3000, help="rig: seconds to wait for the board (default: %(default)s)")
    parser.add_argument("--serial", help="a probe on this PC instead of the rig")
    parser.add_argument("--qemu", action="store_true", help="an an524 kernel in QEMU instead of a board")
    parser.add_argument("--kernel", type=Path, help="--qemu: the kernel (default: zig-out/bin/yasos_kernel)")
    parser.add_argument("--serve", metavar="ACTION", help=argparse.SUPPRESS)
    parser.add_argument("--payload", help=argparse.SUPPRESS)
    parser.add_argument("--paths", help=argparse.SUPPRESS)
    parser.add_argument("--run", help=argparse.SUPPRESS)
    parser.add_argument("--out", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    if args.serve:
        args.dest = args.dest or "/root/tinycc"
        args.action = args.serve
        args.command = args.run
        for name in ("paths", "out", "payload"):
            value = getattr(args, name)
            if value:
                setattr(args, name, os.path.expandvars(value))
        Path(args.out).mkdir(parents=True, exist_ok=True) if args.out else None
        return serve(args)
    if not args.action:
        parser.error("what to do: push, make, all, run or pull")
    args.dest = args.dest or ("/tmp/tinycc" if args.qemu else "/root/tinycc")
    if not args.dest.startswith("/"):
        parser.error("--dest must be absolute")
    if args.action == "run" and not args.command:
        parser.error("run needs a command")
    if args.qemu:
        return qemu(args)

    work = WORK / args.label
    if args.serial:
        board = Local(args)
    else:
        board = Rig(args)
        board.prepare()

    if args.action in ("push", "all"):
        payload = make_payload(work, args.sources_only)
        if isinstance(board, Rig):
            rc = board.call("push", payload=board.send_payload(payload), full=args.full, force=args.force)
        else:
            rc = serve(argparse.Namespace(**{**vars(args), "action": "push", "payload": str(payload)}))
        if rc:
            return rc
        remember_push(args.label, payload)
        log(f"sources are in {args.dest}/tree/src")
    if args.action in ("make", "all"):
        if isinstance(board, Rig):
            return board.call("make", configure=args.configure)
        return serve(argparse.Namespace(**{**vars(args), "action": "make"}))
    if args.action == "run":
        if isinstance(board, Rig):
            return board.call("run", run=args.command)
        return serve(argparse.Namespace(**{**vars(args), "action": "run"}))
    if args.action == "pull":
        return pull(board, args)
    return 0


def qemu(args) -> int:
    if args.action == "pull":
        sys.exit("--qemu keeps nothing to pull: nothing survives the boot")
    work = WORK / args.label
    with device.QemuMount([], kernel=args.kernel) as guest:
        session = guest.session
        try:
            set_clock(session)
            if args.action in ("push", "all"):
                payload = make_payload(work, args.sources_only)
                board_push(session, payload, args.dest.rstrip("/"), args.full, True)
                log(f"sources are in {args.dest}/tree/src")
            if args.action in ("make", "all"):
                return board_make(session, args.dest.rstrip("/"), args.configure)
            if args.action == "run":
                return do_board(session, args)
            return 0
        finally:
            guest.stop()


if __name__ == "__main__":
    sys.exit(main())
