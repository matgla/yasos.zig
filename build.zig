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
    const run_tests_step = b.step("test", "Run Yasos tests");
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

    const optimize = b.standardOptimizeOption(.{});

    const kernel_module_for_tests = b.addModule("kernel_under_test", .{
        .root_source_file = b.path("source/kernel/kernel.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
    });
    // fs_tests.root_module.addImport("kernel", kernel_module_for_tests);

    const kernel_tests = b.addTest(.{
        .name = "kernel_tests",
        // .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .root_module = kernel_module_for_tests,
    });

    // const fs_tests = b.addTest(.{
    //     .name = "fs_tests",
    //     .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    //     // .root_source_file = b.path("source/fs/tests.zig"),
    // });

    const generate_defconfig_for_tests = generate_config(b, "configs/host_defconfig", "config/tests");
    generate_defconfig_for_tests.step.dependOn(&venv.step);
    generate_defconfig_for_tests.has_side_effects = true;
    kernel_tests.step.dependOn(&generate_defconfig_for_tests.step);
    // fs_tests.step.dependOn(&generate_defconfig_for_tests.step);

    b.installArtifact(kernel_tests);
    // b.installArtifact(fs_tests);

    kernel_tests.linkLibC();
    // fs_tests.linkLibC();

    const test_config_module = b.addModule("test_config", .{
        .root_source_file = b.path("config/tests/config.zig"),
    });
    kernel_tests.root_module.addImport("config", test_config_module);
    // fs_tests.root_module.addImport("config", test_config_module);

    const oop = b.dependency("modules/oop", .{});

    kernel_tests.root_module.addImport("interface", oop.module("interface"));
    // fs_tests.root_module.addImport("interface", oop.module("interface"));

    const libc_imports_for_tests = b.addModule("libc_imports_for_tests", .{
        .root_source_file = b.path("source/libc_imports.zig"),
    });
    libc_imports_for_tests.addIncludePath(b.path("."));
    kernel_tests.root_module.addImport("libc_imports", libc_imports_for_tests);
    // fs_tests.root_module.addImport("libc_imports", libc_imports_for_tests);

    const run_kernel_tests = b.addRunArtifact(kernel_tests);
    // const run_fs_tests = b.addRunArtifact(fs_tests);

    run_tests_step.dependOn(&run_kernel_tests.step);
    // run_tests_step.dependOn(&run_fs_tests.step);

    kernel_tests.root_module.addIncludePath(b.path("."));
    // fs_tests.root_module.addIncludePath(b.path("."));
    kernel_module_for_tests.addImport("interface", oop.module("interface"));
    kernel_module_for_tests.addImport("libc_imports", libc_imports_for_tests);
    if (!has_config) {
        std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
        return;
    }

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
            const kernel_exec = boardDep.artifact("yasos_kernel");
            kernel_exec.addIncludePath(b.path("source/sys/include"));
            kernel_exec.addIncludePath(b.path("."));

            const yasld = b.dependency("yasld", .{
                .optimize = optimize,
                .target = kernel_exec.root_module.resolved_target.?,
                .cpu_arch = @as([]const u8, config.cpu_arch),
            });

            const kernel_module = b.addModule("kernel", .{
                .root_source_file = b.path("source/kernel/kernel.zig"),
                .target = kernel_exec.root_module.resolved_target,
                .optimize = optimize,
            });

            const libc_imports_module = b.addModule("libc_imports", .{
                .root_source_file = b.path("source/libc_imports.zig"),
                .target = kernel_exec.root_module.resolved_target,
                .optimize = optimize,
            });

            const cimports_module = b.addModule("libc_imports", .{
                .root_source_file = b.path("source/cimports.zig"),
                .target = kernel_exec.root_module.resolved_target,
                .optimize = optimize,
            });

            libc_imports_module.include_dirs = try kernel_exec.root_module.include_dirs.clone(b.allocator);
            cimports_module.include_dirs = try kernel_exec.root_module.include_dirs.clone(b.allocator);

            kernel_module.addImport("libc_imports", libc_imports_module);
            kernel_module.addImport("c", cimports_module);

            kernel_exec.root_module.addImport("kernel", kernel_module);
            kernel_exec.root_module.addImport("yasld", yasld.module("yasld"));
            kernel_exec.root_module.addImport("libc_imports", libc_imports_module);
            kernel_exec.root_module.addIncludePath(b.path("."));
            const arch_module = b.addModule("arch", .{
                .root_source_file = b.path(b.fmt("source/arch/{s}/arch.zig", .{config.cpu_arch})),
            });

            const hal_module = boardDep.artifact("yasos_kernel").root_module.import_table.get("hal").?;
            const board_module = boardDep.artifact("yasos_kernel").root_module.import_table.get("board").?;

            arch_module.addImport("hal", hal_module);
            kernel_module.addImport("hal", hal_module);
            kernel_module.addImport("board", board_module);

            if (std.mem.eql(u8, config.cpu_arch, "armv6-m") or std.mem.eql(u8, config.cpu_arch, "armv8-m")) {
                const arch_arm_m = b.addModule("arm-m", .{
                    .root_source_file = b.path("source/arch/arm-m/arch.zig"),
                });
                arch_module.addImport("arm-m", arch_arm_m);
                const config_module = boardDep.artifact("yasos_kernel").root_module.import_table.get("config").?;

                arch_module.addImport("config", config_module);
                arch_arm_m.addImport("config", config_module);
                kernel_module.addImport("config", config_module);
                kernel_module.addImport("yasld", yasld.module("yasld"));
                kernel_module.addImport("arch", arch_module);
                arch_arm_m.addImport("hal", hal_module);
            }
            arch_module.addAssemblyFile(b.path(b.fmt("source/arch/{s}/context_switch.S", .{config.cpu_arch})));
            boardDep.artifact("yasos_kernel").root_module.addImport("arch", arch_module);
            boardDep.artifact("yasos_kernel").root_module.addImport("interface", oop.module("interface"));
            kernel_module.addImport("interface", oop.module("interface"));

            const date_data = "2025-10-10";

            var date: []const u8 = date_data[0..];
            const zfat = b.dependency("modules/fatfs", .{
                .optimize = optimize,
                .target = kernel_exec.root_module.resolved_target.?,
                .@"no-libc" = true,
                .@"static-rtc" = date[0..],
            });
            _ = try zfat.builder.addUserInputOption("no-libc", "true");
            const zfat_module = zfat.module("zfat");
            for (kernel_exec.root_module.include_dirs.items) |include_dir| {
                switch (include_dir) {
                    .path_system => |path| {
                        zfat_module.link_objects.items[0].other_step.root_module.addSystemIncludePath(path);
                    },

                    else => {},
                }
            }
            zfat_module.link_objects.items[0].other_step.root_module.sanitize_c = .trap;
            kernel_exec.root_module.addImport("zfat", zfat_module);

            _ = boardDep.module("board");
        } else {
            std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
        }
    }
}
