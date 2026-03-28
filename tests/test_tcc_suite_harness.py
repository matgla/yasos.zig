from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parent))

from smoke import tcc_suite_test as suite


class FakeSerial:
    def __init__(self):
        self.timeout = 1.0


class FakeSession:
    def __init__(self, responses):
        self.serial = FakeSerial()
        self.commands = []
        self._responses = list(responses)

    def write_command(self, command: str) -> None:
        self.commands.append(command)

    def wait_for_prompt_except_logs(self):
        assert self._responses, "unexpected wait_for_prompt_except_logs call"
        response = self._responses.pop(0)
        return list(response)


def _cleanup_command(session: FakeSession) -> str | None:
    cleanup_commands = [command for command in session.commands if command.startswith("rm -f ")]
    return cleanup_commands[-1] if cleanup_commands else None


def _copy_commands(session: FakeSession) -> list[str]:
    return [command for command in session.commands if command.startswith("cp ")]


def test_compile_testcase_keeps_single_source_in_remote_tree(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="00_assignment.c",
        name="00_assignment.c",
        sources=("00_assignment.c",),
        expected_lines=(),
    )
    session = FakeSession([
        [],
        [],
        [],
        [f"{suite.COMPILE_MARKER_PREFIX}0"],
        [f"{suite.EXIT_MARKER_PREFIX}0"],
        [],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(testcase, session)

    compile_command = next(command for command in session.commands if command.startswith("tcc "))
    assert _copy_commands(session) == []
    assert "/root/ci/sources/tests2/00_assignment.c" in compile_command
    assert not session._responses


def test_compile_testcase_keeps_opted_out_source_in_place(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="18_include.c",
        name="18_include.c",
        sources=("18_include.c",),
        expected_lines=(),
    )
    session = FakeSession([
        [],
        [],
        [f"{suite.COMPILE_MARKER_PREFIX}0"],
        [f"{suite.EXIT_MARKER_PREFIX}0"],
        [],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(testcase, session)

    compile_command = next(command for command in session.commands if command.startswith("tcc "))
    assert all(not command.startswith("cp ") for command in session.commands)
    assert "/root/ci/sources/tests2/18_include.c" in compile_command
    assert "/tmp/18_include__18_include.c" not in compile_command
    assert not session._responses


def test_compile_only_testcase_cleans_up_temp_source_but_keeps_output(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="00_assignment.c",
        name="00_assignment.c",
        sources=("00_assignment.c",),
        expected_lines=(),
        compile_only=True,
    )
    session = FakeSession([
        [],
        [],
        [],
        [f"{suite.COMPILE_MARKER_PREFIX}0"],
        [],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(testcase, session)

    cleanup_command = _cleanup_command(session)
    assert cleanup_command is None
    assert not session._responses


def test_compile_testcase_does_not_copy_or_reuse_temp_sources(monkeypatch):
    testcase = suite.TccTestCase(
        test_id="60_errors_and_warnings.c[test_a]",
        name="60_errors_and_warnings.c",
        sources=("60_errors_and_warnings.c",),
        expected_lines=(),
        expected_compile_failure=True,
        expected_error_patterns=(r"60_errors_and_warnings\.c:1:\ error:\ foo",),
    )
    plan = suite._build_temp_source_reuse_marks([
        ("tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_a]", testcase),
        ("tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_b]", testcase),
    ])

    first_session = FakeSession([
        [],
        [],
        [],
        [f"{suite.COMPILE_MARKER_PREFIX}1", "60_errors_and_warnings.c:1: error: foo"],
        [],
    ])
    second_session = FakeSession([
        [],
        [],
        [f"{suite.COMPILE_MARKER_PREFIX}1", "60_errors_and_warnings.c:1: error: foo"],
        [],
    ])
    monkeypatch.setattr(suite, "get_remote_hash", lambda remote_path, _: "a" * 64)

    suite.compile_testcase(
        testcase,
        first_session,
        current_item_id="tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_a]",
        temp_source_plan=plan,
    )
    suite.compile_testcase(
        testcase,
        second_session,
        current_item_id="tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[test_b]",
        temp_source_plan=plan,
    )

    assert _copy_commands(first_session) == []
    assert _cleanup_command(first_session) is None
    assert _copy_commands(second_session) == []
    assert _cleanup_command(second_session) is None
    assert not first_session._responses
    assert not second_session._responses


def test_build_temp_source_reuse_marks_tracks_first_and_last_users():
    testcase = suite.TccTestCase(
        test_id="60_errors_and_warnings.c[test_a]",
        name="60_errors_and_warnings.c",
        sources=("60_errors_and_warnings.c",),
    )
    other_testcase = suite.TccTestCase(
        test_id="00_assignment.c",
        name="00_assignment.c",
        sources=("00_assignment.c",),
    )

    plan = suite._build_temp_source_reuse_marks([
        ("first", testcase),
        ("middle", testcase),
        ("single", other_testcase),
        ("last", testcase),
    ])

    assert plan.first_users == frozenset()
    assert plan.last_users == frozenset()


def test_build_tcc_test_cases_marks_tagged_compile_failures():
    testcase = next(
        case
        for case in suite.build_tcc_test_cases()
        if case.test_id == "60_errors_and_warnings.c[test_56_btype_excess_1]"
    )

    assert testcase.expected_compile_failure is True
    assert testcase.expected_error_patterns == (
        r"60_errors_and_warnings\.c:2:\ error:\ too\ many\ basic\ types",
    )


def test_build_tcc_test_cases_marks_empty_tagged_compile_only_variants_by_source():
    compile_only_ids = {
        "60_errors_and_warnings.c[test_incomplete_array_array]",
        "60_errors_and_warnings.c[test_var_4]",
    }
    runtime_id = "60_errors_and_warnings.c[test_var_1]"

    cases = {case.test_id: case for case in suite.build_tcc_test_cases()}

    assert all(cases[test_id].compile_only is True for test_id in compile_only_ids)
    assert cases[runtime_id].compile_only is False
