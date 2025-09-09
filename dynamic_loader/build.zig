const std = @import("std");

pub fn build(b: *std.Build) !void {
    const maybe_cpu_arch = b.option([]const u8, "cpu_arch", "CPU architecture to build for") orelse null;
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    if (maybe_cpu_arch) |cpu_arch| {
        if (std.mem.eql(u8, cpu_arch, "host")) {
            _ = b.addModule("yasld", .{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("stub/yasld.zig"),
            });
        } else {
            const yasld = b.addModule("yasld", .{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("source/yasld.zig"),
            });
            yasld.addAssemblyFile(b.path(b.fmt("source/arch/{s}/call.S", .{cpu_arch})));
            yasld.addAssemblyFile(b.path(b.fmt("source/arch/{s}/indirect_call_thunk.S", .{cpu_arch})));
        }
    }
}
