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

"""scp over the debug-probe UART: push files and directories to the board.

    scripts/transfer.py apps/fpbench/fpbench /root/ci/
    scripts/transfer.py -r tests/data /root/ci/data
    scripts/transfer.py a.c b.c /tmp/

Everything goes in ONE ``rz --zmodem --batch`` session. That is the whole
reason this script exists rather than a shell loop around the single-file
sender: at the smoke corpus's average size the bytes are not the cost, the rz
spawn and the shell round trip around each file are, and a batch pays them
once. The receiver creates the directories it needs from each file's own name,
so nothing has to exist on the target beforehand.

The target's batch receiver addresses its own filesystem and refuses anything
but an absolute path, so the destination must be absolute.
"""

import argparse
import fnmatch
import os
import shutil
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tests.smoke.framework import file_transfer  # noqa: E402
from tests.smoke.framework.session import Session  # noqa: E402


# What a directory walk skips unless told otherwise. These are the things that
# are never wanted on a 128 MiB card and are big enough that sending one by
# accident costs minutes of UART time, not seconds.
DEFAULT_EXCLUDES = (".git", "__pycache__", "*.pyc", ".DS_Store")


class TransferAbort(Exception):
    """A problem the user can fix, reported without a traceback."""


# ---- Building the file list ----

def _excluded(name: str, patterns) -> bool:
    return any(fnmatch.fnmatch(name, pattern) for pattern in patterns)


def _walk(root: Path, remote_root: str, excludes) -> list:
    """Every file under *root*, paired with its path under *remote_root*."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Pruning in place stops os.walk descending into an excluded directory
        # at all, so a .git with thousands of objects costs one comparison.
        dirnames[:] = sorted(d for d in dirnames if not _excluded(d, excludes))
        here = Path(dirpath)
        for filename in sorted(filenames):
            if _excluded(filename, excludes):
                continue
            local = here / filename
            if local.is_symlink() and not local.exists():
                print(f"  skipping broken symlink {local}", file=sys.stderr)
                continue
            relative = local.relative_to(root).as_posix()
            found.append((local, f"{remote_root}/{relative}"))
    return found


def _remote_join(base: str, name: str) -> str:
    return base.rstrip("/") + "/" + name


def plan_transfers(sources, destination: str, excludes, recursive: bool) -> list:
    """Resolve the argument shapes into explicit (local, remote) pairs.

    Directories follow rsync's rule rather than scp's, because scp's depends on
    whether the destination already exists and there is no way to ask the
    target that without a round trip whose answer we would then have to trust:

        -r dir  /root/ci   ->  /root/ci/dir/...
        -r dir/ /root/ci   ->  /root/ci/...

    For plain files, a trailing slash on the destination or more than one
    source means "*destination* is a directory to place things in". Only a lone
    file with a slashless destination renames, which is the one case where
    guessing wrong would silently write the wrong filename.
    """
    raw = list(sources)
    sources = [Path(s) for s in raw]
    for source in sources:
        if not source.exists():
            raise TransferAbort(f"{source}: no such file or directory")
        if source.is_dir() and not recursive:
            raise TransferAbort(f"{source}: is a directory (use -r)")

    destination_is_dir = (
        destination.endswith("/")
        or len(sources) > 1
        or sources[0].is_dir()
    )

    transfers = []
    for spelling, source in zip(raw, sources):
        if source.is_dir():
            contents_only = spelling.endswith(("/", "/."))
            base = (destination.rstrip("/") if contents_only
                    else _remote_join(destination, source.name))
            transfers.extend(_walk(source, base, excludes))
        elif destination_is_dir:
            transfers.append((source, _remote_join(destination, source.name)))
        else:
            transfers.append((source, destination))

    seen = {}
    for local, remote in transfers:
        if remote in seen and seen[remote] != local:
            raise TransferAbort(
                f"two sources both map to {remote}: {seen[remote]} and {local}")
        seen[remote] = local
    return transfers


# ---- Progress ----

def _format_size(count: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if count < 1024 or unit == "GiB":
            return f"{count:.0f} {unit}" if unit == "B" else f"{count:.1f} {unit}"
        count /= 1024
    return f"{count:.1f} GiB"


def _format_duration(seconds: float) -> str:
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m{seconds % 60:02d}s"
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


class ProgressBar:
    """A one-line bar on a tty, periodic lines everywhere else.

    The link runs at a few KiB/s, so a transfer of any size is measured in
    minutes and the interesting number is the ETA. It is computed from the
    rate over the whole transfer rather than an instantaneous one: zmodem is
    lockstep and a single retry stalls a second or two, which would make a
    short-window estimate swing wildly on a link that is otherwise fine.
    """

    REDRAW_INTERVAL = 0.15
    LOG_INTERVAL = 5.0

    def __init__(self, total_bytes: int, total_files: int, stream=sys.stderr):
        self.total_bytes = total_bytes
        self.total_files = total_files
        self.stream = stream
        self.tty = stream.isatty()
        self.started = time.monotonic()
        self.sent = 0
        self.files_done = 0
        self.current = ""
        self._last_draw = 0.0
        self._painted = False
        self._file_base = 0

    def start_file(self, name: str) -> None:
        self.current = name
        self.draw(force=not self.tty and self.total_files <= 1)

    def file_done(self, files_done: int, sent_bytes: int) -> None:
        self.files_done = files_done
        self.sent = sent_bytes
        self.draw()

    def file_bytes(self, offset: int, _size: int) -> None:
        # *offset* is the acknowledged position in the file being sent, and it
        # walks backwards when the receiver asks for a resend; the bar must not
        # walk backwards with it or the transfer looks broken when it is merely
        # retrying.
        self.sent = max(self.sent, self._file_base + offset)
        self.draw()

    def begin_file(self, name: str, base: int) -> None:
        self._file_base = base
        self.start_file(name)

    def draw(self, force: bool = False) -> None:
        now = time.monotonic()
        interval = self.REDRAW_INTERVAL if self.tty else self.LOG_INTERVAL
        if not force and now - self._last_draw < interval:
            return
        self._last_draw = now
        elapsed = now - self.started
        rate = self.sent / elapsed if elapsed > 0.5 else 0.0
        fraction = (self.sent / self.total_bytes) if self.total_bytes else 1.0
        fraction = min(max(fraction, 0.0), 1.0)
        eta = ((self.total_bytes - self.sent) / rate) if rate > 0 else None

        tail = "{}/{} {}/{} {}/s ETA {}".format(
            self.files_done, self.total_files,
            _format_size(self.sent), _format_size(self.total_bytes),
            _format_size(rate) if rate else "--",
            _format_duration(eta) if eta is not None else "--",
        )

        if not self.tty:
            self.stream.write(f"  {int(fraction * 100):3d}%  {tail}\n")
            self.stream.flush()
            return

        columns = shutil.get_terminal_size((100, 24)).columns
        # The name is what gets sacrificed when the terminal is narrow: the
        # numbers are why anyone is watching, and a truncated bar reads as a
        # stalled one.
        width = max(10, min(32, columns - len(tail) - 24))
        filled = int(width * fraction)
        bar = "#" * filled + "-" * (width - filled)
        name_room = columns - len(tail) - width - 12
        name = self.current
        if name_room > 4 and len(name) > name_room:
            name = "..." + name[-(name_room - 3):]
        elif name_room <= 4:
            name = ""
        line = f"\r[{bar}] {int(fraction * 100):3d}% {tail} {name}"
        self.stream.write(line[:columns].ljust(columns))
        self.stream.flush()
        self._painted = True

    def finish(self) -> None:
        if self._painted:
            self.stream.write("\r" + " " * shutil.get_terminal_size((100, 24)).columns + "\r")
            self.stream.flush()


# ---- Driving the session ----

def run_transfer(transfers, timeout: float, quiet: bool) -> int:
    sizes = [os.path.getsize(local) for local, _ in transfers]
    total_bytes = sum(sizes)

    # send_files sorts by remote path to keep each directory's files together
    # for the receiver's mkdir cache; mirror that here so the bar's per-file
    # accounting follows the same order the wire does.
    ordered = sorted(range(len(transfers)), key=lambda i: str(transfers[i][1]))
    order_sizes = [sizes[i] for i in ordered]
    names = [str(transfers[i][1]) for i in ordered]

    bar = None if quiet else ProgressBar(total_bytes, len(transfers))
    prefix_bytes = [0]
    for size in order_sizes[:-1]:
        prefix_bytes.append(prefix_bytes[-1] + size)

    if bar is not None:
        bar.begin_file(names[0], 0)
        bar.draw(force=True)

    def on_bytes(offset, size):
        if bar is not None:
            bar.file_bytes(offset, size)

    def on_progress(done, _total, sent):
        if bar is None:
            return
        bar.file_done(done, sent)
        if done < len(names):
            bar.begin_file(names[done], prefix_bytes[done])

    print(f"sending {len(transfers)} file(s), {_format_size(total_bytes)} "
          f"in one batch", file=sys.stderr)

    # A fresh process starts with target_needs_reset set, which would reboot the
    # board before every transfer and throw away whatever state the user is in
    # the middle of. Clearing it makes Session try the prompt first and reset
    # only when the board does not answer -- which is the recovery this is for.
    Session.target_needs_reset = False
    session = Session("transfer")
    started = time.monotonic()
    try:
        sent = file_transfer.send_files(
            session, transfers, timeout=timeout,
            on_progress=on_progress, on_bytes=on_bytes)
    finally:
        if bar is not None:
            bar.finish()
        session.close()

    elapsed = time.monotonic() - started
    rate = (sent / elapsed) if elapsed > 0 else 0.0
    print("sent {} file(s), {} in {} ({}/s); log: {}".format(
        len(transfers), _format_size(sent), _format_duration(elapsed),
        _format_size(rate), session.log_path), file=sys.stderr)
    return sent


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Send files to the board over the debug-probe UART.",
        epilog="The destination must be an absolute path on the target: the "
               "batch receiver addresses the target's filesystem and a "
               "relative name would land wherever the shell was left.")
    parser.add_argument("sources", nargs="+", metavar="SOURCE",
                        help="local files or directories to send")
    parser.add_argument("destination", metavar="DEST",
                        help="absolute path on the target; a trailing slash, "
                             "several sources or a directory source make it a "
                             "directory to place things in")
    parser.add_argument("-r", "--recursive", action="store_true",
                        help="descend into directory sources; rsync's rule "
                             "decides where they land -- `dir DEST` makes "
                             "DEST/dir, `dir/ DEST` puts its contents in DEST")
    parser.add_argument("-x", "--exclude", action="append", default=[],
                        metavar="GLOB",
                        help="skip names matching GLOB (repeatable); adds to "
                             f"the defaults {', '.join(DEFAULT_EXCLUDES)}")
    parser.add_argument("--no-default-excludes", action="store_true",
                        help="send .git and friends too")
    parser.add_argument("--serial", metavar="DEVICE",
                        help="serial port to use (default: SERIAL_DEVICE, or "
                             "auto-detect the debug probe)")
    parser.add_argument("--timeout", type=float, default=30.0, metavar="SEC",
                        help="seconds to wait for a target response "
                             "(default: %(default)s)")
    parser.add_argument("-n", "--dry-run", action="store_true",
                        help="list what would be sent and stop")
    parser.add_argument("-q", "--quiet", action="store_true",
                        help="no progress bar")
    args = parser.parse_args(argv)

    if args.serial:
        os.environ["SERIAL_DEVICE"] = args.serial

    excludes = list(args.exclude)
    if not args.no_default_excludes:
        excludes.extend(DEFAULT_EXCLUDES)

    try:
        if not args.destination.startswith("/"):
            raise TransferAbort(
                f"destination {args.destination!r} must be absolute "
                "(the target's batch receiver rejects relative paths)")
        transfers = plan_transfers(
            args.sources, args.destination, excludes, args.recursive)
        if not transfers:
            print("nothing to send", file=sys.stderr)
            return 0

        if args.dry_run:
            for local, remote in sorted(transfers, key=lambda t: str(t[1])):
                print(f"{local} -> {remote}  ({_format_size(os.path.getsize(local))})")
            total = sum(os.path.getsize(local) for local, _ in transfers)
            print(f"{len(transfers)} file(s), {_format_size(total)}",
                  file=sys.stderr)
            return 0

        run_transfer(transfers, args.timeout, args.quiet)
    except TransferAbort as error:
        print(f"transfer.py: {error}", file=sys.stderr)
        return 2
    except file_transfer.TransferError as error:
        print(f"transfer.py: transfer failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ntransfer.py: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
