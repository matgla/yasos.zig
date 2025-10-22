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

from .conftest import session_key

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

