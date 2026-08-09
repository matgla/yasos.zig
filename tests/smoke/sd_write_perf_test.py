"""SD-card write throughput, as a regression gate.

Unlike the instruments in `measure_test.py`, this one asserts. It exists because
the write path is the part of the storage stack that has already regressed once
in a way nothing else in the suite would have caught: before the MMC/SDIO
transfer rework, `sdio_write` issued one CMD24 plus a full program busy-wait per
512-byte sector, so writes sat at ~0.4 MiB/s *regardless of request size* while
reads streamed at up to 8.2 MiB/s. Every functional test still passed. A
filesystem that is correct and 8x too slow looks exactly like a filesystem that
is correct.

Two kinds of check, because a card is not a constant:

  * **absolute floors**, deliberately loose (roughly half the slowest run
    observed), to catch a wholesale collapse — a bus that came up 1-bit wide, a
    lost high-speed negotiation, a misconfigured clock;
  * **a floor on the sequential 512-byte rate**, which is what now pins the
    batched path. Since 2026-08-10 the block layer combines contiguous
    single-sector writes into one multi-block request, so a 512-byte sequential
    pass reaches the card as 4 KiB runs and measures like one. Losing either
    the combining or CMD25 drops it back to one command per sector -- 2695
    KiB/s to ~376 -- which no plausible card swap can imitate.

    This replaced a set of speedup *ratios* (32 KiB against 512 B, and so on).
    They were card-independent and good at their job, but combining lifts the
    512-byte denominator to the same speed as the numerator, so every ratio
    collapsed to ~1.0 on a change that made writes 7x faster. A check that
    fails on an improvement is worse than no check.

Reference numbers are the rig's card, measured across three rounds of work on
this path (docs/remote_smoke_speedup_plan.md, "2.9 SD path tuning"):

    write() size   pre-CMD25   CMD25   + multi-block DMA, memcpy, HAL -O
    512 B          373          376    500 KiB/s   (single sectors keep CMD24)
    4 KiB          406         2139   2659 KiB/s
    32 KiB         412         3514   4370 KiB/s

    read() size    CMD25 era   now
    512 B          3115        5394 KiB/s
    32 KiB         8271       13336 KiB/s

Where the floors come from: four back-to-back runs on that rig, 2026-08-06,
taken in the middle column above (the CMD25 era).

    pass              runs                     spread
    seq_write 512 B   379, 378, 238, 374       -37% on one run
    seq_write 4 KiB   1859, 2089, 2078, 2053   +-6%
    seq_write 32 KiB  3532, 3437, 3422, 3444   +-2%
    rand_write 512 B  374, 374, 374, 374       none
    ratio 4 KiB       4.91, 5.53, 8.73, 5.49
    ratio 32 KiB      9.32, 9.09, 14.38, 9.21

The one 238 is the card, not the driver: that pass issues 2048 separate CMD24s
over ~2.7 s, which is the longest window in the benchmark for the card's own
garbage collection to land in, and every other pass in that same run was
normal. So the single-sector floors are set low enough to ride out a stall --
they check that the CMD24 path still works at all, they are not tuning gates.

The floors are deliberately NOT re-tightened onto the right-hand column. They
are set at roughly half the *slowest* run of the CMD25 era, which keeps them
2x or more clear of the pre-CMD25 numbers they exist to separate from, and
leaves headroom for a different card on a different rig. A gate pinned to the
best figure ever measured fails on the first slow card and teaches everyone to
ignore it. The 512-byte combined-rate floor below is what actually detects a
lost batching path, and it is set the same way: far enough above the broken
value and below the observed one that neither a slow card nor a real
regression lands near it.

The environment knobs below are for local runs and for bringing a different
board up. They do **not** reach the rig: `scripts/remote_smoke_tui.py` generates
a remote script that exports a fixed list of variables and forwards nothing
else, so the defaults in this file are what CI actually gates on. A slower card
is meant to be accommodated by lowering `..._FLOOR_SCALE` here, in a commit,
rather than by an invocation nobody can see afterwards.

Skipped on targets whose /root is not SD-backed — the QEMU boards mount a
RAM-backed FAT window, where this would time a memcpy and call it a disk.
"""

import os
import re

import pytest

from .conftest import session_key


# Where the scratch file goes. /root is the SD mount point on the RP2350 boards;
# the tcc suite's /root/ci lives on the same filesystem and is not always present
# on a fresh card, so the gate does not depend on it.
SCRATCH_DIR = os.environ.get("YASOS_SMOKE_SD_BENCH_DIR", "/root")

# KiB per pass. 1 MiB matches the reference measurements above, and outruns
# FatFs's disk cache (4 lines x 4 KiB) by 64x so nothing here is served from RAM.
BENCH_KIB = int(os.environ.get("YASOS_SMOKE_SD_BENCH_KIB", "1024"))

# One knob for a slower card, applied to every absolute floor. The ratio floors
# are deliberately left alone: they are already card-independent.
FLOOR_SCALE = float(os.environ.get("YASOS_SMOKE_SD_WRITE_FLOOR_SCALE", "1.0"))

# Idle timeout, not a deadline (see Session._read_until) -- sdbench flushes after
# every pass, so this bounds a single pass. The slowest one is the 512-byte
# sequential write: ~2.8 s healthy, and a regression makes it slower, not silent.
BENCH_TIMEOUT = float(os.environ.get("YASOS_SMOKE_SD_BENCH_TIMEOUT", "60"))

# sdbench emits one space-separated key=value line per pass, e.g.
#   seq_write bs=4096 bytes=1048576 us=489000 kib_s=2139 ops=256 us_per_op=1869
_PASS_RE = re.compile(
    r"^(?P<name>seq_write|seq_read|rand_write|rand_read)\s+bs=(?P<bs>\d+)\s+"
    r"bytes=(?P<bytes>\d+)\s+us=(?P<us>-?\d+)\s+kib_s=(?P<kib_s>\d+)"
    r"(?:\s+ops=(?P<ops>\d+)\s+us_per_op=(?P<us_per_op>\d+))?\s*$"
)

# (block size, floor KiB/s, reference KiB/s). Roughly half the slowest of the
# four runs above, each still >=2x clear of the pre-CMD25 value it has to
# separate from (406 at 4 KiB, 412 at 32 KiB).
SEQ_WRITE_FLOORS = (
    (512, 120, 376),
    (4096, 900, 2139),
    (32768, 1500, 3514),
)

# Scattered single-sector writes: the CMD24 path again, and the one the FAT
# metadata updates take. Reference 368 KiB/s, unchanged by the CMD25 work.
RAND_WRITE_FLOOR = 180
RAND_WRITE_REFERENCE = 368

# Sequential 512-byte writes must reach multi-block speed.
#
# This replaced a set of speedup *ratios* (4 KiB and 32 KiB against the
# 512-byte pass) on 2026-08-10, when the block layer started combining
# contiguous single-sector writes into one multi-block request
# (`write_combined` in source/fs/fatfs/fatfs.zig). Small sequential writes now
# reach the card as 4 KiB runs, so every size measures about the same and the
# ratios collapsed to ~1.0 -- not because batching was lost but because it
# moved above the driver, where the 512-byte denominator gets it too.
#
# The regression those ratios existed to catch is still caught, and more
# directly: if either the combining or the CMD25 path stopped working, small
# sequential writes would fall back to one command per sector, which measures
# ~376 KiB/s (the pre-combining reference). Observed after combining: 2695 and
# 2728 KiB/s. The floor sits between the two with wide margin on both sides --
# 2.7x above the value that means "broken", 2.7x below the value observed --
# so it neither fires on a slower card nor passes a real regression.
SEQ_WRITE_512_COMBINED_FLOOR = 1000
SEQ_WRITE_512_COMBINED_REFERENCE = 2695
SEQ_WRITE_512_PER_COMMAND_RATE = 376


def _target_is_sd_backed(session):
    """True when the board actually has an SD/MMC partition behind /root.

    The QEMU boards declare no `mmc` interface (hal/boards/qemu_mps3_an524), so
    main.zig mounts a RAM-backed FAT window -- or a RamFs -- at /root instead.
    Timing that would measure the host's memory bandwidth through an emulator's
    idea of a clock, which is neither a floor nor a ratio worth asserting on.
    """
    session.write_command("ls /dev")
    return "mmc0p0" in "\n".join(session.wait_for_prompt_except_logs())


def _run_sdbench(session):
    """Run one full sdbench pass; return (raw lines, {(pass, bs): fields})."""
    with session.timeout(BENCH_TIMEOUT):
        session.write_command(f"sdbench -s {BENCH_KIB} {SCRATCH_DIR}")
        lines = session.wait_for_prompt_except_logs()

    results = {}
    for line in lines:
        match = _PASS_RE.match(line.strip())
        if match is None:
            continue
        results[(match.group("name"), int(match.group("bs")))] = {
            "kib_s": int(match.group("kib_s")),
            "us_per_op": int(match.group("us_per_op") or 0),
            "bytes": int(match.group("bytes")),
        }
    return lines, results


def _format_report(results):
    """Every pass, floors alongside. The read rows carry no verdict but earn
    their place in the output: if reads fell with writes it is the card or the
    bus, and the write path is not the thing to go looking at."""
    floors = {("seq_write", bs): (floor, reference)
              for bs, floor, reference in SEQ_WRITE_FLOORS}
    floors[("rand_write", 512)] = (RAND_WRITE_FLOOR, RAND_WRITE_REFERENCE)

    rows = [
        f"=== SD write throughput ({SCRATCH_DIR}, {BENCH_KIB} KiB per pass) ===",
        f"{'pass':<12}{'block':>8}{'KiB/s':>10}{'us/op':>9}{'floor':>9}{'ref':>8}",
    ]
    for key in sorted(results):
        name, bs = key
        fields = results[key]
        floor, reference = floors.get(key, (None, None))
        floor_text = f"{floor * FLOOR_SCALE:.0f}" if floor else "-"
        reference_text = str(reference) if reference else "-"
        rows.append(
            f"{name:<12}{bs:>8}{fields['kib_s']:>10}{fields['us_per_op']:>9}"
            f"{floor_text:>9}{reference_text:>8}"
        )

    baseline = results.get(("seq_write", 512))
    if baseline and baseline["kib_s"] > 0:
        # Sizes converge once the block layer combines contiguous sectors, so
        # the interesting number is how far the 512-byte pass sits above the
        # one-command-per-sector rate rather than below the larger passes.
        rows.append(
            f"seq 512 B = {baseline['kib_s']} KiB/s"
            f"  (floor {SEQ_WRITE_512_COMBINED_FLOOR},"
            f" ref {SEQ_WRITE_512_COMBINED_REFERENCE},"
            f" per-command {SEQ_WRITE_512_PER_COMMAND_RATE})"
        )
    return "\n".join(rows)


def _collect_failures(results):
    """Every floor that was missed, not just the first -- one run should say
    everything that is wrong with the write path, since re-running it costs a
    board."""
    failures = []

    for bs, floor, reference in SEQ_WRITE_FLOORS:
        if bs > BENCH_KIB * 1024:
            continue  # sdbench skips blocks larger than the total
        measured = results.get(("seq_write", bs))
        if measured is None:
            failures.append(f"sequential write at bs={bs} did not report a result")
            continue
        # A pass that wrote less than it was asked to still reports a plausible
        # rate, because sdbench divides by the bytes it actually moved. Guard
        # the denominator before trusting the quotient.
        expected = BENCH_KIB * 1024
        if measured["bytes"] < expected:
            failures.append(
                f"sequential write bs={bs} moved only {measured['bytes']} of"
                f" {expected} bytes -- short write, the rate below is not"
                f" comparable"
            )
        scaled = floor * FLOOR_SCALE
        if measured["kib_s"] < scaled:
            failures.append(
                f"sequential write bs={bs}: {measured['kib_s']} KiB/s"
                f" < floor {scaled:.0f} KiB/s (reference {reference} KiB/s)"
            )

    measured = results.get(("rand_write", 512))
    if measured is None:
        failures.append("random write did not report a result")
    else:
        scaled = RAND_WRITE_FLOOR * FLOOR_SCALE
        if measured["kib_s"] < scaled:
            failures.append(
                f"random write bs=512: {measured['kib_s']} KiB/s"
                f" < floor {scaled:.0f} KiB/s"
                f" (reference {RAND_WRITE_REFERENCE} KiB/s)"
            )

    baseline = results.get(("seq_write", 512))
    if baseline is not None and baseline["kib_s"] > 0:
        if baseline["kib_s"] < SEQ_WRITE_512_COMBINED_FLOOR:
            failures.append(
                f"sequential 512-byte writes are not being combined:"
                f" {baseline['kib_s']} KiB/s, floor"
                f" {SEQ_WRITE_512_COMBINED_FLOOR} (reference"
                f" {SEQ_WRITE_512_COMBINED_REFERENCE}). One command per sector"
                f" measures ~{SEQ_WRITE_512_PER_COMMAND_RATE} -- check that"
                f" write_combined still merges contiguous sectors and that"
                f" sdio_write still issues CMD25 for the merged request."
            )

    return failures


def test_sd_write_throughput(request):
    session = request.node.stash[session_key]

    if not _target_is_sd_backed(session):
        pytest.skip("no /dev/mmc0p0: this target's /root is not SD-backed")

    try:
        lines, results = _run_sdbench(session)
    finally:
        # sdbench removes its own scratch file on a clean run; a crashed or
        # timed-out one leaves a megabyte behind on the card the suite shares.
        session.write_command(f"rm -f {SCRATCH_DIR}/sdbench.tmp")
        session.wait_for_prompt_except_logs()

    if not results:
        pytest.fail(
            "sdbench produced no parseable results (missing binary, or it"
            " failed before the first pass). Output was:\n"
            + "\n".join(lines)
        )

    print("\n" + _format_report(results))

    failures = _collect_failures(results)
    if failures:
        pytest.fail(
            "SD write throughput regressed:\n  - "
            + "\n  - ".join(failures)
            + "\n\n"
            + _format_report(results)
        )
