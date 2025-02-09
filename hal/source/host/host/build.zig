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
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    _ = b.option([]const u8, "cmake", "path to CMake executable") orelse "";
    _ = b.option([]const u8, "gcc", "path to arm-none-eabi-gcc executable") orelse "";

    const hal = b.addModule("hal", .{
        .root_source_file = b.path("host.zig"),
        .target = target,
        .optimize = optimize,
    });
    const halInterface = b.dependency("hal_interface", .{});
    hal.addImport("hal_interface", halInterface.module("hal_interface"));
}
