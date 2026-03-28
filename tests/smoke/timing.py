"""On-target timing instrumentation for TCC test suite profiling.

Measures compile and execute time on the target device (excludes file
transfer overhead).  Results are printed as a pytest terminal summary and
persisted to a JSON file for further analysis.
"""

import json
import os
import time
from dataclasses import dataclass


@dataclass
class CaseTiming:
    """Timing data for a single test case's on-target execution."""

    test_id: str
    compile_ms: float = 0.0
    execute_ms: float = 0.0

    @property
    def target_total_ms(self):
        return self.compile_ms + self.execute_ms


timing_results: list[CaseTiming] = []


def start_timer():
    """Return a monotonic timestamp for interval measurement."""
    return time.monotonic()


def elapsed_ms(start):
    """Milliseconds elapsed since *start* (returned by `start_timer`)."""
    return (time.monotonic() - start) * 1000.0


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
                    },
                    "tests": [
                        {
                            "test_id": t.test_id,
                            "compile_ms": round(t.compile_ms, 2),
                            "execute_ms": round(t.execute_ms, 2),
                            "total_ms": round(t.target_total_ms, 2),
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
    terminalreporter.write_line(f"Tests profiled: {len(timing_results)}")
    terminalreporter.write_line("")

    n = min(30, len(sorted_results))
    terminalreporter.write_line(f"Top {n} slowest tests (on-target):")
    terminalreporter.write_line(
        f"  {'#':<4} {'Test ID':<55} {'Compile':>10} {'Execute':>10} {'Total':>10}"
    )
    terminalreporter.write_line(f"  {'-' * 89}")
    for i, t in enumerate(sorted_results[:n], 1):
        terminalreporter.write_line(
            f"  {i:<4} {t.test_id:<55} "
            f"{t.compile_ms:>8.1f}ms "
            f"{t.execute_ms:>8.1f}ms "
            f"{t.target_total_ms:>8.1f}ms"
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
            f"{'Compile':>12} {'Execute':>12} {'Total':>12} {'Avg':>10}"
        )
        terminalreporter.write_line(f"  {'-' * 71}")
        for cat_name in ("tests2", "ir_tests", "gcc_compile", "gcc_execute"):
            tests = categories.get(cat_name)
            if not tests:
                continue
            cat_compile = sum(t.compile_ms for t in tests)
            cat_execute = sum(t.execute_ms for t in tests)
            cat_total = cat_compile + cat_execute
            cat_avg = cat_total / len(tests) if tests else 0
            terminalreporter.write_line(
                f"  {cat_name:<15} {len(tests):>6} "
                f"{cat_compile / 1000:>10.2f}s "
                f"{cat_execute / 1000:>10.2f}s "
                f"{cat_total / 1000:>10.2f}s "
                f"{cat_avg:>8.1f}ms"
            )

    if report_path is not None:
        terminalreporter.write_line(
            f"\nFull timing data saved to: {os.path.abspath(report_path)}"
        )
