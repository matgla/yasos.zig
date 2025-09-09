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

def test_change_dir(request):
    session = request.node.stash[session_key]
    session.write_command("pwd")
    line = session.read_line_except_logs()
    assert line == "/"

    session.write_command("cd /bin")
    session.write_command("ls")
    line = session.read_until_prompt()
    assert set(["ls", "cat", "sh"]).issubset(line.split())

    session.write_command("pwd")
    line = session.read_line_except_logs()
    assert line == "/bin"

    session.write_command("cd ..")
    session.write_command("pwd")
    line = session.read_line_except_logs()
    assert line == "/"
