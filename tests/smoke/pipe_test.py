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
    session.write_command("rm -f /tmp/pipe_direct.bin /tmp/pipe_copy.bin")
    session.read_until_prompt()


def test_pipeline_in_a_subshell(request):
    session = request.node.stash[session_key]
    session.write_command('sh -c "echo nested_pipe | cat"')
    assert "nested_pipe" in session.read_until_prompt()
