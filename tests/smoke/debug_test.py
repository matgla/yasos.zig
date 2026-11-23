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

 What a debugger on the board needs before it can do anything:

 - PTRACE_TRACEME makes the next exec load the program into RAM, even from
   the XIP romfs, where its code could not take a breakpoint;
 - a program linked with -g runs, and carries its debug data only in the file:
   the loader stops reading at debug_offset;
 - strip -f splits that data off on the board, and leaves a program that runs;
 - ptrace: stops at exec, breakpoints, registers, faults, ATTACH/INTERRUPT,
   KILL and DETACH, through apps/ptracetest.
 """

import re

import pytest

from .conftest import session_key

WORKDIR = "/tmp/debugtest"

# vfork, optionally PTRACE_TRACEME, then exec cat on its own /proc/self/maps;
# a traced child stops at exec, and is continued.
# No backslashes: they go through the shell's echo.
TRACEME_SOURCE = [
    "#include <stdio.h>",
    "#include <unistd.h>",
    "#include <sys/ptrace.h>",
    "#include <sys/wait.h>",
    "int main(int argc, char **argv)",
    "{",
    "  int status = 0;",
    "  pid_t pid = vfork();",
    "  if (pid == 0) {",
    "    if (argc > 1 && ptrace(PTRACE_TRACEME, 0, 0, 0) != 0)",
    "      _exit(126);",
    '    char *args[] = {"cat", "/proc/self/maps", 0};',
    '    execv("/bin/cat", args);',
    "    _exit(127);",
    "  }",
    "  waitpid(pid, &status, 0);",
    "  if (argc > 1) {",
    "    ptrace(PTRACE_CONT, pid, 0, 0);",
    "    waitpid(pid, &status, 0);",
    "  }",
    '  printf("CHILD_STATUS=%d", status);',
    "  putchar(10);",
    "  return 0;",
    "}",
]

HELLO_SOURCE = [
    "#include <stdio.h>",
    "static int twice(int x) { return 2 * x; }",
    "int main(void)",
    "{",
    '  printf("DEBUG_HELLO %d", twice(21));',
    "  putchar(10);",
    "  return 0;",
    "}",
]


@pytest.fixture(autouse=True)
def _workdir(request):
    session = request.node.stash[session_key]
    session.write_command("rm -rf %s; mkdir -p %s; cd %s" % (WORKDIR, WORKDIR, WORKDIR))
    session.read_until_prompt()
    yield
    try:
        session.write_command("cd /; rm -rf " + WORKDIR)
        session.read_until_prompt()
    except Exception:
        pass


def _write_source(session, name, lines):
    session.write_command("rm -f " + name)
    session.read_until_prompt()
    for line in lines:
        session.write_command("echo '%s' >> %s" % (line, name))
        session.read_until_prompt()


def _run(session, command):
    session.write_command(command)
    return session.read_until_prompt()


def _text_address(output):
    """The exec'd program's own .text line in its /proc/self/maps."""
    m = re.search(r"^\S+ \.text (0x[0-9a-f]+) 0x[0-9a-f]+", output, re.M)
    assert m, output
    return int(m.group(1), 16)


def test_traceme_exec_loads_the_program_into_ram(request):
    session = request.node.stash[session_key]
    _write_source(session, "traceme.c", TRACEME_SOURCE)
    out = _run(session, "tcc -ccompat traceme.c -o traceme && echo BUILD_OK")
    assert "BUILD_OK" in out, out

    plain = _run(session, "./traceme")
    assert "CHILD_STATUS=0" in plain, plain
    again = _run(session, "./traceme")
    traced = _run(session, "./traceme traced")
    assert "CHILD_STATUS=0" in traced, traced

    # In place, the code sits where the romfs holds the image: the same address
    # for every run.  Traced, it is a private copy somewhere else.
    assert _text_address(plain) == _text_address(again)
    assert _text_address(traced) != _text_address(plain), (plain, traced)


def test_debug_build_runs_and_strips_on_the_board(request):
    session = request.node.stash[session_key]
    _write_source(session, "hello.c", HELLO_SOURCE)
    out = _run(session, "tcc -ccompat -g hello.c -o hello && echo BUILD_OK")
    assert "BUILD_OK" in out, out
    assert "DEBUG_HELLO 42" in _run(session, "./hello")

    out = _run(session, "yaffdump hello")
    assert re.search(r"debug data\s+\d+ bytes at 0x[0-9a-f]+", out), out
    assert ".debug_line" in out, out

    out = _run(session, "strip -f hello.debug hello && echo STRIP_OK")
    assert "STRIP_OK" in out, out
    out = _run(session, "yaffdump hello")
    assert ".yaff_debuglink" in out and "-> hello.debug" in out, out
    assert "DEBUG_HELLO 42" in _run(session, "./hello")

    out = _run(session, "strip hello && yaffdump hello")
    # A plain strip keeps the link: it is how a debugger finds hello.debug.
    assert "-> hello.debug" in out, out


def test_ptrace(request):
    """apps/ptracetest traces copies of itself; each check is a line of its
    output, and the last line says whether all passed."""
    session = request.node.stash[session_key]
    out = _run(session, "ptracetest")
    failed = [line for line in out.splitlines() if line.startswith("not ok")]
    assert not failed and "PTRACE_TEST PASS" in out, out
