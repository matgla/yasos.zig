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
    r"^# bench total\s+(?P<phase>\S+)\s+(?P<total_us>\d+)\s+us\s+(?P<calls>\d+)\s+calls\s+(?P<avg_us>[\d.]+)\s+us avg$"
)
# `# init <phase> <delta_us> <at_us>` — the startup/teardown stamps, which are
# the only instrument that covers the part of a compile before and after the
# bench phases. The header row and the trailing `total` row (which has no
# at_us column) are handled by the same pattern via the optional group.
_INIT_RE = re.compile(
    r"^# init (?P<phase>.+?)\s+(?P<delta_us>\d+)(?:\s+(?P<at_us>\d+))?\s*$"
)
_BENCH_OUTPUT_SPLIT_RE = re.compile(
    r"^# bench output-split (?P<pairs>.*)$"
)
_BENCH_OUTPUT_SPLIT_PAIR_RE = re.compile(r"(?P<name>[a-z]+) (?P<us>\d+) us")
_BENCH_BIGALLOC_RE = re.compile(
    r"^# bench total big-allocs\s+(?P<calls>\d+)\s+calls\s+(?P<kib>\d+) KiB"
)
_BENCH_ALLOC_SITE_RE = re.compile(
    r"^# bench alloc-site (?P<site>\S+) (?P<calls>\d+) calls (?P<kib>\d+) KiB$"
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
_PERF_SYS_RE = re.compile(
    r"^# perf: sys calls=(?P<calls>\d+) us=(?P<us>\d+) handler_us=(?P<handler_us>\d+)"
    r" load_us=(?P<load_us>\d+) dropped=(?P<dropped>\d+)$"
)
_PERF_IO_RE = re.compile(
    r"^# perf: io read=(?P<read_bytes>\d+)/(?P<read_us>\d+)"
    r" write=(?P<write_bytes>\d+)/(?P<write_us>\d+)$"
)
_PERF_TOP_RE = re.compile(r"^# perf: top (?P<entries>.*)$")
_PERF_TOP_ENTRY_RE = re.compile(r"(?P<name>\w+)=(?P<calls>\d+)/(?P<us>\d+)")


@dataclass
class TestProfile:
    test_id: str
    raw_lines: list[str] = field(default_factory=list)
    bench_phases: dict[str, dict] = field(default_factory=dict)
    # `# init` stamps: label -> microseconds spent since the previous stamp.
    # Covers the whole process, including what happens before and after the
    # bench phases, which is where the per-compile floor lives.
    init_phases: dict[str, int] = field(default_factory=dict)
    init_total_us: int = 0
    output_split: dict[str, int] = field(default_factory=dict)
    alloc_sites: list[dict] = field(default_factory=list)
    big_allocs: dict[str, int] = field(default_factory=dict)
    stats: dict[str, int] = field(default_factory=dict)
    output_sizes: dict[str, int] = field(default_factory=dict)
    compile_speed: dict[str, float] = field(default_factory=dict)
    syscall_entries: list[dict] = field(default_factory=list)
    # Kernel-measured totals for the tcc process (see libs/libc/sys/perf.c).
    syscall_summary: dict = field(default_factory=dict)

    @property
    def internal_compile_ms(self) -> float | None:
        if not self.compile_speed:
            return None
        time_s = self.compile_speed.get("time_s")
        if time_s is None:
            return None
        return time_s * 1000.0


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
                "total_us": int(m.group("total_us")),
                "calls": int(m.group("calls")),
                "avg_us": float(m.group("avg_us")),
            }
            continue

        m = _BENCH_BIGALLOC_RE.match(line)
        if m:
            entry.big_allocs = {"calls": int(m.group("calls")), "kib": int(m.group("kib"))}
            continue

        m = _BENCH_ALLOC_SITE_RE.match(line)
        if m:
            entry.alloc_sites.append({
                "site": m.group("site"),
                "calls": int(m.group("calls")),
                "kib": int(m.group("kib")),
            })
            continue

        m = _BENCH_OUTPUT_SPLIT_RE.match(line)
        if m:
            for pair in _BENCH_OUTPUT_SPLIT_PAIR_RE.finditer(m.group("pairs")):
                entry.output_split[pair.group("name")] = int(pair.group("us"))
            continue

        m = _INIT_RE.match(line)
        if m:
            phase = m.group("phase").strip()
            if phase == "phase":  # header row
                continue
            if phase == "total":
                entry.init_total_us = int(m.group("delta_us"))
                continue
            # A phase can be stamped more than once per compile (`source open`
            # fires for every file opened, includes and all), so accumulate.
            entry.init_phases[phase] = entry.init_phases.get(phase, 0) + int(m.group("delta_us"))
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

    # Parse the compact syscall profile (three `# perf:` lines). The old
    # 64-line table form is still available on the device via TCC_PERF_TABLE=1,
    # but a suite run cannot afford to print it.
    for line in profile_lines:
        m = _PERF_SYS_RE.match(line)
        if m:
            entry.syscall_summary.update({
                "calls": int(m.group("calls")),
                "total_us": int(m.group("us")),
                "handler_us": int(m.group("handler_us")),
                "load_us": int(m.group("load_us")),
                "dropped": int(m.group("dropped")),
            })
            continue

        m = _PERF_IO_RE.match(line)
        if m:
            entry.syscall_summary.update({
                "read_bytes": int(m.group("read_bytes")),
                "read_us": int(m.group("read_us")),
                "write_bytes": int(m.group("write_bytes")),
                "write_us": int(m.group("write_us")),
            })
            continue

        m = _PERF_TOP_RE.match(line)
        if m:
            for top in _PERF_TOP_ENTRY_RE.finditer(m.group("entries")):
                entry.syscall_entries.append({
                    "name": top.group("name"),
                    "calls": int(top.group("calls")),
                    "total_us": int(top.group("us")),
                })

    profile_results.append(entry)


def format_profile_report(terminalreporter) -> None:
    """Print profiling summary and write JSON report."""
    if not profile_results:
        return

    from .timing import timing_results

    wall_compile_ms_by_test = {entry.test_id: entry.compile_ms for entry in timing_results}

    report_dir = os.environ.get("YASOS_TIMING_REPORT_DIR", ".")
    report_path = os.path.join(report_dir, "tcc_profile_report.json")

    report_data = []
    for p in profile_results:
        wall_compile_ms = wall_compile_ms_by_test.get(p.test_id)
        internal_compile_ms = p.internal_compile_ms
        compile_overhead_ms = None
        if wall_compile_ms is not None and internal_compile_ms is not None:
            compile_overhead_ms = max(0.0, wall_compile_ms - internal_compile_ms)
        report_data.append({
            "test_id": p.test_id,
            "bench_phases": p.bench_phases,
            "init_phases": p.init_phases,
            "init_total_us": p.init_total_us,
            "output_split": p.output_split,
            "alloc_sites": p.alloc_sites,
            "big_allocs": p.big_allocs,
            "stats": p.stats,
            "compile_speed": p.compile_speed,
            "wall_compile_ms": round(wall_compile_ms, 2) if wall_compile_ms is not None else None,
            "internal_compile_ms": round(internal_compile_ms, 2) if internal_compile_ms is not None else None,
            "compile_overhead_ms": round(compile_overhead_ms, 2) if compile_overhead_ms is not None else None,
            "output_sizes": p.output_sizes,
            "syscall_entries": p.syscall_entries,
            "syscall_summary": p.syscall_summary,
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
                phase_totals[phase] = {"total_us": 0, "calls": 0}
            phase_totals[phase]["total_us"] += data["total_us"]
            phase_totals[phase]["calls"] += data["calls"]

    # Aggregate the startup/teardown stamps the same way. These are the only
    # rows that cover the per-compile floor, which is why they are reported
    # separately from the bench phases rather than merged into them.
    init_totals: dict[str, int] = {}
    init_grand_total_us = 0
    for p in profile_results:
        init_grand_total_us += p.init_total_us
        for phase, us in p.init_phases.items():
            init_totals[phase] = init_totals.get(phase, 0) + us

    alloc_site_totals: dict[str, dict] = {}
    for p in profile_results:
        for site in p.alloc_sites:
            row = alloc_site_totals.setdefault(site["site"], {"calls": 0, "kib": 0})
            row["calls"] += site["calls"]
            row["kib"] += site["kib"]

    # Aggregate syscall time across all tests
    syscall_totals: dict[str, dict] = {}
    for p in profile_results:
        for entry in p.syscall_entries:
            name = entry["name"]
            if name not in syscall_totals:
                syscall_totals[name] = {"calls": 0, "total_us": 0}
            syscall_totals[name]["calls"] += entry["calls"]
            syscall_totals[name]["total_us"] += entry["total_us"]

    wall_compile_total_ms = 0.0
    internal_compile_total_ms = 0.0
    loader_total_ms = 0.0
    compile_overhead_rows = []
    for p in profile_results:
        wall_compile_ms = wall_compile_ms_by_test.get(p.test_id)
        internal_compile_ms = p.internal_compile_ms
        if wall_compile_ms is None or internal_compile_ms is None:
            continue
        compile_overhead_ms = max(0.0, wall_compile_ms - internal_compile_ms)
        loader_ms = p.syscall_summary.get("load_us", 0) / 1000.0
        wall_compile_total_ms += wall_compile_ms
        internal_compile_total_ms += internal_compile_ms
        loader_total_ms += loader_ms
        compile_overhead_rows.append({
            "test_id": p.test_id,
            "wall_compile_ms": wall_compile_ms,
            "internal_compile_ms": internal_compile_ms,
            "compile_overhead_ms": compile_overhead_ms,
            "loader_ms": loader_ms,
        })
    compile_overhead_rows.sort(key=lambda row: row["compile_overhead_ms"], reverse=True)

    terminalreporter.section("TCC Performance Profile")
    terminalreporter.write_line(f"Tests profiled: {len(profile_results)}")

    if compile_overhead_rows:
        compile_overhead_total_ms = wall_compile_total_ms - internal_compile_total_ms
        overhead_pct = (compile_overhead_total_ms / wall_compile_total_ms * 100.0) if wall_compile_total_ms else 0.0
        terminalreporter.write_line("")
        terminalreporter.write_line("Wall vs internal compile time:")
        terminalreporter.write_line(
            f"  Wall compile total:     {wall_compile_total_ms / 1000.0:.2f}s"
        )
        terminalreporter.write_line(
            f"  TCC internal total:     {internal_compile_total_ms / 1000.0:.2f}s"
        )
        terminalreporter.write_line(
            f"  Estimated overhead:     {compile_overhead_total_ms / 1000.0:.2f}s ({overhead_pct:.1f}%)"
        )
        terminalreporter.write_line(
            f"    of which loader:      {loader_total_ms / 1000.0:.2f}s "
            f"({loader_total_ms / compile_overhead_total_ms * 100.0 if compile_overhead_total_ms else 0.0:.1f}% of overhead)"
        )
        terminalreporter.write_line(
            "  The rest is wall-clock outside TCC bench timing: shell/process setup, "
            "process teardown, and prompt/serial wait."
        )

        terminalreporter.write_line("")
        terminalreporter.write_line("Top tests by wall-minus-bench compile overhead:")
        terminalreporter.write_line(
            f"  {'#':<4} {'Test ID':<55} {'Wall':>10} {'Bench':>10} {'Overhead':>10} {'Loader':>10}"
        )
        terminalreporter.write_line(f"  {'-' * 108}")
        for index, row in enumerate(compile_overhead_rows[:15], 1):
            terminalreporter.write_line(
                f"  {index:<4} {row['test_id']:<55} "
                f"{row['wall_compile_ms']:>8.1f}ms "
                f"{row['internal_compile_ms']:>8.1f}ms "
                f"{row['compile_overhead_ms']:>8.1f}ms "
                f"{row['loader_ms']:>8.1f}ms"
            )

    n_profiled = len(profile_results)

    if init_totals:
        terminalreporter.write_line("")
        terminalreporter.write_line(
            "Startup/teardown stamps (whole process, includes the per-compile floor):"
        )
        terminalreporter.write_line(
            f"  {'Phase':<24} {'Total s':>10} {'Per compile':>13} {'Share':>8}"
        )
        terminalreporter.write_line(f"  {'-' * 58}")
        for phase, us in sorted(init_totals.items(), key=lambda x: x[1], reverse=True):
            pct = (us / init_grand_total_us * 100) if init_grand_total_us else 0
            terminalreporter.write_line(
                f"  {phase:<24} {us / 1e6:>10.2f} {us / 1000.0 / n_profiled:>11.2f}ms {pct:>7.1f}%"
            )
        terminalreporter.write_line(
            f"  {'in-main total':<24} {init_grand_total_us / 1e6:>10.2f} "
            f"{init_grand_total_us / 1000.0 / n_profiled:>11.2f}ms"
        )

    if phase_totals:
        terminalreporter.write_line("")
        terminalreporter.write_line("Aggregated TCC phase breakdown:")
        terminalreporter.write_line(
            f"  {'Phase':<20} {'Total s':>10} {'Calls':>8} {'Avg us':>11} {'Per compile':>13}"
        )
        terminalreporter.write_line(f"  {'-' * 66}")
        for phase, data in sorted(phase_totals.items(), key=lambda x: x[1]["total_us"], reverse=True):
            avg = data["total_us"] / data["calls"] if data["calls"] else 0
            terminalreporter.write_line(
                f"  {phase:<20} {data['total_us'] / 1e6:>10.2f} {data['calls']:>8} "
                f"{avg:>11.1f} {data['total_us'] / 1000.0 / n_profiled:>11.2f}ms"
            )
        terminalreporter.write_line(
            "  Phases nest: compile = setup+exec+finalize; exec contains the four "
            "func-* phases plus top-level declarations."
        )

    if alloc_site_totals:
        terminalreporter.write_line("")
        terminalreporter.write_line("Top mmap-class allocation sites (>=2 KiB):")
        terminalreporter.write_line(f"  {'Site':<32} {'Calls':>10} {'MiB':>10} {'Per compile':>13}")
        terminalreporter.write_line(f"  {'-' * 68}")
        for site, data in sorted(alloc_site_totals.items(), key=lambda x: x[1]["kib"], reverse=True)[:15]:
            terminalreporter.write_line(
                f"  {site:<32} {data['calls']:>10} {data['kib'] / 1024.0:>10.1f} "
                f"{data['calls'] / n_profiled:>9.1f}/cc"
            )

    if syscall_totals:
        terminalreporter.write_line("")
        terminalreporter.write_line("Aggregated syscall profile (kernel time, tcc process only):")
        terminalreporter.write_line(
            f"  {'Syscall':<16} {'Calls':>10} {'Total':>14} {'Avg':>12}"
        )
        terminalreporter.write_line(f"  {'-' * 54}")
        grand_total = sum(d["total_us"] for d in syscall_totals.values())
        for name, data in sorted(syscall_totals.items(), key=lambda x: x[1]["total_us"], reverse=True):
            avg = data["total_us"] / data["calls"] if data["calls"] else 0
            pct = (data["total_us"] / grand_total * 100) if grand_total else 0
            terminalreporter.write_line(
                f"  {name:<16} {data['calls']:>10} {data['total_us'] / 1000.0:>12.1f}ms "
                f"{avg:>10.1f}us  ({pct:.1f}%)"
            )

    if report_path:
        terminalreporter.write_line(f"\nProfile report saved to: {report_path}")
