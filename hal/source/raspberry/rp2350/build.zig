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

fn addBoardIncludes(b: *std.Build, picosdk: []const u8, t: anytype) void {
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
        // The C library headers are libs/libc's, as for the C the image is
        // built from; gcc's own (stddef.h, stdarg.h) are the only others.
        "-nostdinc",
    });
    pp.addPrefixedDirectoryArg("-isystem", toolchain.libc(b, target, optimize).namedLazyPath("include"));
    pp.addArg(b.fmt("-isystem{s}", .{arm.gcc_include_path}));
    pp.addArg(b.fmt("-I{s}", .{b.pathJoin(&.{ picosdk, "generated" })}));
    pp.addArg(b.fmt("-I{s}", .{b.pathJoin(&.{ picosdk, "generated/pico_base" })}));
    for (board_include_paths) |path| pp.addPrefixedDirectoryArg("-I", b.path(path));
    pp.addFileArg(b.path(header));
    // Only `header` is a declared input, so without a depfile an edit to any
    // header it includes leaves the cached translation in place, and Zig code
    // keeps seeing the old declarations and macro values.
    pp.addArg("-MD");
    _ = pp.addPrefixedDepFileOutputArg("-MF", b.fmt("{s}_pp.d", .{import_name}));
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

    // Only the configure step's generated headers are used (pico_base's
    // version.h and config_autogen.h); pioasm comes from apps/pioasm.
    const version_header = b.pathJoin(&.{ cmake_binary_dir, "generated", "pico_base", "pico", "version.h" });
    std.Io.Dir.cwd().access(b.graph.io, version_header, .{}) catch |err| {
        if (err != error.FileNotFound) return err;

        std.Io.Dir.cwd().deleteTree(b.graph.io, cmake_binary_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(b.graph.io, cmake_binary_dir);

        const configure_project = b.run(&.{ cmake_exe, "-S", @as([]const u8, pico_sdk_path), "-B", @as([]const u8, cmake_binary_dir) });
        std.log.info("{s}", .{configure_project});
        return cmake_binary_dir;
    };

    return cmake_binary_dir;
}

// The C port of the SDK's pioasm (apps/pioasm), built for this machine. The
// same sources are built by tcc into the rootfs, so a kernel built on the
// device runs the same assembler.
fn build_pioasm(b: *std.Build) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    module.addCSourceFiles(.{
        .root = b.path("../../../../apps/pioasm"),
        .files = &.{ "main.c", "parse.c", "assemble.c", "disasm.c", "output.c" },
        .flags = &.{"-std=c11"},
    });
    return b.addExecutable(.{ .name = "pioasm", .root_module = module });
}

// A .pio program as Zig declarations (pioasm -o zig), so the Zig side needs no
// translate-c pass over a generated C header.
fn generate_pio(b: *std.Build, pioasm: *std.Build.Step.Compile, file: []const u8) std.Build.LazyPath {
    const cmd = b.addRunArtifact(pioasm);
    cmd.addArgs(&.{ "-o", "zig" });
    cmd.addFileArg(b.path(b.pathJoin(&.{ "source", file })));
    return cmd.addOutputFileArg(b.fmt("{s}.zig", .{std.fs.path.basename(file)}));
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

    const pioasm = build_pioasm(b);
    hal.addAnonymousImport("mmc_pio", .{ .root_source_file = generate_pio(b, pioasm, "mmc.pio") });
    hal.addAnonymousImport("mmc_spi_pio", .{ .root_source_file = generate_pio(b, pioasm, "mmc/mmc_spi.pio") });
    hal.addAnonymousImport("mmc_sdio_pio", .{ .root_source_file = generate_pio(b, pioasm, "mmc/mmc_sdio.pio") });

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
    try toolchain.decorateModuleWithArmToolchain(b, hal, target, optimize);
    try toolchain.decorateModuleWithArmToolchain(b, hal_common, target, optimize);

    addBoardIncludes(b, picosdk, hal);
    addBoardMacros(hal);

    const arm = try toolchain.resolveArmToolchain(b, target);
    addBoardHeaders(b, picosdk, arm, target, optimize, hal, "picosdk_headers", "source/picosdk_c.h");
    addBoardHeaders(b, picosdk, arm, target, optimize, hal, "clocks_headers", "source/cpu_c.h");
    addBoardHeaders(b, picosdk, arm, target, optimize, hal, "external_memory_headers", "source/external_memory_c.h");
    addBoardHeaders(b, picosdk, arm, target, optimize, hal, "mmc_spi_headers", "source/mmc/mmc_spi_c.h");
    addBoardHeaders(b, picosdk, arm, target, optimize, hal, "mmc_sdio_headers", "source/mmc/mmc_sdio_c.h");
    addBoardHeaders(b, picosdk, arm, target, optimize, hal, "crt_headers", "startup/crt_c.h");

    hal.addCSourceFiles(.{
        .files = &.{
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
        .flags = &.{"-std=c23"},
    });
    hal.addIncludePath(b.path("source/mmc"));
    hal.addIncludePath(b.path("startup"));
    hal.addAssemblyFile(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_irq/irq_handler_chain.S"));
    hal.addAssemblyFile(b.path("startup/startup.S"));
    hal.addAssemblyFile(b.path("source/external_memory.S"));
}
