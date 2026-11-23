"""Regression coverage for the cross-compiled device Zig compiler."""

import shlex

import pytest

from .conftest import session_key


# Workload kept from the closed device-zig build-obj fault investigation.
SOURCE = """const std = @import("std");

export fn yasos_zig_workload() u32 {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "Hello, World!", .{}) catch return 0;
    return @intCast(s.len);
}

comptime {
    _ = yasos_zig_workload;
}
"""


def test_zig_build_obj_emits_c_and_tcc_compiles_it(request):
    session = request.node.stash[session_key]
    session.write_command("test -x /usr/bin/zig; echo ZIG_PRESENT=$?")
    if "ZIG_PRESENT=0" not in session.wait_for_prompt():
        pytest.skip("rootfs was built without --zig")

    work = "/tmp/zig_buildobj"
    session.write_command(f"rm -rf {work} && mkdir -p {work}/cache {work}/home")
    session.wait_for_prompt()
    try:
        for index, line in enumerate(SOURCE.splitlines()):
            redirect = ">" if index == 0 else ">>"
            session.write_command(f"echo {shlex.quote(line)} {redirect} {work}/probe.zig")
            session.wait_for_prompt()
        # The lib lives on the SD card (/var/lib/zig, which the compiler searches);
        # QEMU smoke runs have no card and carry it on the fatdisk volume instead
        # (scripts/build_smoke_fatdisk.py).
        session.write_command(
            "ZL=/var/lib/zig; test -f /mnt/var/lib/zig/std/std.zig && ZL=/mnt/var/lib/zig; "
            f"HOME={work}/home zig build-obj -ofmt=c -target thumb-freestanding "
            f"-mcpu=cortex_m33 -OReleaseSmall {work}/probe.zig "
            f"--zig-lib-dir $ZL --cache-dir {work}/cache "
            f"-femit-bin={work}/probe.c && test -s {work}/probe.c "
            f"&& tcc -ccompat -c -I$ZL -include $ZL/zig_c_prelude.h "
            f"{work}/probe.c -o {work}/probe.o && test -s {work}/probe.o; "
            "echo ZIG_BUILDOBJ_RC=$?"
        )
        output = session.wait_for_prompt(timeout=600)
        assert "ZIG_BUILDOBJ_RC=0" in output, output
    finally:
        session.write_command(f"rm -rf {work}")
        session.wait_for_prompt()


HEADER = """#include <stdio.h>
#include <string.h>
#include <unistd.h>
#define PROBE_MAGIC 42
struct probe { int a; char name[8]; };
static inline int probe_twice(int x) { return 2 * x; }
"""

PROGRAM = """const c = @import("probe.zig");

pub fn main() void {
    var p: c.struct_probe = .{ .a = c.probe_twice(c.PROBE_MAGIC), .name = undefined };
    _ = c.strcpy(&p.name, "yasos");
    _ = c.printf("TRANSLATED %d %s %d\\n", p.a, &p.name, @as(c_int, @intFromBool(c.getpid() > 0)));
}
"""


def test_zig_translate_c_libc_headers_build_and_run(request):
    """`zig translate-c` on the device (the prebuilt lib/compiler/translate-c):
    YasOS libc headers to Zig, which a program then builds against and runs."""
    session = request.node.stash[session_key]
    session.write_command("test -x /usr/bin/zig; echo ZIG_PRESENT=$?")
    if "ZIG_PRESENT=0" not in session.wait_for_prompt():
        pytest.skip("rootfs was built without --zig")

    work = "/tmp/zig_translate_c"
    session.write_command(f"rm -rf {work} && mkdir -p {work}/cache {work}/home")
    session.wait_for_prompt()
    try:
        for name, text in (("probe.h", HEADER), ("main.zig", PROGRAM)):
            for index, line in enumerate(text.splitlines()):
                redirect = ">" if index == 0 else ">>"
                session.write_command(f"echo {shlex.quote(line)} {redirect} {work}/{name}")
                session.wait_for_prompt()
        session.write_command(
            "ZL=/var/lib/zig; test -f /mnt/var/lib/zig/std/std.zig && ZL=/mnt/var/lib/zig; "
            f"cd {work} && HOME={work}/home zig translate-c -lc probe.h --zig-lib-dir $ZL "
            f"--cache-dir {work}/cache --global-cache-dir {work}/cache > probe.zig "
            f"&& HOME={work}/home zig build-exe -lc main.zig --zig-lib-dir $ZL "
            f"--cache-dir {work}/cache --global-cache-dir {work}/cache -femit-bin={work}/main "
            f"&& {work}/main; echo ZIG_TRANSLATE_RC=$?; cd /"
        )
        output = session.wait_for_prompt(timeout=900)
        assert "ZIG_TRANSLATE_RC=0" in output, output
        assert "TRANSLATED 84 yasos 1" in output, output
    finally:
        session.write_command(f"rm -rf {work}")
        session.wait_for_prompt()
