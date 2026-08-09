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
import logging
import os
import sys
from pathlib import Path

import pytest

from .framework.session import Session
from .log_artifacts import move_failed_target_logs
from .log_artifacts import write_failed_pytest_log
from .progress import ANNOUNCE_AFTER_SECONDS
from .progress import ANNOUNCE_EVERY_SECONDS
from .progress import RunningTestAnnouncer
from .progress import format_duration

session_key = pytest.StashKey()
test_command_hooks_key = pytest.StashKey()
test_log_paths_by_nodeid: dict[str, list[Path]] = {}

_test_progress_total = 0
_test_progress_current = 0
_failed_nodeids_handled: set[str] = set()
# Wall time already spent in earlier phases (setup) of the running test, so the
# reported duration is the whole time the test occupied the line.
_phase_seconds_by_nodeid: dict[str, float] = {}
_running_announcer: RunningTestAnnouncer | None = None


def pytest_configure(config):
    test_log_paths_by_nodeid.clear()
    config.addinivalue_line("markers", "gcc_torture: GCC torture smoke tests executed on target")
    config.addinivalue_line("markers", "gcc_compile: GCC torture compile-only smoke tests")
    config.addinivalue_line("markers", "gcc_execute: GCC torture execute smoke tests")
    config.addinivalue_line(
        "markers",
        "measure: opt-in instruments that report numbers instead of asserting;"
        " skipped unless selected with -m measure",
    )

    global _running_announcer
    _running_announcer = RunningTestAnnouncer(
        config, ANNOUNCE_AFTER_SECONDS, ANNOUNCE_EVERY_SECONDS
    )


def pytest_unconfigure(config):
    global _running_announcer
    if _running_announcer is not None:
        _running_announcer.stop()
        _running_announcer = None


@pytest.hookimpl(trylast=True)
def pytest_runtest_logstart(nodeid, location):
    if _running_announcer is not None:
        _running_announcer.start(nodeid)


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_logfinish(nodeid, location):
    if _running_announcer is not None:
        _running_announcer.finish()
    _phase_seconds_by_nodeid.pop(nodeid, None)


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(config, items):
    # Instruments are collected by the default `tests/smoke` glob like anything
    # else, so they have to opt out rather than in: a measurement that reports
    # numbers has no verdict to contribute to a suite run, and the run should
    # not pay for it. Selecting them takes `-m measure`, which reaches the
    # remote pytest through --pytest-args -- an environment variable would not,
    # since the generated remote script forwards none.
    if "measure" not in (config.getoption("-m") or ""):
        skip_measure = pytest.mark.skip(reason="instrument; select with -m measure")
        for item in items:
            if "measure" in item.keywords:
                item.add_marker(skip_measure)

    global _test_progress_total, _test_progress_current
    _test_progress_total = len(items)
    _test_progress_current = 0


# tryfirst so the counter is incremented before the terminal reporter asks
# pytest_report_teststatus for the word it prints -- that call happens inside
# the reporter's own pytest_runtest_logreport, so a later hook would label the
# first test [0/N] and the last [N-1/N].
@pytest.hookimpl(tryfirst=True)
def pytest_runtest_logreport(report):
    global _test_progress_current
    if report.when == "setup":
        _phase_seconds_by_nodeid[report.nodeid] = report.duration
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
        # setup + call, i.e. the wall time from the nodeid appearing to the
        # result being printed. Teardown is still pending at this point.
        duration = _phase_seconds_by_nodeid.get(report.nodeid, 0.0) + report.duration
        suffix = f"{progress} {format_duration(duration)}"
        if report.passed:
            return "passed", ".", f"PASSED{suffix}"
        if report.failed:
            return "failed", "F", f"FAILED{suffix}"
        if report.skipped:
            return "skipped", "s", f"SKIPPED{suffix}"


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


def _imported_module(name):
    """This package's ``name`` module, if something already imported it."""
    if __package__:
        module = sys.modules.get(f"{__package__}.{name}")
        if module is not None:
            return module
    suffix = f".{name}"
    for module_name, module in list(sys.modules.items()):
        if module_name == name or module_name.endswith(suffix):
            return module
    return None


def _record_source_manifest():
    """Persist the smoke source manifest before the target is shut down.

    The manifest is rewritten every ``SOURCE_MANIFEST_FLUSH_EVERY`` newly
    verified sources, so without this the tail of a run -- everything verified
    since the last threshold -- would go unrecorded and be re-verified next
    time. This runs on interrupted runs too, which is where it matters most:
    pytest still calls sessionfinish after a Ctrl-C.
    """
    # Looked up rather than imported: importing the compiler suite builds its
    # whole test corpus, which a run that never touched it should not pay for
    # (and conftest cannot import it at module level anyway -- that module
    # imports this one).
    suite = _imported_module("tcc_suite_test")
    if suite is None or Session.target_crashed or Session.target_needs_reset:
        return
    session = Session.detached("source_manifest")
    if session is None:
        return
    try:
        # A run cut short mid-compile leaves the device busy; the manifest is
        # not worth fighting for a prompt over, the next run just re-verifies.
        if session._try_recover_prompt():
            suite.flush_source_manifest(session, force=True)
    except Exception:
        # Never turn a bookkeeping write into a test-run failure.
        logging.getLogger(__name__).warning(
            "failed to record the smoke source manifest", exc_info=True
        )
    finally:
        session.close()


@pytest.hookimpl
def pytest_runtest_teardown(item):
    session = item.stash.get(session_key, None)
    if session is None:
        return
    try:
        if Session.target_crashed:
            # Board is wedged in a panic; running teardown commands on it would
            # just time out. Reboot and pull the persisted kernel logs off the
            # SD card into this test's log instead.
            session.collect_crash_logs()
        else:
            commands = item.stash.get(test_command_hooks_key, {"setup": (), "teardown": ()})
            _run_target_commands(session, commands["teardown"])
    finally:
        session.close()


@pytest.hookimpl
def pytest_sessionfinish(session, exitstatus):
    _record_source_manifest()
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
