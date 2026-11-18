"""
 Copyright (c) 2025 Mateusz Stadnik

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
 """

import re
import time

from .conftest import session_key


def _type_until(session, keys, expected_line, timeout=10):
    """Type *keys* raw (a completion redraws the line, so write_command's echo
    check does not apply) and return the output lines once one of them is
    exactly *expected_line* and the prompt is back after it."""
    session.serial.write(keys.encode("utf-8"))
    session.serial.flush()
    out = ""
    deadline = time.time() + timeout
    while time.time() < deadline:
        out += session._drain_serial_buffer()
        lines = re.split(r"\r?\n|\r", out)
        if expected_line in lines and out.endswith(session.prompt):
            return lines
        time.sleep(0.1)
    return re.split(r"\r?\n|\r", out)

def test_shell_accept_command_from_line(request):
    session = request.node.stash[session_key]
    session.write_command("sh -c \"echo Hello\"")
    line = session.read_line_except_logs()
    assert "Hello" in line

def test_shell_run_script(request):
    session = request.node.stash[session_key]
    session.write_command("sh /usr/hello_script.sh")
    line = session.read_until_prompt()
    assert "Hello from script" in line


def test_shell_tab_completes_file_name(request):
    session = request.node.stash[session_key]
    lines = _type_until(session, "echo /usr/hello_scr\t\n", "/usr/hello_script.sh")
    assert "/usr/hello_script.sh" in lines, lines

def test_shell_tab_completes_command_name(request):
    session = request.node.stash[session_key]
    lines = _type_until(session, "ech\ttab-completed\n", "tab-completed")
    assert "tab-completed" in lines, lines

def test_shell_tab_in_here_document_stays_literal(request):
    session = request.node.stash[session_key]
    lines = _type_until(session, "cat <<EOF\n\tkept-tab\nEOF\n", "\tkept-tab")
    assert "\tkept-tab" in lines, lines
