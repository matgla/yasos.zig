"""TCC performance profiling capture for smoke tests.

When YASOS_TCC_PROFILE=1 is set, collects TCC bench breakdown lines
(``# bench ...``) and kernel syscall profile lines (``# perf: ...``)
emitted to stderr during compilation on the target device.

Results are stored per-test and written out as a JSON report at the end
of the pytest session.
"""

import json
import os
import re
from dataclasses import dataclass, field


_BENCH_TOTAL_RE = re.compile(
    r"^# bench total\s+(?P<phase>\S+)\s+(?P<total_ms>\d+)\s+ms\s+(?P<calls>\d+)\s+calls\s+(?P<avg_ms>[\d.]+)\s+ms avg$"
)
_BENCH_STATS_RE = re.compile(
    r"^# (?P<idents>\d+) idents, (?P<lines>\d+) lines, (?P<bytes>\d+) bytes$"
)
_BENCH_SPEED_RE = re.compile(
    r"^# (?P<time>[\d.]+) s, (?P<lines_per_s>\d+) lines/s, (?P<mb_per_s>[\d.]+) MB/s$"
)
_BENCH_OUTPUT_RE = re.compile(
    r"^# text (?P<text>\d+), data\.rw (?P<data_rw>\d+), data\.ro (?P<data_ro>\d+), bss (?P<bss>\d+) bytes$"
)
_PERF_ENTRY_RE = re.compile(
    r"^# (?:syscall_\d+|[\w]+)\s+(?P<calls>\d+)\s+(?P<total>\d+)\s+(?P<max>\d+)\s+(?P<avg>\d+)$"
)


@dataclass
class TestProfile:
    test_id: str
    raw_lines: list[str] = field(default_factory=list)
    bench_phases: dict[str, dict] = field(default_factory=dict)
    stats: dict[str, int] = field(default_factory=dict)
    output_sizes: dict[str, int] = field(default_factory=dict)
    compile_speed: dict[str, float] = field(default_factory=dict)
    syscall_entries: list[dict] = field(default_factory=list)


profile_results: list[TestProfile] = []


def profiling_enabled() -> bool:
    return os.environ.get("YASOS_TCC_PROFILE", "").strip().lower() in {
        "1", "true", "yes", "on",
    }


def extract_profile_lines(lines: list[str]) -> list[str]:
    """Return lines starting with ``# `` (TCC bench/perf output)."""
    return [line for line in lines if line.startswith("# ")]


def record_profile(test_id: str, profile_lines: list[str]) -> None:
    """Parse and store profiling data from a single test compilation."""
    entry = TestProfile(test_id=test_id, raw_lines=list(profile_lines))

    for line in profile_lines:
        m = _BENCH_TOTAL_RE.match(line)
        if m:
            entry.bench_phases[m.group("phase")] = {
                "total_ms": int(m.group("total_ms")),
                "calls": int(m.group("calls")),
                "avg_ms": float(m.group("avg_ms")),
            }
            continue

        m = _BENCH_STATS_RE.match(line)
        if m:
            entry.stats = {
                "idents": int(m.group("idents")),
                "lines": int(m.group("lines")),
                "bytes": int(m.group("bytes")),
            }
            continue

        m = _BENCH_SPEED_RE.match(line)
        if m:
            entry.compile_speed = {
                "time_s": float(m.group("time")),
                "lines_per_s": int(m.group("lines_per_s")),
                "mb_per_s": float(m.group("mb_per_s")),
            }
            continue

        m = _BENCH_OUTPUT_RE.match(line)
        if m:
            entry.output_sizes = {
                "text": int(m.group("text")),
                "data_rw": int(m.group("data_rw")),
                "data_ro": int(m.group("data_ro")),
                "bss": int(m.group("bss")),
            }
            continue

    # Parse syscall profile table (lines after "# perf: syscall profile")
    in_perf_table = False
    for line in profile_lines:
        if "perf: syscall profile" in line:
            in_perf_table = True
            continue
        if in_perf_table and line.startswith("# ") and not line.startswith("# perf:"):
            parts = line[2:].split()
            if len(parts) >= 5:
                try:
                    name = parts[0]
                    calls = int(parts[1])
                    total = int(parts[2])
                    max_cyc = int(parts[3])
                    avg = int(parts[4])
                    entry.syscall_entries.append({
                        "name": name,
                        "calls": calls,
                        "total_cycles": total,
                        "max_cycles": max_cyc,
                        "avg_cycles": avg,
                    })
                except (ValueError, IndexError):
                    pass

    profile_results.append(entry)


def format_profile_report(terminalreporter) -> None:
    """Print profiling summary and write JSON report."""
    if not profile_results:
        return

    report_dir = os.environ.get("YASOS_TIMING_REPORT_DIR", ".")
    report_path = os.path.join(report_dir, "tcc_profile_report.json")

    report_data = []
    for p in profile_results:
        report_data.append({
            "test_id": p.test_id,
            "bench_phases": p.bench_phases,
            "stats": p.stats,
            "compile_speed": p.compile_speed,
            "output_sizes": p.output_sizes,
            "syscall_entries": p.syscall_entries,
            "raw_lines": p.raw_lines,
        })

    try:
        with open(report_path, "w") as fh:
            json.dump(report_data, fh, indent=2)
    except OSError:
        report_path = None

    # Aggregate bench phases across all tests
    phase_totals: dict[str, dict] = {}
    for p in profile_results:
        for phase, data in p.bench_phases.items():
            if phase not in phase_totals:
                phase_totals[phase] = {"total_ms": 0, "calls": 0}
            phase_totals[phase]["total_ms"] += data["total_ms"]
            phase_totals[phase]["calls"] += data["calls"]

    # Aggregate syscall cycles across all tests
    syscall_totals: dict[str, dict] = {}
    for p in profile_results:
        for entry in p.syscall_entries:
            name = entry["name"]
            if name not in syscall_totals:
                syscall_totals[name] = {"calls": 0, "total_cycles": 0, "max_cycles": 0}
            syscall_totals[name]["calls"] += entry["calls"]
            syscall_totals[name]["total_cycles"] += entry["total_cycles"]
            syscall_totals[name]["max_cycles"] = max(
                syscall_totals[name]["max_cycles"], entry["max_cycles"]
            )

    terminalreporter.section("TCC Performance Profile")
    terminalreporter.write_line(f"Tests profiled: {len(profile_results)}")

    if phase_totals:
        terminalreporter.write_line("")
        terminalreporter.write_line("Aggregated TCC phase breakdown:")
        terminalreporter.write_line(
            f"  {'Phase':<20} {'Total ms':>10} {'Calls':>8} {'Avg ms':>10}"
        )
        terminalreporter.write_line(f"  {'-' * 50}")
        total_all_phases = sum(d["total_ms"] for d in phase_totals.values())
        for phase, data in sorted(phase_totals.items(), key=lambda x: x[1]["total_ms"], reverse=True):
            avg = data["total_ms"] / data["calls"] if data["calls"] else 0
            pct = (data["total_ms"] / total_all_phases * 100) if total_all_phases else 0
            terminalreporter.write_line(
                f"  {phase:<20} {data['total_ms']:>10} {data['calls']:>8} {avg:>10.2f}  ({pct:.1f}%)"
            )

    if syscall_totals:
        terminalreporter.write_line("")
        terminalreporter.write_line("Aggregated syscall cycle profile:")
        terminalreporter.write_line(
            f"  {'Syscall':<16} {'Calls':>10} {'Total cyc':>14} {'Max cyc':>12} {'Avg cyc':>12}"
        )
        terminalreporter.write_line(f"  {'-' * 66}")
        grand_total = sum(d["total_cycles"] for d in syscall_totals.values())
        for name, data in sorted(syscall_totals.items(), key=lambda x: x[1]["total_cycles"], reverse=True):
            avg = data["total_cycles"] // data["calls"] if data["calls"] else 0
            pct = (data["total_cycles"] / grand_total * 100) if grand_total else 0
            terminalreporter.write_line(
                f"  {name:<16} {data['calls']:>10} {data['total_cycles']:>14} {data['max_cycles']:>12} {avg:>12}  ({pct:.1f}%)"
            )

    if report_path:
        terminalreporter.write_line(f"\nProfile report saved to: {report_path}")
