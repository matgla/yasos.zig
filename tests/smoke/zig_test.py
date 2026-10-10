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
        session.write_command(
            f"HOME={work}/home zig build-obj -ofmt=c -target thumb-freestanding "
            f"-mcpu=cortex_m33 -OReleaseSmall {work}/probe.zig "
            f"--zig-lib-dir /usr/lib/zig --cache-dir {work}/cache "
            f"-femit-bin={work}/probe.c && test -s {work}/probe.c "
            f"&& tcc -c -I/usr/lib/zig -include /usr/lib/zig/zig_c_prelude.h "
            f"{work}/probe.c -o {work}/probe.o && test -s {work}/probe.o; "
            "echo ZIG_BUILDOBJ_RC=$?"
        )
        output = session.wait_for_prompt(timeout=600)
        assert "ZIG_BUILDOBJ_RC=0" in output, output
    finally:
        session.write_command(f"rm -rf {work}")
        session.wait_for_prompt()
