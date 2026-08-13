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
const builtin = @import("builtin");

const toolchain = @import("toolchains").arm_none_eabi_toolchain;

pub const targetOptions = std.Target.Query{
    .cpu_arch = .thumb,
    .os_tag = .other,
    .abi = .eabihf,
    .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
    .cpu_features_add = std.Target.arm.featureSet(&[_]std.Target.arm.Feature{
        .fp_armv8d16sp,
    }),
};

const board_include_paths = [_][]const u8{
    "source/mmc",
    "startup",
    "../../../libs/pico-sdk/src/rp2_common/cmsis/stub/CMSIS/Core/Include",
    "../../../libs/pico-sdk/src/rp2_common/cmsis/stub/CMSIS/Device/RP2350/Include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_base/include",
    "../../../libs/pico-sdk/src/rp2350/hardware_structs/include",
    "../../../libs/pico-sdk/src/common/pico_base_headers/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_uart/include",
    "../../../libs/pico-sdk/src/rp2350/hardware_regs/include",
    "../../../libs/pico-sdk/src/rp2350/pico_platform/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_platform_common/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_platform_compiler/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_platform_sections/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_platform_panic/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_resets/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_clocks/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_timer/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_pll/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_irq/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_gpio/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_pio/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_dma/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_sync/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_vreg/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_sync_spin_lock/include",
    "../../../libs/pico-sdk/src/common/hardware_claim/include",
    "../../../libs/pico-sdk/src/common/pico_sync/include",
    "../../../libs/pico-sdk/src/common/pico_time/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_runtime/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_runtime_init/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_divider/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_divider/include",
    "../../../libs/pico-sdk/src/common/pico_binary_info/include",
    "../../../libs/pico-sdk/src/common/boot_picobin_headers/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_bootrom/include",
    "../../../libs/pico-sdk/src/common/boot_picoboot_headers/include",
    "../../../libs/pico-sdk/src/rp2_common/boot_bootrom_headers/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_time_adapter/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_ticks/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_watchdog/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_xosc/include",
    "../../../libs/pico-sdk/src/rp2_common/hardware_boot_lock/include",
    "../../../libs/pico-sdk/src/rp2_common/pico_flash/include",
};

fn addBoardIncludes(b: *std.Build, picosdk: []const u8, pio_dirs: []const std.Build.LazyPath, t: anytype) void {
    for (pio_dirs) |dir| t.addIncludePath(dir);
    t.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ picosdk, "generated" }) });
    t.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ picosdk, "generated/pico_base" }) });
    for (board_include_paths) |path| t.addIncludePath(b.path(path));
}

fn addBoardMacros(t: anytype) void {
    if (@hasDecl(@typeInfo(@TypeOf(t)).pointer.child, "addCMacro")) {
        t.addCMacro("PICO_RP2350", "1");
        t.addCMacro("PICO_USE_GPIO_COPROCESSOR", "0");
    } else {
        t.defineCMacro("PICO_RP2350", "1");
        t.defineCMacro("PICO_USE_GPIO_COPROCESSOR", "0");
    }
}

fn addBoardHeaders(
    b: *std.Build,
    picosdk: []const u8,
    pio_dirs: []const std.Build.LazyPath,
    arm: toolchain.ArmToolchain,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    owner: *std.Build.Module,
    import_name: []const u8,
    header: []const u8,
) void {
    const pp = b.addSystemCommand(&.{
        arm.gcc,        "-E",
        "-dD",          "-std=gnu11",
        arm.mcpu_arg,   arm.mfloat_arg,
        "-DPICO_RP2350=1", "-DPICO_USE_GPIO_COPROCESSOR=0",
    });
    for (pio_dirs) |dir| pp.addPrefixedDirectoryArg("-I", dir);
    pp.addArg(b.fmt("-I{s}", .{b.pathJoin(&.{ picosdk, "generated" })}));
    pp.addArg(b.fmt("-I{s}", .{b.pathJoin(&.{ picosdk, "generated/pico_base" })}));
    for (board_include_paths) |path| pp.addPrefixedDirectoryArg("-I", b.path(path));
    pp.addFileArg(b.path(header));
    pp.addArg("-o");
    const expanded = pp.addOutputFileArg(b.fmt("{s}_pp.h", .{import_name}));

    const step = b.addTranslateC(.{
        .root_source_file = expanded,
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    owner.addImport(import_name, step.createModule());
}

fn configureCmake(b: *std.Build) ![]const u8 {
    const cmake_exe = b.findProgram(.{ .names = &.{"cmake"} }) orelse {
        std.log.err("Can't find CMake in system path", .{});
        unreachable;
    };

    const pico_sdk_path = b.pathResolve(&.{ try b.root.toString(b.graph.arena), "../../../libs", "pico-sdk" });
    std.log.info("Used PicoSDK: {s}", .{pico_sdk_path});
    std.log.info("CMake: {s}", .{cmake_exe});

    const cmake_binary_dir = b.pathJoin(&.{ try b.root.toString(b.graph.arena), "pico_sdk_generated" });
    std.log.info("CMake project binary dir: {s}", .{cmake_binary_dir});

    const pioasm_path = b.pathJoin(&.{ cmake_binary_dir, "pioasm", "pioasm" });
    std.Io.Dir.cwd().access(b.graph.io, pioasm_path, .{}) catch |err| {
        if (err != error.FileNotFound) return err;

        // Reconfiguring a stale/partial cache does not reliably regenerate the
        // pioasmBuild ExternalProject target, so start from a clean directory.
        std.Io.Dir.cwd().deleteTree(b.graph.io, cmake_binary_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(b.graph.io, cmake_binary_dir);

        const configure_project = b.run(&.{ cmake_exe, "-S", @as([]const u8, pico_sdk_path), "-B", @as([]const u8, cmake_binary_dir) });
        std.log.info("{s}", .{configure_project});

        const build_pioasm = b.run(&.{ cmake_exe, "--build", @as([]const u8, cmake_binary_dir), "--target", "pioasmBuild" });
        std.log.info("{s}", .{build_pioasm});
        return cmake_binary_dir;
    };

    return cmake_binary_dir;
}

fn generate_pio(b: *std.Build, file: []const u8, picosdk: []const u8) !std.Build.LazyPath {
    const pioasm = b.pathJoin(&.{ picosdk, "pioasm", "pioasm" });
    const pio_file = b.path(b.pathJoin(&.{ "source", file }));
    const output_filename = try std.mem.concat(b.allocator, u8, &.{ file, ".h" });
    const output_file = b.pathJoin(&.{ picosdk, "generated", output_filename });
    const cmd = b.addSystemCommand(&.{pioasm});
    cmd.addFileArg(pio_file);
    cmd.has_side_effects = true;
    return cmd.addOutputFileArg(output_file);
}

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(targetOptions);

    const hal = b.addModule("hal", .{
        .root_source_file = b.path("rp2350.zig"),
        .target = target,
        .optimize = optimize,
    });

    const picosdk = try configureCmake(b);

    const mmc_pio = try generate_pio(b, "mmc.pio", picosdk);
    hal.addAnonymousImport("mmc_pio", .{
        .root_source_file = mmc_pio,
    });
    hal.addIncludePath(mmc_pio.dirname());

    const mmc_spi_pio = try generate_pio(b, "mmc/mmc_spi.pio", picosdk);
    hal.addAnonymousImport("mmc_spi_pio", .{
        .root_source_file = mmc_spi_pio,
    });
    hal.addIncludePath(mmc_spi_pio.dirname());

    const mmc_sdio_pio = try generate_pio(b, "mmc/mmc_sdio.pio", picosdk);
    hal.addAnonymousImport("mmc_sdio_pio", .{
        .root_source_file = mmc_sdio_pio,
    });
    hal.addIncludePath(mmc_sdio_pio.dirname());

    hal.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ picosdk, "generated" }) });

    const halInterface = b.dependency("hal_interface", .{ .optimize = optimize, .target = target });
    hal.addImport("hal_interface", halInterface.module("hal_interface"));

    const raspberry_common = b.addModule("raspberry_common", .{
        .root_source_file = b.path("../common/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    hal.addImport("raspberry_common", raspberry_common);
    raspberry_common.addImport("hal_interface", halInterface.module("hal_interface"));

    const hal_common = b.addModule("hal_common", .{
        .root_source_file = b.path("../../common/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cmsis = b.addModule("cmsis", .{
        .root_source_file = b.path("cmsis.zig"),
        .target = target,
        .optimize = optimize,
    });
    cmsis.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/cmsis/stub/CMSIS/Core/Include"));
    cmsis.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/cmsis/stub/CMSIS/Device/RP2350/Include"));
    hal_common.addImport("cmsis", cmsis);
    hal.addImport("hal_common", hal_common);

    const cortex_m = b.addModule("cortex-m", .{
        .root_source_file = b.path("../../common/cores/arm/cortex-m/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    cortex_m.addImport("cmsis", cmsis);

    const hal_armv8_m = b.addModule("hal_armv8_m", .{
        .root_source_file = b.path("../../common/arch/arm/armv8-m/registers.zig"),
        .target = target,
        .optimize = optimize,
    });
    hal_armv8_m.addAssemblyFile(b.path("../../common/arch/arm/armv8-m/irq.S"));
    hal_armv8_m.addImport("hal", hal);
    hal_armv8_m.addImport("cmsis", cmsis);
    hal.addImport("arch", hal_armv8_m);
    cortex_m.addImport("arch", hal_armv8_m);
    hal.addImport("cortex-m", cortex_m);

    _ = halInterface.module("hal_interface");
    _ = try toolchain.decorateModuleWithArmToolchain(b, hal, target);
    _ = try toolchain.decorateModuleWithArmToolchain(b, hal_common, target);

    const pio_dirs = [_]std.Build.LazyPath{ mmc_pio.dirname(), mmc_spi_pio.dirname(), mmc_sdio_pio.dirname() };
    addBoardIncludes(b, picosdk, &pio_dirs, hal);
    addBoardMacros(hal);

    const arm = try toolchain.resolveArmToolchain(b, target);
    addBoardHeaders(b, picosdk, &pio_dirs, arm, target, optimize, hal, "picosdk_headers", "source/picosdk_c.h");
    addBoardHeaders(b, picosdk, &pio_dirs, arm, target, optimize, hal, "clocks_headers", "source/cpu_c.h");
    addBoardHeaders(b, picosdk, &pio_dirs, arm, target, optimize, hal, "external_memory_headers", "source/external_memory_c.h");
    addBoardHeaders(b, picosdk, &pio_dirs, arm, target, optimize, hal, "mmc_spi_headers", "source/mmc/mmc_spi_c.h");
    addBoardHeaders(b, picosdk, &pio_dirs, arm, target, optimize, hal, "mmc_sdio_headers", "source/mmc/mmc_sdio_c.h");
    addBoardHeaders(b, picosdk, &pio_dirs, arm, target, optimize, hal, "crt_headers", "startup/crt_c.h");

    hal.addCSourceFiles(.{
        .files = &.{
            // MUST be first: provides interrupt-safe __malloc_lock/__malloc_unlock
            // ahead of any object that references malloc, so newlib's no-op mlock.o
            // is never pulled from libc_nano.a (avoids a duplicate-symbol error).
            "malloc_lock.c",
            // Second, and for the same class of reason: word-at-a-time
            // memcpy/memset/memmove that must be seen before anything
            // references them, or newlib-nano's byte-loop versions get pulled
            // out of libc_nano.a and collide. Only pays when this HAL is built
            // optimised -- at -O0 it is slower than the byte loop it replaces.
            "mem_ops.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_uart/uart.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_clocks/clocks.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_irq/irq.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_pll/pll.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_gpio/gpio.c",
            "../../../libs/pico-sdk/src/common/hardware_claim/claim.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_timer/timer.c",
            "../../../libs/pico-sdk/src/rp2_common/pico_runtime/runtime.c",
            "../../../libs/pico-sdk/src/rp2_common/pico_runtime_init/runtime_init_clocks.c",
            "../../../libs/pico-sdk/src/rp2_common/pico_runtime_init/runtime_init_stack_guard.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_sync/sync.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_xosc/xosc.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_sync_spin_lock/sync_spin_lock.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_ticks/ticks.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_pio/pio.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_dma/dma.c",
            "../../../libs/pico-sdk/src/rp2_common/hardware_vreg/vreg.c",
            "source/mmc/sdio_rp2350.c",
            "startup/overclock.c",
            // "../../../libs/pico-sdk/src/common/pico_time/time.c",
            // "../../../libs/pico-sdk/src/common/pico_sync/lock_core.c",
        },
        // -fno-builtin is kept for when mem_ops.c returns: without it the compiler
        // recognises its copy loops and lowers them back into calls to the very
        // functions being defined. It is harmless for the rest.
        .flags = &.{ "-std=c23", "-fno-builtin" },
    });
    hal.addIncludePath(b.path("source/mmc"));
    hal.addIncludePath(b.path("startup"));
    hal.addAssemblyFile(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_irq/irq_handler_chain.S"));
    hal.addAssemblyFile(b.path("startup/startup.S"));
    hal.addAssemblyFile(b.path("source/external_memory.S"));
}
