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

const littlefs = @import("source/fs/littlefs/build.zig");

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
    std.Io.Dir.cwd().createDirPath(b.graph.io, config_dir) catch |err| {
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
    /// Optional so a config.json generated before these symbols existed still
    /// parses; both default to "no DCP state to preserve".
    cpu_has_dcp: ?bool = null,
    build_userspace_hardware_fp: ?bool = null,
    /// Gates the SVC-entry cycle stamp in context_switch.S; kept in step with
    /// `perf_profile.enabled`, which reads the same Kconfig symbol.
    instrumentation_perf_profiling: ?bool = null,
};

fn load_config(b: *std.Build, config_file: []const u8) !Config {
    const file = try std.Io.Dir.cwd().openFile(b.graph.io, config_file, .{ .mode = .read_only });
    defer file.close(b.graph.io);

    const endPosition = try file.length(b.graph.io);
    const buffer = b.allocator.alloc(u8, endPosition) catch return error.OutOfMemory;
    const readed = try file.readPositionalAll(b.graph.io, buffer, 0);
    const parsed = try std.json.parseFromSlice(
        Config,
        b.allocator,
        buffer[0..readed],
        .{
            .ignore_unknown_fields = true,
        },
    );
    return parsed.value;
}

/// How many FAT volumes may be mounted at once.
///
/// Must match `source/fs/fatfs/fatfs.zig`'s `max_volumes`. One is what FatFs
/// defaults to, and it made a second `FatFs` instance silently repoint the
/// first at its own device rather than fail.
const fat_volume_count: u5 = 4;

pub fn build(b: *std.Build) !void {
    const test_filters = b.option([]const []const u8, "test-filter", "comma separated list of test name filters") orelse &[0][]const u8{};
    const defconfig_file = b.option([]const u8, "defconfig_file", "use a specific defconfig file") orelse null;
    const run_tests_step = b.step("test", "Run Yasos tests");
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
    var has_config = true;
    var maybe_config_directory: ?std.Io.Dir = std.Io.Dir.cwd().openDir(b.graph.io, "config/target", .{}) catch blk: {
        has_config = false;
        break :blk null;
    };

    var maybe_config_exists: ?std.Io.File.Stat = null;
    if (maybe_config_directory) |config_directory| {
        maybe_config_exists = config_directory.statFile(b.graph.io, "config.json", .{}) catch blk: {
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
    const target = b.standardTargetOptions(.{});
    const kernel_module_for_tests = b.addModule("kernel_under_test", .{
        .root_source_file = b.path("source/kernel/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kernel_tests_module = b.addModule("kernel_tests_module", .{
        .root_source_file = b.path("source/kernel/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kernel_tests = b.addTest(.{
        .name = "kernel_tests",
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .root_module = kernel_tests_module,
        .use_llvm = true,
        .filters = test_filters,
    });

    const arch_tests_module = b.addModule("arch_tests_module", .{
        .root_source_file = b.path("source/arch/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const arch_tests = b.addTest(.{
        .name = "arch_tests",
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .root_module = arch_tests_module,
        .use_llvm = true,
        .filters = test_filters,
    });

    const fs_tests_module = b.addModule("fs_tests_module", .{
        .root_source_file = b.path("source/fs/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fs_tests = b.addTest(.{
        .name = "fs_tests",
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .root_module = fs_tests_module,
        .use_llvm = true,
        .filters = test_filters,
    });
    fs_tests.root_module.addImport("kernel", kernel_module_for_tests);

    const yasld_stub = b.addModule("yasld_stub", .{
        .root_source_file = b.path("dynamic_loader/stub/yasld.zig"),
        .target = target,
        .optimize = optimize,
    });

    kernel_tests.root_module.addImport("yasld", yasld_stub);
    // fs_tests needs it too now: the FatFs lock is a *sleeping* mutex, so it
    // reaches the process manager to block and wake a caller, and that pulls in
    // the syscall handlers behind it. The cost of a lock that can yield.
    kernel_module_for_tests.addImport("yasld", yasld_stub);

    const c_for_tests = b.addModule("c_for_tests", .{
        .root_source_file = b.path("source/cimports.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_tests.root_module.addImport("c", c_for_tests);
    c_for_tests.addIncludePath(b.path("libs/libc"));
    const stdlib_headers_for_tests = b.addTranslateC(.{
        .root_source_file = b.path("libs/libc/stdlib.h"),
        .target = target,
        .optimize = optimize,
    });
    stdlib_headers_for_tests.addIncludePath(b.path("libs/libc"));
    c_for_tests.addImport("c_headers", stdlib_headers_for_tests.createModule());

    const generate_defconfig_for_tests = generate_config(b, "configs/host_defconfig", "config/tests");
    generate_defconfig_for_tests.step.dependOn(&venv.step);
    generate_defconfig_for_tests.has_side_effects = true;
    kernel_tests.step.dependOn(&generate_defconfig_for_tests.step);
    fs_tests.step.dependOn(&generate_defconfig_for_tests.step);
    arch_tests.step.dependOn(&generate_defconfig_for_tests.step);

    const install_kernel_tests = b.addInstallBinFile(kernel_tests.getEmittedBin(), "kernel_tests");
    const install_fs_tests = b.addInstallBinFile(fs_tests.getEmittedBin(), "fs_tests");
    const install_arch_tests = b.addInstallBinFile(arch_tests.getEmittedBin(), "arch_tests");
    run_tests_step.dependOn(&install_arch_tests.step);
    run_tests_step.dependOn(&install_fs_tests.step);
    run_tests_step.dependOn(&install_kernel_tests.step);
    kernel_tests.root_module.link_libc = true;

    const test_config_module = b.addModule("test_config", .{
        .root_source_file = b.path("config/tests/config.zig"),
    });
    kernel_tests.root_module.addImport("config", test_config_module);
    fs_tests.root_module.addImport("config", test_config_module);
    arch_tests.root_module.addImport("config", test_config_module);

    const arch_for_tests = b.addModule("arch_for_tests", .{
        .root_source_file = b.path("source/arch/ut/arch.zig"),
    });

    fs_tests.root_module.addImport("arch", arch_for_tests);

    const hal_interface = b.addModule("hal_interface", .{
        .root_source_file = b.path("hal/interface/hal.zig"),
    });

    const hal_for_tests = b.addModule("hal_for_tests", .{
        .root_source_file = b.path("hal/source/ut_stub/hal.zig"),
    });

    hal_for_tests.addImport("hal_interface", hal_interface);
    kernel_tests.root_module.addImport("hal", hal_for_tests);
    kernel_tests.root_module.addImport("arch", arch_for_tests);

    // The kernel module exposes `kernel.perf` (perf_profile.zig) so filesystem
    // code outside source/kernel can attribute its own work. That module reads
    // the instrumentation Kconfig and the CPU frequency, so the module needs
    // both imports even in a test build where profiling compiles out — without
    // them fs_tests fails with "no module named 'config' available".
    kernel_module_for_tests.addImport("config", test_config_module);
    kernel_module_for_tests.addImport("hal", hal_for_tests);
    // fs_tests reaches `kernel.sync` (ramfs refcounts), and the sync primitives
    // ask the arch layer how wide a lock-free atomic is and how to mask
    // interrupts. Zig only analyses an import when something references it, so
    // this was previously satisfied by nothing in fs_tests touching that path.
    kernel_module_for_tests.addImport("arch", arch_for_tests);

    // Forward optimize, for the same reason as the MCU dependency in
    // hal/build.zig: without it this builds Debug inside a release kernel, and
    // `interface` is the vtable machinery every filesystem, driver and file
    // object in the tree dispatches through.
    const oop = b.dependency("modules/oop", .{ .optimize = optimize });

    kernel_tests.root_module.addImport("interface", oop.module("interface"));
    fs_tests.root_module.addImport("interface", oop.module("interface"));
    arch_tests.root_module.addImport("interface", oop.module("interface"));

    const libc_imports_for_tests = b.addModule("libc_imports_for_tests", .{
        .root_source_file = b.path("source/libc_imports.zig"),
    });

    hal_for_tests.addImport("libc_imports", libc_imports_for_tests);
    libc_imports_for_tests.addIncludePath(b.path("."));
    libc_imports_for_tests.addIncludePath(b.path("libs/libc"));

    const libc_headers_for_tests = b.addTranslateC(.{
        .root_source_file = b.path("source/libc_imports.h"),
        .target = target,
        .optimize = optimize,
    });
    libc_headers_for_tests.addIncludePath(b.path("."));
    libc_headers_for_tests.addIncludePath(b.path("libs/libc"));
    libc_imports_for_tests.addImport("c_headers", libc_headers_for_tests.createModule());

    kernel_tests.root_module.addImport("libc_imports", libc_imports_for_tests);
    fs_tests.root_module.addImport("libc_imports", libc_imports_for_tests);
    arch_tests.root_module.addImport("libc_imports", libc_imports_for_tests);

    const run_kernel_tests = b.addRunArtifact(kernel_tests);
    const run_fs_tests = b.addRunArtifact(fs_tests);
    const run_arch_tests = b.addRunArtifact(arch_tests);

    run_tests_step.dependOn(&run_kernel_tests.step);
    run_tests_step.dependOn(&run_fs_tests.step);
    run_tests_step.dependOn(&run_arch_tests.step);

    kernel_tests.root_module.addIncludePath(b.path("."));
    kernel_tests.root_module.addIncludePath(b.path("libs/libc"));
    fs_tests.root_module.addIncludePath(b.path("."));
    arch_tests.root_module.addIncludePath(b.path("."));

    const zfat_host = b.dependency("modules/fatfs", .{
        .optimize = optimize,
        .mkfs = true,
        .relative_path_api = .enabled_with_getcwd,
        // More than one FAT volume. Costs a pointer per slot in FatFs's
        // `FatFs[]` and in zfat's `disks[]`; buys an SD rootfs and a flash
        // /mnt on the same board, which a single volume made impossible.
        .@"volume-count" = @as(u5, fat_volume_count),
    });
    const zfat_host_module = zfat_host.module("zfat");

    fs_tests.root_module.addImport("zfat", zfat_host_module);

    kernel_module_for_tests.addImport("interface", oop.module("interface"));
    kernel_module_for_tests.addImport("libc_imports", libc_imports_for_tests);
    if (!has_config) {
        std.log.err("'config/config.json' not found. Please call 'zig build menuconfig' before compilation", .{});
        return;
    }

    const run_kernel_tests_coverage = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-path=source/",
    });
    run_kernel_tests_coverage.addDirectoryArg(b.graph.path(.install_prefix, "kernel_tests"));

    const run_arch_tests_coverage = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-path=source/",
    });
    run_arch_tests_coverage.addDirectoryArg(b.graph.path(.install_prefix, "arch_tests"));

    const run_fs_tests_coverage = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-path=source/",
    });
    run_fs_tests_coverage.addDirectoryArg(b.graph.path(.install_prefix, "fs_tests"));

    run_kernel_tests_coverage.addArtifactArg(kernel_tests);
    run_arch_tests_coverage.addArtifactArg(fs_tests);
    run_fs_tests_coverage.addArtifactArg(arch_tests);

    const run_coverage = b.addSystemCommand(&.{
        "kcov",
        "--exclude-path=source/fs/romfs/tests,source/fs/fatfs/tests,source/arch/ut",
        "--exclude-pattern=tests.zig,stub.zig,osthread.zig",
        "--merge",
    });
    run_coverage.addDirectoryArg(b.graph.path(.install_prefix, "coverage_report"));
    run_coverage.addDirectoryArg(b.graph.path(.install_prefix, "coverage_kernel"));
    run_coverage.addDirectoryArg(b.graph.path(.install_prefix, "coverage_arch"));
    run_coverage.addDirectoryArg(b.graph.path(.install_prefix, "coverage_fs"));

    run_coverage.step.dependOn(&run_kernel_tests_coverage.step);
    run_coverage.step.dependOn(&run_arch_tests_coverage.step);
    run_coverage.step.dependOn(&run_fs_tests_coverage.step);

    run_arch_tests_coverage.step.dependOn(&install_arch_tests.step);
    run_fs_tests_coverage.step.dependOn(&install_fs_tests.step);
    run_kernel_tests_coverage.step.dependOn(&install_kernel_tests.step);

    const coverage_step = b.step("coverage", "Generate code coverage report");
    coverage_step.dependOn(&run_coverage.step);

    if (maybe_config_exists) |config_exists| {
        if (config_exists.kind == .file) {
            const config_path = try maybe_config_directory.?.realPathFileAlloc(b.graph.io, "config.json", b.allocator);
            std.debug.print("Using configuration file: {s}\n", .{config_path});
            const config = try load_config(b, config_path);
            const boardDep = b.dependency("yasos_hal", .{
                .board = @as([]const u8, config.board),
                .root_file = b.path("source/main.zig"),
                .optimize = optimize,
                .name = @as([]const u8, "yasos_kernel"),
                .config_file = @as([]const u8, config_path),
            });
            b.installArtifact(boardDep.artifact("yasos_kernel"));
            const kernel_exec = boardDep.artifact("yasos_kernel");
            kernel_exec.root_module.addIncludePath(b.path("source/sys/include"));
            kernel_exec.root_module.addIncludePath(b.path("."));
            kernel_exec.root_module.addIncludePath(b.path("libs/littlefs"));

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
            libc_imports_module.addIncludePath(b.path("."));
            libc_imports_module.addIncludePath(b.path("libs/libc"));
            libc_imports_module.addIncludePath(b.path("rootfs/usr/include"));
            const cimports_module = b.addModule("cimports", .{
                .root_source_file = b.path("source/cimports.zig"),
                .target = kernel_exec.root_module.resolved_target,
                .optimize = optimize,
            });

            cimports_module.include_dirs = try kernel_exec.root_module.include_dirs.clone(b.allocator);

            const kernel_target = kernel_exec.root_module.resolved_target.?;
            const libc_headers = b.addTranslateC(.{
                .root_source_file = b.path("source/libc_imports.h"),
                .target = kernel_target,
                .optimize = optimize,
                .link_libc = false,
            });
            libc_headers.addIncludePath(b.path("."));
            libc_headers.addIncludePath(b.path("libs/libc"));
            libc_headers.addIncludePath(b.path("rootfs/usr/include"));
            libc_imports_module.addImport("c_headers", libc_headers.createModule());

            const stdlib_headers = b.addTranslateC(.{
                .root_source_file = b.path("libs/libc/stdlib.h"),
                .target = kernel_target,
                .optimize = optimize,
                .link_libc = false,
            });
            stdlib_headers.addIncludePath(b.path("."));
            stdlib_headers.addIncludePath(b.path("libs/libc"));
            cimports_module.addImport("c_headers", stdlib_headers.createModule());

            kernel_module.addImport("libc_imports", libc_imports_module);
            kernel_module.addImport("c", cimports_module);

            kernel_exec.root_module.addImport("kernel", kernel_module);
            kernel_exec.root_module.addImport("yasld", yasld.module("yasld"));
            yasld.module("yasld").addIncludePath(b.path("./libs/tinycc/source/obj"));
            kernel_exec.root_module.addImport("libc_imports", libc_imports_module);
            kernel_exec.root_module.addIncludePath(b.path("."));
            const arch_module = b.addModule("arch", .{
                .root_source_file = b.path(b.fmt("source/arch/{s}/arch.zig", .{config.cpu_arch})),
            });
            arch_module.addIncludePath(b.path("."));
            arch_module.addIncludePath(b.path("libs/libc"));
            arch_module.addImport("libc_imports", libc_imports_module);

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
                arch_arm_m.addImport("libc_imports", libc_imports_module);
                kernel_module.addImport("config", config_module);
                kernel_module.addImport("yasld", yasld.module("yasld"));
                kernel_module.addImport("arch", arch_module);
                arch_arm_m.addImport("hal", hal_module);
            }
            // The context switch has to preserve the DCP's X/Y/EFD state when
            // user code may run DCP sequences -- they are not atomic and the
            // hardware stacks nothing for CP4. Same condition as
            // `saves_dcp_state` in source/arch/arm-m/process.zig, which sizes
            // the matching slot in the software frame.
            if ((config.cpu_has_dcp orelse false) and (config.build_userspace_hardware_fp orelse false)) {
                arch_module.addCMacro("YASOS_SAVE_DCP_STATE", "1");
            }
            // The syscall profiler needs a cycle stamp from inside the SVC
            // handler; without it the recorded time would start after the
            // trampoline and miss the dispatch cost entirely.
            if (config.instrumentation_perf_profiling orelse false) {
                arch_module.addCMacro("YASOS_PERF_SYSCALL_STAMP", "1");
            }
            arch_module.addAssemblyFile(b.path(b.fmt("source/arch/{s}/context_switch.S", .{config.cpu_arch})));
            boardDep.artifact("yasos_kernel").root_module.addImport("arch", arch_module);
            boardDep.artifact("yasos_kernel").root_module.addImport("interface", oop.module("interface"));
            kernel_module.addImport("interface", oop.module("interface"));
            const littlefs_lib = littlefs.build_littlefs(b, optimize, kernel_exec.root_module.resolved_target.?);
            for (kernel_exec.root_module.include_dirs.items) |include_dir| {
                switch (include_dir) {
                    .path_system => |path| {
                        littlefs_lib.root_module.addSystemIncludePath(path);
                    },

                    else => {},
                }
            }
            kernel_module.addIncludePath(b.path("libs/littlefs"));
            kernel_module.linkLibrary(littlefs_lib);
            const littlefs_headers = b.addTranslateC(.{
                .root_source_file = b.path("libs/littlefs/lfs.h"),
                .target = kernel_target,
                .optimize = optimize,
                .link_libc = false,
            });
            littlefs_headers.addIncludePath(b.path("libs/littlefs"));
            littlefs_headers.addIncludePath(b.path("libs/libc"));
            littlefs_headers.addIncludePath(b.path("."));
            kernel_module.addImport("littlefs_headers", littlefs_headers.createModule());

            const date_data = "2025-10-10";

            var date: []const u8 = date_data[0..];
            const zfat = b.dependency("modules/fatfs", .{
                .optimize = optimize,
                .target = kernel_exec.root_module.resolved_target.?,
                .@"no-libc" = true,
                .@"static-rtc" = date[0..],
                .mkfs = true,
                .relative_path_api = .enabled_with_getcwd,
                .@"volume-count" = @as(u5, fat_volume_count),
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
