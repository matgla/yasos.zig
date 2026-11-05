// Copyright (c) 2026 Mateusz Stadnik
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

// `/proc/faultstat` -- processes killed by a fault, and how many of them died
// holding a sleeping lock, which is the one case that can leave a filesystem half
// updated. Counters, because the postmortem cannot be relied on for this: the
// console drops output once the UART stalls, and a run of faults is what stalls it.

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

// Two labelled decimal values; 128 is well past the worst case.
const BufferSize = 128;
const FaultStatBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const FaultStatFile = interface.DeriveFromBase(FaultStatBufferedFile, struct {
    const Self = @This();
    base: FaultStatBufferedFile,

    pub fn create(allocator: std.mem.Allocator) FaultStatFile {
        return FaultStatFile.init(.{
            .base = FaultStatBufferedFile.InstanceType.create(allocator, "faultstat"),
        });
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create(allocator).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const buffer = interface.base(self).buffer() orelse return -1;
        const process_manager = kernel.process.process_manager;
        var written: usize = 0;
        var buf = vfmt.print(buffer, "fault_kills {d}\n", .{process_manager.fault_kills});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "fault_kills_holding_locks {d}\n", .{process_manager.fault_kills_holding_locks});
        written += buf.len;
        interface.base(self)._end = written;
        return 0;
    }

    pub fn delete(self: *Self) void {
        interface.base(self).delete();
    }
});

test "FaultStatFile.ShouldCreateNode" {
    var node = try FaultStatFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("faultstat", node.name());
}

test "FaultStatFile.ShouldReportBothCounters" {
    const process_manager = kernel.process.process_manager;
    const saved = .{ process_manager.fault_kills, process_manager.fault_kills_holding_locks };
    defer process_manager.fault_kills = saved[0];
    defer process_manager.fault_kills_holding_locks = saved[1];
    process_manager.fault_kills = 7;
    process_manager.fault_kills_holding_locks = 2;

    var sut = try FaultStatFile.InstanceType.create(std.testing.allocator).interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expect(readed > 0);
    const text = buffer[0..@intCast(readed)];
    try std.testing.expect(std.mem.indexOf(u8, text, "fault_kills 7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fault_kills_holding_locks 2\n") != null);
}
