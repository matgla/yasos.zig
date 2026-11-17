"""
 Copyright (c) 2026 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.

 Ctrl-C and kill from the shell.

 The console's ISIG turns ^C into SIGINT for the foreground program -- the end
 of the chain of processes waiting in waitpid from the root shell -- whether it
 sleeps, spins in user code or reads the console.  The shell itself, at its
 prompt, reads ^C as a byte (raw mode) and stays.  kill(1) from the shell ends
 a background job.
 """

import re
import time

from .conftest import session_key


def _run(session, command):
    session.write_command(command)
    return session.read_until_prompt()


def _interrupt(session, command, settle=0.5):
    """Start `command`, press ^C, return (seconds until the prompt, $?)."""
    session.write_command(command)
    time.sleep(settle)
    start = time.monotonic()
    session.write_raw(b"\x03", 1)
    session.read_until_prompt()
    elapsed = time.monotonic() - start
    out = _run(session, "echo STATUS=$?")
    m = re.search(r"STATUS=(\d+)", out)
    assert m, out
    return elapsed, int(m.group(1))


def test_ctrl_c_ends_a_sleeping_program(request):
    session = request.node.stash[session_key]
    elapsed, status = _interrupt(session, "sleep 30")
    assert elapsed < 10, elapsed
    assert status == 128 + 2, status  # killed by SIGINT


def test_ctrl_c_ends_a_program_spinning_in_user_code(request):
    session = request.node.stash[session_key]
    _run(session, "rm -rf /tmp/sigtest; mkdir -p /tmp/sigtest")
    _run(session, "echo 'int main(void) { volatile unsigned n = 0; for (;;) ++n; }' > /tmp/sigtest/spin.c")
    out = _run(session, "tcc /tmp/sigtest/spin.c -o /tmp/sigtest/spin && echo BUILD_OK")
    assert "BUILD_OK" in out, out
    elapsed, status = _interrupt(session, "/tmp/sigtest/spin")
    assert elapsed < 10, elapsed
    assert status == 128 + 2, status
    _run(session, "rm -rf /tmp/sigtest")


def test_ctrl_c_ends_a_program_reading_the_console(request):
    session = request.node.stash[session_key]
    elapsed, status = _interrupt(session, "cat")
    assert elapsed < 10, elapsed
    assert status == 128 + 2, status


def test_ctrl_c_at_the_prompt_leaves_the_shell(request):
    session = request.node.stash[session_key]
    session.write_raw(b"\x03", 1)
    session.read_until_prompt()
    assert "SHELL_ALIVE" in _run(session, "echo SHELL_ALIVE")


def test_kill_ends_a_background_job(request):
    session = request.node.stash[session_key]
    _run(session, "sleep 30 &")
    out = _run(session, "kill $! && wait $!; echo STATUS=$?")
    m = re.search(r"STATUS=(\d+)", out)
    assert m, out
    assert int(m.group(1)) == 128 + 15, out  # SIGTERM
