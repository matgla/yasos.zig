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

 pipe(2) on target. The unit tests in source/kernel/fs/pipe.zig cover the ring
 buffer itself; what needs a device is the part that has two processes in it --
 blocking, and the end-of-stream that only a closing writer can produce.
 """

from .conftest import session_key


def test_pipeline_passes_data(request):
    session = request.node.stash[session_key]
    session.write_command("echo through_a_pipe | cat")
    assert "through_a_pipe" in session.read_until_prompt()


def test_multi_stage_pipeline(request):
    """Three processes, two pipes, and the middle one is both ends at once."""
    session = request.node.stash[session_key]
    session.write_command("echo three_stages | cat | cat")
    assert "three_stages" in session.read_until_prompt()


def test_pipe_carries_more_than_it_can_hold(request):
    """A transfer far larger than the ring, compared byte for byte.

    219 KB through a 4 KB buffer is ~54 rounds of filling it, so both sides
    block repeatedly and the ring wraps on almost every one. Getting the same
    hash as the direct copy is what says nothing was lost, duplicated or
    reordered across all of them.
    """
    session = request.node.stash[session_key]
    # Every step is silent until its prompt, and /tmp spills these 219 KB files
    # to the card: on the ReleaseSafe CI kernel the copy outlasts the session's
    # 1 s silence window while the board is fine.
    with session.timeout(60):
        session.write_command("cat /usr/bin/toybox > /tmp/pipe_direct.bin")
        session.read_until_prompt()
        session.write_command("cat /usr/bin/toybox | cat > /tmp/pipe_copy.bin")
        session.read_until_prompt()

        session.write_command("sha256sum /tmp/pipe_direct.bin")
        direct = session.read_until_prompt().split()
        session.write_command("sha256sum /tmp/pipe_copy.bin")
        piped = session.read_until_prompt().split()

    assert direct and piped, (direct, piped)
    assert direct[0] == piped[0], (direct, piped)

    # 219 KB apiece. /tmp is a shared ~32 KiB arena that holds about a dozen
    # small files, so leaving these behind is most of it gone for everything
    # that runs later.
    with session.timeout(60):
        session.write_command("rm -f /tmp/pipe_direct.bin /tmp/pipe_copy.bin")
        session.read_until_prompt()


def test_writer_ends_when_its_reader_has_gone(request):
    """A reader that leaves early must not leave the writer waiting for ever.

    More than the ring holds, so the writer blocks with nobody reading. The shell
    gave the last stage its stdin by moving the read end onto its own fd 0 and only
    put that back after waiting, so it held the pipe open against the writer it was
    waiting for: one process stuck on the other, and no prompt again.
    """
    session = request.node.stash[session_key]
    with session.timeout(30):
        # Last stage external, then builtin: both are run by the shell's fd 0.
        session.write_command("cat /usr/bin/toybox | /bin/true; echo external_done")
        assert "external_done" in session.read_until_prompt()
        session.write_command("cat /usr/bin/toybox | true; echo builtin_done")
        assert "builtin_done" in session.read_until_prompt()
        # A middle stage leaving early already worked, and has to stay that way.
        session.write_command("cat /usr/bin/toybox | head -c 5 | wc -c")
        assert "5" in session.read_until_prompt()
        # The shell's own stdin is back: it is still reading these commands.
        session.write_command("echo through_a_pipe | cat; echo stdin_back")
        output = session.read_until_prompt()
        assert "through_a_pipe" in output and "stdin_back" in output


# Fills a pipe, then reports what write() says: full, and with no reader left.
_PIPE_ERRORS_PROBE = [
    "#include <errno.h>",
    "#include <fcntl.h>",
    "#include <stdio.h>",
    "#include <unistd.h>",
    "int main(void)",
    "{",
    "int p[2]; static char b[1024]; long r;",
    "if (pipe2(p, O_NONBLOCK)) return 1;",
    "errno = 0; while ((r = write(p[1], b, sizeof b)) > 0) ;",
    'printf("full %ld %s\\n", r, errno == EAGAIN ? "EAGAIN" : "other");',
    "close(p[0]);",
    "errno = 0; r = write(p[1], b, 1);",
    'printf("gone %ld %s\\n", r, errno == EPIPE ? "EPIPE" : "other");',
    "return 0;",
    "}",
]


def test_write_to_a_pipe_reports_why_it_failed(request):
    """EPIPE and EAGAIN, not whatever errno last held.

    The kernel has no signals, so a writer losing its reader only has errno to go
    on, and toybox stays quiet about exactly EPIPE: without it every early reader
    printed "cat: xwrite".
    """
    session = request.node.stash[session_key]
    with session.timeout(30):
        session.write_command("cat /usr/bin/toybox | true; echo writer_done")
        output = session.read_until_prompt()
        assert "writer_done" in output
        assert "xwrite" not in output, output

        session.write_command("rm -f /tmp/pipe_errors.c /tmp/pipe_errors")
        session.read_until_prompt()
        for index, line in enumerate(_PIPE_ERRORS_PROBE):
            redirect = ">" if index == 0 else ">>"
            session.write_command(f"echo '{line}' {redirect} /tmp/pipe_errors.c")
            session.read_until_prompt()
        session.write_command("tcc /tmp/pipe_errors.c -o /tmp/pipe_errors")
        assert "error" not in session.read_until_prompt()
        session.write_command("/tmp/pipe_errors")
        output = session.read_until_prompt()
        session.write_command("rm -f /tmp/pipe_errors.c /tmp/pipe_errors")
        session.read_until_prompt()
    assert "full -1 EAGAIN" in output, output
    assert "gone -1 EPIPE" in output, output


def test_pipeline_in_a_subshell(request):
    session = request.node.stash[session_key]
    session.write_command('sh -c "echo nested_pipe | cat"')
    assert "nested_pipe" in session.read_until_prompt()
