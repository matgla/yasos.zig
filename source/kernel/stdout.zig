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
const vfmt = @import("vfmt.zig");

const board = @import("board");

var stdout: std.Io.Writer = undefined;
var write_callback: ?WriteCallback = null;
var write_context: ?*const anyopaque = null;
var suppressed: bool = false;

// Optional secondary sink (e.g. SD-card file log). It mirrors everything
// written to the primary console. Errors from the secondary are swallowed so a
// failing log file can never break console output.
var secondary_callback: ?WriteCallback = null;
var secondary_context: ?*const anyopaque = null;

pub const WriteCallback = *const fn (self: *const anyopaque, data: []const u8) anyerror!usize;

fn drain_sink(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = splat;
    _ = io_w;
    if (suppressed) return data[0].len;
    if (write_context == null) return error.WriteFailed;
    if (write_callback) |callback| {
        const written = callback(write_context.?, data[0]) catch return error.WriteFailed;
        if (secondary_callback) |secondary| {
            _ = secondary(secondary_context orelse undefined, data[0][0..written]) catch {};
        }
        return written;
    }
    return error.WriteFailed;
}

pub fn set_output(context: *const anyopaque, writer: WriteCallback) void {
    write_callback = writer;
    write_context = context;
    stdout = std.Io.Writer{
        .vtable = &.{
            .drain = drain_sink,
        },
        .buffer = &.{},
    };
}

pub fn set_secondary_output(context: *const anyopaque, writer: WriteCallback) void {
    secondary_context = context;
    secondary_callback = writer;
}

pub fn clear_secondary_output() void {
    secondary_callback = null;
    secondary_context = null;
}

pub fn get() *std.Io.Writer {
    return &stdout;
}

pub fn print(comptime format: []const u8, args: anytype) void {
    const argv = vfmt.erase(args);
    print_formatted(format, &argv);
}

noinline fn print_formatted(format: []const u8, argv: []const vfmt.Value) void {
    var buf: [256]u8 = undefined;
    _ = stdout.write(vfmt.vprint(&buf, format, argv)) catch return;
}

pub fn write(comptime data: []const u8) void {
    _ = stdout.write(data) catch return;
}

// Like `write` but for runtime byte slices (e.g. a pre-formatted log line).
pub fn write_bytes(data: []const u8) void {
    _ = stdout.write(data) catch return;
}

pub fn suppress(value: bool) void {
    suppressed = value;
}

// Fault-path escape hatch (extern-callable from arch code): a HardFault dump
// must never be swallowed by an active klog_ctl(0) suppression — the
// suppressing process (e.g. `rz` during a zmodem transfer) may be the very
// process that faulted, and it will never run klog_ctl(1) again.
export fn klog_force_enable() void {
    suppressed = false;
}
