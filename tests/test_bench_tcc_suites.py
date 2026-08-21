"""Tests for the hardware best-of-N harness (scripts/bench_tcc_suites.py).

Everything covered here is a thing that would produce a *plausible* number
rather than an error, which is the only failure mode that matters in a
measurement tool: a run whose second half of `run_info.txt` never arrived
timing as zero and winning; a category split that quietly folds gcc_execute
into tests2; a failed run being offered as the baseline. The suite selection is
pinned too, because the one thing this script must never do is silently measure
a different corpus than the one it names.
"""

import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import bench_tcc_suites as bench  # noqa: E402


RUN_INFO = """run_id=7
started=2026-08-17T10:00:00+02:00
kernel_sha=abc123
rootfs_sha=def456
profile=0
opt_levels=-O0 -O1 -O2
gcc_torture=1
extra_tcc_cflags=
tcc_env_prefix=
git_rev=deadbee
pytest_args='tests/smoke/tcc_suite_test.py' '-m' 'not gcc_compile'
finished=2026-08-17T10:10:36+02:00
status=0
"""


# ---------------------------------------------------------------------------
# The suite selection
# ---------------------------------------------------------------------------


class TestSuiteSelection:
    def test_it_names_the_tcc_corpus_and_drops_compile_only(self) -> None:
        # The three suites are "everything in tcc_suite_test.py that is not
        # gcc_compile". If either half of that changes, the script is measuring
        # a different corpus than its name and its report claim.
        assert "tests/smoke/tcc_suite_test.py" in bench.SUITE_PYTEST_ARGS
        assert "not gcc_compile" in bench.SUITE_PYTEST_ARGS

    def test_the_command_carries_the_selection_and_stays_non_interactive(self) -> None:
        args = bench.parse_args([])
        cmd = bench.build_command(args)

        assert "--run-cached" in cmd, "a benchmark must not stop at the TUI"
        assert "--with-gcc-torture" in cmd, "gcc_execute needs torture enabled"
        assert bench.SUITE_PYTEST_ARGS in cmd

    def test_retries_are_off_by_default(self) -> None:
        # A retry turns a failure into a slower pass, which is exactly what a
        # wall-time measurement must not absorb silently.
        cmd = bench.build_command(bench.parse_args([]))
        assert cmd[cmd.index("--test-retries") + 1] == "0"

    def test_opt_levels_and_keyword_reach_the_runner(self) -> None:
        cmd = bench.build_command(bench.parse_args(["--opt-levels", "-O0", "-k", "09_do_while"]))
        assert cmd[cmd.index("--smoke-tcc-opt-levels") + 1] == "-O0"
        assert cmd[cmd.index("-k") + 1] == "09_do_while"

    def test_several_levels_are_absorbed_into_one_value(self) -> None:
        # `-O0` reads as a flag to argparse, so the spelling run_hw_smoke.sh
        # documents has to be folded up before the parser sees it.
        args = bench.parse_args(["--opt-levels", "-O0", "-O2", "-n", "2"])
        assert args.opt_levels == "-O0 -O2"
        assert args.repeats == 2

    def test_the_comma_form_survives_an_unquoted_expansion(self) -> None:
        assert bench.parse_args(["--opt-levels", "-O0,-O2"]).opt_levels == "-O0 -O2"
        assert bench.parse_args(["--opt-levels=-O1"]).opt_levels == "-O1"

    def test_levels_are_not_absorbed_from_the_passthrough(self) -> None:
        # Everything after `--` belongs to remote_smoke_tui, including its own
        # flags that happen to start with -O.
        args = bench.parse_args(["--opt-levels", "-O0", "--", "--force"])
        assert args.opt_levels == "-O0"
        assert args.passthrough == ["--force"]

    def test_arguments_after_the_separator_are_passed_through(self) -> None:
        cmd = bench.build_command(bench.parse_args(["--", "--force"]))
        assert cmd[-1] == "--force"


# ---------------------------------------------------------------------------
# Reading a run back
# ---------------------------------------------------------------------------


class TestRunInfo:
    def test_a_value_with_equals_signs_survives(self, tmp_path: Path) -> None:
        path = tmp_path / "run_info.txt"
        path.write_text("pytest_args='-k' 'a=b'\nstatus=0\n", encoding="utf-8")
        assert bench.parse_run_info(path)["pytest_args"] == "'-k' 'a=b'"

    def test_the_remote_pytest_phase_is_what_is_timed(self, tmp_path: Path) -> None:
        path = tmp_path / "run_info.txt"
        path.write_text(RUN_INFO, encoding="utf-8")
        assert bench.suite_seconds_from(bench.parse_run_info(path)) == 636.0

    def test_a_run_that_never_finished_has_no_time(self) -> None:
        # The killed-run case, and the one that matters: a missing `finished`
        # must not read as zero seconds, which would win every ranking.
        half = {"run_id": "7", "started": "2026-08-17T10:00:00+02:00"}
        assert bench.suite_seconds_from(half) is None

    def test_an_unparseable_stamp_is_no_time_rather_than_a_crash(self) -> None:
        assert bench.suite_seconds_from({"started": "yesterday", "finished": "today"}) is None

    def test_a_missing_file_is_empty_rather_than_an_error(self, tmp_path: Path) -> None:
        assert bench.parse_run_info(tmp_path / "nope.txt") == {}


class TestTimingReport:
    def _report(self, tmp_path: Path) -> Path:
        path = tmp_path / "tcc_timing_report.json"
        path.write_text(
            json.dumps(
                {
                    "summary": {"total_tests": 4},
                    "tests": [
                        {"test_id": "00_assignment.c[-O0]", "compile_ms": 100.0, "execute_ms": 10.0},
                        {"test_id": "ir_tests/mibench_rijndael.c[-O0]", "compile_ms": 200.0,
                         "execute_ms": 20.0},
                        {"test_id": "gcc_execute/strlen-5[-O0]", "compile_ms": 300.0,
                         "execute_ms": 30.0},
                        {"test_id": "gcc_compile/pr28982b[-O0]", "compile_ms": 400.0,
                         "execute_ms": 0.0},
                    ],
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_each_suite_lands_in_its_own_category(self, tmp_path: Path) -> None:
        # Split on the test-id prefix, exactly as tests/smoke/timing.py does it,
        # so this report and the one the suite prints cannot disagree.
        categories, total = bench.parse_timing_report(self._report(tmp_path))

        assert total == 4
        assert categories["tests2"]["compile_ms"] == 100.0
        assert categories["ir_tests"]["compile_ms"] == 200.0
        assert categories["gcc_execute"]["execute_ms"] == 30.0
        assert categories["gcc_compile"]["compile_ms"] == 400.0

    def test_cases_are_counted_per_category(self, tmp_path: Path) -> None:
        categories, _ = bench.parse_timing_report(self._report(tmp_path))
        assert [int(categories[name]["tests"]) for name in
                ("tests2", "ir_tests", "gcc_execute", "gcc_compile")] == [1, 1, 1, 1]

    def test_a_missing_or_broken_report_is_empty(self, tmp_path: Path) -> None:
        assert bench.parse_timing_report(tmp_path / "nope.json") == ({}, None)
        broken = tmp_path / "broken.json"
        broken.write_text("{not json", encoding="utf-8")
        assert bench.parse_timing_report(broken) == ({}, None)


class TestPytestCounts:
    def _write(self, tmp_path: Path, text: str) -> Path:
        path = tmp_path / "run.log"
        path.write_text(text, encoding="utf-8")
        return path

    def test_the_summary_line(self, tmp_path: Path) -> None:
        log = self._write(tmp_path, "lots of output\n=== 2489 passed, 33 skipped in 622.13s ===\n")
        assert bench.parse_pytest_counts(log) == (2489, None, 33)

    def test_failures_are_counted(self, tmp_path: Path) -> None:
        log = self._write(tmp_path, "=== 12 failed, 2480 passed, 30 skipped in 700.00s ===\n")
        assert bench.parse_pytest_counts(log) == (2480, 12, 30)

    def test_errors_count_as_failures(self, tmp_path: Path) -> None:
        # An erroring test is a test that did not run to completion, so the
        # run is no more a baseline than one with an assertion failure.
        log = self._write(tmp_path, "=== 2 errors, 10 passed in 5.00s ===\n")
        assert bench.parse_pytest_counts(log) == (10, 2, None)

    def test_the_last_summary_wins(self, tmp_path: Path) -> None:
        log = self._write(
            tmp_path,
            "=== 1 passed in 1.00s ===\nrerunning\n=== 5 passed, 1 failed in 9.00s ===\n",
        )
        assert bench.parse_pytest_counts(log) == (5, 1, None)

    def test_no_summary_at_all(self, tmp_path: Path) -> None:
        assert bench.parse_pytest_counts(self._write(tmp_path, "board wedged\n")) == (
            None, None, None
        )
        assert bench.parse_pytest_counts(None) == (None, None, None)


class TestRunDirectories:
    def test_only_numbered_directories_count(self, tmp_path: Path) -> None:
        (tmp_path / "1").mkdir()
        (tmp_path / "2").mkdir()
        (tmp_path / "notes").mkdir()
        (tmp_path / "latest").symlink_to(tmp_path / "2")
        (tmp_path / "3.txt").write_text("", encoding="utf-8")

        assert bench.run_ids_in(tmp_path) == {1, 2}

    def test_a_mirror_that_does_not_exist_yet(self, tmp_path: Path) -> None:
        assert bench.run_ids_in(tmp_path / "nope") == set()


# ---------------------------------------------------------------------------
# What may win
# ---------------------------------------------------------------------------


class TestRanking:
    def test_a_run_with_failures_is_not_clean(self) -> None:
        assert not bench.RunResult(index=1, status=0, failed=3).clean
        assert not bench.RunResult(index=1, status=1, failed=0).clean
        assert bench.RunResult(index=1, status=0, failed=0).clean

    def test_a_run_with_no_time_sorts_last(self) -> None:
        # Not first, which is what a `None` treated as zero would do.
        timed = bench.RunResult(index=1, suite_seconds=900.0)
        untimed = bench.RunResult(index=2)
        assert min([untimed, timed], key=lambda r: r.ranked_seconds) is timed

    def test_durations_read_the_way_a_run_is_talked_about(self) -> None:
        assert bench.format_duration(636.0) == "10:36"
        assert bench.format_duration(45.6) == "45.6s"
        assert bench.format_duration(None) == "—"


class TestHardwareOnly:
    def test_a_config_with_no_board_is_refused(self) -> None:
        # There is no QEMU path here on purpose: the XIP cache, the flash
        # transactions and the SD write path are the measurement.
        with pytest.raises(SystemExit):
            bench.require_hardware({"ssh_target": ""})

    def test_a_configured_board_passes(self) -> None:
        bench.require_hardware({"ssh_target": "mateusz@192.168.0.113"})
