"""Timing instrumentation for TCC test suite profiling.

Two halves of the wall clock, kept apart on purpose:

* **on-target** — the compile and execute windows, as measured around the
  serial reads that bracket each device command;
* **harness** — the per-test serial round trips the framework itself spends
  before and after that work: the source hash checks, the prompt resync and
  ``cd``, and the output ``rm``.

The harness half exists because it is the thing Phase 1.2 (round-trip batching)
would attack, and nobody knows how much of it survived Phase 1.1 — the
2026-08-03 run put the whole non-on-target remainder at 388 s, but that number
also contains boot, collection and flash checks, which batching cannot touch.
Attributing it needs it measured, not subtracted.

On-target time has exactly two *windows*: compile and execute. Everything else
this module records — loader time, syscall time, IO — is a **component** of one
of those windows, measured on the device and reported inside it. That
distinction is the whole point: the earlier version of this report added loader
time to compile+execute as if it were a third window, so any run that actually
produced loader numbers would have overstated the total by the loader's share.

Results are printed as a pytest terminal summary and persisted to JSON.
"""

import json
import os
import re
import time
from contextlib import contextmanager
from dataclasses import dataclass, field


@dataclass
class CaseTiming:
    """Timing data for a single test case."""

    test_id: str
    # On-target windows: wall time the device spent working. Disjoint.
    compile_ms: float = 0.0
    execute_ms: float = 0.0

    # Components of `compile_ms`, measured by the kernel and reported by tcc's
    # own perf dump (needs --profile: tcc only dumps under -bench).
    compile_loader_ms: float = 0.0
    syscall_ms: float = 0.0
    syscall_handler_ms: float = 0.0
    syscall_calls: int = 0
    syscall_dropped: int = 0
    read_bytes: int = 0
    read_ms: float = 0.0
    write_bytes: int = 0
    write_ms: float = 0.0
    # syscall name -> {"calls": int, "ms": float}, top entries only (the device
    # folds the tail into "other" to keep the serial line short).
    syscall_breakdown: dict = field(default_factory=dict)

    # Component of `execute_ms`: loading the compiled test binary.
    execute_loader_ms: float = 0.0

    # Harness: time this process spent driving the device around that work.
    # Accumulated, not assigned — a case may hash several sources.
    hash_ms: float = 0.0
    setup_ms: float = 0.0
    cleanup_ms: float = 0.0

    @property
    def target_total_ms(self):
        """Wall time on the device. Loader and syscall time live *inside* these
        two windows, so adding them here would double-count."""
        return self.compile_ms + self.execute_ms

    @property
    def loader_ms(self):
        return self.compile_loader_ms + self.execute_loader_ms

    @property
    def harness_total_ms(self):
        return self.hash_ms + self.setup_ms + self.cleanup_ms


timing_results: list[CaseTiming] = []

# Both spellings of the per-load line the kernel can emit. `yasld-bench` is the
# file-only log.debug in modules.zig; `load kind=` is the perf.trace mirror that
# reaches the serial console, and is the only one that survives on a build
# without CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING's log level. Matching only
# the first is why `loader_ms` read 0.00 for all 4449 tests of the 2026-08-03
# run — the report showed a zero column rather than a missing one, which is the
# worse failure of the two.
LOADER_TIMING_RE = re.compile(
    r"(?:yasld-bench |load kind=)"
    r"(?P<kind>executable|library) path=(?P<path>\S+) pid=(?P<pid>\d+) us=(?P<us>\d+)"
)

# The compact syscall profile tcc prints under -bench (libs/libc/sys/perf.c).
# `us` is the whole kernel-side syscall (SVC entry through end of handler),
# `handler_us` only the handler body, so the difference is dispatch overhead.
# `load_us` is this process's own dynamic-load time, which it cannot measure
# itself — the kernel hands it back through the same dump.
PERF_SYS_RE = re.compile(
    r"# perf: sys calls=(?P<calls>\d+) us=(?P<us>\d+) handler_us=(?P<handler_us>\d+)"
    r" load_us=(?P<load_us>\d+) dropped=(?P<dropped>\d+)"
)
PERF_IO_RE = re.compile(
    r"# perf: io read=(?P<read_bytes>\d+)/(?P<read_us>\d+)"
    r" write=(?P<write_bytes>\d+)/(?P<write_us>\d+)"
)
PERF_TOP_RE = re.compile(r"# perf: top (?P<entries>.*)")
PERF_TOP_ENTRY_RE = re.compile(r"(?P<name>\w+)=(?P<calls>\d+)/(?P<us>\d+)")


def start_timer():
    """Return a monotonic timestamp for interval measurement."""
    return time.monotonic()


def elapsed_ms(start):
    """Milliseconds elapsed since *start* (returned by `start_timer`)."""
    return (time.monotonic() - start) * 1000.0


# The case currently being timed. A module-level current-case is safe here
# because a pytest worker runs one test at a time and each xdist worker is its
# own process; it saves threading a `timing` argument through the upload and
# prompt-handling helpers, which are several call layers below the test.
_current_case: CaseTiming | None = None


def begin_case(test_id):
    """Start timing *test_id* and make it the target of `record`."""
    global _current_case
    _current_case = CaseTiming(test_id=test_id)
    return _current_case


def end_case():
    """Stop attributing `record` blocks to the current case."""
    global _current_case
    _current_case = None


@contextmanager
def record(field_name):
    """Add this block's duration to *field_name* of the case being timed.

    A no-op when no case is active, so the helpers below stay callable from
    session setup and from tests that do not time themselves.
    """
    start = time.monotonic()
    try:
        yield
    finally:
        case = _current_case
        if case is not None:
            setattr(
                case,
                field_name,
                getattr(case, field_name) + (time.monotonic() - start) * 1000.0,
            )


def add(field_name, milliseconds):
    """Add *milliseconds* to *field_name* of the case being timed, if there is one."""
    case = _current_case
    if case is not None:
        setattr(case, field_name, getattr(case, field_name) + milliseconds)


def attach_loader_timing(timing: CaseTiming, log_path: str, executable_path: str):
    """Attach the most recent executable-load timing for *executable_path*.

    This is the *execute* window's loader time (the compiled test binary). The
    compile window's loader time — tcc's own image — comes back through
    `attach_compile_profile`, which needs no serial line at all.
    """
    if not log_path or not executable_path:
        return

    try:
        with open(log_path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                match = LOADER_TIMING_RE.search(line)
                if match is None:
                    continue
                if match.group("kind") != "executable":
                    continue
                if match.group("path") != executable_path:
                    continue
                timing.execute_loader_ms = int(match.group("us")) / 1000.0
    except OSError:
        return


def attach_compile_profile(timing: CaseTiming, profile_lines: list[str]):
    """Attach the device-side compile breakdown from tcc's ``# perf:`` lines."""
    for line in profile_lines:
        match = PERF_SYS_RE.search(line)
        if match:
            timing.syscall_calls = int(match.group("calls"))
            timing.syscall_ms = int(match.group("us")) / 1000.0
            timing.syscall_handler_ms = int(match.group("handler_us")) / 1000.0
            timing.compile_loader_ms = int(match.group("load_us")) / 1000.0
            timing.syscall_dropped = int(match.group("dropped"))
            continue

        match = PERF_IO_RE.search(line)
        if match:
            timing.read_bytes = int(match.group("read_bytes"))
            timing.read_ms = int(match.group("read_us")) / 1000.0
            timing.write_bytes = int(match.group("write_bytes"))
            timing.write_ms = int(match.group("write_us")) / 1000.0
            continue

        match = PERF_TOP_RE.search(line)
        if match:
            for entry in PERF_TOP_ENTRY_RE.finditer(match.group("entries")):
                timing.syscall_breakdown[entry.group("name")] = {
                    "calls": int(entry.group("calls")),
                    "ms": int(entry.group("us")) / 1000.0,
                }


def _format_bytes(count):
    if count >= 1024 * 1024 * 1024:
        return f"{count / (1024 * 1024 * 1024):.2f} GiB"
    if count >= 1024 * 1024:
        return f"{count / (1024 * 1024):.2f} MiB"
    if count >= 1024:
        return f"{count / 1024:.2f} KiB"
    return f"{count} B"


def _throughput(byte_count, milliseconds):
    if milliseconds <= 0:
        return "n/a"
    return f"{byte_count / (milliseconds / 1000.0) / (1024 * 1024):.2f} MiB/s"


def format_timing_report(terminalreporter):
    """Print timing summary to pytest terminal and save JSON report."""
    if not timing_results:  # pragma: no branch
        return

    sorted_results = sorted(
        timing_results, key=lambda t: t.target_total_ms, reverse=True
    )

    total_compile = sum(t.compile_ms for t in timing_results)
    total_execute = sum(t.execute_ms for t in timing_results)
    total = total_compile + total_execute

    total_compile_loader = sum(t.compile_loader_ms for t in timing_results)
    total_execute_loader = sum(t.execute_loader_ms for t in timing_results)
    total_loader = total_compile_loader + total_execute_loader
    compile_loads = sum(1 for t in timing_results if t.compile_loader_ms > 0)
    execute_loads = sum(1 for t in timing_results if t.execute_loader_ms > 0)

    total_syscall = sum(t.syscall_ms for t in timing_results)
    total_handler = sum(t.syscall_handler_ms for t in timing_results)
    total_calls = sum(t.syscall_calls for t in timing_results)
    total_dropped = sum(t.syscall_dropped for t in timing_results)
    total_read_bytes = sum(t.read_bytes for t in timing_results)
    total_read_ms = sum(t.read_ms for t in timing_results)
    total_write_bytes = sum(t.write_bytes for t in timing_results)
    total_write_ms = sum(t.write_ms for t in timing_results)
    profiled_compiles = sum(1 for t in timing_results if t.syscall_calls > 0)

    syscall_totals: dict[str, dict] = {}
    for t in timing_results:
        for name, data in t.syscall_breakdown.items():
            bucket = syscall_totals.setdefault(name, {"calls": 0, "ms": 0.0})
            bucket["calls"] += data["calls"]
            bucket["ms"] += data["ms"]

    total_hash = sum(t.hash_ms for t in timing_results)
    total_setup = sum(t.setup_ms for t in timing_results)
    total_cleanup = sum(t.cleanup_ms for t in timing_results)
    total_harness = total_hash + total_setup + total_cleanup

    # --- JSON report ---
    report_dir = os.environ.get("YASOS_TIMING_REPORT_DIR", ".")
    report_path = os.path.join(report_dir, "tcc_timing_report.json")
    try:
        with open(report_path, "w") as fh:
            json.dump(
                {
                    "summary": {
                        "total_tests": len(timing_results),
                        "total_compile_ms": round(total_compile, 2),
                        "total_execute_ms": round(total_execute, 2),
                        "total_on_target_ms": round(total, 2),
                        "total_loader_ms": round(total_loader, 2),
                        "total_compile_loader_ms": round(total_compile_loader, 2),
                        "total_execute_loader_ms": round(total_execute_loader, 2),
                        "total_syscall_ms": round(total_syscall, 2),
                        "total_syscall_handler_ms": round(total_handler, 2),
                        "total_syscall_calls": total_calls,
                        "total_syscall_dropped": total_dropped,
                        "total_read_bytes": total_read_bytes,
                        "total_read_ms": round(total_read_ms, 2),
                        "total_write_bytes": total_write_bytes,
                        "total_write_ms": round(total_write_ms, 2),
                        "profiled_compiles": profiled_compiles,
                        "syscall_totals": {
                            name: {"calls": data["calls"], "ms": round(data["ms"], 2)}
                            for name, data in syscall_totals.items()
                        },
                        "total_hash_ms": round(total_hash, 2),
                        "total_setup_ms": round(total_setup, 2),
                        "total_cleanup_ms": round(total_cleanup, 2),
                        "total_harness_ms": round(total_harness, 2),
                    },
                    "tests": [
                        {
                            "test_id": t.test_id,
                            "compile_ms": round(t.compile_ms, 2),
                            "execute_ms": round(t.execute_ms, 2),
                            "total_ms": round(t.target_total_ms, 2),
                            "compile_loader_ms": round(t.compile_loader_ms, 2),
                            "execute_loader_ms": round(t.execute_loader_ms, 2),
                            "loader_ms": round(t.loader_ms, 2),
                            "syscall_ms": round(t.syscall_ms, 2),
                            "syscall_handler_ms": round(t.syscall_handler_ms, 2),
                            "syscall_calls": t.syscall_calls,
                            "syscall_dropped": t.syscall_dropped,
                            "read_bytes": t.read_bytes,
                            "read_ms": round(t.read_ms, 2),
                            "write_bytes": t.write_bytes,
                            "write_ms": round(t.write_ms, 2),
                            "syscall_breakdown": {
                                name: {"calls": data["calls"], "ms": round(data["ms"], 2)}
                                for name, data in t.syscall_breakdown.items()
                            },
                            "hash_ms": round(t.hash_ms, 2),
                            "setup_ms": round(t.setup_ms, 2),
                            "cleanup_ms": round(t.cleanup_ms, 2),
                            "harness_ms": round(t.harness_total_ms, 2),
                        }
                        for t in sorted_results
                    ],
                },
                fh,
                indent=2,
            )
    except OSError:
        report_path = None

    # --- Terminal summary ---
    terminalreporter.section("TCC On-Target Timing Report")
    terminalreporter.write_line(
        f"Total on-target time: {total / 1000:.2f}s "
        f"(compile: {total_compile / 1000:.2f}s, "
        f"execute: {total_execute / 1000:.2f}s)"
    )
    terminalreporter.write_line(
        f"Harness overhead: {total_harness / 1000:.2f}s "
        f"(hash: {total_hash / 1000:.2f}s, "
        f"setup: {total_setup / 1000:.2f}s, "
        f"cleanup: {total_cleanup / 1000:.2f}s)"
    )
    if timing_results:
        count = len(timing_results)
        terminalreporter.write_line(
            f"Per test: on-target {total / count:.1f}ms, harness {total_harness / count:.1f}ms "
            f"(hash {total_hash / count:.1f}ms, setup {total_setup / count:.1f}ms, "
            f"cleanup {total_cleanup / count:.1f}ms)"
        )
    terminalreporter.write_line(f"Tests profiled: {len(timing_results)}")

    _write_component_breakdown(
        terminalreporter,
        total_compile=total_compile,
        total_execute=total_execute,
        total_compile_loader=total_compile_loader,
        total_execute_loader=total_execute_loader,
        compile_loads=compile_loads,
        execute_loads=execute_loads,
        total_syscall=total_syscall,
        total_handler=total_handler,
        total_calls=total_calls,
        total_dropped=total_dropped,
        total_read_bytes=total_read_bytes,
        total_read_ms=total_read_ms,
        total_write_bytes=total_write_bytes,
        total_write_ms=total_write_ms,
        profiled_compiles=profiled_compiles,
        test_count=len(timing_results),
        syscall_totals=syscall_totals,
    )

    terminalreporter.write_line("")
    n = min(30, len(sorted_results))
    terminalreporter.write_line(
        f"Top {n} slowest tests (on-target; loader/syscall are components, not extra):"
    )
    terminalreporter.write_line(
        f"  {'#':<4} {'Test ID':<55} {'Compile':>10} {'Execute':>10} {'Total':>10} "
        f"{'Loader':>10} {'Syscall':>10} {'IO':>10}"
    )
    terminalreporter.write_line(f"  {'-' * 124}")
    for i, t in enumerate(sorted_results[:n], 1):
        io_ms = t.read_ms + t.write_ms
        terminalreporter.write_line(
            f"  {i:<4} {t.test_id:<55} "
            f"{t.compile_ms:>8.1f}ms "
            f"{t.execute_ms:>8.1f}ms "
            f"{t.target_total_ms:>8.1f}ms "
            f"{t.loader_ms:>8.1f}ms "
            f"{t.syscall_ms:>8.1f}ms "
            f"{io_ms:>8.1f}ms"
        )

    if total_syscall > 0:
        by_syscall = sorted(timing_results, key=lambda t: t.syscall_ms, reverse=True)
        terminalreporter.write_line("")
        terminalreporter.write_line("Top 15 tests by syscall time (compile step):")
        terminalreporter.write_line(
            f"  {'#':<4} {'Test ID':<55} {'Syscall':>10} {'Calls':>10} "
            f"{'Read':>12} {'Written':>12} {'% compile':>10}"
        )
        terminalreporter.write_line(f"  {'-' * 116}")
        for i, t in enumerate(by_syscall[:15], 1):
            share = (t.syscall_ms / t.compile_ms * 100.0) if t.compile_ms else 0.0
            terminalreporter.write_line(
                f"  {i:<4} {t.test_id:<55} "
                f"{t.syscall_ms:>8.1f}ms "
                f"{t.syscall_calls:>10} "
                f"{_format_bytes(t.read_bytes):>12} "
                f"{_format_bytes(t.write_bytes):>12} "
                f"{share:>9.1f}%"
            )

    # --- Category breakdown ---
    categories: dict[str, list[CaseTiming]] = {}
    for t in timing_results:
        if t.test_id.startswith("ir_tests/"):
            cat = "ir_tests"
        elif t.test_id.startswith("gcc_compile/"):
            cat = "gcc_compile"
        elif t.test_id.startswith("gcc_execute/"):
            cat = "gcc_execute"
        else:
            cat = "tests2"
        categories.setdefault(cat, []).append(t)

    if len(categories) > 1:
        terminalreporter.write_line("")
        terminalreporter.write_line("Timing by category:")
        terminalreporter.write_line(
            f"  {'Category':<15} {'Tests':>6} "
            f"{'Compile':>12} {'Execute':>12} {'Total':>12} {'Loader':>12} "
            f"{'Syscall':>12} {'Avg':>10}"
        )
        terminalreporter.write_line(f"  {'-' * 108}")
        for cat_name in ("tests2", "ir_tests", "gcc_compile", "gcc_execute"):
            tests = categories.get(cat_name)
            if not tests:
                continue
            cat_compile = sum(t.compile_ms for t in tests)
            cat_execute = sum(t.execute_ms for t in tests)
            cat_loader = sum(t.loader_ms for t in tests)
            cat_syscall = sum(t.syscall_ms for t in tests)
            cat_total = cat_compile + cat_execute
            cat_avg = cat_total / len(tests) if tests else 0
            terminalreporter.write_line(
                f"  {cat_name:<15} {len(tests):>6} "
                f"{cat_compile / 1000:>10.2f}s "
                f"{cat_execute / 1000:>10.2f}s "
                f"{cat_total / 1000:>10.2f}s "
                f"{cat_loader / 1000:>10.2f}s "
                f"{cat_syscall / 1000:>10.2f}s "
                f"{cat_avg:>8.1f}ms"
            )

    if report_path is not None:
        terminalreporter.write_line(
            f"\nFull timing data saved to: {os.path.abspath(report_path)}"
        )


def _write_component_breakdown(
    terminalreporter,
    *,
    total_compile,
    total_execute,
    total_compile_loader,
    total_execute_loader,
    compile_loads,
    execute_loads,
    total_syscall,
    total_handler,
    total_calls,
    total_dropped,
    total_read_bytes,
    total_read_ms,
    total_write_bytes,
    total_write_ms,
    profiled_compiles,
    test_count,
    syscall_totals,
):
    """Print what the two on-target windows are made of.

    Everything here is measured *on the device*, inside the compile/execute
    wall clock. A run without --profile has none of it: tcc only dumps the
    kernel's counters under -bench, and the kernel only keeps them with
    CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y, which --profile also turns
    on. Saying so beats printing a column of zeroes that reads as "free".
    """
    terminalreporter.write_line("")
    have_device_data = total_syscall > 0 or total_compile_loader > 0 or total_execute_loader > 0
    if not have_device_data:
        terminalreporter.write_line(
            "On-target breakdown: n/a — rerun with --profile for loader, syscall and IO time"
        )
        return

    def pct(part, whole):
        return (part / whole * 100.0) if whole else 0.0

    terminalreporter.write_line("On-target breakdown (components of the windows above, not extra time):")
    terminalreporter.write_line(
        f"  compile window            {total_compile / 1000:>10.2f}s   over {test_count} compiles"
    )
    if total_compile_loader > 0:
        per_load = total_compile_loader / compile_loads if compile_loads else 0.0
        terminalreporter.write_line(
            f"    loader (tcc image)      {total_compile_loader / 1000:>10.2f}s "
            f"{pct(total_compile_loader, total_compile):>6.1f}%   "
            f"{compile_loads} loads, {per_load:.1f}ms each"
        )
    if total_syscall > 0:
        dispatch = max(0.0, total_syscall - total_handler)
        terminalreporter.write_line(
            f"    syscalls (kernel)       {total_syscall / 1000:>10.2f}s "
            f"{pct(total_syscall, total_compile):>6.1f}%   "
            f"{total_calls} calls over {profiled_compiles} compiles, "
            f"{total_syscall * 1000 / total_calls if total_calls else 0:.1f}us each"
        )
        # Two different splits of that same number: by where the time goes
        # (work vs. getting into the kernel), then by which call spent it.
        terminalreporter.write_line(
            f"      = handler work        {total_handler / 1000:>10.2f}s "
            f"{pct(total_handler, total_syscall):>6.1f}%   of syscall time: the work itself"
        )
        terminalreporter.write_line(
            f"      + dispatch overhead   {dispatch / 1000:>10.2f}s "
            f"{pct(dispatch, total_syscall):>6.1f}%   of syscall time: SVC entry + "
            f"trampoline, only fewer calls shrink it"
        )
        terminalreporter.write_line(
            f"      read                  {total_read_ms / 1000:>10.2f}s "
            f"{pct(total_read_ms, total_syscall):>6.1f}%   "
            f"{_format_bytes(total_read_bytes)} at {_throughput(total_read_bytes, total_read_ms)}"
        )
        terminalreporter.write_line(
            f"      write                 {total_write_ms / 1000:>10.2f}s "
            f"{pct(total_write_ms, total_syscall):>6.1f}%   "
            f"{_format_bytes(total_write_bytes)} at {_throughput(total_write_bytes, total_write_ms)}"
        )
        rest = total_compile - total_compile_loader - total_syscall
        terminalreporter.write_line(
            f"    everything else         {rest / 1000:>10.2f}s "
            f"{pct(rest, total_compile):>6.1f}%   tcc user-mode compute, shell "
            f"spawn/teardown, serial"
        )
        if total_dropped:
            terminalreporter.write_line(
                f"    dropped samples         {total_dropped:>10}      calls whose cycle "
                f"delta was implausible (blocked/counter wrap) and were left out"
            )
    if total_execute_loader > 0:
        per_load = total_execute_loader / execute_loads if execute_loads else 0.0
        terminalreporter.write_line(
            f"  execute window            {total_execute / 1000:>10.2f}s   over {execute_loads} runs"
        )
        terminalreporter.write_line(
            f"    loader (test binary)    {total_execute_loader / 1000:>10.2f}s "
            f"{pct(total_execute_loader, total_execute):>6.1f}%   "
            f"{execute_loads} loads, {per_load:.1f}ms each"
        )

    # A component cannot outlast the window it happened in. If one does, the
    # measurement is wrong (a load line matched from a neighbouring test, a
    # window that started too late) and every percentage above is wrong with
    # it — better to say so than to let a >100% figure be read as a finding.
    if total_compile_loader + total_syscall > total_compile:
        terminalreporter.write_line(
            "  WARNING: loader + syscall time exceeds the compile window; the "
            "components are misattributed, do not trust the split above"
        )
    if total_execute_loader > total_execute:
        terminalreporter.write_line(
            "  WARNING: loader time exceeds the execute window; the loader line "
            "is probably matching a load from another test"
        )
    if profiled_compiles and profiled_compiles < test_count:
        terminalreporter.write_line(
            f"  note: syscall/IO data covers {profiled_compiles} of {test_count} compiles "
            f"(only compiles that reached tcc's -bench dump report it); the executed "
            f"binaries report none"
        )

    if syscall_totals:
        terminalreporter.write_line("")
        terminalreporter.write_line("Syscall time by call (compile step, device-measured):")
        terminalreporter.write_line(
            f"  {'Syscall':<16} {'Calls':>12} {'Total':>12} {'Avg':>10} {'% syscall':>10} {'% compile':>10}"
        )
        terminalreporter.write_line(f"  {'-' * 74}")
        for name, data in sorted(
            syscall_totals.items(), key=lambda item: item[1]["ms"], reverse=True
        ):
            avg_us = (data["ms"] * 1000 / data["calls"]) if data["calls"] else 0.0
            terminalreporter.write_line(
                f"  {name:<16} {data['calls']:>12} {data['ms'] / 1000:>10.2f}s "
                f"{avg_us:>8.1f}us "
                f"{pct(data['ms'], total_syscall):>9.1f}% "
                f"{pct(data['ms'], total_compile):>9.1f}%"
            )
