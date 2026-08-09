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
const file_log = @import("file_log.zig");
const vfmt = @import("vfmt.zig");

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
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime log_level_as_text(level) ++ "][" ++ @tagName(scope) ++ "] ";
    const line_format = prefix ++ format ++ "\n";

    // The serial console is a per-byte BLOCKING UART (see the driver's
    // console_baudrate). Mirroring
    // the voluminous info/debug diagnostics (notably the per-process loader
    // load lines) to it stalls the CPU on every spawn and floods the test
    // harness's serial stream. So route info/debug only to the file log; keep
    // warnings and errors on serial so crash markers stay live for crash
    // detection. Everything is captured in the file log when it is enabled.
    const to_serial = @intFromEnum(level) <= @intFromEnum(std.log.Level.warn);
    const to_file = file_log.is_enabled();

    // Fast path: an info/debug line with no file sink has nowhere to go — drop
    // it before paying the formatting cost.
    if (!to_serial and !to_file) return;

    const argv = vfmt.erase(args);
    log_line(line_format, &argv, to_serial, to_file);
}

noinline fn emit(line: []const u8, to_serial: bool, to_file: bool) void {
    if (to_file) file_log.append(line);
    if (to_serial) stdout.write_bytes(line);
}

noinline fn log_line(fmt: []const u8, argv: []const vfmt.Value, to_serial: bool, to_file: bool) void {
    var buf: [512]u8 = undefined;
    emit(vfmt.vprint(&buf, fmt, argv), to_serial, to_file);
}


pub const log = std.log.scoped(.kernel);
