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

"""GNU make on the device.

make is the first autoconf/gnulib program in the image, and the only one that
forks a shell per recipe line, so these cover more than the binary starting:
the recipe tests go through fork/exec/wait and the pipe the shell writes back
on.  test_load_average_option is deliberate -- make's -l takes a double, and
the double paths are why this program was left out of the rootfs until now.

The last two build a real two-file C program with the on-device tcc, which is
the pairing the image exists for and the one that exercises make's implicit
rule search (pattern_search) -- three of the four bugs that kept make out of
the rootfs were reached through that function.
"""

from .conftest import session_key

MAKEDIR = "/tmp/maketest"


def _fresh_dir(session):
    session.write_command("rm -rf " + MAKEDIR)
    session.write_command("mkdir -p " + MAKEDIR)
    session.write_command("cd " + MAKEDIR)


def _write_makefile(session, lines):
    """Write a Makefile a line at a time with echo.

    Recipe lines normally have to start with a real tab, which cannot be typed
    over this link -- the shell's line editor reads a tab as a completion
    request -- and toybox has no printf to emit one.  So every Makefile here
    opens with .RECIPEPREFIX and marks its recipe lines with `>` instead.
    """
    session.write_command("rm -f Makefile")
    session.write_command("echo '.RECIPEPREFIX = >' > Makefile")
    for line in lines:
        session.write_command("echo '%s' >> Makefile" % line)


def test_version(request):
    session = request.node.stash[session_key]
    session.write_command("make --version")
    out = session.read_until_prompt()
    assert "GNU Make" in out


def test_runs_a_recipe(request):
    session = request.node.stash[session_key]
    _fresh_dir(session)
    _write_makefile(session, ["all:", ">echo hello-from-make"])
    session.write_command("make")
    out = session.read_until_prompt()
    assert "hello-from-make" in out


def test_rebuilds_only_stale_targets(request):
    """The prerequisite/timestamp core: a second make must do nothing."""
    session = request.node.stash[session_key]
    _fresh_dir(session)
    _write_makefile(session, ["out.txt: in.txt", ">cat in.txt > out.txt"])
    session.write_command("echo seed > in.txt")
    session.write_command("make")
    out = session.read_until_prompt()
    assert "cat in.txt > out.txt" in out
    session.write_command("cat out.txt")
    assert "seed" in session.read_until_prompt()

    session.write_command("make")
    out = session.read_until_prompt()
    assert "up to date" in out


def test_variables_and_functions(request):
    """Expansion, $(subst) and $(shell) -- the last one forks again."""
    session = request.node.stash[session_key]
    _fresh_dir(session)
    _write_makefile(
        session,
        [
            "NAME = yas-os",
            "all:",
            ">echo $(subst -,,$(NAME))-$(shell echo forked)",
        ],
    )
    session.write_command("make")
    out = session.read_until_prompt()
    assert "yasos-forked" in out


def test_load_average_option(request):
    """-l parses a double and compares it against the load average."""
    session = request.node.stash[session_key]
    _fresh_dir(session)
    _write_makefile(session, ["all:", ">echo load-limited"])
    session.write_command("make -l 2.5")
    out = session.read_until_prompt()
    assert "load-limited" in out


# ---------------------------------------------------------------------------
# make + tcc: build a real program from sources on the device.
# ---------------------------------------------------------------------------

PROGDIR = "/tmp/makeprog"

GREET_H = ["void greet(const char *name);"]

# No backslash escapes anywhere in these sources: they are typed through the
# shell, and `echo` is not required to leave \n alone.  Hence fputs+puts
# rather than one printf.
GREET_C = [
    "#include <stdio.h>",
    '#include "greet.h"',
    "void greet(const char *name)",
    "{",
    '  fputs("built-by-make: ", stdout);',
    "  puts(name);",
    "}",
]

# A pattern rule, not two explicit ones: matching %.o against main.c is what
# runs pattern_search, and $< / $@ make it depend on stem substitution too.
PROGRAM_MAKEFILE = [
    ".RECIPEPREFIX = >",
    "CC = tcc",
    "OBJS = main.o greet.o",
    "app: $(OBJS)",
    ">$(CC) -o app $(OBJS)",
    "%.o: %.c greet.h",
    ">$(CC) -c $< -o $@",
]


def _main_c(tag):
    return [
        '#include "greet.h"',
        "int main(void)",
        "{",
        '  greet("%s");' % tag,
        "  return 0;",
        "}",
    ]


def _write_file(session, name, lines):
    session.write_command("rm -f " + name)
    for line in lines:
        session.write_command("echo '%s' >> %s" % (line, name))


def _write_program(session, main_tag):
    _write_file(session, "greet.h", GREET_H)
    _write_file(session, "greet.c", GREET_C)
    _write_file(session, "main.c", _main_c(main_tag))
    _write_file(session, "Makefile", PROGRAM_MAKEFILE)


def _build_program(session, main_tag="app-v1"):
    """Lay the program down in a fresh PROGDIR and build it once.

    Every test below starts from here rather than inheriting the previous
    test's directory: the suite runs under xdist, so each test gets its own
    board and its own empty /tmp, and a test that assumed a predecessor had
    run would fail with "no makefile found" depending only on which worker
    picked it up.
    """
    session.write_command("rm -rf " + PROGDIR)
    session.write_command("mkdir -p " + PROGDIR)
    session.write_command("cd " + PROGDIR)
    _write_program(session, main_tag)

    session.write_command("make")
    return session.wait_for_prompt(timeout=60)


def test_builds_a_c_program_with_tcc(request):
    """make drives tcc over a two-file program, then the result runs."""
    session = request.node.stash[session_key]
    out = _build_program(session)
    assert "tcc -c main.c -o main.o" in out
    assert "tcc -c greet.c -o greet.o" in out
    assert "tcc -o app main.o greet.o" in out

    session.write_command(PROGDIR + "/app")
    out = session.wait_for_prompt(timeout=30)
    assert "built-by-make: app-v1" in out

    # Nothing changed, so the whole graph is satisfied.
    session.write_command("make")
    out = session.wait_for_prompt(timeout=30)
    assert "up to date" in out


def test_recompiles_only_the_changed_source(request):
    """One source changes: its object is rebuilt, the other one is not.

    This is the timestamp test that matters, and it is a rewrite with nothing
    deleted: main.o and app are both still on disk and still satisfy the graph
    by existence, so the only thing that can make make rebuild them is main.c
    having a later mtime than main.o.  An earlier version of this test had to
    delete the targets instead, because every file on the device reported
    mtime 0 and no edit could ever look newer than anything.

    /tmp is a ramfs, whose timestamps come straight from the kernel's
    microsecond clock, so the rewrite and the object it invalidates cannot
    collide in the same tick the way they could on a FAT volume (whose
    two-second granularity is a property of the format -- see
    source/fs/fatfs/fat_time.zig).
    """
    session = request.node.stash[session_key]
    _build_program(session)

    # Only main.c is rewritten. Nothing is removed, so every target still
    # exists and only the timestamps can drive the rebuild.
    _write_file(session, "main.c", _main_c("app-v2"))

    session.write_command("make")
    out = session.wait_for_prompt(timeout=60)
    assert "tcc -c main.c -o main.o" in out
    assert "tcc -c greet.c -o greet.o" not in out
    assert "tcc -o app main.o greet.o" in out

    session.write_command(PROGDIR + "/app")
    out = session.wait_for_prompt(timeout=30)
    assert "built-by-make: app-v2" in out


def test_clean_target(request):
    """A phony-style recipe: `make clean` removes what the build produced."""
    session = request.node.stash[session_key]
    _build_program(session)
    session.write_command("echo 'clean:' >> Makefile")
    session.write_command("echo '>rm -f app $(OBJS)' >> Makefile")

    session.write_command("make clean")
    out = session.wait_for_prompt(timeout=30)
    assert "rm -f app main.o greet.o" in out

    session.write_command("ls")
    out = session.wait_for_prompt(timeout=30)
    assert "app" not in out.split()
    assert "main.o" not in out.split()
    assert "greet.c" in out.split()
