#!/usr/bin/env python3
"""What the three tcc suites cost on the board, best of N runs.

The speedup plan is measured in wall time of a hardware run, and a single run
is not a measurement: the same firmware on the same board varies with SD card
state, serial retries, and whichever test happens to hit a slow path twice. The
convention this script implements is the usual answer to that — **run it N
times and keep the fastest** — because the minimum is the one summary statistic
that noise can only move in one direction. A mean drags in every retry storm; a
median still does. The fastest run is the closest thing to "what this firmware
does when nothing goes wrong", which is what an A/B between two firmwares is
trying to compare.

Three suites and no others: **tests2**, **ir_tests** and **gcc_execute**. What
is deliberately left out is `gcc_compile`, which is 2003 of the 4525 cases at
one -O level and compiles without ever running the result — it is a compiler
crash-check, so it moves with compile cost alone and dilutes exactly the
execute-side numbers this is pointed at. The selection is a pytest file plus one
marker exclusion (:data:`SUITE_PYTEST_ARGS`), so it cannot drift out of step
with what the suites are called.

**This runs on the board, and only on the board.** Every number here comes from
`scripts/remote_smoke_tui.py` driving the real RP2350 over SSH — there is no
QEMU path and no host fallback, because the whole point of the measurement is
the hardware: the XIP cache, the flash transactions and the SD write path are
where the time goes, and none of them exist in an emulator. A configuration
that does not name an SSH target is refused rather than quietly measuring
something else.

What is ranked is the **remote pytest phase** — `finished - started` out of the
run's own `run_info.txt` — not this script's wall time. The first run of a
session builds and flashes and the ones after it do not, and comparing a run
that flashed against one that did not would measure the flash. Those two stamps
are `date -Iseconds` on the board host, so the ranking has one-second
resolution: nothing against a run of ten or twenty minutes, but it means a
`-k`-narrowed smoke check of a few seconds can legitimately report a tie.

Usage::

    scripts/bench_tcc_suites.py                     # 3 runs, cached opt levels
    scripts/bench_tcc_suites.py -n 5 --opt-levels -O0
    scripts/bench_tcc_suites.py --dry-run           # print what it would run
    scripts/bench_tcc_suites.py -- --force          # pass --force to the TUI

Results land under ``.cache/tcc_suite_bench/<timestamp>/``: a ``summary.json``
with every run, and ``fastest/`` holding the winning run's artifacts, copied so
that the remote's own pruning (``keep_runs``) cannot take the baseline away.

No caching or batching mode is enabled here, and none may be: the speedup plan
locks validation runs to one-shot, cache-off, and a baseline measured with a
compile cache warm is not a baseline.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent

sys.path.insert(0, str(SCRIPT_DIR))

import remote_smoke_tui as tui  # noqa: E402

#: The three suites, as pytest says them. Everything the tcc corpus runs lives
#: in one file, so naming the file and dropping one marker is the whole
#: selection: `tests2` and `ir_tests` carry no marker of their own, and
#: `gcc_execute` is what is left of gcc-torture once the compile-only half is
#: excluded. Written as a string because that is what `--pytest-args` takes.
SUITE_PYTEST_ARGS = "tests/smoke/tcc_suite_test.py -m 'not gcc_compile'"

#: Enough repeats for a minimum to mean something, few enough to finish. Three
#: is the smallest N where one bad run cannot be the answer.
DEFAULT_REPEATS = 3

#: Where a run's artifacts are kept once it has won, out of reach of the
#: remote's own log pruning.
BENCH_ROOT = REPO_ROOT / ".cache" / "tcc_suite_bench"

#: The categories the timing report splits the corpus into, in the order they
#: are reported. `gcc_compile` is here so a run that somehow collected it is
#: visible rather than silently folded into the total.
CATEGORIES = ("tests2", "ir_tests", "gcc_execute", "gcc_compile")


@dataclass
class RunResult:
    """One hardware run: how long it took, and what it did."""

    index: int
    run_id: int | None = None
    #: The remote pytest phase, out of run_info.txt. What runs are ranked on.
    suite_seconds: float | None = None
    #: This script's own view: build, flash, upload and the run together.
    harness_seconds: float = 0.0
    #: pytest's exit code as the remote recorded it. 0 is a clean run.
    status: int | None = None
    passed: int | None = None
    failed: int | None = None
    skipped: int | None = None
    #: Per-category on-target milliseconds, from tcc_timing_report.json.
    categories: dict[str, dict[str, float]] = field(default_factory=dict)
    total_tests: int | None = None
    kernel_sha: str = ""
    rootfs_sha: str = ""
    git_rev: str = ""
    log_dir: Path | None = None
    transcript: Path | None = None

    @property
    def clean(self) -> bool:
        """Whether this run is fit to be a baseline.

        A run with failures in it is not comparable with a run without them:
        a failed test is a test that stopped early, or retried, or took a
        board reset with it, and each of those moves the wall time in a
        direction that has nothing to do with the firmware being measured.
        """
        return self.status == 0 and not self.failed

    @property
    def ranked_seconds(self) -> float:
        """The number this run is ranked on, or infinity if it produced none."""
        if self.suite_seconds is None:
            return float("inf")
        return self.suite_seconds


def format_duration(seconds: float | None) -> str:
    """``12:34`` for a run, ``45.6s`` for anything under a minute."""
    if seconds is None:
        return "—"
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes, rest = divmod(int(round(seconds)), 60)
    return f"{minutes}:{rest:02d}"


# ------------------------------------------------------------------ #
#  Reading what a run left behind                                     #
# ------------------------------------------------------------------ #


def parse_run_info(path: Path) -> dict[str, str]:
    """``run_info.txt`` as a dict, tolerating a run that never finished.

    The file is written in two halves — the header before pytest starts and
    ``finished``/``status`` after it exits — so a killed run leaves a readable
    file with the second half missing. That is a result too (it says the run
    did not complete) and is worth more than an exception.
    """
    info: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return info
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            info[key.strip()] = value.strip()
    return info


def suite_seconds_from(info: dict[str, str]) -> float | None:
    """How long the remote pytest phase took, in seconds.

    Both stamps are ``date -Iseconds`` on the remote host, so they share a
    clock and a timezone and the subtraction is honest even when this machine's
    clock is not.
    """
    started, finished = info.get("started"), info.get("finished")
    if not started or not finished:
        return None
    try:
        return (
            datetime.fromisoformat(finished) - datetime.fromisoformat(started)
        ).total_seconds()
    except ValueError:
        return None


def parse_timing_report(path: Path) -> tuple[dict[str, dict[str, float]], int | None]:
    """Per-category on-target milliseconds out of ``tcc_timing_report.json``.

    Categorised the same way ``tests/smoke/timing.py`` does it — by the prefix
    of the test id — rather than by re-deriving it from the nodeid, so the
    split here and the split the suite prints at the end of a run cannot
    disagree.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}, None

    categories: dict[str, dict[str, float]] = {}
    for case in data.get("tests") or []:
        test_id = str(case.get("test_id", ""))
        if test_id.startswith("ir_tests/"):
            name = "ir_tests"
        elif test_id.startswith("gcc_compile/"):
            name = "gcc_compile"
        elif test_id.startswith("gcc_execute/"):
            name = "gcc_execute"
        else:
            name = "tests2"
        bucket = categories.setdefault(name, {"tests": 0.0, "compile_ms": 0.0, "execute_ms": 0.0})
        bucket["tests"] += 1
        bucket["compile_ms"] += float(case.get("compile_ms", 0.0) or 0.0)
        bucket["execute_ms"] += float(case.get("execute_ms", 0.0) or 0.0)

    summary = data.get("summary") or {}
    total_tests = summary.get("total_tests")
    return categories, int(total_tests) if isinstance(total_tests, int) else None


#: The words pytest counts things with on its final line, e.g.
#: ``=== 2489 passed, 33 skipped in 622.13s ===``.
_COUNT_WORDS = ("passed", "failed", "skipped", "error", "errors", "xfailed", "xpassed")


def parse_pytest_counts(transcript: Path | None) -> tuple[int | None, int | None, int | None]:
    """Passed / failed / skipped, read back out of the run's transcript.

    Scanned from the end for the last line that pairs a number with one of
    pytest's own count words, which is its summary line whatever decoration the
    terminal put around it. A regex over the whole line would have to know the
    order and the separators; the numbers are simply the token before each word.

    The authoritative pass-or-fail signal is the exit status the remote
    recorded — this is for the report, so a summary line that never arrived is
    three ``None`` rather than a failure.
    """
    if transcript is None or not transcript.is_file():
        return None, None, None
    try:
        lines = transcript.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None, None, None

    for line in reversed(lines):
        tokens = line.replace(",", " ").replace("=", " ").split()
        counts: dict[str, int] = {}
        for position, token in enumerate(tokens):
            if token not in _COUNT_WORDS or position == 0:
                continue
            try:
                counts[token] = int(tokens[position - 1])
            except ValueError:
                continue
        if counts:
            errors = counts.get("error", 0) + counts.get("errors", 0)
            failed = counts.get("failed", 0) + errors
            return (
                counts.get("passed"),
                failed if ("failed" in counts or errors) else None,
                counts.get("skipped"),
            )
    return None, None, None


def run_ids_in(mirror: Path) -> set[int]:
    """The numbered run directories currently in the local mirror."""
    if not mirror.is_dir():
        return set()
    ids: set[int] = set()
    for entry in mirror.iterdir():
        if entry.is_dir() and not entry.is_symlink() and entry.name.isdigit():
            ids.add(int(entry.name))
    return ids


# ------------------------------------------------------------------ #
#  Running one                                                        #
# ------------------------------------------------------------------ #


def build_command(args: argparse.Namespace) -> list[str]:
    """The `remote_smoke_tui.py` invocation one repeat is.

    ``--run-cached`` rather than the TUI, because a benchmark that stops to ask
    which board it is talking to is not one that can be left running.
    """
    cmd = [
        sys.executable,
        str(SCRIPT_DIR / "remote_smoke_tui.py"),
        "--run-cached",
        "--with-gcc-torture",
        "--pytest-args",
        SUITE_PYTEST_ARGS,
    ]
    if args.opt_levels:
        cmd += ["--smoke-tcc-opt-levels", args.opt_levels]
    if args.keyword:
        cmd += ["-k", args.keyword]
    # Retries turn a flaky failure into a slower pass, which is exactly the
    # thing a wall-time measurement must not silently absorb.
    cmd += ["--test-retries", str(args.test_retries)]
    cmd += args.passthrough
    return cmd


def run_once(args: argparse.Namespace, index: int, mirror: Path, out_dir: Path) -> RunResult:
    """One hardware run, and everything it can be asked about afterwards."""
    result = RunResult(index=index)
    before = run_ids_in(mirror)

    cmd = build_command(args)
    transcript = out_dir / f"run-{index}.log"
    print(f"\n=== run {index}/{args.repeats} — {tui.command_string(cmd)}", flush=True)

    started = time.monotonic()
    with transcript.open("w", encoding="utf-8") as sink:
        process = subprocess.Popen(
            cmd,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            sink.write(line)
        process.wait()
    result.harness_seconds = time.monotonic() - started
    result.transcript = transcript

    # Which directory this run wrote is whichever one is new. Taken from the
    # mirror rather than from `latest`, which a concurrent run would move.
    new_ids = sorted(run_ids_in(mirror) - before)
    log_dir = mirror / str(new_ids[-1]) if new_ids else None
    if log_dir is None:
        print(f"!! run {index}: no new run directory under {mirror}", file=sys.stderr)
        return result

    result.log_dir = log_dir
    info = parse_run_info(log_dir / "run_info.txt")
    result.run_id = int(info["run_id"]) if info.get("run_id", "").isdigit() else None
    result.suite_seconds = suite_seconds_from(info)
    result.status = int(info["status"]) if info.get("status", "").lstrip("-").isdigit() else None
    result.kernel_sha = info.get("kernel_sha", "")
    result.rootfs_sha = info.get("rootfs_sha", "")
    result.git_rev = info.get("git_rev", "")
    result.categories, result.total_tests = parse_timing_report(log_dir / "tcc_timing_report.json")
    result.passed, result.failed, result.skipped = parse_pytest_counts(transcript)
    return result


# ------------------------------------------------------------------ #
#  Reporting                                                          #
# ------------------------------------------------------------------ #


def print_table(results: list[RunResult], fastest: RunResult | None) -> None:
    print("\n" + "=" * 78)
    print("tcc suites on hardware — tests2 + ir_tests + gcc_execute")
    print("=" * 78)
    print(f"{'run':>4} {'id':>4} {'suite':>9} {'harness':>9} {'tests':>7} "
          f"{'passed':>7} {'failed':>7} {'':>2}")
    print("-" * 78)
    for result in results:
        mark = "*" if result is fastest else ""
        print(
            f"{result.index:>4} "
            f"{result.run_id if result.run_id is not None else '—':>4} "
            f"{format_duration(result.suite_seconds):>9} "
            f"{format_duration(result.harness_seconds):>9} "
            f"{result.total_tests if result.total_tests is not None else '—':>7} "
            f"{result.passed if result.passed is not None else '—':>7} "
            f"{result.failed if result.failed is not None else '—':>7} "
            f"{mark:>2}"
        )

    if fastest is None:
        print("\nNo run produced a time to rank.")
        return

    print(f"\nfastest: run {fastest.index} (remote run id {fastest.run_id}) — "
          f"{format_duration(fastest.suite_seconds)}")

    times = [r.suite_seconds for r in results if r.suite_seconds is not None]
    if len(times) > 1:
        spread = (max(times) - min(times)) / min(times) * 100.0
        print(f"spread:  {format_duration(min(times))} .. {format_duration(max(times))} "
              f"({spread:.1f}% over the fastest)")

    if fastest.categories:
        print("\non-target time in the fastest run:")
        print(f"  {'category':<14} {'tests':>7} {'compile':>10} {'execute':>10} {'total':>10}")
        print(f"  {'-' * 54}")
        for name in CATEGORIES:
            bucket = fastest.categories.get(name)
            if not bucket:
                continue
            compile_s = bucket["compile_ms"] / 1000.0
            execute_s = bucket["execute_ms"] / 1000.0
            print(f"  {name:<14} {int(bucket['tests']):>7} "
                  f"{compile_s:>9.1f}s {execute_s:>9.1f}s {compile_s + execute_s:>9.1f}s")


def warn_about_comparability(results: list[RunResult]) -> None:
    """Say so when the runs were not measuring the same thing.

    Two firmwares' worth of runs averaged together is not a measurement of
    either, and the shas are the only place that shows up.
    """
    shas = {(r.kernel_sha, r.rootfs_sha) for r in results if r.kernel_sha or r.rootfs_sha}
    if len(shas) > 1:
        print(
            "\n!! the runs did not all use the same firmware — kernel/rootfs "
            "hashes differ between them, so the fastest is not a baseline",
            file=sys.stderr,
        )
    dirty = [r.index for r in results if not r.clean]
    if dirty:
        print(
            f"!! runs with failures or a bad exit status: {dirty} — "
            "excluded from the ranking (pass --allow-failures to include them)",
            file=sys.stderr,
        )


def write_summary(out_dir: Path, results: list[RunResult], fastest: RunResult | None,
                  args: argparse.Namespace) -> Path:
    payload: dict[str, Any] = {
        "pytest_args": SUITE_PYTEST_ARGS,
        "opt_levels": args.opt_levels or "(cached)",
        "repeats": args.repeats,
        "ranked_on": "remote pytest phase (run_info.txt finished - started)",
        "fastest_run": fastest.index if fastest else None,
        "fastest_run_id": fastest.run_id if fastest else None,
        "fastest_seconds": fastest.suite_seconds if fastest else None,
        "runs": [
            {
                "index": r.index,
                "run_id": r.run_id,
                "suite_seconds": r.suite_seconds,
                "harness_seconds": round(r.harness_seconds, 2),
                "status": r.status,
                "passed": r.passed,
                "failed": r.failed,
                "skipped": r.skipped,
                "total_tests": r.total_tests,
                "kernel_sha": r.kernel_sha,
                "rootfs_sha": r.rootfs_sha,
                "git_rev": r.git_rev,
                "categories": r.categories,
                "log_dir": str(r.log_dir) if r.log_dir else None,
            }
            for r in results
        ],
    }
    path = out_dir / "summary.json"
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def collect_fastest(out_dir: Path, fastest: RunResult) -> Path | None:
    """Copy the winning run's artifacts out of the mirror.

    Copied rather than pointed at: the remote prunes its numbered runs
    (``keep_runs``), the mirror is where those arrive, and a baseline that
    evaporates twenty runs later is not a baseline.
    """
    if fastest.log_dir is None or not fastest.log_dir.is_dir():
        return None
    destination = out_dir / "fastest"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(fastest.log_dir, destination)
    return destination


# ------------------------------------------------------------------ #
#  Entry point                                                        #
# ------------------------------------------------------------------ #


def require_hardware(config: dict[str, Any]) -> None:
    """Refuse anything that is not the board.

    The measurement is of hardware behaviour — XIP cache, flash transactions,
    the SD write path — so a configuration with no SSH target is not a
    degraded run of this, it is a different experiment.
    """
    target = str(config.get("ssh_target", "")).strip()
    if not target:
        raise SystemExit(
            "no ssh_target configured — this benchmark only runs on the board.\n"
            "Configure the rig first: scripts/remote_smoke_tui.py --reconfigure"
        )


#: The flag spellings whose value is a list of ``-O`` levels.
_OPT_LEVEL_FLAGS = ("--opt-levels", "--opt-level")


def absorb_opt_levels(argv: list[str]) -> list[str]:
    """Fold ``--opt-levels -O0 -O2`` into one value argparse will accept.

    ``-O0`` is indistinguishable from a flag to argparse, so the spelling every
    other entry point in this repo documents — ``--opt-levels -O0 -O2``, as
    `scripts/run_hw_smoke.sh` takes it — is rejected before the parser is
    reached. That script absorbs the trailing levels by hand for the same
    reason; this is the same absorption, so both are typed the same way.

    The comma form (``-O0,-O2``) is accepted too and normalised to spaces,
    because that is the one that survives an unquoted `make` or
    `run_container.sh` expansion.
    """
    rewritten: list[str] = []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--":
            rewritten.extend(argv[index:])
            break
        if token in _OPT_LEVEL_FLAGS:
            levels: list[str] = []
            index += 1
            while index < len(argv) and argv[index].startswith("-O"):
                levels.append(argv[index])
                index += 1
            if levels:
                rewritten.append(f"--opt-levels={' '.join(levels).replace(',', ' ')}")
                continue
            # No level followed it — hand the bare flag on so argparse gives
            # its own "expected one argument" rather than a silent no-op.
            rewritten.append(token)
            continue
        if token.startswith("--opt-levels=") or token.startswith("--opt-level="):
            _, _, value = token.partition("=")
            rewritten.append(f"--opt-levels={value.replace(',', ' ')}")
            index += 1
            continue
        rewritten.append(token)
        index += 1
    return rewritten


def parse_args(argv: list[str]) -> argparse.Namespace:
    argv = absorb_opt_levels(argv)
    parser = argparse.ArgumentParser(
        description="Run tests2 + ir_tests + gcc_execute on the board N times and keep the fastest.",
        epilog="Arguments after -- are passed straight to remote_smoke_tui.py.",
    )
    parser.add_argument("-n", "--repeats", type=int, default=DEFAULT_REPEATS,
                        help=f"How many times to run the suites (default {DEFAULT_REPEATS}).")
    parser.add_argument("--opt-levels", "--opt-level", dest="opt_levels", default=None,
                        metavar="LEVELS",
                        help="tcc -O levels to run at, e.g. '-O0' or '-O0 -O2'. "
                             "Defaults to whatever the runner cache holds (all three).")
    parser.add_argument("-k", dest="keyword", default=None, metavar="EXPRESSION",
                        help="Narrow the corpus with a pytest -k expression. For "
                             "checking the harness end to end without a full run.")
    parser.add_argument("--test-retries", type=int, default=0,
                        help="Retries for a failing test (default 0). A retry turns a "
                             "failure into a slower pass, which a timing run must not hide.")
    parser.add_argument("--allow-failures", action="store_true",
                        help="Let a run with test failures win. Off by default: a failed "
                             "test is one that stopped early or took a board reset with it.")
    parser.add_argument("--out", type=Path, default=None, metavar="DIR",
                        help=f"Where to write the summary (default {BENCH_ROOT}/<timestamp>).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the command each repeat would run, and stop.")
    parser.add_argument("passthrough", nargs="*", default=[],
                        help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.repeats < 1:
        raise SystemExit("--repeats must be at least 1")

    config = tui.merge_config(tui.load_cache())
    require_hardware(config)
    mirror = tui.local_smoke_logs_dir(config)

    if args.dry_run:
        print(tui.command_string(build_command(args)))
        print(f"\n{args.repeats} run(s) against {config['ssh_target']}")
        print(f"log mirror: {mirror}")
        return 0

    out_dir = args.out or (BENCH_ROOT / datetime.now().strftime("%Y-%m-%d_%H-%M-%S"))
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"board:   {config['ssh_target']}")
    print(f"suites:  {SUITE_PYTEST_ARGS}")
    print(f"levels:  {args.opt_levels or config.get('smoke_tcc_opt_level', '(cached)')}")
    print(f"output:  {out_dir}")

    results: list[RunResult] = []
    try:
        for index in range(1, args.repeats + 1):
            results.append(run_once(args, index, mirror, out_dir))
    except KeyboardInterrupt:
        # What has been measured so far is still worth reporting; a benchmark
        # interrupted at run four of five has four runs in it.
        print("\ninterrupted — reporting the runs that finished", file=sys.stderr)

    if not results:
        return 1

    eligible = [r for r in results if r.suite_seconds is not None
                and (args.allow_failures or r.clean)]
    fastest = min(eligible, key=lambda r: r.ranked_seconds) if eligible else None

    print_table(results, fastest)
    warn_about_comparability(results)

    summary = write_summary(out_dir, results, fastest, args)
    print(f"\nsummary: {summary}")
    if fastest is not None:
        collected = collect_fastest(out_dir, fastest)
        if collected is not None:
            print(f"fastest run's artifacts: {collected}")

    return 0 if fastest is not None else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
