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

 Coverage for the two ways a process could spawn another and not survive it.

 Both are shell-level because that is where they were found, and because
 neither is visible from a single command: they need a program that keeps
 running after the spawn (so the frame it comes back to has to be the one it
 left) and one that collects a child it did not name up front.
 """

from .conftest import session_key


def test_background_job_is_reaped(request):
    """`cmd &` then `wait` returns.

    waitpid(-1) used to answer -1 immediately -- there was no "any child" case
    at all -- so the shell's `wait` builtin span forever on a job table it could
    never empty. The marker after `wait` is the whole assertion: reaching it
    means the call came back.
    """
    session = request.node.stash[session_key]
    session.write_command("hello &")
    session.read_until_prompt()
    session.write_command("wait")
    session.read_until_prompt()
    session.write_command("echo WAIT_RETURNED")
    assert "WAIT_RETURNED" in session.read_until_prompt()


def test_backgrounded_builtin_is_a_real_job(request):
    """`echo hi &` is a job with a pid, and `wait` collects it.

    A builtin that may run either way used to run in the shell itself even when
    backgrounded, so it finished before the job line was printed and the job it
    left had pid 0 -- unwaitable, and `wait` span on it. Two assertions: the
    reported pid is not 0, and `wait` comes back.
    """
    session = request.node.stash[session_key]
    session.write_command("echo hi &")
    output = session.read_until_prompt()
    assert "[1] 0" not in output, output

    session.write_command("wait")
    session.read_until_prompt()
    session.write_command("echo BUILTIN_WAIT_RETURNED")
    assert "BUILTIN_WAIT_RETURNED" in session.read_until_prompt()


def test_backgrounded_shell_builtin_does_not_move_this_shell(request):
    """`cd /bin &` must leave the shell where it was, and leave no job.

    `cd` cannot be given a process of its own -- it exists to change the shell
    it runs in -- so backgrounding it used to move the interactive shell, where
    a fork-capable shell confines that to a child that exits at once. It is now
    not run at all, which is what that child's parent observes. Two assertions:
    the directory is unchanged, and `wait` still returns (a job with no process
    behind it is one nothing can ever collect).
    """
    session = request.node.stash[session_key]
    session.write_command("cd /")
    session.read_until_prompt()
    session.write_command("cd /bin &")
    session.read_until_prompt()
    session.write_command("wait")
    session.read_until_prompt()
    session.write_command("pwd")
    assert "/bin" not in session.read_until_prompt()

    # ... and the ordinary foreground form still does its job.
    session.write_command("cd /bin")
    session.read_until_prompt()
    session.write_command("pwd")
    assert "/bin" in session.read_until_prompt()
    session.write_command("cd /")
    session.read_until_prompt()


def _compile_and_run(session, source, name):
    """Write `source` to the device a line at a time, compile it, run it.

    The device shell has no here-documents, so each line is echoed on its own;
    the sources below keep clear of single quotes for that reason.

    /tmp is a ~32 KiB tmpfs arena that holds roughly a dozen small files, and it
    is shared with every other test in the run.  These tests passed on their own
    and failed in a full suite -- every echo answering "Out of memory" -- purely
    because earlier tests had filled it.  So: sweep the leftovers before writing,
    and delete both artifacts afterwards rather than leaving the binary behind
    for whatever runs next.
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
    session.write_command(f"tcc -O0 /tmp/{name}.c -o /tmp/{name}")
    session.read_until_prompt()
    session.write_command(f"/tmp/{name}")
    output = session.read_until_prompt()
    session.write_command(f"rm -f /tmp/{name}.c /tmp/{name}")
    session.read_until_prompt()
    return output


# A vfork child that dies on an undefined instruction without ever exec'ing.
_CRASHING_CHILD_PROBE = [
    "#include <stdio.h>",
    "#include <sys/wait.h>",
    "#include <unistd.h>",
    "static char marker[32];",
    "int main(void) {",
    "int st = 0;",
    "pid_t p;",
    "snprintf(marker, sizeof(marker), \"intact\");",
    "p = vfork();",
    "if (p == 0) { __asm__ volatile(\"udf #0\"); _exit(1); }",
    "waitpid(p, &st, 0);",
    "printf(\"PARENT_ALIVE marker=%s\\n\", marker);",
    "return 0;",
    "}",
]


def test_parent_survives_a_child_that_crashes(request):
    """A vfork child killed by a fault must not take its parent with it.

    The handler resumes a dying process at `_exit(-1)` on a frame it builds at
    the top of its stack -- which for a vfork child is the *parent's* stack, so
    the frame and everything the exit path pushed landed on the frames the
    parent was suspended on. The parent then faulted the moment it resumed.
    """
    session = request.node.stash[session_key]
    # The child's fault prints the same diagnostics a dying kernel does, and
    # this one is the point of the test rather than a failure of it.
    with session.expect_process_fault():
        output = _compile_and_run(session, _CRASHING_CHILD_PROBE, "crashkid")

    assert "PARENT_ALIVE marker=intact" in output, output
    session.write_command("echo SHELL_ALIVE")
    assert "SHELL_ALIVE" in session.read_until_prompt()


# A vfork child that execs with no environment at all.
_NULL_ENVP_PROBE = [
    "#include <stdio.h>",
    "#include <sys/wait.h>",
    "#include <unistd.h>",
    "int main(void) {",
    "static char *av[2];",
    "int st = 0;",
    "pid_t p;",
    "av[0] = \"/bin/hello\";",
    "av[1] = 0;",
    "p = vfork();",
    "if (p == 0) { execve(av[0], av, 0); _exit(127); }",
    "waitpid(p, &st, 0);",
    "printf(\"NULL_ENVP=%d\\n\", WEXITSTATUS(st));",
    "return 0;",
    "}",
]


def test_execve_accepts_a_null_environment(request):
    """`execve(path, argv, NULL)` is allowed, and must not panic the kernel.

    The handler unwrapped the envp pointer, so a null one -- which POSIX
    permits, and which is the natural way to exec with an empty environment --
    took the whole system down from an unprivileged process. The assertion is
    both halves: the exec worked, and the shell is still there to say so.
    """
    session = request.node.stash[session_key]
    output = _compile_and_run(session, _NULL_ENVP_PROBE, "null_envp")

    assert "NULL_ENVP=0" in output, output
    session.write_command("echo KERNEL_ALIVE")
    assert "KERNEL_ALIVE" in session.read_until_prompt()


def test_vfork_child_keeps_its_callers_frame(request):
    """A vfork child runs its caller's code, not just exec.

    The child used to be released on the kernel's stack pointer rather than the
    one its caller's frame is addressed from, so every local in that frame --
    including the GOT base tcc spills around calls -- came back as whatever the
    syscall had left there. `prun` is the reproducer: its child opens a log,
    dup2()s it and only then execs, and each of those reads a local first.

    A -j above 1 also puts several children in flight at once, which is what
    needs waitpid(-1) to name the child it collected rather than any child.
    """
    session = request.node.stash[session_key]
    session.write_command("ls /bin/prun")
    if "prun" not in session.read_until_prompt():
        import pytest

        pytest.skip("prun is not in this rootfs")

    # /tmp is a ~32 KiB arena shared with the rest of the run, and prun writes a
    # log per job into it.  Clear leftovers first, or the batch file cannot even
    # be written (see _compile_and_run for the same problem).
    session.write_command("rm -f /tmp/*.c /tmp/*.log /tmp/prun_batch.txt")
    session.read_until_prompt()

    session.write_command("echo /bin/hello > /tmp/prun_batch.txt")
    out = session.read_until_prompt()
    assert "Out of memory" not in out, f"/tmp is full before prun could start:\n{out}"
    session.write_command("echo /bin/hello >> /tmp/prun_batch.txt")
    session.read_until_prompt()
    session.write_command("prun -j 2 -o /tmp /tmp/prun_batch.txt")
    output = session.read_until_prompt()

    assert "PRUN_DONE 2" in output, output
    # Both jobs exec'd and exited 0; a job that could not be started reports -1.
    assert output.count("PRUN 0 0") == 1, output
    assert output.count("PRUN 1 0") == 1, output

    session.write_command("cat /tmp/0.log")
    log = session.read_until_prompt()
    session.write_command("rm -f /tmp/prun_batch.txt /tmp/0.log /tmp/1.log")
    session.read_until_prompt()
    assert "Hello, World!" in log
