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

pub fn decorateModuleWithArmToolchain(b: *std.Build, module: anytype, target: std.Build.ResolvedTarget) ![]const u8 {
    const arm_gcc_exe = b.findProgram(&.{"arm-none-eabi-gcc"}, &.{}) catch {
        std.log.err("Can't find arm-none-eabi-gcc in system path", .{});
        unreachable;
    };

    // idea from: https://github.com/haydenridd/stm32-zig-porting-guide/blob/main/03_with_zig_build/build.zig
    //
    // NOTE: we intentionally do NOT rebuild paths from `-print-sysroot`. Distro
    // toolchains (Debian/Ubuntu gcc-arm-none-eabi, e.g. under WSL) report an EMPTY
    // sysroot, which turned the old "{sysroot}/include" / "{sysroot}/lib/..." forms
    // into bogus absolute paths like "/include" and broke the C library builds.
    // Instead we ask gcc for the concrete multilib-resolved artifact locations,
    // which are correct whether or not the toolchain reports a sysroot.
    const gcc_arm_sysroot_path = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, "-print-sysroot" }), " \r\n");
    var cpu_name_buffer: [128]u8 = undefined;
    @memset(cpu_name_buffer[0..], 0);
    _ = std.mem.replace(u8, target.result.cpu.model.name, "_", "-", cpu_name_buffer[0..]);
    const cpu_name = std.mem.sliceTo(cpu_name_buffer[0..], 0);
    const mcpu_arg = b.fmt("-mcpu={s}", .{cpu_name});
    const mfloat_arg = b.fmt("-mfloat-abi={s}", .{@tagName(target.result.abi.float())});

    // Exact multilib-resolved artifact paths, e.g.
    //   .../arm-none-eabi/lib/thumb/v8-m.main+fp/hard/libc.a
    //   .../lib/gcc/arm-none-eabi/<ver>/thumb/v8-m.main+fp/hard/libgcc.a
    const libgcc_path = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, mcpu_arg, mfloat_arg, "-print-libgcc-file-name" }), " \r\n");
    const libc_path = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, mcpu_arg, mfloat_arg, "-print-file-name=libc.a" }), " \r\n");

    // Library search dirs: the gcc multilib dir (libgcc) and the newlib multilib dir (libc/libm).
    const gcc_arm_lib_path1 = std.fs.path.dirname(libgcc_path) orelse libgcc_path;
    const gcc_arm_lib_path2 = std.fs.path.dirname(libc_path) orelse libc_path;

    // Newlib headers live at "<newlib-root>/include", where <newlib-root> is the
    // libc.a path truncated at its final "/lib/" segment (this resolves correctly
    // even through Debian's symlinked arm-none-eabi/include -> /usr/include/newlib).
    // Fall back to the sysroot form for toolchains that do report a sysroot.
    const include_path = if (std.mem.lastIndexOf(u8, libc_path, "/lib/")) |idx|
        b.fmt("{s}/include", .{libc_path[0..idx]})
    else
        b.fmt("{s}/include", .{gcc_arm_sysroot_path});

    module.addLibraryPath(.{ .cwd_relative = gcc_arm_lib_path1 });
    module.addLibraryPath(.{ .cwd_relative = gcc_arm_lib_path2 });
    module.addSystemIncludePath(.{ .cwd_relative = include_path });
    module.linkSystemLibrary("c_nano", .{});
    module.linkSystemLibrary("m", .{});
    module.addObjectFile(.{ .cwd_relative = libgcc_path });
    return gcc_arm_sysroot_path;
}
