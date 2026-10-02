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


def test_uname_names_the_kernel(request):
    session = request.node.stash[session_key]
    session.write_command("uname")
    assert session.read_line_except_logs().split() == ["YasOS"]


def test_uname_all_fields(request):
    # -srvm rather than -a: -a ends in toybox's own " Toybox", which is the
    # applet talking, not the kernel. Walking all four fields is what catches a
    # utsname whose fields are not equal width -- toybox steps through it by
    # sizeof(sysname), so a mismatched layout prints the wrong bytes here.
    session = request.node.stash[session_key]
    session.write_command("uname -srvm")
    fields = session.read_line_except_logs().split()
    assert len(fields) == 4, fields
    sysname, release, version, machine = fields
    assert sysname == "YasOS"
    assert release.count(".") == 2, release
    assert len(version) == 10 and version[4] == "-" and version[7] == "-", version
    assert machine.startswith("armv"), machine
