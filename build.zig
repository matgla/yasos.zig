const std = @import("std");
const hal = @import("yasos_hal");

pub fn configure_kconfig(b: *std.Build) void {
    const python = b.findProgram(&.{"python3"}, &.{}) catch {
        std.log.err("Can't find python3 in system path", .{});
        unreachable;
    };
    _ = b.run(&.{ python, "-m", "venv", "yasos_venv" });
    _ = b.run(&.{ "./yasos_venv/bin/pip", "install", "-r", "./kconfiglib/requirements.txt" });
    _ = b.run(&.{ "./yasos_venv/bin/python", "-m", "menuconfig", "KConfig" });
}

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const board = b.option([]const u8, "board", "a board for which the HAL is used") orelse "host";
    const cmake = b.option([]const u8, "cmake", "path to CMake executable") orelse "";
    const gcc = b.option([]const u8, "gcc", "path to arm-none-eabi-gcc executable") orelse "";

    configure_kconfig(b);
    const boardDep = b.dependency("yasos_hal", .{
        .board = board,
        .root_file = @as([]const u8, b.pathFromRoot("source/main.zig")),
        .optimize = optimize,
        .name = @as([]const u8, "yasos_kernel"),
        .cmake = cmake,
        .gcc = gcc,
    });
    b.installArtifact(boardDep.artifact("yasos_kernel"));
    _ = boardDep.module("board");
}
