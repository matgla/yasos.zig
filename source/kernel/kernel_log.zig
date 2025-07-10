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
const stdout = @import("stdout.zig");

fn log_level_as_text(comptime level: std.log.Level) []const u8 {
    switch (level) {
        std.log.Level.info => return "INF",
        std.log.Level.debug => return "DBG",
        std.log.Level.err => return "ERR",
        std.log.Level.warn => return "WRN",
    }
    return "UNK";
}

pub fn kernel_stdout_log(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = switch (scope) {
        std.log.default_log_scope => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            @tagName(scope),
    } ++ ": ";
    const prefix = comptime log_level_as_text(level) ++ "/" ++ scope_prefix;
    stdout.get().print(prefix ++ format ++ "\n", args) catch return;
}

pub const log = std.log.scoped(.kernel);
