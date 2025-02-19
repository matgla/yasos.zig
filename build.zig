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
var cmake: ?[]const u8 = null;
var gcc: ?[]const u8 = null;

fn prepare_venv(b: *std.Build) *std.Build.Step.Run {
    const create_venv_args = [_][]const u8{ "python3", "-m", "venv", "yasos_venv" };
    const create_venv_command = b.addSystemCommand(&create_venv_args);
    const install_requirements_args = [_][]const u8{ "./yasos_venv/bin/pip", "install", "-r", "kconfiglib/requirements.txt" };
    const install_requirements_args_command = b.addSystemCommand(&install_requirements_args);
    install_requirements_args_command.step.dependOn(&create_venv_command.step);
    return install_requirements_args_command;
}

fn configure_kconfig(b: *std.Build) *std.Build.Step.Run {
    const argv = [_][]const u8{ "./yasos_venv/bin/python", "-m", "menuconfig", "KConfig" };
    const command = b.addSystemCommand(&argv);
    return command;
}

fn generate_config(b: *std.Build) *std.Build.Step.Run {
    const argv = [_][]const u8{ "./yasos_venv/bin/python", "./kconfiglib/generate.py", "--input", ".config", "-k", "KConfig", "-o", "config" };
    const command = b.addSystemCommand(&argv);
    return command;
}

const Config = struct {
    board: []const u8,
    cpu: []const u8,
    cpu_arch: []const u8,
};

fn load_config(b: *std.Build) !Config {
    const config_directory = try std.fs.cwd().openDir("config", .{});
    const file = try config_directory.openFile("config.json", .{ .mode = .read_only });
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
    const clean = b.option(bool, "clean", "clean before configuration") orelse false;
    const venv = prepare_venv(b);
    const configure = configure_kconfig(b);
    const generate = generate_config(b);

    if (clean) {
        std.fs.cwd().deleteTree("config") catch {};
        std.fs.cwd().deleteFile(".config") catch {};
    }

    configure.step.dependOn(&venv.step);
    generate.step.dependOn(&venv.step);

    const menuconfig = b.step("menuconfig", "Execute menuconfig UI");
    generate.step.dependOn(&configure.step);
    menuconfig.dependOn(&generate.step);
    generate.has_side_effects = true;
    const cwd = std.fs.cwd();

    const config_directory: std.fs.Dir = cwd.openDir("config", .{}) catch {
        std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
        return;
    };
    const config_exists = config_directory.statFile("config.json") catch {
        std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
        return;
    };

    const optimize = b.standardOptimizeOption(.{});

    if (config_exists.kind == .file) {
        const config_path = try config_directory.realpathAlloc(b.allocator, "config.json");
        const config = try load_config(b);
        const boardDep = b.dependency("yasos_hal", .{
            .board = @as([]const u8, config.board),
            .root_file = @as([]const u8, b.pathFromRoot("source/main.zig")),
            .optimize = optimize,
            .name = @as([]const u8, "yasos_kernel"),
            .config_file = @as([]const u8, config_path),
        });
        b.installArtifact(boardDep.artifact("yasos_kernel"));
        boardDep.artifact("yasos_kernel").addAssemblyFile(b.path(b.fmt("source/arch/{s}/context_switch.S", .{config.cpu_arch})));
        boardDep.artifact("yasos_kernel").addIncludePath(b.path("source"));
        const yasld = b.dependency("yasld", .{
            .optimize = optimize,
            .target = boardDep.artifact("yasos_kernel").root_module.resolved_target.?,
        });
        boardDep.artifact("yasos_kernel").root_module.addImport("yasld", yasld.module("yasld"));

        _ = boardDep.module("board");
    } else {
        std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
    }

    const tests = b.addTest(.{
        .name = "yasos_tests",
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
        .root_source_file = b.path("tests.zig"),
    });
    b.installArtifact(tests);
    tests.linkLibC();
    const config_module = b.addModule("test_config", .{
        .root_source_file = b.path("config/config.zig"),
    });

    tests.root_module.addImport("config", config_module);

    const run_tests_step = b.step("tests", "Run Yasos tests");
    const run_tests = b.addRunArtifact(tests);
    run_tests_step.dependOn(&run_tests.step);
}
