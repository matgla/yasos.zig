#!/usr/bin/env python3
"""Time sequential SD reads and directory scans on the target.

The zmodem push spends most of its wall clock inside `open()` on a new file,
and that cost grows linearly with the number of files already in the
directory -- a FAT directory scan. Whether the fix belongs in the disk layer
(cache and read ahead) or somewhere else depends on what one 512-byte sector
read actually costs, which is what this measures:

  bulk read  -- sha256sum of a large file: streaming throughput, the best case
                the card and driver can do
  dir scan   -- `ls` of a directory of known size: the same sectors the create
                path walks, with no per-file work on top

Run on the machine holding the serial port:

    workdir/venv/bin/python scripts/bench_sd_read.py
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "smoke"))

from framework.session import Session  # noqa: E402


def timed_command(session, command, timeout=120):
    started = time.monotonic()
    session.write_command(command)
    lines = session.wait_for_prompt_except_logs(timeout=timeout)
    return time.monotonic() - started, lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", default="/root/ci/zbench",
                        help="directory to scan (left over from bench_zmodem)")
    parser.add_argument("--file", default="",
                        help="large file to hash; default: pick one from the corpus")
    args = parser.parse_args()

    session = Session("bench_sd_read")

    # A command that touches nothing measures the shell round trip, which every
    # other number here includes and none of them is about.
    baseline, _ = timed_command(session, "cd /")
    print("shell round trip: %.1f ms" % (1000 * baseline))

    target = args.file
    if not target:
        _, lines = timed_command(session, "ls -l /root/ci/sources/tests2")
        biggest = None
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[-2].isdigit():
                size = int(parts[-2])
                if biggest is None or size > biggest[0]:
                    biggest = (size, parts[-1])
        if biggest is None:
            print("no file found to hash; pass --file")
            return
        size, name = biggest
        target = f"/root/ci/sources/tests2/{name}"
    else:
        size = 0

    elapsed, lines = timed_command(session, f"sha256sum {target}")
    elapsed -= baseline
    print("sha256sum %s (%d bytes): %.2f s" % (target, size, elapsed))
    if size:
        sectors = (size + 511) // 512
        print("   -> %.1f KiB/s streaming, %.2f ms per 512-byte sector"
              " (includes hashing, so this is an upper bound on read cost)"
              % (size / 1024.0 / elapsed, 1000 * elapsed / sectors))

    for directory in (args.dir, "/root/ci/sources/gcc_torture/compile",
                      "/root/ci/sources/ir_tests"):
        elapsed, lines = timed_command(session, f"ls {directory}")
        entries = sum(len(line.split()) for line in lines)
        if entries == 0:
            continue
        elapsed -= baseline
        print("ls %s: %d names in %.2f s -> %.2f ms per name"
              % (directory, entries, elapsed, 1000 * elapsed / entries))

    session.close()


if __name__ == "__main__":
    main()
