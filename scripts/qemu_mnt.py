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

"""The two halves of run_qemu.sh's /mnt: before boot and after exit.

    qemu_mnt.py seed DIR BACKING STATE   guest RAM file with DIR on the fatdisk
    qemu_mnt.py sync BACKING DIR STATE   bring what the guest changed back to DIR

STATE remembers what DIR held when it was sent, so sync only brings back what
the guest changed and never overwrites a file that was also edited on the PC
meanwhile (the guest's copy lands next to it as <file>.target). Runs under a
plain python3.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from yasos_device import DeviceError, print_merge_report, seed_backing, sync_backing  # noqa: E402


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    seed = sub.add_parser("seed")
    seed.add_argument("dir", type=Path)
    seed.add_argument("backing", type=Path)
    seed.add_argument("state", type=Path)
    seed.add_argument("--ram-size", type=int, default=2 * 1024 ** 3)
    sync = sub.add_parser("sync")
    sync.add_argument("backing", type=Path)
    sync.add_argument("dir", type=Path)
    sync.add_argument("state", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.cmd == "seed":
            args.dir.mkdir(parents=True, exist_ok=True)
            seed_backing(args.dir.resolve(), args.backing, args.ram_size, args.state)
        else:
            report = sync_backing(args.backing, args.dir.resolve(), args.state)
            print_merge_report(report, args.dir)
            return 3 if report["conflicts"] else 0
    except DeviceError as error:
        print(f"qemu_mnt: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
