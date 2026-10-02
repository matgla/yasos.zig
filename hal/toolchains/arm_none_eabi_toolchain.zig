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

pub const ArmToolchain = struct {
    gcc: []const u8,
    mcpu_arg: []const u8,
    mfloat_arg: []const u8,
    /// gcc's own headers (stddef.h, stdarg.h, ...), for a preprocessor run
    /// with -nostdinc that must still find them.
    gcc_include_path: []const u8,
    libgcc_path: []const u8,
};

pub fn resolveArmToolchain(b: *std.Build, target: std.Build.ResolvedTarget) !ArmToolchain {
    const arm_gcc_exe = b.findProgram(.{ .names = &.{"arm-none-eabi-gcc"} }) orelse {
        std.log.err("Can't find arm-none-eabi-gcc in system path", .{});
        unreachable;
    };

    // idea from: https://github.com/haydenridd/stm32-zig-porting-guide/blob/main/03_with_zig_build/build.zig
    //
    // gcc is only asked for its own files here: libgcc and its builtin headers.
    // The C library is libs/libc (see `decorateModuleWithArmToolchain`), not
    // the newlib the toolchain ships. Both paths come from the multilib-resolved
    // queries rather than `-print-sysroot`, which distro toolchains (Debian,
    // WSL) report empty.
    var cpu_name_buffer: [128]u8 = undefined;
    @memset(cpu_name_buffer[0..], 0);
    _ = std.mem.replace(u8, target.result.cpu.model.name, "_", "-", cpu_name_buffer[0..]);
    const cpu_name = std.mem.sliceTo(cpu_name_buffer[0..], 0);
    const mcpu_arg = b.fmt("-mcpu={s}", .{cpu_name});
    const mfloat_arg = b.fmt("-mfloat-abi={s}", .{@tagName(target.result.abi.float())});

    // e.g. .../lib/gcc/arm-none-eabi/<ver>/thumb/v8-m.main+fp/hard/libgcc.a
    const libgcc_path = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, mcpu_arg, mfloat_arg, "-print-libgcc-file-name" }), " \r\n");
    const gcc_include_path = std.mem.trim(u8, b.run(&.{ arm_gcc_exe, "-print-file-name=include" }), " \r\n");

    return .{
        .gcc = arm_gcc_exe,
        .mcpu_arg = mcpu_arg,
        .mfloat_arg = mfloat_arg,
        .gcc_include_path = gcc_include_path,
        .libgcc_path = libgcc_path,
    };
}

/// The C library of the kernel image: the no-OS build of libs/libc. The
/// calling package has to list `yaslibc` among its dependencies.
pub fn libc(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Dependency {
    return b.dependency("yaslibc", .{ .target = target, .optimize = optimize });
}

/// Build `module`'s C against libs/libc's headers and link it with libs/libc
/// and libgcc. The kernel supplies libc's porting hooks (_sbrk, _write,
/// __malloc_lock, ...); see libs/libc/noos/.
pub fn decorateModuleWithArmToolchain(b: *std.Build, module: anytype, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !void {
    const tc = try resolveArmToolchain(b, target);
    const yaslibc = libc(b, target, optimize);
    module.addSystemIncludePath(yaslibc.namedLazyPath("include"));
    module.linkLibrary(yaslibc.artifact("yaslibc"));
    module.addObjectFile(.{ .cwd_relative = tc.libgcc_path });
}
