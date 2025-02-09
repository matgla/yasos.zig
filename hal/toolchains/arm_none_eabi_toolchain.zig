//
// arm_none_eabi_toolchain.zig
//
// Copyright (C) 2024 Mateusz Stadnik <matgla@live.com>
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

pub fn decorateModuleWithArmToolchain(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) ![]const u8 {
    const arm_gcc_exe = b.findProgram(&.{"arm-none-eabi-gcc"}, &.{}) catch {
        std.log.err("Can't find arm-none-eabi-gcc in system path", .{});
        unreachable;
    };

    // idea from: https://github.com/haydenridd/stm32-zig-porting-guide/blob/main/03_with_zig_build/build.zig
    const gcc_arm_sysroot_path = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, "-print-sysroot" }), "\r\n");
    var cpu_name_buffer: [128]u8 = undefined;
    @memset(cpu_name_buffer[0..], 0);
    _ = std.mem.replace(u8, target.result.cpu.model.name, "_", "-", cpu_name_buffer[0..]);
    const cpu_name = std.mem.sliceTo(cpu_name_buffer[0..], 0);
    const gcc_arm_multidir_relative_path = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, b.fmt("-mcpu={s}", .{cpu_name}), b.fmt("-mfloat-abi={s}", .{@tagName(target.result.floatAbi())}), "-print-multi-directory" }), "\r\n");
    const gcc_arm_version = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, "-dumpversion" }), "\r\n");
    const gcc_arm_lib_path1 = b.fmt("{s}/../lib/gcc/arm-none-eabi/{s}/{s}", .{ gcc_arm_sysroot_path, gcc_arm_version, gcc_arm_multidir_relative_path });
    const gcc_arm_lib_path2 = b.fmt("{s}/lib/{s}", .{ gcc_arm_sysroot_path, gcc_arm_multidir_relative_path });

    module.addLibraryPath(.{ .cwd_relative = gcc_arm_lib_path1 });
    module.addLibraryPath(.{ .cwd_relative = gcc_arm_lib_path2 });
    module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{gcc_arm_sysroot_path}) });
    module.linkSystemLibrary("c_nano", .{});
    module.linkSystemLibrary("m", .{});
    module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libgcc.a", .{gcc_arm_lib_path1}) });
    return gcc_arm_sysroot_path;
}
