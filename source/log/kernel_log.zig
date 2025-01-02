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

const FatPointer = struct {
    pub const WriteCallback = *const fn (self: *const anyopaque, data: []const u8) usize;
    state: *const anyopaque,
    method: WriteCallback,
};

const KernelLog = struct {
    writeFn: ?FatPointer,

    const Writer = std.io.Writer(KernelLog, WriteError, write_some);

    pub fn writer(self: KernelLog) Writer {
        return Writer{
            .context = self,
        };
    }
    pub fn attach_to(self: *KernelLog, writeFn: FatPointer) void {
        self.writeFn = writeFn;
    }

    fn write_some(self: KernelLog, buffer: []const u8) WriteError!usize {
        if (self.writeFn) |writeFn| {
            return writeFn.method(writeFn.state, buffer);
        }
        return 0;
    }
};

const Logger = struct {
    log: KernelLog,
    writer: ?KernelLog.Writer,

    pub fn print(self: *const Logger, comptime str: []const u8, comptime args: anytype) void {
        // Writing to kernel log is not critical and if not working
        // there is no alternative implemented
        if (self.writer) |writer| {
            _ = writer.print(str, args) catch {};
        }
    }

    pub fn write(self: *const Logger, comptime str: []const u8) void {
        if (self.writer) |writer| {
            _ = writer.write(str) catch {};
        }
    }

    pub fn attach_to(self: *Logger, write_fn: FatPointer) void {
        self.log.attach_to(write_fn);
        self.writer = self.log.writer();
        // context in GenericWrite is lifetime of pointer for write callback
        // for me it should be KernelLog + write_some function
        // self.writer = Writer{ .context = writeFn };
    }
};

pub const kernel_log = Logger{
    .log = KernelLog{
        .writeFn = null,
    },
    .writer = null,
};

pub const WriteError = error{
    WriteFailure,
};
