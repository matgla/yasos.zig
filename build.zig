const std = @import("std");

const stm32target = @import("hal/cortex-m3/stm32f103/build.zig").target;

pub fn build(b: *std.Build) void {
    // const exe = b.addExecutable(.{
    //     .name = "yasos.zig",
    //     .root_source_file = b.path("source/main.zig"),
    //     .target = b.host,
    // });
    // b.installArtifact(exe);
    // const hostBoard = b.addModule("board", .{
    //     .root_source_file = b.path("bsp/host/board.zig"),
    // });
    // exe.root_module.addImport("board", hostBoard);

    const rpiExe = b.addExecutable(.{
        .name = "yasos_rpi.zig",
        .root_source_file = b.path("bsp/raspberry_pico/board.zig"),
        .target = b.resolveTargetQuery(stm32target),
    });
    rpiExe.setLinkerScript(b.path("hal/cortex-m3/stm32f103/memory.ld"));
    b.installArtifact(rpiExe);
    const picoBoard = b.addModule("app", .{
        .root_source_file = b.path("source/main.zig"),
    });
    rpiExe.root_module.addImport("app", picoBoard);
}
