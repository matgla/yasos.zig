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

 Swap: a process waiting in waitpid is written out and comes back intact.

 Swap normally happens only when the process pool is full, which the QEMU
 boards never are; /proc/swapnext makes the next allocation take the same path
 a full pool does. Needs swap space: a card has its swap partition;
 otherwise the test makes a small swap file on /var or on QEMU's FAT drive at
 /mnt, and skips if neither is real storage.
 """

import re

import pytest

from .conftest import session_key


# The parent fills a heap block and a static one, re-runs itself as its child,
# and checks both after waitpid. The child arms /proc/swapnext and allocates:
# that allocation swaps out the largest process waiting in waitpid -- the
# parent, with its 1 MB block -- through the same hook a full pool calls. It
# repeats until SwapUsed shows it happened (it may get there before the parent
# waits).
_SWAP_PROBE = [
    "#include <fcntl.h>",
    "#include <stdio.h>",
    "#include <stdlib.h>",
    "#include <string.h>",
    "#include <sys/wait.h>",
    "#include <unistd.h>",
    "static unsigned char statics[8192];",
    "static int swapped(void) {",
    "char buf[1024];",
    "char *line;",
    "int n, fd = open(\"/proc/meminfo\", O_RDONLY);",
    "if (fd < 0) return 0;",
    "n = read(fd, buf, sizeof(buf) - 1);",
    "close(fd);",
    "if (n <= 0) return 0;",
    "buf[n] = 0;",
    "line = strstr(buf, \"SwapUsed:\");",
    "return line && !strstr(line, \"SwapUsed:               0 B\");",
    "}",
    "static int child(void) {",
    "char buf[32];",
    "char *block;",
    "int i, fd;",
    "for (i = 0; i < 300; i++) {",
    "fd = open(\"/proc/swapnext\", O_RDONLY);",
    "if (fd < 0) return 3;",
    "read(fd, buf, sizeof(buf));",
    "close(fd);",
    "block = malloc(64 * 1024);",
    "if (block) memset(block, 1, 64 * 1024);",
    "free(block);",
    "if (swapped()) { printf(\"CHILD swapped after %d\\n\", i); return 0; }",
    "usleep(10000);",
    "}",
    "return 4;",
    "}",
    "int main(int argc, char **argv) {",
    "size_t size = 1024 * 1024, i;",
    "unsigned char *p;",
    "char *args[3];",
    "int st = 0;",
    "pid_t pid;",
    "if (argc > 1) return child();",
    "p = malloc(size);",
    "for (i = 0; i < size; i++) p[i] = (unsigned char)(i * 31 + 7);",
    "for (i = 0; i < sizeof(statics); i++) statics[i] = (unsigned char)(i ^ 0x5a);",
    "args[0] = argv[0]; args[1] = \"child\"; args[2] = 0;",
    "pid = vfork();",
    "if (pid == 0) { execv(argv[0], args); _exit(9); }",
    "waitpid(pid, &st, 0);",
    "for (i = 0; i < size; i++) if (p[i] != (unsigned char)(i * 31 + 7)) { printf(\"SWAP_BAD heap %u\\n\", (unsigned)i); return 1; }",
    "for (i = 0; i < sizeof(statics); i++) if (statics[i] != (unsigned char)(i ^ 0x5a)) { printf(\"SWAP_BAD static %u\\n\", (unsigned)i); return 1; }",
    "printf(\"SWAP_DONE child=%d\\n\", WEXITSTATUS(st));",
    "return 0;",
    "}",
]


def _swap_total(session):
    session.write_command("grep SwapTotal /proc/meminfo")
    out = session.read_until_prompt()
    match = re.search(r"SwapTotal:\s+(\d+)", out)
    return int(match.group(1)) if match else 0


def _ensure_swap(session):
    """Swap space on, or skip the test."""
    # The card's /var where there is one, else the FAT drive QEMU mounts at /mnt.
    for place in ("/var", "/mnt"):
        if _swap_total(session):
            break
        # 2 MB: room for the parent's 1 MB block, and what the FAT drive has free
        # beside the smoke corpus. A file left by an earlier, failed run goes.
        session.write_command(f"rm -f {place}/swap; mount -t swap -o size=2M {place}/swap {place} 2>&1; echo rc=$?")
        session.read_until_prompt()
    if _swap_total(session) == 0:
        pytest.skip("no swap space: neither /var nor /mnt is real storage here")


def _build(session, source, name):
    session.write_command(f"rm -f /tmp/{name}.c /tmp/{name}")
    session.read_until_prompt()
    for index, line in enumerate(source):
        redirect = ">" if index == 0 else ">>"
        session.write_command(f"echo '{line}' {redirect} /tmp/{name}.c")
        session.read_until_prompt()
    session.write_command(f"tcc -ccompat -O0 /tmp/{name}.c -o /tmp/{name}")
    session.read_until_prompt()


def _swap_runs(output):
    return [tuple(map(int, m)) for m in re.findall(r"SwapRuns:\s+(\d+) out (\d+) in", output)]


def test_waiting_process_comes_back_from_swap(request):
    """A parent written out while it waits sees its memory unchanged after.

    The parent's heap and statics go to swap while it sits in waitpid, the
    pages are free for its child meanwhile, and waitpid reads them back at the
    same addresses before it returns. SwapRuns says runs went out and as many
    came back.
    """
    session = request.node.stash[session_key]
    _ensure_swap(session)
    _build(session, _SWAP_PROBE, "swapprobe")
    session.write_command("grep SwapRuns /proc/meminfo; /tmp/swapprobe; grep SwapRuns /proc/meminfo")
    output = session.read_until_prompt()
    session.write_command("rm -f /tmp/swapprobe.c /tmp/swapprobe")
    session.read_until_prompt()

    assert "SWAP_DONE child=0" in output, output
    assert "SWAP_BAD" not in output, output
    assert "CHILD swapped" in output, output
    runs = _swap_runs(output)
    assert len(runs) == 2, output
    (out_before, in_before), (out_after, in_after) = runs
    assert out_after > out_before and in_after - in_before == out_after - out_before, output


# Two jobs at once. "grab", started in the background, arms /proc/swapnext and
# maps 64 KB, over and over, while "hold" -- 1 MB of its own -- waits in waitpid
# for "nap". Neither hold nor the shell waiting for hold is anything grab
# descends from, so neither may be swapped out for it: grab could still hold
# their pages when their wait ends, and they come back only at the addresses
# they left. It used to write out hold, the largest waiting process.
#
# The flag /proc/swapnext sets is for the next heap allocation of anybody, and
# nap is hold's heir: swapping hold out for nap would be right. So grab arms it
# only while nap has said it sleeps (its marker file), and maps at once.
_PARALLEL_PROBE = [
    "#include <fcntl.h>",
    "#include <stdio.h>",
    "#include <stdlib.h>",
    "#include <string.h>",
    "#include <sys/mman.h>",
    "#include <sys/wait.h>",
    "#include <unistd.h>",
    "#define MARK \"/tmp/swapjob.napping\"",
    "static int grab(void) {",
    "char buf[32];",
    "void *p;",
    "int i, fd, armed = 0;",
    "for (i = 0; i < 300 && armed < 20; i++) {",
    "usleep(20000);",
    "if (access(MARK, F_OK) != 0) { if (armed) break; continue; }",
    "fd = open(\"/proc/swapnext\", O_RDONLY);",
    "if (fd < 0) return 3;",
    "read(fd, buf, sizeof(buf));",
    "close(fd);",
    "p = mmap(0, 64 * 1024, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);",
    "if (p != MAP_FAILED) { memset(p, 1, 64 * 1024); munmap(p, 64 * 1024); }",
    "armed++;",
    "}",
    "printf(\"GRAB_DONE armed=%d\\n\", armed);",
    "return 0;",
    "}",
    "static int nap(void) {",
    "int fd = open(MARK, O_WRONLY | O_CREAT | O_TRUNC, 0644);",
    "if (fd >= 0) close(fd);",
    "usleep(1500000);",
    "unlink(MARK);",
    "usleep(300000);",
    "return 0;",
    "}",
    "static int hold(char *self) {",
    "size_t size = 1024 * 1024, i;",
    "unsigned char *p = malloc(size);",
    "char *args[3];",
    "int st = 0;",
    "pid_t pid;",
    "if (!p) return 2;",
    "for (i = 0; i < size; i++) p[i] = (unsigned char)(i * 13 + 5);",
    "args[0] = self; args[1] = \"nap\"; args[2] = 0;",
    "pid = vfork();",
    "if (pid == 0) { execv(self, args); _exit(9); }",
    "waitpid(pid, &st, 0);",
    "for (i = 0; i < size; i++) if (p[i] != (unsigned char)(i * 13 + 5)) { printf(\"SWAP_BAD heap %u\\n\", (unsigned)i); return 1; }",
    "printf(\"HOLD_DONE nap=%d\\n\", WEXITSTATUS(st));",
    "return 0;",
    "}",
    "int main(int argc, char **argv) {",
    "if (argc > 1 && strcmp(argv[1], \"grab\") == 0) return grab();",
    "if (argc > 1 && strcmp(argv[1], \"nap\") == 0) return nap();",
    "return hold(argv[0]);",
    "}",
]


def test_a_job_is_not_swapped_out_for_another_job(request):
    """A background job finding the pool full swaps out nothing of a job beside it.

    A process waiting in waitpid is swapped out only for the process it waits
    for or that one's descendants, which are gone before it wakes. Another job
    could still hold its pages then, and the waiting process could not come
    back at its addresses until that job ended -- or would be killed by the
    swap-in watchdog, or panic the kernel as pid 1.
    """
    session = request.node.stash[session_key]
    _ensure_swap(session)
    _build(session, _PARALLEL_PROBE, "swapjob")
    session.write_command(
        "rm -f /tmp/swapjob.napping; grep SwapRuns /proc/meminfo; "
        "/tmp/swapjob grab & /tmp/swapjob hold; wait; grep SwapRuns /proc/meminfo"
    )
    # Quiet for a second and a half while nap sleeps: past the idle timeout.
    output = session.wait_for_data("$", timeout=30)
    session.write_command("rm -f /tmp/swapjob.c /tmp/swapjob /tmp/swapjob.napping")
    session.read_until_prompt()

    assert "HOLD_DONE nap=0" in output, output
    assert "SWAP_BAD" not in output, output
    armed = re.search(r"GRAB_DONE armed=(\d+)", output)
    assert armed and int(armed.group(1)) > 0, output  # it did ask while hold waited
    runs = _swap_runs(output)
    assert len(runs) == 2, output
    assert runs[0] == runs[1], output
