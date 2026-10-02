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

The QEMU counterpart needs none of this: scripts/run_qemu.sh mounts a host
directory at /mnt and brings the guest's changes back when it exits.
"""

import argparse
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
    args = parser.parse_args(argv)
    if not args.target_dir.startswith("/"):
        parser.error("the board directory must be absolute")

    host_dir = args.host_dir.resolve()
    session = device.uart_session(args.serial)
    try:
        if args.action == "push":
            report = device.uart_push(session, host_dir, args.target_dir)
            print_report(report, f"to {args.target_dir}")
        elif args.action == "pull":
            report = device.uart_pull(session, host_dir, args.target_dir)
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


if __name__ == "__main__":
    sys.exit(main())
