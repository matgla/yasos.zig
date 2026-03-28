"""
 Copyright (c) 2025 Mateusz Stadnik

 Permission is hereby granted, free of charge, to any person obtaining a copy of
 this software and associated documentation files (the "Software"), to deal in
 the Software without restriction, including without limitation the rights to
 use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 the Software, and to permit persons to whom the Software is furnished to do so,
 subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 """


import json
import os
from pathlib import Path

import pytest

from .framework.session import Session
from .log_artifacts import move_failed_target_logs
from .log_artifacts import write_failed_pytest_log

session_key = pytest.StashKey()
test_command_hooks_key = pytest.StashKey()
test_log_paths_by_nodeid: dict[str, list[Path]] = {}

_test_progress_total = 0
_test_progress_current = 0
_failed_nodeids_handled: set[str] = set()


def pytest_configure(config):
    test_log_paths_by_nodeid.clear()
    config.addinivalue_line("markers", "gcc_torture: GCC torture smoke tests executed on target")
    config.addinivalue_line("markers", "gcc_compile: GCC torture compile-only smoke tests")
    config.addinivalue_line("markers", "gcc_execute: GCC torture execute smoke tests")


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(items):
    global _test_progress_total, _test_progress_current
    _test_progress_total = len(items)
    _test_progress_current = 0


@pytest.hookimpl
def pytest_runtest_logreport(report):
    global _test_progress_current
    if report.when == "call":
        _test_progress_current += 1
        if report.failed:
            nodeid = report.nodeid
            logs_dir = Path("logs")
            move_failed_target_logs(logs_dir, test_log_paths_by_nodeid.get(nodeid, []))
            write_failed_pytest_log(logs_dir, nodeid, [report])
            _failed_nodeids_handled.add(nodeid)


@pytest.hookimpl(tryfirst=True)
def pytest_report_teststatus(report, config):
    if report.when == "call" and _test_progress_total > 0:
        progress = f" [{_test_progress_current}/{_test_progress_total}]"
        if report.passed:
            return "passed", ".", f"PASSED{progress}"
        if report.failed:
            return "failed", "F", f"FAILED{progress}"
        if report.skipped:
            return "skipped", "s", f"SKIPPED{progress}"


def _load_target_test_command_hooks():
    raw_hooks = os.environ.get("YASOS_SMOKE_TARGET_TEST_COMMAND_HOOKS", "").strip()
    if not raw_hooks:
        return {}

    parsed_hooks = json.loads(raw_hooks)
    normalized_hooks = {}
    for test_id, phases in parsed_hooks.items():
        if not isinstance(test_id, str) or not isinstance(phases, dict):
            continue
        normalized_hooks[test_id] = {
            "setup": tuple(str(command) for command in phases.get("setup", []) if str(command).strip()),
            "teardown": tuple(str(command) for command in phases.get("teardown", []) if str(command).strip()),
        }
    return normalized_hooks


def _item_identifiers(item):
    identifiers = {item.nodeid, item.name}
    callspec = getattr(item, "callspec", None)
    if callspec is None:
        return identifiers

    testcase = callspec.params.get("testcase")
    testcase_id = getattr(testcase, "test_id", None)
    testcase_name = getattr(testcase, "name", None)
    if isinstance(testcase_id, str):
        identifiers.add(testcase_id)
    if isinstance(testcase_name, str):
        identifiers.add(testcase_name)
    return identifiers


def _commands_for_item(item):
    identifiers = _item_identifiers(item)
    for test_id, commands in _load_target_test_command_hooks().items():
        if test_id in identifiers:
            return commands
    return {"setup": (), "teardown": ()}


def _run_target_commands(session, commands):
    for command in commands:
        session.write_command(command)
        session.wait_for_prompt_except_logs()


@pytest.hookimpl
def pytest_runtest_setup(item):
    session = Session(item.name)
    item.stash[session_key] = session
    log_path = getattr(session, "log_path", "")
    if log_path:
        test_log_paths_by_nodeid.setdefault(item.nodeid, []).append(Path(log_path))
    commands = _commands_for_item(item)
    item.stash[test_command_hooks_key] = commands
    _run_target_commands(session, commands["setup"])


@pytest.hookimpl
def pytest_runtest_teardown(item):
    session = item.stash.get(session_key, None)
    if session is None:
        return
    try:
        commands = item.stash.get(test_command_hooks_key, {"setup": (), "teardown": ()})
        _run_target_commands(session, commands["teardown"])
    finally:
        session.close()


@pytest.hookimpl
def pytest_sessionfinish(session, exitstatus):
    Session.finalize()


@pytest.hookimpl
def pytest_terminal_summary(terminalreporter, exitstatus, config):
    failed_reports_by_nodeid: dict[str, list[object]] = {}
    for report in terminalreporter.stats.get("failed", []):
        nodeid = getattr(report, "nodeid", "")
        if not nodeid:
            continue
        failed_reports_by_nodeid.setdefault(nodeid, []).append(report)

    if failed_reports_by_nodeid:
        logs_dir = Path("logs")
        for nodeid, reports in failed_reports_by_nodeid.items():
            if nodeid in _failed_nodeids_handled:
                continue
            move_failed_target_logs(logs_dir, test_log_paths_by_nodeid.get(nodeid, []))
            write_failed_pytest_log(logs_dir, nodeid, reports)
        terminalreporter.write_line(f"Stored failed smoke logs in {logs_dir / 'failed'}")

    from .timing import format_timing_report
    format_timing_report(terminalreporter)

    from .profiling import format_profile_report
    format_profile_report(terminalreporter)
