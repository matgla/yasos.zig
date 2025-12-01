const std = @import("std");

pub fn build_littlefs(b: *std.Build, optimize: std.builtin.OptimizeMode, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const littlefs_path = "libs/littlefs/";

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "littlefs",
        .root_module = b.createModule(
            .{
                // .root_source_file = b.path(littlefs_path ++ "littlefs.zig"),
                .target = target,
                .optimize = optimize,
            },
        ),
    });

    // Add C source files
    lib.addCSourceFiles(.{
        .files = &.{
            littlefs_path ++ "lfs.c",
            littlefs_path ++ "lfs_util.c",
        },
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror=implicit-function-declaration",
            "-Wno-unused-parameter",
            "-DLFS_NO_DEBUG",
            "-DLFS_NO_WARN",
            "-DLFS_NO_ERROR",
            "-DLFS_NO_ASSERT",
        },
    });

    // Add include path
    lib.addIncludePath(b.path(littlefs_path));

    // Install the library
    b.installArtifact(lib);

    return lib;
}
