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

"""Boot YasOS in QEMU with a host directory mounted at /mnt.

    scripts/qemu_mount.py src/                       # a shell, Ctrl-] to quit
    scripts/qemu_mount.py src/ -c 'ls /mnt'          # run, print, exit with its status
    scripts/qemu_mount.py src/ --dest /tmp/src -c 'cd /tmp/src && make'
    scripts/qemu_mount.py src/ -c 'tcc -c /mnt/a.c -o /mnt/a.o' --pull out/
    scripts/qemu_mount.py --sdcard -c 'cat /proc/mounts'   # a partitioned SD card

The directory goes onto the an524's fatdisk window as a FAT volume with long
names and subdirectories, so nothing is sent over the serial line. --dest copies
it off /mnt into a guest directory first (the /tmp arena is faster than FAT and
not capped at the window's size for what gets built there). --pull copies the
whole /mnt back to the host after the guest stops, so anything written there
comes home. The UART counterpart for a real board is scripts/transfer.py -r.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from yasos_device import REPO_ROOT, DeviceError, QemuMount, run, sdcard_image  # noqa: E402


def interactive(session):
    from serial.tools.miniterm import Miniterm
    print("--- YasOS console, Ctrl-] to quit ---", file=sys.stderr)
    term = Miniterm(session.serial, echo=False, eol="lf")
    term.exit_character = chr(0x1d)
    term.menu_character = chr(0x14)
    term.set_rx_encoding("utf-8", "replace")
    term.set_tx_encoding("utf-8")
    session.serial.write(b"\n")
    term.start()
    try:
        term.join(True)
    except KeyboardInterrupt:
        pass
    term.join()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Boot YasOS in QEMU with a host directory at /mnt.")
    parser.add_argument("directory", nargs="?", type=Path, help="host directory to mount (default: an empty volume)")
    parser.add_argument("--dest", metavar="GUEST_DIR", help="also copy /mnt into this guest directory before running")
    parser.add_argument("-c", "--cmd", action="append", default=[], metavar="COMMAND",
                        help="shell command to run in the guest (repeatable); without one, an interactive console")
    parser.add_argument("--pull", type=Path, metavar="HOST_DIR",
                        help="copy /mnt back here after the guest stops (with --sdcard: save the card image to this file)")
    parser.add_argument("--kernel", type=Path, help="an mps3-an524 kernel ELF (default: zig-out/bin/yasos_kernel)")
    parser.add_argument("--silence", type=float, default=600.0, metavar="SEC",
                        help="give up when a command prints nothing for this long (default: %(default)s)")
    parser.add_argument("--keep", action="store_true", help="keep the work directory (qemu log, images)")
    parser.add_argument("--sdcard", action="store_true",
                        help="put a partitioned SD card image in the window instead of /mnt, laid out by "
                             "usr/bin/cardreformat (shrunk to 16 MiB); /etc/fstab "
                             "then mounts /boot, /var, /opt and /home from it")
    args = parser.parse_args(argv)

    if args.sdcard and args.directory:
        parser.error("--sdcard replaces the /mnt volume; give no directory")
    sources = [(args.directory, "")] if args.directory else []
    status = 0
    try:
        image = None
        if args.sdcard:
            image = sdcard_image(REPO_ROOT / ".cache/qemu_sdcard.img")
        with QemuMount(sources, kernel=args.kernel, keep_work=args.keep, image=image) as guest:
            try:
                if args.dest:
                    # `cp -r /mnt/. DEST` is refused ("bad '/mnt/.'"), so copy
                    # the top-level entries one by one.
                    copy = f"mkdir -p {args.dest}"
                    if sources:
                        copy += f" && cd /mnt && cp -r * {args.dest}/; r=$?; cd /; test $r = 0"
                    rc = run(guest.session, copy, echo=True)
                    if rc:
                        raise DeviceError(f"copying /mnt to {args.dest} failed ({rc})")
                for command in args.cmd:
                    status = run(guest.session, command, silence=args.silence)
                    if status:
                        print(f"qemu_mount: '{command}' exited with {status}", file=sys.stderr)
                        break
                if not args.cmd:
                    interactive(guest.session)
            finally:
                guest.stop()
                if args.pull is not None and args.sdcard:
                    guest.snapshot(args.pull)
                    print(f"qemu_mount: card image saved to {args.pull}", file=sys.stderr)
                elif args.pull is not None:
                    guest.pull(args.pull)
                    print(f"qemu_mount: /mnt copied to {args.pull}", file=sys.stderr)
    except DeviceError as error:
        print(f"qemu_mount: {error}", file=sys.stderr)
        return 2
    return status


if __name__ == "__main__":
    sys.exit(main())
