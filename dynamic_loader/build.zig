const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const yasld = b.addModule("yasld", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("source/yasld.zig"),
    });
    yasld.addAssemblyFile(b.path("source/arch/armv6-m/call.S"));
}
