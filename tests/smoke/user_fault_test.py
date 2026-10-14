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

 Coverage for the kernel's survival of a faulting user process: the
 postmortem must finish (or be dropped), the process must die with -1,
 and the shell must still be there afterwards.
 """

from .conftest import session_key


def _compile_and_run(session, source, name):
    """Write `source` to the device a line at a time, compile it, run it.

    The device shell has no here-documents, so each line is echoed on its own;
    the sources below keep clear of single quotes for that reason. /tmp is a
    small shared arena, so sweep the leftovers before and after (see
    vfork_test.py for the full story).
    """
    session.write_command("rm -f /tmp/*.c /tmp/*.o")
    session.read_until_prompt()
    session.write_command(f"rm -f /tmp/{name}.c /tmp/{name}")
    session.read_until_prompt()
    for index, line in enumerate(source):
        redirect = ">" if index == 0 else ">>"
        session.write_command(f"echo '{line}' {redirect} /tmp/{name}.c")
        out = session.read_until_prompt()
        assert "Out of memory" not in out, (
            f"/tmp is full while writing /tmp/{name}.c -- something earlier in "
            f"the run left files behind:\n{out}"
        )
    session.write_command(f"tcc /tmp/{name}.c -o /tmp/{name}")
    session.read_until_prompt()
    session.write_command(f"/tmp/{name}")
    output = session.read_until_prompt()
    session.write_command(f"rm -f /tmp/{name}.c /tmp/{name}")
    session.read_until_prompt()
    return output


# A process whose only act is a write through the null pointer. The fault is
# the point: it sends the kernel through the full HardFault postmortem (~20 KB
# of console output) and then the resume-at-_exit(-1) path.
_NULL_DEREF_PROBE = [
    "int main(void) {",
    "*(volatile int *)0 = 0;",
    "return 0;",
    "}",
]


def test_null_write_fault_kills_the_process_not_the_kernel(request):
    """A user process writing through NULL must be killed, not the guest.

    The postmortem is printed through the polling console UART from HardFault
    priority, with every interrupt on that core masked. If the sink behind the
    UART stops accepting bytes -- QEMU's chardev applies backpressure once the
    host stops reading the console; hardware flow control does the same on a
    real board -- the TX-full poll used to spin forever: one wedged CPU and a
    "lost" guest, on both the tcc and the LLVM kernel. Two things now keep it
    alive: the UART driver bounds its TX poll and reports the stall, and the
    console sink latches the stall and drops further output instead of paying
    the poll budget per line.

    The marker must stay suppressed while the faulting program runs: the
    reader keeping up with the postmortem is what lets it finish on QEMU at
    all, and is part of what this locks in.
    """
    session = request.node.stash[session_key]
    with session.expect_process_fault():
        output = _compile_and_run(session, _NULL_DEREF_PROBE, "nullderef")

    assert "HardFault diagnostics:" in output, output
    session.write_command("echo KERNEL_ALIVE")
    assert "KERNEL_ALIVE" in session.read_until_prompt()
