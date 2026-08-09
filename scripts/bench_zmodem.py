#!/usr/bin/env python3
"""Attribute the per-file cost of an `rz --zmodem --batch` push.

The push runs at a few KiB/s against a 45 KiB/s line, and a sub-packet CRC
timing cannot say why: every file costs three blocking round trips, and each
one has a filesystem operation inside it (open, write, close). This measures
the four costs separately so the fix targets the one that matters:

  link      -- a round trip that does no filesystem work at all, obtained by
               sending a frame the receiver answers with a bare ZRINIT
  open      -- ZFILE .. ZRPOS, minus the link cost
  write     -- one data sub-packet .. ZACK, minus link and wire time
  close     -- ZEOF .. ZRINIT, minus the link cost

Run it on the machine holding the serial port (the rig's Pi):

    workdir/venv/bin/python scripts/bench_zmodem.py [--files 200] [--big-kib 64]
"""

import argparse
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "smoke"))

from framework.session import CONSOLE_BAUDRATE, Session  # noqa: E402
from framework import file_transfer as ft  # noqa: E402

BENCH_DIR = "/root/ci/zbench"


def _now():
    return time.monotonic()


def _wait_header(ser):
    """Blocking header receive, returning (elapsed_seconds, type, offset)."""
    started = _now()
    hdr = ft._recv_header(ser)
    elapsed = _now() - started
    if hdr is None:
        raise ft.TransferError("no header")
    frame_type, fields = hdr
    return elapsed, frame_type, ft._frame_offset(fields)


def probe_link_rtt(ser, count):
    """Round trips the receiver answers without touching the filesystem.

    Between files an unrecognised frame makes the receiver repeat its ZRINIT
    (zmodem.c: the `type != ZFILE` arm), which is the only reply in the whole
    protocol with no open/write/close behind it. The receiver gives up after
    ZMODEM_MAX_RETRIES of these in a row, so the caller keeps *count* under it
    and sends a real file afterwards to reset the counter.
    """
    samples = []
    for _ in range(count):
        ser.write(ft._build_header(ft.ZNAK, 0, 0, 0, 0))
        elapsed, frame_type, _ = _wait_header(ser)
        if frame_type != ft.ZRINIT:
            raise ft.TransferError(f"probe got 0x{frame_type:02x}, expected ZRINIT")
        samples.append(elapsed)
    return samples


def send_file_timed(ser, remote_path, data):
    """One file, timing each of the three blocking waits separately."""
    size = len(data)

    ser.write(ft._build_header(ft.ZFILE, 0, 0, 0, 0))
    info = b"\x00".join([remote_path.encode(), str(size).encode(), b"0", b"0"]) + b"\x00"
    ser.write(ft._build_data_subpacket(info, ft.ZCRCW))
    ser.flush()
    t_open, frame_type, _ = _wait_header(ser)
    if frame_type != ft.ZRPOS:
        raise ft.TransferError(f"expected ZRPOS, got 0x{frame_type:02x}")

    acks = []
    encoded = 0
    if size:
        ser.write(ft._build_header(ft.ZDATA, 0, 0, 0, 0))
        offset = 0
        while offset < size:
            end = ft._chunk_end_within_wire_budget(data, offset)
            chunk = data[offset:end]
            packet = ft._build_data_subpacket(chunk, ft.ZCRCW if end == size else ft.ZCRCQ)
            encoded += len(packet)
            ser.write(packet)
            ser.flush()
            elapsed, frame_type, ack_offset = _wait_header(ser)
            if frame_type != ft.ZACK or ack_offset != end:
                raise ft.TransferError(
                    f"expected ZACK({end}), got 0x{frame_type:02x}({ack_offset})")
            acks.append((elapsed, len(packet)))
            offset = end

    ser.write(ft._build_header(ft.ZEOF, *ft._split_offset(size)))
    ser.flush()
    t_close, frame_type, _ = _wait_header(ser)
    if frame_type != ft.ZRINIT:
        raise ft.TransferError(f"expected ZRINIT, got 0x{frame_type:02x}")

    return t_open, acks, t_close, encoded


def _ms(values):
    if not values:
        return "        n/a"
    return "%6.1f (p50 %5.1f)" % (1000 * statistics.mean(values),
                                  1000 * statistics.median(values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", type=int, default=150,
                        help="small files per pass")
    parser.add_argument("--size", type=int, default=554,
                        help="bytes per small file (corpus average)")
    parser.add_argument("--big-kib", type=int, default=64,
                        help="size of the single large file, 0 to skip")
    parser.add_argument("--passes", default="create,overwrite",
                        help="which passes to run; the create pass alone is what "
                             "the corpus push actually does")
    args = parser.parse_args()

    # Was a hardcoded 460800, which silently became a lie the moment the console
    # rate moved; the wire-time column is only meaningful against the real rate.
    baud_bytes = CONSOLE_BAUDRATE / 10.0

    session = Session("bench_zmodem")
    ser = session.serial

    session.write_command(f"mkdir -p {BENCH_DIR}")
    session.wait_for_prompt_except_logs()

    # Recognisable, incompressible-ish payload; ZDLE escaping is content
    # dependent, so use printable bytes like the C sources it stands in for.
    body = bytes(((i * 7 + 33) % 95) + 32 for i in range(args.size))
    big = bytes(((i * 7 + 33) % 95) + 32 for i in range(args.big_kib * 1024))

    session.write_command("rz --zmodem --batch")
    old_timeout = ser.timeout
    ser.timeout = 30.0
    results = {}
    try:
        elapsed, frame_type, _ = _wait_header(ser)
        if frame_type != ft.ZRINIT:
            raise ft.TransferError(f"expected ZRINIT, got 0x{frame_type:02x}")

        results["link"] = probe_link_rtt(ser, 4)

        for pass_name in args.passes.split(","):
            opens, writes, closes, wire = [], [], [], []
            started = _now()
            for i in range(args.files):
                t_open, acks, t_close, encoded = send_file_timed(
                    ser, f"{BENCH_DIR}/f{i:05d}.c", body)
                opens.append(t_open)
                closes.append(t_close)
                for elapsed, packet_len in acks:
                    writes.append(elapsed)
                    wire.append(packet_len / baud_bytes)
            results[pass_name] = {
                "open": opens, "write": writes, "close": closes,
                "wire": wire, "wall": _now() - started,
            }

        if args.big_kib:
            t_open, acks, t_close, encoded = send_file_timed(
                ser, f"{BENCH_DIR}/big.bin", big)
            results["big"] = {
                "open": [t_open], "close": [t_close],
                "write": [elapsed for elapsed, _ in acks],
                "wire": [n / baud_bytes for _, n in acks],
                "bytes": len(big), "encoded": encoded,
            }

        ser.write(ft._build_header(ft.ZFIN, 0, 0, 0, 0))
        _wait_header(ser)
    finally:
        ser.timeout = old_timeout

    link = statistics.median(results["link"])
    print()
    print("link round trip (no filesystem work): %s ms  [%s]"
          % (_ms(results["link"]),
             " ".join("%.1f" % (1000 * v) for v in results["link"])))
    print()
    print("%-10s %18s %18s %18s %10s" % ("pass", "open (ZFILE>ZRPOS)",
                                         "write (data>ZACK)", "close (ZEOF>ZRINIT)",
                                         "KiB/s"))
    for pass_name in args.passes.split(","):
        entry = results.get(pass_name)
        if entry is None:
            continue
        rate = args.files * args.size / 1024.0 / entry["wall"]
        print("%-10s %18s %18s %18s %10.1f"
              % (pass_name, _ms(entry["open"]), _ms(entry["write"]),
                 _ms(entry["close"]), rate))
        wire_mean = statistics.mean(entry["wire"])
        print("%-10s   minus link+wire: open %+.1f ms, write %+.1f ms, close %+.1f ms"
              " (wire in the write wait: %.1f ms)"
              % ("", 1000 * (statistics.median(entry["open"]) - link),
                 1000 * (statistics.median(entry["write"]) - link - wire_mean),
                 1000 * (statistics.median(entry["close"]) - link),
                 1000 * wire_mean))

    # A FAT directory entry is found by a linear scan of the directory, so the
    # cost of creating file N is a function of how many files are already there.
    # Bucketing the create pass shows that growth directly, which matters far
    # more than its average: the real corpus puts thousands of sources in one
    # directory, and the push slows down as it fills.
    creates = results.get("create", {}).get("open", [])
    bucket = max(1, len(creates) // 6) if creates else 1
    print()
    print("create cost as the directory fills (median ms per bucket of %d):" % bucket)
    print("   " + "  ".join(
        "%d-%d: %.1f" % (start, start + bucket - 1,
                         1000 * statistics.median(creates[start:start + bucket]))
        for start in range(0, len(creates) - bucket + 1, bucket)))

    big = results.get("big")
    if big:
        wire_mean = statistics.mean(big["wire"])
        write_med = statistics.median(big["write"])
        print()
        print("one %d KiB file: %d sub-packets, ack wait %s ms"
              % (args.big_kib, len(big["write"]), _ms(big["write"])))
        print("   wire per sub-packet %.1f ms, so per-ack overhead %.1f ms"
              " -> effective %.1f KiB/s inside one file"
              % (1000 * wire_mean, 1000 * (write_med - wire_mean),
                 (big["bytes"] / 1024.0) / sum(big["write"])))
    print()

    # Cleanup is a courtesy, not a result: the numbers above are already in
    # hand, and a shell that came back slowly must not throw them away.
    try:
        session.wait_for_prompt_except_logs()
        session.write_command(f"rm -rf {BENCH_DIR}")
        session.wait_for_prompt_except_logs()
    except Exception as error:  # noqa: BLE001
        print(f"(cleanup of {BENCH_DIR} skipped: {error})")


if __name__ == "__main__":
    main()
