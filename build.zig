const std = @import("std");
const hal = @import("yasos_hal");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const board = b.option([]const u8, "board", "a board for which the HAL is used") orelse "host";
    const cmake = b.option([]const u8, "cmake", "path to CMake executable") orelse "";
    const gcc = b.option([]const u8, "gcc", "path to arm-none-eabi-gcc executable") orelse "";

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
