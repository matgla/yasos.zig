from pathlib import Path
from types import SimpleNamespace
import sys


sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke.log_artifacts import move_failed_target_logs
from smoke.log_artifacts import write_failed_pytest_log


def test_move_failed_target_logs_moves_only_existing_logs(tmp_path):
    logs_dir = tmp_path / "logs"
    logs_dir.mkdir()
    first_log = logs_dir / "shell_test_2026-03-31_10-00-00.txt"
    second_log = logs_dir / "cd_test_2026-03-31_10-00-01.txt"
    missing_log = logs_dir / "missing.txt"

    first_log.write_text("shell target output\n", encoding="utf-8")
    second_log.write_text("cd target output\n", encoding="utf-8")

    moved_paths = move_failed_target_logs(logs_dir, [first_log, second_log, missing_log, first_log])

    failed_dir = logs_dir / "failed"
    assert moved_paths == [
        failed_dir / first_log.name,
        failed_dir / second_log.name,
    ]
    assert not first_log.exists()
    assert not second_log.exists()
    assert (failed_dir / first_log.name).read_text(encoding="utf-8") == "shell target output\n"
    assert (failed_dir / second_log.name).read_text(encoding="utf-8") == "cd target output\n"


def test_write_failed_pytest_log_includes_phase_traceback_and_sections(tmp_path):
    logs_dir = tmp_path / "logs"
    report = SimpleNamespace(
        when="call",
        outcome="failed",
        longreprtext="assert 1 == 2",
        sections=[
            ("Captured stdout call", "board says hello"),
            ("Captured stderr call", "oops"),
        ],
    )

    artifact_path = write_failed_pytest_log(
        logs_dir,
        "tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[00_assignment.c]",
        [report],
    )

    assert artifact_path.parent == logs_dir / "failed"
    assert artifact_path.name.endswith("_pytest.txt")
    content = artifact_path.read_text(encoding="utf-8")
    assert "nodeid: tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[00_assignment.c]" in content
    assert "phase: call" in content
    assert "outcome: failed" in content
    assert "assert 1 == 2" in content
    assert "--- Captured stdout call ---" in content
    assert "board says hello" in content
    assert "--- Captured stderr call ---" in content
    assert "oops" in content
