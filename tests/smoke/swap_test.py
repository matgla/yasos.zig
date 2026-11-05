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


def test_waiting_process_comes_back_from_swap(request):
    """A parent written out while it waits sees its memory unchanged after.

    The parent's heap and statics go to swap while it sits in waitpid, the
    pages are free for anyone meanwhile, and waitpid reads them back at the
    same addresses before it returns. SwapRuns says runs went out and as many
    came back.
    """
    session = request.node.stash[session_key]
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

    session.write_command("rm -f /tmp/swapprobe.c /tmp/swapprobe")
    session.read_until_prompt()
    for index, line in enumerate(_SWAP_PROBE):
        redirect = ">" if index == 0 else ">>"
        session.write_command(f"echo '{line}' {redirect} /tmp/swapprobe.c")
        session.read_until_prompt()
    session.write_command("tcc -O0 /tmp/swapprobe.c -o /tmp/swapprobe")
    session.read_until_prompt()
    session.write_command("grep SwapRuns /proc/meminfo; /tmp/swapprobe; grep SwapRuns /proc/meminfo")
    output = session.read_until_prompt()
    session.write_command("rm -f /tmp/swapprobe.c /tmp/swapprobe")
    session.read_until_prompt()

    assert "SWAP_DONE child=0" in output, output
    assert "SWAP_BAD" not in output, output
    assert "CHILD swapped" in output, output
    runs = [tuple(map(int, m)) for m in re.findall(r"SwapRuns:\s+(\d+) out (\d+) in", output)]
    assert len(runs) == 2, output
    (out_before, in_before), (out_after, in_after) = runs
    assert out_after > out_before and in_after - in_before == out_after - out_before, output
