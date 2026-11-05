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

import re

from .conftest import session_key
from .framework import qemu


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


# Eats argv[1] bytes of its own stack, then enters the kernel on what is left.
# Sweeping that number lands the overflow at every depth of the kernel path:
# holding a sleeping mutex, holding a spinlock with interrupts masked, or inside
# the console. Syscalls run on the process stack, so all of those are reachable.
_STACK_PROBE = [
    "#include <fcntl.h>",
    "#include <stdlib.h>",
    "#include <sys/stat.h>",
    "#include <sys/wait.h>",
    "#include <unistd.h>",
    "int call(const char *path, int mode)",
    "{",
    "struct stat st; char buf[32]; int fd, n;",
    "if (mode == 0) return stat(path, &st);",
    "if (mode == 3) return chdir(path);",
    "if (mode == 4) {",
    "n = vfork(); if (n < 0) return -1;",
    "if (n == 0) { char *av[2]; av[0] = (char *)path; av[1] = 0; execv(path, av); _exit(9); }",
    "fd = 0; waitpid(n, &fd, 0); return 0; }",
    "if (mode == 1) {",
    "fd = open(path, O_RDONLY); if (fd < 0) return -1;",
    "n = read(fd, buf, sizeof buf); close(fd); return n; }",
    "fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644); if (fd < 0) return -1;",
    'n = write(fd, "probe", 5); close(fd); unlink(path); return n;',
    "}",
    "int main(int argc, char **argv)",
    "{",
    "int n = atoi(argv[1]); char eat[n + 1]; int rc;",
    "eat[0] = 1; eat[n] = 1;",
    "rc = call(argv[2], atoi(argv[3]));",
    "return rc < 0 ? 3 : eat[0] - 1;",
    "}",
]

# Every depth from "the kernel path fits" to "main barely starts": the stack is
# larger than any of these paths reach without a disk. 16 is twice the alignment
# of the variable-length array, which keeps this near a minute. A board takes a
# coarser walk: each kill prints a 20 KB postmortem over a real UART.
# The disks are scripts/stack_overflow_sweep.py's: the smoke suite has no card.
_PROBE_STACK = 6144
_SWEEP_STEP = 16 if qemu.qemu_kernel() is not None else 256
_SWEEP_TARGETS = [
    ("/tmp/stkprobe_target", 0),
    ("/tmp/stkprobe_target", 1),
    ("/tmp/stkprobe_new", 2),
    ("/tmp", 3),
    ("/usr/bin/cardreformat", 1),
    ("/bin/true", 4),
]


def test_stack_overflow_inside_a_syscall_kills_only_that_process(request):
    """Whatever the overflowing syscall holds, the kernel must carry on.

    The first overflow to reach this was `cd /root` on a 4 KiB stack: inside
    ext4, holding the filesystem mutex, and exit then tripped lockdep. Deeper in
    the sweep it lands in malloc with interrupts masked, where the exit's SVC
    escalates straight back to HardFault, forever, which on a board is a silent
    hang. Both would also leave a lock held for everyone else, which is why the
    filesystems are used again at the end.
    """
    session = request.node.stash[session_key]
    name = "stkprobe"
    session.write_command(f"rm -f /tmp/{name}.c /tmp/{name} /tmp/{name}_*")
    session.read_until_prompt()
    for index, line in enumerate(_STACK_PROBE):
        redirect = ">" if index == 0 else ">>"
        session.write_command(f"echo '{line}' {redirect} /tmp/{name}.c")
        session.read_until_prompt()
    session.write_command(f"tcc /tmp/{name}.c -o /tmp/{name} -stack-size={_PROBE_STACK}")
    assert "error" not in session.read_until_prompt()
    session.write_command(f"echo target > /tmp/{name}_target")
    session.read_until_prompt()

    killed = 0
    finished = 0
    with session.expect_process_fault():
        for path, mode in _SWEEP_TARGETS:
            session.write_command(
                f"n={_PROBE_STACK - 8}; while [ $n -gt 0 ]; do "
                f"/tmp/{name} $n {path} {mode} >/dev/null 2>&1; echo SWEEP $n $?; "
                f"n=$((n-{_SWEEP_STEP})); done"
            )
            output = session.read_until_prompt()
            # Not at the start of a line: a fault's message is on the console too, and on a
            # board it can lose its newline. Digits keep the echoed command from matching.
            statuses = re.findall(r"SWEEP (\d+) (\d+)", output)
            expected = (_PROBE_STACK - 8 + _SWEEP_STEP - 1) // _SWEEP_STEP
            assert len(statuses) == expected, output[-2000:]
            for depth, status in statuses:
                # 0 finished, 255 is the kill. Anything else is a syscall that
                # came back broken, such as a lock left behind turning into EBUSY.
                assert status in ("0", "255"), f"{path} mode {mode} at {depth}: {status}"
                killed += status == "255"
                finished += status == "0"
    assert killed > 0, "no run overflowed, so this tested nothing"
    assert finished > 0, "no run fit the stack, so the deepest kernel frames went unreached"

    # Nothing may have been left locked behind the dead processes.
    session.write_command(f"/tmp/{name} 0 /tmp/{name}_target 1; echo AFTER $?")
    assert "AFTER 0" in session.read_until_prompt()
    session.write_command(f"/tmp/{name} 0 /tmp/{name}_new 2; echo AFTER $?")
    assert "AFTER 0" in session.read_until_prompt()
    session.write_command("ls /usr/bin /proc > /dev/null; echo KERNEL_ALIVE")
    assert "KERNEL_ALIVE" in session.read_until_prompt()
    session.write_command(f"rm -f /tmp/{name}.c /tmp/{name} /tmp/{name}_*")
    session.read_until_prompt()
