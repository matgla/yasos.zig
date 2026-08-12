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
from fnmatch import fnmatch
from pathlib import Path

import pytest

from .framework.paths import smoke_log_dir
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
    config.addinivalue_line(
        "markers",
        "heavy: memory-heavy. Applied from tests/smoke/heavy_tests.txt, not"
        " written on the test. Nothing selects on it by default -- it is there"
        " for a hand-written -m 'not heavy'",
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


# Under xdist the controller never collects -- the workers do -- so the hook
# above leaves the controller total at 0 and the [n/total] suffix vanishes from
# the parallel QEMU gate. Every worker collects the same set, so the first node
# to report its ids fixes the total. optionalhook because the hardware venv has
# no pytest-xdist, where an unknown hook name is a PluginValidationError.
@pytest.hookimpl(optionalhook=True)
def pytest_xdist_node_collection_finished(node, ids):
    global _test_progress_total
    if _test_progress_total == 0:
        _test_progress_total = len(ids)


# tryfirst so the counter is incremented before the terminal reporter asks
# pytest_report_teststatus for the word it prints; a later hook would label the
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
            logs_dir = smoke_log_dir()
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


HEAVY_LIST_PATH = Path(__file__).with_name("heavy_tests.txt")
MEM_REPORT_DIR = os.environ.get("YASOS_SMOKE_MEM_REPORT", "").strip()


_heavy_patterns_cache = None


def _heavy_patterns():
    """Globs naming the tests that must not run in parallel.

    Kept in a data file rather than as markers on the tests themselves because
    the entries are mostly individual parametrised cases out of a generated
    corpus -- there is no source line to decorate, and the set is a property of
    how big a translation unit happens to be rather than of what the test means.
    """
    global _heavy_patterns_cache
    if _heavy_patterns_cache is not None:
        return _heavy_patterns_cache
    try:
        raw = HEAVY_LIST_PATH.read_text(encoding="utf-8")
    except OSError:
        _heavy_patterns_cache = []
        return _heavy_patterns_cache
    patterns = []
    for line in raw.splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            patterns.append(entry)
    _heavy_patterns_cache = patterns
    return _heavy_patterns_cache


def _is_heavy(nodeid, patterns):
    for pattern in patterns:
        if fnmatch(nodeid, pattern):
            return True
        # A pattern with no wildcard is also accepted as a plain substring, so
        # a whole family can be named by the fragment its ids share.
        if not any(ch in pattern for ch in "*?[") and pattern in nodeid:
            return True
    return False


def pytest_itemcollected(item):
    """Tag the memory-heavy tests so a run can hold them out of -n auto.

    Applied here rather than in pytest_collection_modifyitems, and that is not a
    style choice: -m deselection *is* a pytest_collection_modifyitems hook, and
    this file's own implementation of that hook is trylast, so a marker added
    there lands after the filter has already picked its items and the entries in
    heavy_tests.txt are silently ignored. pytest_itemcollected runs while the
    items are still being collected, before any of that.
    """
    patterns = _heavy_patterns()
    if patterns and _is_heavy(item.nodeid, patterns):
        item.add_marker(pytest.mark.heavy)


def _guest_mempeak(session):
    """Sample /proc/mempeak on the target, in bytes, and clear it.

    The number that matters is the *guest's*, not the qemu process's. A qemu
    running this kernel sits at about 72 MiB of host RSS no matter what the
    guest is doing, and the per-test differences ride on top of that as a couple
    of MiB -- which is why these tests also fit on an rp2350 with 8 MB. In the
    guest the same two tests differ by 3.6x.
    """
    try:
        session.write_command("cat /proc/mempeak")
        for line in session.wait_for_prompt_except_logs():
            if line.startswith("process_peak_bytes "):
                return int(line.split()[1])
    except Exception:
        # A wedged target must not turn a bookkeeping read into a failure.
        return None
    return None


def _reset_guest_mempeak(item):
    """Open this test's measurement window (the read is what clears the mark)."""
    if not MEM_REPORT_DIR:
        return
    session = item.stash.get(session_key, None)
    if session is not None and not Session.target_crashed:
        _guest_mempeak(session)


def _record_peak_memory(item):
    """Append this test's peak memory to the per-worker report.

    Off unless YASOS_SMOKE_MEM_REPORT names a directory: it costs two target
    commands per test, and it exists to *maintain* heavy_tests.txt rather than
    to run all the time. One file per xdist worker, because appends from
    parallel workers to one file interleave.

    Both numbers are recorded -- guest peak first, since that is what ranks the
    tests, and host RSS beside it because it is what actually has to fit N times
    over in the machine running them.
    """
    if not MEM_REPORT_DIR:
        return
    session = item.stash.get(session_key, None)
    if session is None or Session.target_crashed:
        return
    guest_peak = _guest_mempeak(session)
    if guest_peak is None:
        return
    backend = getattr(Session, "backend", None)
    host_peak = getattr(backend, "peak_rss", None)
    host_kb = host_peak() if host_peak is not None else 0
    try:
        report_dir = Path(MEM_REPORT_DIR)
        report_dir.mkdir(parents=True, exist_ok=True)
        worker = os.environ.get("PYTEST_XDIST_WORKER", "main")
        with open(report_dir / f"{worker}.tsv", "a", encoding="utf-8") as report:
            report.write(f"{guest_peak}\t{host_kb}\t{item.nodeid}\n")
    except OSError:
        logging.getLogger(__name__).warning("could not write the memory report", exc_info=True)


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
    # Session() has just (re)launched qemu for this test, so the measurement
    # window starts here -- the backend is shared by every test this worker
    # runs, and its peak would otherwise be the worst of all of them.
    backend = getattr(Session, "backend", None)
    if backend is not None and hasattr(backend, "reset_peak_rss"):
        backend.reset_peak_rss()
    commands = _commands_for_item(item)
    item.stash[test_command_hooks_key] = commands
    _run_target_commands(session, commands["setup"])
    _reset_guest_mempeak(item)


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
    # Read while qemu is still up: stop() would take the process, and VmHWM
    # with it.
    _record_peak_memory(item)
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
        logs_dir = smoke_log_dir()
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
