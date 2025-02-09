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
    .os_tag = .freestanding,
    .abi = .eabi,
    .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
    .cpu_features_add = std.Target.arm.featureSet(&[_]std.Target.arm.Feature{
        .fp_armv8d16sp,
    }),
};

fn configureCmake(b: *std.Build) ![]const u8 {
    const cmake_exe = b.findProgram(&.{"cmake"}, &.{}) catch {
        std.log.err("Can't find CMake in system path", .{});
        unreachable;
    };

    const pico_sdk_path = b.pathJoin(&.{ b.pathFromRoot("../../../libs"), "pico-sdk" });
    std.log.info("Used PicoSDK: {s}", .{pico_sdk_path});
    std.log.info("CMake: {s}", .{cmake_exe});

    const cmake_binary_dir = b.pathJoin(&.{ b.cache_root.path.?, "pico_sdk_generated" });
    const cache_dir = try std.fs.openDirAbsolute(b.cache_root.path.?, .{});
    _ = try cache_dir.makePath("pico_sdk_generated");
    std.log.info("CMake project binary dir: {s}", .{cmake_binary_dir});

    const configure_project = b.run(&.{ cmake_exe, "-S", @as([]const u8, pico_sdk_path), "-B", @as([]const u8, cmake_binary_dir) });
    std.log.info("{s}", .{configure_project});
    return cmake_binary_dir;
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
    const halInterface = b.dependency("hal_interface", .{ .optimize = optimize, .target = target });
    hal.addImport("hal_interface", halInterface.module("hal_interface"));

    const raspberry_common = b.addModule("raspberry_common", .{
        .root_source_file = b.path("../common/init.zig"),
        .target = target,
        .optimize = optimize,
    });
    hal.addImport("raspberry_common", raspberry_common);

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
    hal_armv8_m.addImport("hal", hal);
    cortex_m.addImport("arch", hal_armv8_m);
    hal.addImport("cortex-m", cortex_m);

    hal.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ picosdk, "generated/pico_base" }) });
    _ = halInterface.module("hal_interface");
    _ = try toolchain.decorateModuleWithArmToolchain(b, hal, target);
    _ = try toolchain.decorateModuleWithArmToolchain(b, hal_common, target);

    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_base/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2350/hardware_structs/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/common/pico_base_headers/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_uart/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2350/hardware_regs/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2350/pico_platform/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_platform_compiler/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_platform_sections/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_platform_panic/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_resets/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_clocks/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_timer/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_pll/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_irq/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_gpio/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_sync/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_sync_spin_lock/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/common/hardware_claim/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/common/pico_sync/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/common/pico_time/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_runtime/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_runtime_init/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_divider/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_divider/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/common/pico_binary_info/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/common/boot_picobin_headers/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_bootrom/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/common/boot_picoboot_headers/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/boot_bootrom_headers/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_time_adapter/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_ticks/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_watchdog/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_xosc/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_boot_lock/include"));
    hal.addIncludePath(b.path("../../../libs/pico-sdk/src/rp2_common/pico_flash/include"));

    hal.addCMacro("PICO_RP2350", "1");

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
        },
        .flags = &.{"-std=c23"},
    });
    hal.addAssemblyFile(b.path("../../../libs/pico-sdk/src/rp2_common/hardware_irq/irq_handler_chain.S"));
    hal.addAssemblyFile(b.path("startup/startup.S"));
}
