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

import pytest

from .framework.session import Session

session_key = pytest.StashKey()
test_command_hooks_key = pytest.StashKey()


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
