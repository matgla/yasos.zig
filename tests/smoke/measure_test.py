"""Phase 0.7 / 0.8 instruments: XIP cache behaviour and the SD throughput floor.

These are measurements, not assertions. They exist because every remaining
estimate in docs/remote_smoke_speedup_plan.md was sized against a wall-time
budget that no longer holds, and because two specific questions decide whether
whole phases get built at all:

  0.7  Is the on-target compile waiting on the core or on QMI fetches? The
       compile bucket is 78% of the run and 2.17 MiB of tcc .text executes
       through a 16 KiB XIP cache, so the answer decides all of Phase 5.
  0.8  Is the SD path slow enough to be worth tuning? Reads already stream
       through CMD18 while writes go one CMD24 plus a busy-wait per sector, so
       the two directions are expected to differ sharply. Under ~2% of compile
       and item 2.9 closes unbuilt.

Opt-in, and they print rather than assert, so a full suite run neither pays for
them nor can be failed by them. Run them with:

    scripts/remote_smoke_tui.py --pytest-args "tests/smoke/measure_test.py -m measure -s"
"""

import json
import os
import posixpath
import re
import time
from pathlib import Path

import pytest

from .conftest import session_key


pytestmark = pytest.mark.measure

def _core_clock_hz():
    """The clock the firmware under test was built for.

    Read from the generated config rather than hardcoded, because the 0.7(b)
    A/B is precisely a run at a different clock: a constant here would silently
    keep reporting per-cycle rates against the old one, and the whole point of
    that experiment is the ratio between the two. The tree is rsynced to the
    rig, so this is the same file the kernel was built from.
    """
    override = os.environ.get("YASOS_SMOKE_MEASURE_CLOCK_HZ")
    if override:
        return float(override)
    config_path = Path(__file__).resolve().parents[2] / "config" / "target" / "config.json"
    try:
        with config_path.open() as handle:
            return float(json.load(handle)["cpu_clock_frequency_mhz"]) * 1e6
    except (OSError, KeyError, ValueError):
        return 0.0


CORE_CLOCK_HZ = _core_clock_hz()

# Where the benchmark writes. /root/ci is the SD-backed directory the suite
# already uses, which is the path whose cost the plan cares about.
SCRATCH_DIR = os.environ.get("YASOS_SMOKE_MEASURE_DIR", "/root/ci")

COMPILE_TIMEOUT = float(os.environ.get("YASOS_SMOKE_MEASURE_TIMEOUT", "60"))

_XIP_FIELD_RE = re.compile(r"^xip_(hit|acc|saturated)\s+(\d+)\s*$", re.MULTILINE)

# Compiles spanning three orders of magnitude of duration, drawn from the corpus
# the suite already uploads, so the miss rate can be compared across them. Any
# that a given target does not hold are reported absent rather than failing --
# /root/ci is populated by ordinary runs, not by this harness.
_CORPUS = "/root/ci/sources"
SWEEP_SOURCES = [
    ("tests2/00_assignment.c", f"{_CORPUS}/tests2/00_assignment.c"),
    ("ir_tests/219_fuzz_strd_spill", f"{_CORPUS}/ir_tests/219_fuzz_strd_spill_dryrun_offset.c"),
    ("ir_tests/mibench_rijndael.c", f"{_CORPUS}/ir_tests/mibench_rijndael.c"),
    ("gcc_torture/limits-fnargs.c", f"{_CORPUS}/gcc_torture/compile/limits-fnargs.c"),
]


def _read_xip(session):
    """Snapshot /proc/xip. Returns None when the target publishes no counters,
    which is every board but the RP2350 -- worth distinguishing from zeros."""
    session.write_command("cat /proc/xip")
    out = session.read_until_prompt()
    fields = {key: int(value) for key, value in _XIP_FIELD_RE.findall(out)}
    if not {"hit", "acc", "saturated"} <= fields.keys():
        return None
    return fields


def _describe_window(label, before, after, wall_s):
    """One line of derived XIP figures for a bracketed window."""
    hit = after["hit"] - before["hit"]
    acc = after["acc"] - before["acc"]
    saturated = after["saturated"] - before["saturated"]
    miss = acc - hit

    hit_rate = (100.0 * hit / acc) if acc else 0.0
    cycles = wall_s * CORE_CLOCK_HZ
    acc_per_cycle = acc / cycles if cycles > 0 else 0.0
    # Misses per second is the number that separates an instruction-fetch miss
    # stream from a data one. tcc cycles through the same 2.17 MiB of .text
    # whatever it is compiling, so a fetch-dominated miss stream should hold a
    # roughly constant rate per second of execution regardless of the source;
    # a data-dominated one should climb as the working set grows.
    miss_per_s = miss / wall_s if wall_s > 0 else 0.0

    note = ""
    if saturated:
        note = (
            f"  !! {saturated} saturated sample(s): the counters pinned, so"
            " these are floors, not counts"
        )

    return (
        f"{label:<34} wall={wall_s * 1000:9.1f} ms  acc={acc:>13}  miss={miss:>11}"
        f"  hit_rate={hit_rate:6.2f}%  acc/cycle={acc_per_cycle:6.3f}"
        f"  miss/s={miss_per_s:11.0f}"
        + note
    )


def _as_text(out):
    """wait_for_prompt_except_logs hands back a list of lines; read_until_prompt
    a single string. Normalise so callers can just search it."""
    if out is None:
        return ""
    if isinstance(out, (list, tuple)):
        return "\n".join(str(line) for line in out)
    return str(out)


def _command_window(session, command, label, expect_failure_free=True):
    """Bracket any one shell command between two counter reads.

    The window is everything the host waits for: the command bytes going out,
    whatever the target does, and the prompt coming back. That is deliberate --
    it is the same envelope the suite's own per-test timing measures, so a floor
    established here is a floor the suite actually pays.
    """
    before = _read_xip(session)
    if before is None:
        pytest.skip("target publishes no /proc/xip counters")

    start = time.monotonic()
    with session.timeout(COMPILE_TIMEOUT):
        session.write_command(command)
        out = _as_text(session.wait_for_prompt_except_logs())
    wall = time.monotonic() - start

    after = _read_xip(session)
    line = _describe_window(label, before, after, wall)
    # A command that failed still produces a perfectly plausible-looking row,
    # and a row measuring an error path would be worse than no row at all.
    if expect_failure_free and re.search(r"error|not found", out, re.IGNORECASE):
        line += "   << FAILED, row is meaningless"
    return line, wall


def _median_command_wall(session, command, label, repeats):
    """Run a command `repeats` times and report the median row, so a ladder step
    of a few milliseconds is not decided by one sample."""
    rows, walls = [], []
    for _ in range(repeats):
        row, wall = _command_window(session, command, label)
        rows.append(row)
        walls.append(wall)
    order = sorted(range(len(walls)), key=lambda i: walls[i])
    middle = order[len(order) // 2]
    return rows[middle], walls[middle]


def _compile_window(session, remote_source, label, extra_flags=""):
    """Bracket one compile. Includes the tcc spawn and module load, because that
    is what the plan's compile bucket includes."""
    output = posixpath.join("/tmp", "measure.out")
    command = f"tcc {extra_flags} {remote_source} -o {output}".replace("  ", " ")
    line, wall = _command_window(session, command, label)
    session.write_command(f"rm -f {output}")
    session.wait_for_prompt_except_logs()
    return line, wall


def _remote_file_exists(session, path):
    session.write_command(f"ls {path}")
    out = _as_text(session.read_until_prompt())
    return path.rsplit("/", 1)[-1] in out and "not found" not in out.lower()


def test_xip_compile_profile(request):
    """Phase 0.7(a): XIP hit/access over an idle window and over compiles."""
    session = request.node.stash[session_key]

    lines = []

    # An idle window first, as the baseline that says how much of what follows
    # is the compile and how much is the machine simply being switched on. The
    # wait happens on the host with the target sitting at its prompt, because
    # the toybox build carries no sleep.
    before = _read_xip(session)
    if before is None:
        pytest.skip("target publishes no /proc/xip counters")
    start = time.monotonic()
    time.sleep(1.0)
    idle_wall = time.monotonic() - start
    lines.append(_describe_window("idle at prompt", before, _read_xip(session), idle_wall))

    # /usr/hello_world.c ships in the rootfs, so this needs no upload and works
    # on a target with nothing in /root/ci. Repeated because the 0.7(b) clock
    # A/B compares wall times between two runs of this, and a difference of a
    # few percent decided by one sample would not be a measurement.
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "5"))
    walls = []
    for attempt in range(repeats):
        line, wall = _compile_window(
            session, "/usr/hello_world.c", f"compile hello_world.c #{attempt + 1}"
        )
        lines.append(line)
        walls.append(wall)
    walls.sort()
    median = walls[len(walls) // 2]
    lines.append(
        f"{'median of ' + str(repeats):<34} wall={median * 1000:9.1f} ms"
    )

    # The sweep that separates a fetch-dominated miss stream from a data one.
    # The counters cannot tell flash instruction fetches from PSRAM data
    # accesses -- one register pair counts both -- so the discriminator has to
    # come from how the miss RATE behaves across compiles of very different
    # duration and working set. Constant miss/s says the misses track executing
    # tcc's code; rising miss/s says they track the data it is chewing on.
    # Which of Phase 5.1 (code size) and Phases 3-4 (allocation volume) is the
    # lever depends entirely on the answer.
    for label, path in SWEEP_SOURCES:
        if not _remote_file_exists(session, path):
            lines.append(f"{label:<34} (absent on target, skipped)")
            continue
        # -c because most of the corpus is fragments with no main: linking them
        # measures the error path, not a compile.
        line, _ = _compile_window(session, path, label, extra_flags="-c")
        lines.append(line)

    clock_label = ("%.0f MHz" % (CORE_CLOCK_HZ / 1e6)) if CORE_CLOCK_HZ else "unknown clock"
    print("\n=== Phase 0.7(a) XIP cache profile @ %s ===" % clock_label)
    for line in lines:
        print(line)
    print(
        "acc counts every XIP access -- flash instruction fetches and PSRAM data\n"
        "alike, through one counter pair. A hit rate read here is the whole XIP\n"
        "window's, not the instruction stream's alone."
    )


def test_compile_fixed_cost(request):
    """Phase 0.1, cheap first cut: how much of a compile is paid before tcc
    reads a line of the source?

    The sweep left a hint worth chasing -- a near-empty source cost 149 ms
    against a corpus p50 of ~223 ms -- which would mean most of a median compile
    is fixed overhead: process spawn, module load (~2,200 relocations, a 43.7 KB
    bss memset, a 289-entry GOT rewrite) and tcc's own init. If that holds, 5.2
    and 5.3 outrank 5.1, and the plan's ordering changes.

    Rather than assume where the floor sits, this walks up to it one layer at a
    time and reports each step, so the arithmetic between rows *is* the
    attribution:

        cd /          harness round trip, no process spawned
        ls /tmp       + spawning and loading one small module
        tcc empty.c   + spawning and loading tcc, and tcc's own init
        tcc stdio.c   + parsing a real header
        tcc main.c    + actually generating code

    Sources live in /tmp, which 2.6 made RAM-backed, so no row here is paying
    for an SD read -- the point is to isolate spawn and init, not to re-measure
    storage.
    """
    session = request.node.stash[session_key]
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "5"))

    # Written with shell redirection rather than uploaded: these are a few bytes
    # each, /tmp is a RAM filesystem, and it avoids making the floor measurement
    # depend on the zmodem path.
    # No double quotes anywhere in these bodies, so shell single-quoting is
    # enough and nothing needs escaping through two layers.
    fixtures = [
        ("m_empty.c", ""),
        ("m_stdio.c", r" #include <stdio.h>"),
        ("m_main.c", r"#include <stdio.h>\nint main(void){return 0;}"),
    ]
    for name, body in fixtures:
        if body:
            session.write_command(f"printf '{body}\\n' > /tmp/{name}")
        else:
            session.write_command(f"printf '' > /tmp/{name}")
        session.wait_for_prompt_except_logs()

    ladder = [
        ("cd /  (no spawn)", "cd /"),
        ("ls /tmp  (small spawn)", "ls /tmp"),
    ]

    lines = []
    for label, command in ladder:
        row, _ = _median_command_wall(session, command, label, repeats)
        lines.append(row)

    walls = {}
    for name, label in (
        ("m_empty.c", "tcc -c empty source"),
        ("m_stdio.c", "tcc -c #include <stdio.h>"),
        ("m_main.c", "tcc -c trivial main()"),
    ):
        rows, samples = [], []
        for _ in range(repeats):
            row, wall = _compile_window(session, f"/tmp/{name}", label, extra_flags="-c")
            rows.append(row)
            samples.append(wall)
        order = sorted(range(len(samples)), key=lambda i: samples[i])
        middle = order[len(order) // 2]
        lines.append(rows[middle])
        walls[name] = samples[middle]

    session.write_command("rm -f /tmp/m_empty.c /tmp/m_stdio.c /tmp/m_main.c")
    session.wait_for_prompt_except_logs()

    print("\n=== Phase 0.1 (first cut): what a compile costs before it compiles ===")
    for line in lines:
        print(line)

    empty = walls.get("m_empty.c")
    if empty:
        print(
            f"\nFloor: an empty source still costs {empty * 1000:.1f} ms.\n"
            f"Header parse (stdio.h):   "
            f"{(walls['m_stdio.c'] - empty) * 1000:+.1f} ms\n"
            f"Codegen for trivial main: "
            f"{(walls['m_main.c'] - walls['m_stdio.c']) * 1000:+.1f} ms\n"
            "Against a corpus p50 of ~223 ms, the floor is the share that 5.2\n"
            "(loader prelink cache) and 5.3 (resident tcc) attack, and that 5.1\n"
            "(code footprint) does not."
        )


# One stamp row of tcc's -bench init dump: "# init <label> <delta_us> [<at_us>]".
# The "total" row carries a single number; labels contain spaces but never end
# in digits, so the lazy label group parses both shapes.
_INIT_STAMP_RE = re.compile(r"^# init\s+(.+?)\s+(\d+)(?:\s+\d+)?\s*$", re.MULTILINE)


def test_tcc_init_breakdown(request):
    """Phase 0.1, second cut: what tcc itself does during the per-compile floor.

    The 25:09 run split the 48.9 ms floor into ~7.5 ms of spawn + module load
    and ~41 ms of tcc's own initialisation -- ~184 s, 12% of the run -- and the
    plan's open question is what that 41 ms actually is. tcc now stamps a µs
    timestamp at each startup milestone (state alloc, arg parse, output-type
    setup incl. section creation, source open, preprocessor setup, predefine
    parsing, parse+codegen, ELF finish, output write, state delete) and dumps
    the deltas under -bench.

    The stamps are recorded before any bench output is written, so their values
    are not inflated by the UART cost of printing them; the envelope wall the
    suite actually pays is taken from a separate non-bench run alongside.
    """
    session = request.node.stash[session_key]
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "5"))

    session.write_command("printf '' > /tmp/m_empty.c")
    session.wait_for_prompt_except_logs()

    # The uninstrumented envelope, for the spawn/load/exit remainder below.
    _, plain_wall = _median_command_wall(
        session,
        "tcc -c /tmp/m_empty.c -o /tmp/measure.out",
        "tcc -c empty (no -bench)",
        repeats,
    )

    runs = []
    for _ in range(repeats):
        with session.timeout(COMPILE_TIMEOUT):
            session.write_command("tcc -bench -c /tmp/m_empty.c -o /tmp/measure.out")
            out = _as_text(session.wait_for_prompt_except_logs())
        phases = []
        total_us = None
        for label, delta in _INIT_STAMP_RE.findall(out):
            if label == "total":
                total_us = int(delta)
            elif label != "phase":
                phases.append((label, int(delta)))
        if phases and total_us is not None:
            runs.append((total_us, phases))

    session.write_command("rm -f /tmp/m_empty.c /tmp/measure.out")
    session.wait_for_prompt_except_logs()

    if not runs:
        pytest.skip("no '# init' stamps in output -- firmware predates them?")

    # One coherent run rather than per-phase medians, so the rows still sum to
    # the total. Chosen by total, so a one-off SD or scheduler hiccup lands in
    # the discarded samples.
    runs.sort(key=lambda item: item[0])
    total_us, phases = runs[len(runs) // 2]

    print("\n=== tcc init breakdown (median of %d, empty source) ===" % len(runs))
    for label, delta_us in phases:
        share = 100.0 * delta_us / total_us if total_us else 0.0
        print(f"{label:<24} {delta_us / 1000.0:8.2f} ms  {share:5.1f}%")
    # `bench prints` is the UART cost of the dump itself -- work the plain run
    # never does. Subtracting the raw in-main total from a non-bench envelope
    # therefore charged the printing to *neither* side and understated
    # outside-main by the whole dump (7+ ms, enough to hide a spawn regression
    # or invent one). Net it out before differencing.
    bench_print_us = sum(us for label, us in phases if label == "bench prints")
    in_main_comparable_us = total_us - bench_print_us
    print(f"{'in-main total':<24} {total_us / 1000.0:8.2f} ms")
    print(
        f"{'  of which bench prints':<24} {bench_print_us / 1000.0:8.2f} ms"
        "  <- the dump's own UART cost; the plain run below never pays it\n"
        f"{'in-main, comparable':<24} {in_main_comparable_us / 1000.0:8.2f} ms"
    )
    print(
        f"{'envelope (no -bench)':<24} {plain_wall * 1000:8.2f} ms\n"
        f"{'outside main()':<24} {plain_wall * 1000 - in_main_comparable_us / 1000.0:8.2f} ms"
        "  <- spawn, module load, crt0/libc init, exit, prompt round trip"
    )
    print(
        "totals across runs: "
        + ", ".join(f"{t / 1000.0:.2f}" for t, _ in runs)
        + " ms"
    )


def test_tcc_decls_programmatic_ab(request):
    """Programmatic builtin prototypes vs parsing the tccdecls text.

    The default configuration builds the ~58 builtin alias prototypes through
    direct Sym construction (tccgen_predef_protos); TCC_NO_PROGRAMMATIC_DECLS=1
    routes the same compile through the tccdecls_.h text instead -- the
    permanent validation knob. The delta is what the programmatic path saves;
    it was ~30 ms/compile when the text was the only path.
    """
    session = request.node.stash[session_key]
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "5"))

    fixtures = [
        ("w_empty.c", ""),
        ("w_main.c", r"int add(int a, int b) { return a + b; }\nint main(void){return add(1,2);}"),
        ("w_stdio.c", r"#include <stdio.h>\nint main(void){return 0;}"),
    ]
    for name, body in fixtures:
        if body:
            session.write_command(f"printf '{body}\\n' > /tmp/{name}")
        else:
            session.write_command(f"printf '' > /tmp/{name}")
        session.wait_for_prompt_except_logs()

    print("\n=== programmatic decls A/B (medians of %d) ===" % repeats)
    for name, _ in fixtures:
        row = {}
        for arm, prefix in (("programmatic", ""), ("text decls", "TCC_NO_PROGRAMMATIC_DECLS=1 ")):
            rows, walls = [], []
            for _ in range(repeats):
                r, wall = _command_window(
                    session,
                    f"{prefix}tcc -c /tmp/{name} -o /tmp/measure.out",
                    f"{name} {arm}",
                )
                rows.append(r)
                walls.append(wall)
            order = sorted(range(len(walls)), key=lambda i: walls[i])
            mid = order[len(order) // 2]
            row[arm] = walls[mid]
            print(rows[mid])
        print(
            f"{name:<12} programmatic {row['programmatic'] * 1000:7.1f} ms"
            f"   text {row['text decls'] * 1000:7.1f} ms"
            f"   saved {(row['text decls'] - row['programmatic']) * 1000:+7.1f} ms"
        )

    session.write_command("rm -f /tmp/w_empty.c /tmp/w_main.c /tmp/w_stdio.c /tmp/measure.out")
    session.wait_for_prompt_except_logs()


# How many extra `-D` macros each rung of the predefine ladder adds. The real
# predefine set is ~170 object-like #defines, so the top rung brackets it.
_PREDEFINE_LADDER = (0, 50, 100, 200)


def test_predefine_marginal_cost(request):
    """Is the `predef macros` phase per-macro work, or first-touch warm-up?

    The 101-test profile puts `predef macros` at a flat 17.2 ms on every
    compile -- 27% of a median compile's 63 ms and ~76 s of a full run -- for
    parsing ~170 object-like #defines that a typical torture source never
    references. That is the case for defining them lazily, but only if the
    17.2 ms is *work proportional to the macro count*. The competing
    explanation is that it is the first heavy tokenizer pass in the process
    and is really paying the XIP misses for that code, in which case skipping
    it would move the cost into the source parse rather than remove it -- and
    this plan has been wrong in exactly that direction before.

    The ladder separates them without touching the compiler: extra `-D` flags
    land in the same `<command line>` buffer, parsed by the same code, in the
    same stamped phase -- but they run *after* the built-in predefines, with
    the tokenizer already hot. A slope that matches the built-in set's
    per-macro rate says the cost is the macros; a slope near zero says it was
    the cold cache and laziness buys nothing.

    The `-D` list is parked in a shell variable first, so the timed window
    sends a short command: the shell echoes every byte of a command line back
    over the UART, and 200 inline flags would put ~80 ms of serial traffic
    inside the measurement.
    """
    session = request.node.stash[session_key]
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "5"))

    session.write_command("printf '' > /tmp/m_empty.c")
    session.wait_for_prompt_except_logs()

    # Short names keep the setup line (which *is* echoed) inside the shell's
    # comfort zone; the count is what is being varied, not the name length.
    for count in _PREDEFINE_LADDER:
        defs = " ".join(f"-DA{i}=1" for i in range(count))
        session.write_command(f"D{count}='{defs}'")
        session.wait_for_prompt_except_logs()

    rows, walls = [], {}
    for count in _PREDEFINE_LADDER:
        samples = []
        for _ in range(repeats):
            row, wall = _command_window(
                session,
                f"tcc -c $D{count} /tmp/m_empty.c -o /tmp/measure.out",
                f"empty + {count} -D",
            )
            samples.append((wall, row))
        samples.sort(key=lambda item: item[0])
        wall, row = samples[len(samples) // 2]
        walls[count] = wall
        rows.append(row)

    # One instrumented run at each end, to confirm the delta lands in the
    # phase this is reasoning about rather than somewhere else.
    stamps = {}
    for count in (_PREDEFINE_LADDER[0], _PREDEFINE_LADDER[-1]):
        with session.timeout(COMPILE_TIMEOUT):
            session.write_command(
                f"tcc -bench -c $D{count} /tmp/m_empty.c -o /tmp/measure.out"
            )
            out = _as_text(session.wait_for_prompt_except_logs())
        stamps[count] = {
            label: int(delta)
            for label, delta in _INIT_STAMP_RE.findall(out)
            if label not in ("phase", "total")
        }

    session.write_command("rm -f /tmp/m_empty.c /tmp/measure.out")
    session.wait_for_prompt_except_logs()

    clock = ("%.0f MHz" % (CORE_CLOCK_HZ / 1e6)) if CORE_CLOCK_HZ else "unknown clock"
    print("\n=== marginal cost of a predefined macro @ %s ===" % clock)
    for row in rows:
        print("  " + row)

    base = walls[_PREDEFINE_LADDER[0]]
    print("\nwall vs macro count (medians of %d):" % repeats)
    for count in _PREDEFINE_LADDER:
        extra = walls[count] - base
        per = (extra / count * 1e6) if count else 0.0
        print(
            f"  {count:>4} extra -D   {walls[count] * 1000:8.2f} ms"
            f"   {extra * 1000:+7.2f} ms   {per:6.1f} us/macro"
        )

    top = _PREDEFINE_LADDER[-1]
    slope_us = (walls[top] - base) / top * 1e6 if top else 0.0
    print(
        f"\nslope {slope_us:.1f} us/macro -> the ~170 built-in predefines "
        f"account for {slope_us * 170 / 1000:.1f} ms at this rate."
    )
    if stamps:
        print("\n`predef macros` stamp, instrumented runs:")
        for count in sorted(stamps):
            phase = stamps[count].get("predef macros")
            print(
                f"  {count:>4} extra -D   "
                + (f"{phase / 1000.0:8.2f} ms" if phase is not None else "   absent")
            )
    print(
        "\nRead it against the measured 17.2 ms: a slope*170 near that figure\n"
        "means the phase is macro work and can be made lazy; a slope near zero\n"
        "means it was the tokenizer's first touch and the cost would relocate."
    )


def test_predefine_skip_ab(request):
    """How much of the `predef macros` phase is recoverable, not relocated?

    The phase is 17.2 ms on every compile. Whether that is 17.2 ms of
    *opportunity* depends on where the cost lives: if it is the tokenizer's
    and symbol table's first touch, skipping the text moves the cold-fetch
    into whatever parses next instead of removing it. The 2026-08-04 probe
    put the non-relocating share of a then-12 ms phase at ~5 ms and declined
    the pre-tokenized-table fix on that basis -- but that predates the .text
    footprint round and the flash transaction round, both of which changed
    what a cold fetch costs.

    TCC_SKIP_PREDEF_MACROS=1 drops the 7.2 KB tccdefs block, so one firmware
    carries both arms. The two deltas answer different questions and only
    their gap is interesting:

      stamp delta  -- what the phase itself loses (its full size)
      wall delta   -- what the compile actually keeps

    Sources with rising demands on the predefines, because a lazy scheme pays
    for what a source uses: the empty file uses none, `main()` uses none, and
    the stdio compile drags in whatever the sysroot header references.
    """
    session = request.node.stash[session_key]
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "5"))

    fixtures = [
        ("p_empty.c", ""),
        ("p_main.c", r"int main(void){return 0;}"),
        ("p_stdio.c", r"#include <stdio.h>\nint main(void){return 0;}"),
    ]
    for name, body in fixtures:
        if body:
            session.write_command(f"printf '{body}\\n' > /tmp/{name}")
        else:
            session.write_command(f"printf '' > /tmp/{name}")
        session.wait_for_prompt_except_logs()

    def predef_stamp(prefix, name):
        with session.timeout(COMPILE_TIMEOUT):
            session.write_command(
                f"{prefix}tcc -bench -c /tmp/{name} -o /tmp/measure.out"
            )
            out = _as_text(session.wait_for_prompt_except_logs())
        stamps = {
            label: int(delta) for label, delta in _INIT_STAMP_RE.findall(out)
        }
        return stamps.get("predef macros"), stamps.get("total")

    print("\n=== predefine skip A/B (medians of %d) ===" % repeats)
    rows = []
    for name, _ in fixtures:
        arms = {}
        for arm, prefix in (("with", ""), ("skipped", "TCC_SKIP_PREDEF_MACROS=1 ")):
            walls = []
            for _ in range(repeats):
                row, wall = _command_window(
                    session,
                    f"{prefix}tcc -c /tmp/{name} -o /tmp/measure.out",
                    f"{name} predefines {arm}",
                )
                walls.append(wall)
                rows.append(row)
            walls.sort()
            stamp, total = predef_stamp(prefix, name)
            arms[arm] = (walls[len(walls) // 2], stamp, total)

        (w_with, s_with, t_with) = arms["with"]
        (w_skip, s_skip, t_skip) = arms["skipped"]
        stamp_delta = ((s_with or 0) - (s_skip or 0)) / 1000.0
        wall_delta = (w_with - w_skip) * 1000.0
        kept = (100.0 * wall_delta / stamp_delta) if stamp_delta else 0.0
        print(
            f"\n{name}\n"
            f"  wall   with {w_with * 1000:8.2f} ms   skipped {w_skip * 1000:8.2f} ms"
            f"   -> {wall_delta:+7.2f} ms\n"
            f"  stamp  with {(s_with or 0) / 1000.0:8.2f} ms   skipped"
            f" {(s_skip or 0) / 1000.0:8.2f} ms   -> {stamp_delta:+7.2f} ms\n"
            f"  in-main with {(t_with or 0) / 1000.0:8.2f} ms   skipped"
            f" {(t_skip or 0) / 1000.0:8.2f} ms\n"
            f"  recovered {kept:5.1f}% of what the phase gave up"
            f"  ({stamp_delta - wall_delta:+.2f} ms relocated)"
        )

    # The doubling arm. The skip arm above can leave the compile erroring out
    # (a source that needs a predefine, or the device build's own buffer), and
    # a compile that bailed has skipped work beyond the phase -- so its wall
    # delta is an upper bound. Appending a second identical copy of the block
    # cannot fail that way: identical redefinition is legal, the compile ends
    # the same way it would have, and the extra copy is parsed with everything
    # already hot. Its cost is therefore the warm price of the content, and
    # first_copy - second_copy is the first-touch component that a lazy scheme
    # would relocate instead of remove.
    print("\ndoubling arm (second identical copy of the tccdefs block):")
    for name, _ in fixtures:
        single_stamp, _ = predef_stamp("", name)
        double_stamp, _ = predef_stamp("TCC_DOUBLE_PREDEF_MACROS=1 ", name)
        walls = []
        for _ in range(repeats):
            _, wall = _command_window(
                session,
                f"TCC_DOUBLE_PREDEF_MACROS=1 tcc -c /tmp/{name} -o /tmp/measure.out",
                f"{name} predefines doubled",
            )
            walls.append(wall)
        walls.sort()
        second = ((double_stamp or 0) - (single_stamp or 0)) / 1000.0
        first = (single_stamp or 0) / 1000.0
        print(
            f"  {name:<12} first copy {first:7.2f} ms   second copy {second:7.2f} ms"
            f"   first-touch {first - second:+7.2f} ms"
            f"   (doubled wall {walls[len(walls) // 2] * 1000:7.2f} ms)"
        )

    print("\nwindows:")
    for row in rows:
        print("  " + row)

    session.write_command("rm -f /tmp/p_empty.c /tmp/p_main.c /tmp/p_stdio.c /tmp/measure.out")
    session.wait_for_prompt_except_logs()


def test_fs_syscall_microbench(request):
    """Split the remaining floor slices: tmpfs operations vs raw syscall cost.

    Compiles a microbenchmark on the device with the on-target tcc and runs
    it. gettimeofday-in-a-loop prices a light syscall; open/write/close/unlink
    loops price the tmpfs file lifecycle the compiler's output path pays; a
    /root variant prices the SD-backed path for contrast.
    """
    session = request.node.stash[session_key]

    src = "\n".join([
        "#include <stdio.h>",
        "#include <sys/time.h>",
        "#include <fcntl.h>",
        "#include <unistd.h>",
        "static long us(void){struct timeval tv;gettimeofday(&tv,0);return tv.tv_sec*1000000L+tv.tv_usec;}",
        "static char buf[2048];",
        "int main(void){",
        "  long t0,t1;int i,fd;",
        "  t0=us();for(i=0;i<2000;i++)us();t1=us();",
        '  printf("gettimeofday_ns %ld\\n",(t1-t0)*1000/2000);',
        '  t0=us();for(i=0;i<200;i++){fd=open("/tmp/bx",O_WRONLY|O_CREAT|O_TRUNC,0644);close(fd);}t1=us();',
        '  printf("tmp_creat_close_us %ld\\n",(t1-t0)/200);',
        '  fd=open("/tmp/bx",O_WRONLY|O_CREAT|O_TRUNC,0644);',
        "  t0=us();for(i=0;i<500;i++)write(fd,buf,2048);t1=us();close(fd);",
        '  printf("tmp_write2k_us %ld\\n",(t1-t0)/500);',
        '  t0=us();for(i=0;i<100;i++){fd=open("/tmp/bx",O_RDONLY);close(fd);}t1=us();',
        '  printf("tmp_open_close_us %ld\\n",(t1-t0)/100);',
        '  t0=us();for(i=0;i<100;i++){fd=open("/tmp/bx",O_WRONLY|O_CREAT|O_TRUNC,0644);write(fd,buf,2048);close(fd);unlink("/tmp/bx");}t1=us();',
        '  printf("tmp_lifecycle_us %ld\\n",(t1-t0)/100);',
        '  t0=us();for(i=0;i<20;i++){fd=open("/root/bx",O_WRONLY|O_CREAT|O_TRUNC,0644);write(fd,buf,2048);close(fd);unlink("/root/bx");}t1=us();',
        '  printf("sd_lifecycle_us %ld\\n",(t1-t0)/20);',
        "  return 0;",
        "}",
        "",
    ])
    import tempfile
    from .framework.file_transfer import send_file as _send_file
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as fh:
        fh.write(src)
        local = fh.name
    _send_file(session, local, "/tmp/bench.c")
    os.unlink(local)

    with session.timeout(COMPILE_TIMEOUT):
        session.write_command("tcc /tmp/bench.c -o /tmp/bench")
        out = _as_text(session.wait_for_prompt_except_logs())
    if "error" in out.lower():
        print(out)
        session.write_command("cat /tmp/bench.c")
        print(_as_text(session.wait_for_prompt_except_logs()))
        pytest.skip("bench compile failed")

    with session.timeout(COMPILE_TIMEOUT):
        session.write_command("/tmp/bench")
        out = _as_text(session.wait_for_prompt_except_logs())
    print("\n=== fs/syscall microbench ===")
    for line in out.splitlines():
        if "_us " in line or "_ns " in line:
            print(line.strip())

    session.write_command("rm -f /tmp/bench.c /tmp/bench /tmp/bx")
    session.wait_for_prompt_except_logs()


def test_tcc_rehearsal_ab(request):
    """Price the rehearsal codegen walk: TCC_NO_REHEARSAL=1 skips it, losing
    CBZ and forward-branch narrowing. Reports compile time and object size per
    arm, and executes two runtime tests under the knob as a correctness sample
    (output legitimately differs, so byte-identity does not apply here)."""
    session = request.node.stash[session_key]
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "3"))

    sources = [
        ("20040709-3", "/root/ci/sources/gcc_torture/execute/20040709-3.c"),
        ("strlen-5", "/root/ci/sources/gcc_torture/execute/strlen-5.c"),
        ("95_bitfields", "/root/ci/sources/tests2/95_bitfields.c"),
        ("rijndael", "/root/ci/sources/ir_tests/mibench_rijndael.c"),
    ]

    def obj_size(path):
        session.write_command(f"ls -l {path}")
        out = _as_text(session.wait_for_prompt_except_logs())
        # toybox ls -l: pick the largest number on the line -- the size field
        # dwarfs link counts and date components for these objects
        nums = [int(x) for x in re.findall(r"\d+", out)]
        return max(nums) if nums else -1

    print("\n=== rehearsal A/B (medians of %d) ===" % repeats)
    for name, src in sources:
        if not _remote_file_exists(session, src):
            print(f"{name:<14} (absent, skipped)")
            continue
        row = {}
        for arm, prefix in (("base", ""), ("skip", "TCC_NO_REHEARSAL=1 ")):
            walls = []
            for _ in range(repeats):
                _, wall = _command_window(
                    session, f"{prefix}tcc -c {src} -o /tmp/m.o", f"{name} {arm}"
                )
                walls.append(wall)
            walls.sort()
            row[arm] = (walls[len(walls) // 2], obj_size("/tmp/m.o"))
        (bw, bs), (sw, ss) = row["base"], row["skip"]
        print(
            f"{name:<14} base {bw*1000:8.1f} ms {bs:7d} B"
            f"   skip {sw*1000:8.1f} ms {ss:7d} B"
            f"   dt {(sw-bw)*1000:+7.1f} ms  dsize {ss-bs:+6d} B ({100.0*(ss-bs)/bs if bs>0 else 0:+.2f}%)"
        )

    for name, src in sources[:2]:
        with session.timeout(COMPILE_TIMEOUT):
            session.write_command(f"TCC_NO_REHEARSAL=1 tcc {src} -o /tmp/m.exe")
            session.wait_for_prompt_except_logs()
        with session.timeout(COMPILE_TIMEOUT):
            session.write_command("/tmp/m.exe; echo RC=$?")
            out = _as_text(session.wait_for_prompt_except_logs())
        ok = "RC=0" in out
        print(f"execute {name:<14} under skip: {'OK' if ok else 'FAILED: ' + out[-120:]}")

    session.write_command("rm -f /tmp/m.o /tmp/m.exe")
    session.wait_for_prompt_except_logs()


def test_sd_throughput_floor(request):
    """Phase 0.8: sequential and small-random read/write against the SD path."""
    session = request.node.stash[session_key]

    size_kib = os.environ.get("YASOS_SMOKE_MEASURE_SD_KIB", "1024")
    with session.timeout(COMPILE_TIMEOUT):
        session.write_command(f"sdbench -s {size_kib} {SCRATCH_DIR}")
        out = session.read_until_prompt()

    print("\n=== Phase 0.8 SD throughput floor (%s) ===" % SCRATCH_DIR)
    print(out)


def test_malloc_microbench(request):
    """Price the userspace allocator, so allocation *counts* can be converted
    into milliseconds.

    The allocator round cut the mapping count per compile; what it did not
    measure is what the remaining calls cost. A compile of the heaviest corpus
    source makes ~203,000 malloc/free pairs, three quarters of them 16-byte
    token-string buffers (tccpp.c tok_str_ensure_heap), so a per-call cost of
    even a microsecond is worth a fifth of a second on that file. This prices
    each path separately, because the fixes differ: the pool path is libc code
    the compiler executes through the XIP cache, the mapping path is a kernel
    entry plus a page clear.

    Sizes are chosen from the measured allocation profile of a compile:
    16 B (the token-string buffers), 256 B (the pool's ordinary traffic),
    8 KiB (a section/sym-pool growth step) and 48 KiB (the TinyAlloc arenas,
    above any pool threshold and therefore always a mapping).
    """
    session = request.node.stash[session_key]

    src = "\n".join([
        "#include <stdio.h>",
        "#include <stdlib.h>",
        "#include <string.h>",
        "#include <sys/time.h>",
        "#include <sys/mman.h>",
        "static long us(void){struct timeval tv;gettimeofday(&tv,0);return tv.tv_sec*1000000L+tv.tv_usec;}",
        "static void *keep[64];",
        "int main(void){",
        "  long t0,t1;int i,j;void *p;",
        # A malloc/free pair that immediately reuses the same free-list block:
        # the cheapest possible path, and the one tok_str_ensure_heap takes.
        "  t0=us();for(i=0;i<20000;i++){p=malloc(16);free(p);}t1=us();",
        '  printf("pair16_ns %ld\\n",(t1-t0)*1000/20000);',
        "  t0=us();for(i=0;i<20000;i++){p=malloc(256);free(p);}t1=us();",
        '  printf("pair256_ns %ld\\n",(t1-t0)*1000/20000);',
        # 64 live at a time, so the free list is exercised rather than one hot
        # block being handed back over and over.
        "  t0=us();for(i=0;i<10000;i++){j=i&63;free(keep[j]);keep[j]=malloc(16+(i&127));}t1=us();",
        '  printf("live64_ns %ld\\n",(t1-t0)*1000/10000);',
        "  for(j=0;j<64;j++){free(keep[j]);keep[j]=0;}",
        # Growth by doubling, the shape every dynarray/section in tcc has.
        "  t0=us();for(i=0;i<200;i++){int n;p=0;for(n=64;n<=8192;n<<=1)p=realloc(p,n);free(p);}t1=us();",
        '  printf("grow64to8k_us %ld\\n",(t1-t0)/200);',
        "  t0=us();for(i=0;i<200;i++){p=malloc(8192);memset(p,0,8192);free(p);}t1=us();",
        '  printf("alloc8k_us %ld\\n",(t1-t0)/200);',
        "  t0=us();for(i=0;i<100;i++){p=malloc(48*1024);free(p);}t1=us();",
        '  printf("alloc48k_us %ld\\n",(t1-t0)/100);',
        # The syscall underneath, unmediated by libc's pool or mapping cache.
        "  t0=us();for(i=0;i<100;i++){p=mmap(0,8192,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);munmap(p,8192);}t1=us();",
        '  printf("mmap8k_pair_us %ld\\n",(t1-t0)/100);',
        "  t0=us();for(i=0;i<50;i++){p=mmap(0,64*1024,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);munmap(p,64*1024);}t1=us();",
        '  printf("mmap64k_pair_us %ld\\n",(t1-t0)/50);',
        "  return 0;",
        "}",
        "",
    ])
    import tempfile
    from .framework.file_transfer import send_file as _send_file
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as fh:
        fh.write(src)
        local = fh.name
    _send_file(session, local, "/tmp/mbench.c")
    os.unlink(local)

    with session.timeout(COMPILE_TIMEOUT):
        session.write_command("tcc /tmp/mbench.c -o /tmp/mbench")
        out = _as_text(session.wait_for_prompt_except_logs())
    if "error" in out.lower():
        print(out)
        pytest.skip("malloc bench compile failed")

    with session.timeout(COMPILE_TIMEOUT):
        session.write_command("/tmp/mbench")
        out = _as_text(session.wait_for_prompt_except_logs())
    print("\n=== allocator microbench @ %s ===" % (
        ("%.0f MHz" % (CORE_CLOCK_HZ / 1e6)) if CORE_CLOCK_HZ else "unknown clock"))
    for line in out.splitlines():
        if "_us " in line or "_ns " in line:
            print(line.strip())

    session.write_command("rm -f /tmp/mbench.c /tmp/mbench")
    session.wait_for_prompt_except_logs()


def test_hello_world_breakdown(request):
    """Everything one small compile spends its time on, in one report.

    The corpus-wide profile answers "where does a 4,449-compile run go"; this
    answers "where does *one* compile go", which is the question you want when
    deciding what to work on next. It measures the same compile four ways and
    prints the pieces side by side:

      - clean wall, median of N, with no instrumentation in the picture;
      - the same for a one-declaration source, which is the fixed cost every
        compile pays before it looks at the program (spawn, module load, tcc
        init, predefines, output);
      - preprocess-only, splitting the frontend off the backend;
      - one -bench run, which adds tcc's own phase table, startup stamps,
        allocation sites and the kernel's per-syscall profile -- and costs
        ~76 ms of serial output to print, which is why it is not the run the
        wall figures come from.

    XIP hit/miss counters bracket every window, so the fetch-stall term is
    visible next to the work.
    """
    session = request.node.stash[session_key]
    repeats = int(os.environ.get("YASOS_SMOKE_MEASURE_REPEATS", "7"))

    # A one-declaration TU: the smallest thing that still goes all the way
    # through to an object file, so the difference against hello_world is that
    # source's own work and nothing else.
    import tempfile
    from .framework.file_transfer import send_file as _send_file
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as fh:
        fh.write("int x;\n")
        local = fh.name
    _send_file(session, local, "/tmp/min.c")
    os.unlink(local)

    lines = []

    def window(command, label):
        row, wall = _command_window(session, command, label)
        lines.append(row)
        return wall

    def median_window(command, label):
        walls = []
        for i in range(repeats):
            walls.append(window(command, f"{label} #{i + 1}"))
        walls.sort()
        return walls[len(walls) // 2]

    hello = median_window("tcc -c /usr/hello_world.c -o /tmp/hw.o", "hello_world -c")
    session.write_command("rm -f /tmp/hw.o")
    session.wait_for_prompt_except_logs()

    minimal = median_window("tcc -c /tmp/min.c -o /tmp/min.o", "int x; -c")
    session.write_command("rm -f /tmp/min.o")
    session.wait_for_prompt_except_logs()

    preprocess = median_window("tcc -E /usr/hello_world.c -o /tmp/hw.i",
                               "hello_world -E")
    session.write_command("rm -f /tmp/hw.i")
    session.wait_for_prompt_except_logs()

    # The instrumented run. Everything tcc knows about itself comes out here;
    # the numbers above are what it costs when nobody is watching.
    with session.timeout(COMPILE_TIMEOUT):
        session.write_command("tcc -bench -c /usr/hello_world.c -o /tmp/hw.o")
        bench = _as_text(session.wait_for_prompt_except_logs())
    session.write_command("rm -f /tmp/hw.o")
    session.wait_for_prompt_except_logs()

    session.write_command("cat /proc/meminfo")
    meminfo = _as_text(session.read_until_prompt())

    clock = ("%.0f MHz" % (CORE_CLOCK_HZ / 1e6)) if CORE_CLOCK_HZ else "unknown clock"
    print("\n=== one hello_world compile, in pieces @ %s ===" % clock)
    print("windows (wall includes the shell spawn and the prompt coming back):")
    for line in lines:
        print("  " + line)

    print("\nsummary (medians of %d):" % repeats)
    print(f"  hello_world -c                 {hello * 1000:9.1f} ms")
    print(f"  int x; -c   (fixed cost)       {minimal * 1000:9.1f} ms"
          f"   = {100.0 * minimal / hello if hello else 0:.0f}% of it")
    print(f"  hello_world -E (preprocess)    {preprocess * 1000:9.1f} ms")
    print(f"  this source's own work         {(hello - minimal) * 1000:9.1f} ms")

    print("\ntcc -bench (one run; its own printing is fenced by the last stamp):")
    for line in bench.splitlines():
        if line.startswith("# "):
            print("  " + line)

    print("\n/proc/meminfo after the run:")
    for line in meminfo.splitlines():
        if ":" in line:
            print("  " + line.strip())
    print("\nThe kernel's own rows for these processes (loader phases, page-pool\n"
          "phases and per-tier clear rates) are in this test's serial transcript\n"
          "under .cache/remote_smoke_logs; grep '[ERR][tprof]'.")

    session.write_command("rm -f /tmp/min.c")
    session.wait_for_prompt_except_logs()
