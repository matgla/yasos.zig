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

"""Keep a directory on the board in step with one on the PC, over the UART.

    scripts/target_sync.py push ~/src/proj /root/proj   # PC changes -> board
    scripts/target_sync.py pull ~/src/proj /root/proj   # board changes -> PC
    scripts/target_sync.py status ~/src/proj /root/proj

No network and no git on the board: the PC keeps the checkout, the board works
on a copy, and this moves only what changed, both ways, in one zmodem session
each (rz up, sz down). Both directions are three-way against what the board
held after the last push or pull, so nothing either side changed meanwhile is
overwritten: push leaves a file both sides changed alone on the board, pull
keeps the board's copy beside the PC's as <file>.target. Resolve on the PC,
delete the .target file, and the next push sends the result. Commit on the PC.

--rig works the same on the rig's board, through the Pi it hangs off (the
SSH target in .cache/remote_smoke_runner.json, remote_smoke_tui.py
--reconfigure). The PC folder is mirrored to the Pi with rsync, target_sync
runs there on the mirror under the board lock (scripts/rig/tinycc_board.sh,
like zig_board.py), and the sync state comes back; a pull brings back only
the files it changed, and skips any you edited on the PC meanwhile. The rig
board has its own state, apart from a board on this PC's probe. A rig with
several boards (scripts/rig/boards.py): --rig-board NAME (default the config's
rig_board), with a state of its own; without a name, the board this folder
synced with last, else the first free one.

    scripts/target_sync.py --rig push apps/ydb /root/ydb

The QEMU counterpart needs none of this: scripts/run_qemu.sh mounts a host
directory at /mnt and brings the guest's changes back when it exits.
"""

import argparse
import json
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import yasos_device as device  # noqa: E402


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("action", choices=("push", "pull", "status"))
    parser.add_argument("host_dir", type=Path, help="directory on the PC (e.g. a git checkout)")
    parser.add_argument("target_dir", help="absolute directory on the board")
    parser.add_argument("--serial", help="serial device (default: SERIAL_DEVICE, else auto-detect the probe)")
    parser.add_argument("--rig", action="store_true",
                        help="the rig's board, over SSH (.cache/remote_smoke_runner.json)")
    parser.add_argument("--lock-wait", type=int, default=3000,
                        help="--rig: seconds to wait for a busy board (default 3000)")
    parser.add_argument("--rig-board", metavar="NAME",
                        help="--rig: which board (scripts/rig/boards.py; default: the config's "
                             "rig_board, else the one this folder synced with last)")
    # What --rig runs on the Pi: the state file and a report for the PC.
    parser.add_argument("--state", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--report", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not args.target_dir.startswith("/"):
        parser.error("the board directory must be absolute")

    host_dir = args.host_dir.resolve()
    if args.rig:
        return rig_main(args, host_dir)
    if args.state:
        device.sync_state_path = lambda *_a, **_k: args.state
    session = device.uart_session(args.serial)
    report = None
    try:
        if args.action == "push":
            report = device.uart_push(session, host_dir, args.target_dir)
            print_report(report, f"to {args.target_dir}")
        elif args.action == "pull":
            report = device.uart_pull(session, host_dir, args.target_dir)
            if not args.report:                 # --rig prints it on the PC, with its paths
                device.print_merge_report(report, host_dir)
        else:
            base = device._load_state(device.sync_state_path(host_dir, args.target_dir))
            target = device.target_manifest(session, args.target_dir)
            host = device.snapshot(host_dir)
            for path in sorted(set(base) | set(target) | set(host)):
                b, t, h = base.get(path), target.get(path), host.get(path)
                pc, board = h != b, t != b
                if pc and board and h != t:
                    print(f"  C {path}")
                elif pc and h != t:
                    print(f"  > {path}  (changed on the PC)")
                elif board and h != t:
                    print(f"  < {path}  (changed on the board)")
        if args.report and report is not None:
            args.report.write_text(json.dumps(report))
        return 3 if args.action != "status" and report["conflicts"] else 0
    except device.DeviceError as error:
        print(f"target_sync: {error}", file=sys.stderr)
        return 2
    finally:
        session.close()


def print_report(report, where):
    for kind, sign in (("added", "A"), ("updated", "M"), ("deleted", "D")):
        for path in report[kind]:
            print(f"  {sign} {path}")
    for path in report["conflicts"]:
        print(f"  C {path}  (changed on both sides; left alone on the board -- pull, resolve, "
              f"delete {path}.target)")
    moved = sum(len(report[k]) for k in ("added", "updated", "deleted"))
    print(f"push: {moved} change(s) {where}" + (f", {len(report['conflicts'])} conflict(s)" if report["conflicts"] else ""))


def rig_main(args, host_dir: Path) -> int:
    """Run this script on the rig's Pi against a mirror of *host_dir*."""
    repo = Path(__file__).resolve().parent.parent
    cfg = json.loads((repo / ".cache/remote_smoke_runner.json").read_text())
    target, port = cfg["ssh_target"], str(cfg.get("ssh_port", 22))
    remote = cfg.get("remote_repo_path", "~/yasos_remote_smoke")
    # A named board keeps its own state (and Pi directory); without one the wrapper
    # keeps to the board that directory synced with last, so the state stays its.
    board = (args.rig_board or str(cfg.get("rig_board") or "")).strip()
    board = "" if board == "auto" else board
    state = device.sync_state_path(host_dir, args.target_dir, kind=f"rig-{board}" if board else "rig")
    rdir = f"target_sync/{state.stem}"          # under the Pi user's home
    ssh_opts = ["-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-p", port]
    rsh = "ssh " + " ".join(shlex.quote(o) for o in ssh_opts)

    def ssh(command):
        return subprocess.run(["ssh", *ssh_opts, target, command], stdin=subprocess.DEVNULL).returncode

    def scp(srcs, dst):
        subprocess.run(["scp", "-q", "-r", "-P", port, *map(str, srcs), dst], check=True)

    if ssh(f"mkdir -p {rdir}/py {rdir}/rig {rdir}/tree {rdir}/.cache && rm -f {rdir}/state.json {rdir}/report.json"):
        print(f"target_sync: cannot reach {target}", file=sys.stderr)
        return 2
    wrapper = (repo / "scripts/rig/tinycc_board.sh").read_text().replace(
        '"$D/py/tinycc_board.py"', '"$D/py/target_sync.py"')
    local_wrapper = state.with_suffix(".rig.sh")
    local_wrapper.write_text(wrapper)
    scp([Path(__file__).resolve(), repo / "scripts/yasos_device.py"], f"{target}:{rdir}/py/")
    scp([local_wrapper], f"{target}:{rdir}/rig/target_sync.sh")
    scp([repo / "scripts/rig/boards.py", repo / "scripts/rig/openocd"], f"{target}:{rdir}/rig/")
    if state.is_file():
        scp([state], f"{target}:{rdir}/state.json")

    # The mirror: everything the sync looks at, plus the *.target files a push
    # checks for (the snapshot itself skips them).
    before = device.snapshot(host_dir)
    excludes = [f"--exclude={x}" for x in device.WORKSPACE_EXCLUDES if x != "*.target"]
    host_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run(["rsync", "-a", "--delete", *excludes, "-e", rsh,
                    f"{host_dir}/", f"{target}:{rdir}/tree/"], check=True)

    words = ["bash", f"$HOME/{rdir}/rig/target_sync.sh", f"$HOME/{rdir}", str(args.lock_wait),
             "NOFLASH", "-", "-", args.action, f"$HOME/{rdir}/tree", args.target_dir,
             "--state", f"$HOME/{rdir}/state.json", "--report", f"$HOME/{rdir}/report.json"]
    quoted = " ".join(w if w.startswith("$HOME") else shlex.quote(w) for w in words)
    env = f"PYTHONPATH={remote} YASOS_RIG_REMOTE={remote}"
    if board:
        env += f" YASOS_BOARD={shlex.quote(board)}"
    if cfg.get("serial_device"):
        # The single board's UART; boards.py replaces it with the held board's.
        env += f" SERIAL_DEVICE={shlex.quote(cfg['serial_device'])}"
    rc = ssh(f"{env} {quoted}")
    if args.action == "status" or rc not in (0, 3):
        if rc == 99:
            print("target_sync: the rig's board stayed busy", file=sys.stderr)
        return rc

    scp([f"{target}:{rdir}/state.json"], state)
    if args.action == "pull":
        work = state.with_suffix(".report.json")
        scp([f"{target}:{rdir}/report.json"], work)
        rc = max(rc, bring_back(json.loads(work.read_text()), before, host_dir,
                                f"{target}:{rdir}/tree/", rsh, state.with_suffix(".stage")))
    return rc


def bring_back(report, before, host_dir: Path, mirror: str, rsh: str, stage: Path) -> int:
    """Apply a pull done on the Pi's mirror to *host_dir*, file by file.

    A file changed here since the mirror was made is left alone (and the
    board's copy fetched as <file>.target instead), so an edit made while the
    rig ran is never lost."""
    now = device.snapshot(host_dir)
    moved = [p for k in ("added", "updated") for p in report[k]]
    late = [p for p in moved + report["deleted"] if now.get(p) != before.get(p)]
    fetch = [p for p in moved if p not in late] + [p + ".target" for p in report["conflicts"]]
    fetch += [p for p in late if p not in report["deleted"]]
    if fetch:
        shutil.rmtree(stage, ignore_errors=True)
        listing = "".join(p + "\n" for p in fetch)
        subprocess.run(["rsync", "-a", "--files-from=-", "-e", rsh, mirror, f"{stage}/"],
                       input=listing.encode(), check=True)
        for p in fetch:
            src = stage / p
            if not src.exists():                 # a conflict whose board side is a deletion
                continue
            dst = host_dir / (p + ".target" if p in late else p)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(src, dst)
        shutil.rmtree(stage, ignore_errors=True)
    for p in report["deleted"]:
        if p not in late:
            (host_dir / p).unlink(missing_ok=True)
    for kind, sign in (("added", "A"), ("updated", "M"), ("deleted", "D")):
        for p in report[kind]:
            if p not in late:
                print(f"  {sign} {p}")
    for p in report["conflicts"]:
        print(f"  C {p}  (changed on both sides; the board's copy is {p}.target)")
    for p in late:
        print(f"  C {p}  (edited on the PC during the pull; the board's copy is {p}.target)"
              if p not in report["deleted"] else f"  C {p}  (edited on the PC; the board deleted it)")
    print(f"pull: {len(moved) + len(report['deleted']) - len(late)} change(s) into {host_dir}"
          + (f", {len(report['conflicts']) + len(late)} conflict(s)" if report["conflicts"] or late else ""))
    return 3 if report["conflicts"] or late else 0


if __name__ == "__main__":
    sys.exit(main())
