const std = @import("std");
const hal = @import("yasos_hal");

fn configure_kconfig(b: *std.Build) *std.Build.Step.Run {
    const argv = [_][]const u8{ "./yasos_venv/bin/python", "-m", "menuconfig", "KConfig" };
    const command = b.addSystemCommand(&argv);
    return command;
}

fn generate_config(b: *std.Build) *std.Build.Step.Run {
    const argv = [_][]const u8{ "./yasos_venv/bin/python", "./kconfiglib/generate.py", "--input", ".config", "-k", "KConfig", "-o", "config.json" };
    const command = b.addSystemCommand(&argv);
    return command;
}

const Config = struct {
    board: []const u8,
    cpu: []const u8,
};

fn load_config(b: *std.Build, config_file: std.Build.LazyPath) !Config {
    const file = try std.fs.cwd().openFile(config_file.getPath(b), .{});
    defer file.close();

    const data = try file.readToEndAlloc(b.allocator, 4096);
    const parsed = try std.json.parseFromSlice(
        Config,
        b.allocator,
        data,
        .{
            .ignore_unknown_fields = true,
        },
    );
    return parsed.value;
}

fn make_kernel() {
    const boardDep = b.dependency("yasos_hal", .{
        .board = @as([]const u8, config.board),
        .root_file = @as([]const u8, b.pathFromRoot("source/main.zig")),
        .optimize = optimize,
        .name = @as([]const u8, "yasos_kernel"),
        .cmake = cmake,
        .gcc = gcc,
    });


}

pub fn build(b: *std.Build) !void {
    // const optimize = b.standardOptimizeOption(.{});
    // const cmake = b.option([]const u8, "cmake", "path to CMake executable") orelse "";
    // const gcc = b.option([]const u8, "gcc", "path to arm-none-eabi-gcc executable") orelse "";

    const configure = configure_kconfig(b);
    const generate = generate_config(b);

    const menuconfig = b.step("menuconfig", "Execute menuconfig UI");
    const build_kernel = b.step("build_kernel", "Compile Yasos Kernel");

    //con.step.dependOn(&configure.step);
    // menuconfig.dependOn(&generate.step);
    generate.step.dependOn(&configure.step);
    _ = generate.addPrefixedOutputFileArg("-o", "config.json");
    menuconfig.dependOn(&generate.step);
    b.default_step.dependOn(menuconfig);
    generate.has_side_effects = true;

    // const config = try load_config(b, config_file);
    // std.log.info("Loading configuration for board: {s}", .{config.board});

    // const config_directory = try std.fs.openDirAbsolute(b.pathFromRoot("."), .{});

    // const config = @import("config/config.zig");

    // b.installArtifact(boardDep.artifact("yasos_kernel"));
    // _ = boardDep.module("board");
}
