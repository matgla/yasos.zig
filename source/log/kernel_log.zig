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

const KernelLog = struct {
    pub fn print(self: KernelLog, comptime str: []const u8, comptime args: anytype) void {
        // Writing to kernel log is not critical and if not working
        // there is no alternative implemented
        _ = self.writer.print(str, args) catch {};
    }

    pub fn write(self: KernelLog, comptime str: []const u8) void {
        _ = self.writer.write(str) catch {};
    }

    writer: @TypeOf(board.uart.uart0).Writer,
};

pub var kernel_log = KernelLog{
    .writer = board.uart.uart0.writer(),
};
