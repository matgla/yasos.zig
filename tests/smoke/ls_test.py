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

def test_list_rootfs(request):
    session = request.node.stash[session_key]
    session.write_command("ls")
    line = session.read_line_except_logs()
    assert sorted(["dev", "usr", "lib", "tmp", "bin", "proc", "root", "home" ]) == sorted(line.split())

def test_list_bin(request):
    session = request.node.stash[session_key]
    session.write_command("cd bin")
    session.write_command("ls")
    line = session.read_until_prompt()
    assert set(["ls", "cat", "sh"]).issubset(line.split())

def test_list_argument(request):
    session = request.node.stash[session_key]
    session.write_command("ls /bin")
    line = session.read_until_prompt()
    assert set(["ls", "cat", "sh"]).issubset(line.split())
    session.write_command("ls /usr")
    line = session.read_until_prompt()
    assert set(["bin", "include", "lib"]).issubset(line.split())
