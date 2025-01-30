//
// build.zig
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
const toolchain = @import("toolchains").arm_none_eabi_toolchain;

pub const targetOptions = std.Target.Query{
    .cpu_arch = .thumb,
    .os_tag = .other,
    .abi = .eabi,
    .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
    .cpu_features_add = std.Target.arm.featureSet(&[_]std.Target.arm.Feature{.soft_float}),
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(targetOptions);

    const exe = b.addExecutable(.{
        .name = "yasos_shell",
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("main.zig"),
        .pic = true,
    });
    // exe.link_emit_relocs = true;
    exe.linker_script = b.path("../../libs/ElfToYaff/arch/arm-m/executable.ld");
    exe.entry = .{
        .symbol_name = "main",
    };
    exe.bundle_compiler_rt = false;
    exe.want_lto = false;
    exe.pie = true;
    b.installArtifact(exe);
    exe.root_module.addIncludePath(b.path("../../libs/libc/include"));
    exe.addLibraryPath(b.path("../../libs/libc/build/"));
    exe.linkSystemLibrary("libc");
}
