//
// build.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//
const std = @import("std");
const hal = @import("yasos_hal");
var gcc: ?[]const u8 = null;

fn prepare_venv(b: *std.Build) *std.Build.Step.Run {
    const create_venv_args = [_][]const u8{ "python3", "-m", "venv", "yasos_venv" };
    const create_venv_command = b.addSystemCommand(&create_venv_args);
    const install_requirements_args = [_][]const u8{ "./yasos_venv/bin/pip", "install", "-r", "kconfiglib/requirements.txt" };
    const install_requirements_args_command = b.addSystemCommand(&install_requirements_args);
    install_requirements_args_command.step.dependOn(&create_venv_command.step);
    return install_requirements_args_command;
}

fn configure_kconfig(b: *std.Build, target: []const u8, module: []const u8) *std.Build.Step.Run {
    const argv = [_][]const u8{ "./yasos_venv/bin/python", "-m", module };
    const command = b.addSystemCommand(&argv);
    const config_dir = b.pathJoin(&.{ "config", target });
    std.fs.cwd().makePath(config_dir) catch |err| {
        std.debug.print("Failed to create config directory: {s}\n", .{@errorName(err)});
        return command;
    };
    const config_path = b.pathJoin(&.{ config_dir, ".config" });
    command.setEnvironmentVariable("KCONFIG_CONFIG", config_path);
    return command;
}

fn generate_config(b: *std.Build, config_file: []const u8, config_output: []const u8) *std.Build.Step.Run {
    const argv = [_][]const u8{ "./yasos_venv/bin/python", "./kconfiglib/generate.py", "--input", config_file, "-k", "Kconfig", "-o", config_output };
    const command = b.addSystemCommand(&argv);
    return command;
}

const Config = struct {
    board: []const u8,
    cpu: []const u8,
    cpu_arch: []const u8,
};

fn load_config(b: *std.Build, config_file: []const u8) !Config {
    const file = try std.fs.cwd().openFile(config_file, .{ .mode = .read_only });
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

pub fn build(b: *std.Build) !void {
    const clean_step = b.step("clean", "Clean build artifacts");
    const defconfig_file = b.option([]const u8, "defconfig_file", "use a specific defconfig file") orelse null;
    // clean_step.dependOn(&b.addRemoveDirTree(b.path(b.install_path)).step);
    if (@import("builtin").os.tag != .windows) {
        clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-cache")).step);
        clean_step.dependOn(&b.addRemoveDirTree(b.path("config")).step);
        clean_step.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
        clean_step.dependOn(&b.addRemoveDirTree(b.path("yasos_venv")).step);
    }

    const venv = prepare_venv(b);
    const configure = configure_kconfig(b, "target", "menuconfig");
    const configure_defconfig = configure_kconfig(b, "target", "defconfig");
    const generate = generate_config(b, "config/target/.config", "config/target");

    configure.step.dependOn(&venv.step);
    configure_defconfig.step.dependOn(&venv.step);
    generate.step.dependOn(&venv.step);
    generate.has_side_effects = true;

    const menuconfig = b.step("menuconfig", "Execute menuconfig UI");
    menuconfig.dependOn(&generate.step);
    const defconfig = b.step("defconfig", "Execute defconfig");
    defconfig.dependOn(&generate.step);

    if (defconfig_file) |file| {
        configure_defconfig.addArg(file);
    }
    const cwd = std.fs.cwd();
    var has_config = true;
    var maybe_config_directory: ?std.fs.Dir = cwd.openDir("config/target", .{}) catch blk: {
        has_config = false;
        break :blk null;
    };

    var maybe_config_exists: ?std.fs.File.Stat = null;
    if (maybe_config_directory) |config_directory| {
        maybe_config_exists = config_directory.statFile("config.json") catch blk: {
            has_config = false;
            break :blk null;
        };
    }

    if (defconfig_file) |_| {
        generate.step.dependOn(&configure_defconfig.step);
    } else {
        generate.step.dependOn(&configure.step);
    }

    if (!has_config) {
        std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
        return;
    }

    const optimize = b.standardOptimizeOption(.{});

    if (maybe_config_exists) |config_exists| {
        if (config_exists.kind == .file) {
            const config_path = try maybe_config_directory.?.realpathAlloc(b.allocator, "config.json");
            std.debug.print("Using configuration file: {s}\n", .{config_path});
            const config = try load_config(b, config_path);
            const boardDep = b.dependency("yasos_hal", .{
                .board = @as([]const u8, config.board),
                .root_file = @as([]const u8, b.pathFromRoot("source/main.zig")),
                .optimize = optimize,
                .name = @as([]const u8, "yasos_kernel"),
                .config_file = @as([]const u8, config_path),
            });
            b.installArtifact(boardDep.artifact("yasos_kernel"));
            boardDep.artifact("yasos_kernel").addAssemblyFile(b.path(b.fmt("source/arch/{s}/context_switch.S", .{config.cpu_arch})));
            boardDep.artifact("yasos_kernel").addIncludePath(b.path("source/sys/include"));
            boardDep.artifact("yasos_kernel").addIncludePath(b.path("."));

            const yasld = b.dependency("yasld", .{
                .optimize = optimize,
                .target = boardDep.artifact("yasos_kernel").root_module.resolved_target.?,
            });

            boardDep.artifact("yasos_kernel").root_module.addImport("yasld", yasld.module("yasld"));
            boardDep.artifact("yasos_kernel").root_module.addIncludePath(b.path("."));

            _ = boardDep.module("board");
        } else {
            std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
        }
    }

    const tests = b.addTest(.{
        .name = "yasos_tests",
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
        .root_source_file = b.path("tests.zig"),
    });
    const generate_defconfig_for_tests = generate_config(b, "configs/host_defconfig", "config/tests");
    generate_defconfig_for_tests.has_side_effects = true;
    tests.step.dependOn(&generate_defconfig_for_tests.step);
    b.installArtifact(tests);
    tests.linkLibC();
    const config_module = b.addModule("test_config", .{
        .root_source_file = b.path("config/tests/config.zig"),
    });
    tests.root_module.addImport("config", config_module);
    const run_tests_step = b.step("test", "Run Yasos tests");
    const run_tests = b.addRunArtifact(tests);
    run_tests_step.dependOn(&run_tests.step);
    tests.root_module.addIncludePath(b.path("."));
}
