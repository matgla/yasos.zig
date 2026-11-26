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

 dlopen(3) and friends against POSIX, through apps/dltest and the
 libdltest.so it opens (/usr/lib): errors reported by dlerror() (null when
 nothing failed, cleared once read, the last failure wins), dlopen(NULL) and
 RTLD_DEFAULT, one copy of a library however often it is opened, RTLD_LOCAL
 and RTLD_GLOBAL, the mode checked, handles that are not open refused, and a
 function from dlsym running with its own library's globals.
 """

from .conftest import session_key


def _run(session, command, timeout=60):
    session.write_command(command)
    return session.wait_for_prompt(timeout=timeout)


def test_dl(request):
    """Each check is a line of dltest's output; the last line says whether
    all passed.  The failed lines are the assertion message."""
    session = request.node.stash[session_key]
    out = _run(session, "dltest")
    failed = [line for line in out.splitlines() if line.startswith("not ok")]
    assert not failed and "DL_TEST PASS" in out, "\n".join(failed) + "\n----\n" + out
