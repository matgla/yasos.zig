"""Tests for the smoke suite's timing instrumentation (Phase 0 of the speedup plan).

Three things are covered because all three failed silently in production rather
than loudly: the loader-timing regex, which matched only one of the two line
formats the kernel can emit and so reported `loader_ms=0.00` for all 4449 tests
of the 2026-08-03 run; the on-target total, which used to *add* loader time to
compile+execute even though the loader runs inside the execute window; and the
harness-overhead accounting, whose whole purpose is to produce a number that
gets believed.
"""

import json
from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke import timing as timing_module
from smoke.timing import (
    CaseTiming,
    LOADER_TIMING_RE,
    add,
    attach_compile_profile,
    attach_loader_timing,
    begin_case,
    end_case,
    record,
)


def _reset():
    end_case()
    timing_module.timing_results.clear()


# ---------------------------------------------------------------------------
# Loader timing
# ---------------------------------------------------------------------------


def test_loader_regex_matches_the_serial_perf_trace_line():
    """`load kind=...` is the only form that reaches the console."""
    line = "[ERR][tprof] load kind=executable path=/tmp/hello.bin pid=7 us=4321"
    match = LOADER_TIMING_RE.search(line)
    assert match is not None
    assert match.group("kind") == "executable"
    assert match.group("path") == "/tmp/hello.bin"
    assert match.group("pid") == "7"
    assert match.group("us") == "4321"


def test_loader_regex_still_matches_the_file_only_bench_line():
    line = "yasld-bench executable path=/tmp/hello.bin pid=7 us=4321 kernel_used=100 allocs=5"
    match = LOADER_TIMING_RE.search(line)
    assert match is not None
    assert match.group("us") == "4321"


def test_attach_loader_timing_reads_the_serial_form(tmp_path):
    log = tmp_path / "session.txt"
    log.write_text(
        "[ERR][tprof] load kind=library path=/lib/libc.so pid=7 us=9000\n"
        "[ERR][tprof] load kind=executable path=/tmp/hello.bin pid=7 us=2500\n",
        encoding="utf-8",
    )
    case = CaseTiming(test_id="t")
    attach_loader_timing(case, str(log), "/tmp/hello.bin")
    # The library line must not be attributed to the executable.
    assert case.execute_loader_ms == 2.5
    assert case.loader_ms == 2.5


def test_attach_loader_timing_takes_the_most_recent_load(tmp_path):
    """A rerun leaves two loads of the same path; the later one is this test's."""
    log = tmp_path / "session.txt"
    log.write_text(
        "[ERR][tprof] load kind=executable path=/tmp/hello.bin pid=7 us=8000\n"
        "[ERR][tprof] load kind=executable path=/tmp/hello.bin pid=8 us=3000\n",
        encoding="utf-8",
    )
    case = CaseTiming(test_id="t")
    attach_loader_timing(case, str(log), "/tmp/hello.bin")
    assert case.execute_loader_ms == 3.0


def test_attach_loader_timing_ignores_a_different_executable(tmp_path):
    log = tmp_path / "session.txt"
    log.write_text(
        "[ERR][tprof] load kind=executable path=/tmp/other.bin pid=7 us=2500\n",
        encoding="utf-8",
    )
    case = CaseTiming(test_id="t")
    attach_loader_timing(case, str(log), "/tmp/hello.bin")
    assert case.execute_loader_ms == 0.0


# ---------------------------------------------------------------------------
# Device-side compile breakdown (syscalls, IO, tcc's own load)
# ---------------------------------------------------------------------------


_PERF_LINES = [
    "# perf: sys calls=4567 us=123456 handler_us=98765 load_us=36012 dropped=2",
    "# perf: io read=1234567/45678 write=8901/2345",
    "# perf: top read=890/45678 write=45/2345 open=12/3456 other=3620/72000",
]


def test_attach_compile_profile_reads_the_syscall_summary():
    case = CaseTiming(test_id="t")
    attach_compile_profile(case, _PERF_LINES)
    assert case.syscall_calls == 4567
    assert case.syscall_ms == 123.456
    assert case.syscall_handler_ms == 98.765
    assert case.syscall_dropped == 2
    # The process's own dynamic-load time comes back through the same dump —
    # no serial trace line, so it works for the compile window too.
    assert case.compile_loader_ms == 36.012


def test_attach_compile_profile_reads_io_counters():
    case = CaseTiming(test_id="t")
    attach_compile_profile(case, _PERF_LINES)
    assert case.read_bytes == 1234567
    assert case.read_ms == 45.678
    assert case.write_bytes == 8901
    assert case.write_ms == 2.345


def test_attach_compile_profile_reads_the_per_call_breakdown():
    case = CaseTiming(test_id="t")
    attach_compile_profile(case, _PERF_LINES)
    assert case.syscall_breakdown["read"] == {"calls": 890, "ms": 45.678}
    assert case.syscall_breakdown["open"] == {"calls": 12, "ms": 3.456}
    # The device folds the tail into `other`; it still has to be counted.
    assert case.syscall_breakdown["other"] == {"calls": 3620, "ms": 72.0}


def test_attach_compile_profile_ignores_unrelated_bench_lines():
    case = CaseTiming(test_id="t")
    attach_compile_profile(case, ["# 123 idents, 456 lines, 789 bytes", "# text 1, data.rw 2, data.ro 3, bss 4 bytes"])
    assert case.syscall_calls == 0
    assert case.compile_loader_ms == 0.0


# ---------------------------------------------------------------------------
# Harness overhead accounting
# ---------------------------------------------------------------------------


def test_record_accumulates_onto_the_current_case():
    _reset()
    case = begin_case("t")
    try:
        with record("hash_ms"):
            pass
        with record("hash_ms"):
            pass
        with record("setup_ms"):
            pass
    finally:
        end_case()
    # Two hash blocks accumulated rather than the second overwriting the first.
    assert case.hash_ms > 0.0
    assert case.setup_ms > 0.0
    assert case.cleanup_ms == 0.0
    assert case.harness_total_ms == case.hash_ms + case.setup_ms


def test_record_still_charges_the_case_when_the_block_raises():
    """A failing upload must not silently drop its round-trip cost."""
    _reset()
    case = begin_case("t")
    try:
        try:
            with record("hash_ms"):
                raise RuntimeError("serial desync")
        except RuntimeError:
            pass
    finally:
        end_case()
    assert case.hash_ms > 0.0


def test_record_is_a_noop_outside_a_case():
    """Session setup and untimed tests call the same helpers."""
    _reset()
    with record("hash_ms"):
        pass
    add("setup_ms", 5.0)
    # Nothing to assert but the absence of an exception and of a stray case.
    assert timing_module._current_case is None


def test_add_folds_in_externally_measured_time():
    _reset()
    case = begin_case("t")
    try:
        add("setup_ms", 12.5)
        add("setup_ms", 2.5)
    finally:
        end_case()
    assert case.setup_ms == 15.0


def test_end_case_stops_attribution():
    _reset()
    case = begin_case("t")
    end_case()
    with record("cleanup_ms"):
        pass
    assert case.cleanup_ms == 0.0


def test_harness_and_target_totals_stay_separate():
    case = CaseTiming(
        test_id="t",
        compile_ms=100.0,
        execute_ms=1.0,
        hash_ms=20.0,
        setup_ms=5.0,
        cleanup_ms=2.0,
    )
    assert case.target_total_ms == 101.0
    assert case.harness_total_ms == 27.0


def test_loader_time_is_a_component_not_a_third_window():
    """The loader runs *inside* compile/execute; adding it overstates the run.

    The device loads tcc during the compile window and the test binary during
    the execute window, both of which the harness already measures with a wall
    clock. The old total added them again.
    """
    case = CaseTiming(
        test_id="t",
        compile_ms=100.0,
        execute_ms=10.0,
        compile_loader_ms=30.0,
        execute_loader_ms=5.0,
    )
    assert case.target_total_ms == 110.0
    assert case.loader_ms == 35.0


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


class _Reporter:
    def __init__(self):
        self.lines = []

    def section(self, title):
        self.lines.append(f"== {title} ==")

    def write_line(self, line):
        self.lines.append(line)


def _report(tmp_path, monkeypatch, *cases):
    _reset()
    monkeypatch.setenv("YASOS_TIMING_REPORT_DIR", str(tmp_path))
    timing_module.timing_results.extend(cases)
    reporter = _Reporter()
    try:
        timing_module.format_timing_report(reporter)
        report = json.loads((tmp_path / "tcc_timing_report.json").read_text())
    finally:
        _reset()
    return reporter, report


def test_report_carries_the_harness_columns(tmp_path, monkeypatch):
    _, report = _report(
        tmp_path,
        monkeypatch,
        CaseTiming(
            test_id="gcc_execute/x[-O0]",
            compile_ms=400.0,
            execute_ms=8.0,
            execute_loader_ms=12.0,
            hash_ms=30.0,
            setup_ms=40.0,
            cleanup_ms=20.0,
        ),
    )

    summary = report["summary"]
    assert summary["total_loader_ms"] == 12.0
    assert summary["total_execute_loader_ms"] == 12.0
    assert summary["total_hash_ms"] == 30.0
    assert summary["total_setup_ms"] == 40.0
    assert summary["total_cleanup_ms"] == 20.0
    assert summary["total_harness_ms"] == 90.0
    # The loader is inside the execute window, so it is not in the total.
    assert summary["total_on_target_ms"] == 408.0

    case = report["tests"][0]
    assert case["harness_ms"] == 90.0
    assert case["hash_ms"] == 30.0


def test_report_carries_the_syscall_and_io_columns(tmp_path, monkeypatch):
    case = CaseTiming(test_id="ir_tests/a.c", compile_ms=1000.0, execute_ms=10.0)
    attach_compile_profile(case, _PERF_LINES)
    _, report = _report(tmp_path, monkeypatch, case)

    summary = report["summary"]
    assert summary["total_syscall_ms"] == 123.46
    assert summary["total_syscall_calls"] == 4567
    assert summary["total_read_bytes"] == 1234567
    assert summary["total_compile_loader_ms"] == 36.01
    assert summary["syscall_totals"]["read"]["calls"] == 890
    assert report["tests"][0]["syscall_breakdown"]["open"]["calls"] == 12


def test_report_says_the_breakdown_is_missing_rather_than_zero(tmp_path, monkeypatch):
    """A run without --profile has no device data; a zeroed column reads as free."""
    reporter, _ = _report(
        tmp_path,
        monkeypatch,
        CaseTiming(test_id="ir_tests/a.c", compile_ms=1000.0, execute_ms=10.0),
    )
    text = "\n".join(reporter.lines)
    assert "On-target breakdown: n/a" in text
    assert "--profile" in text


def test_report_breakdown_reports_dispatch_separately(tmp_path, monkeypatch):
    """total - handler is what fewer syscalls would save; it needs its own row."""
    case = CaseTiming(test_id="ir_tests/a.c", compile_ms=1000.0, execute_ms=10.0)
    attach_compile_profile(case, _PERF_LINES)
    reporter, _ = _report(tmp_path, monkeypatch, case)
    text = "\n".join(reporter.lines)
    assert "dispatch overhead" in text
    assert "handler work" in text
    assert "loader (tcc image)" in text
    # IO gets its own rows: throughput is what says whether the filesystem or
    # the call count is the problem.
    assert "1.18 MiB at" in text


def test_report_warns_when_a_component_outlasts_its_window(tmp_path, monkeypatch):
    """A >100% component means misattribution, not a finding."""
    case = CaseTiming(test_id="ir_tests/a.c", compile_ms=10.0, execute_ms=1.0)
    attach_compile_profile(case, _PERF_LINES)  # 123ms of syscalls in a 10ms compile
    reporter, _ = _report(tmp_path, monkeypatch, case)
    text = "\n".join(reporter.lines)
    assert "WARNING" in text
    assert "do not trust the split" in text
