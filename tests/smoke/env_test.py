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
 """

from .conftest import session_key


def test_home_is_exported_to_children(request):
    # toybox `env`, not `sh -c 'echo $HOME'`: a child shell sets HOME=/root
    # for itself, so only a program that is not a shell shows whether the
    # kernel's environment for pid 1 reached it (vi looks for ~/.cache there).
    session = request.node.stash[session_key]
    session.write_command("env | grep ^HOME=")
    assert session.read_line_except_logs().strip() == "HOME=/root"
