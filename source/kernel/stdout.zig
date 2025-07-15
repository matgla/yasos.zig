//
// kernel_log.zig
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

const board = @import("board");

var stdout: std.io.AnyWriter = undefined;

pub const WriteCallback = *const fn (self: *const anyopaque, data: []const u8) anyerror!usize;

pub fn set_output(context: *const anyopaque, writer: WriteCallback) void {
    stdout = std.io.AnyWriter{
        .context = context,
        .writeFn = writer,
    };
}

pub fn get() *std.io.AnyWriter {
    return &stdout;
}

pub fn print(comptime format: []const u8, args: anytype) void {
    stdout.print(format, args) catch return;
}

pub fn write(comptime data: []const u8) void {
    _ = stdout.write(data) catch return;
}
