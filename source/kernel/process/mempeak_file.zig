// Copyright (c) 2025 Mateusz Stadnik
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

// `/proc/mempeak` -- how much process memory a window of time needed. Reading
// the file clears it, so a caller can bracket a region with two `cat`s; the XIP
// counters have the same shape.
//
// `/proc/meminfo` reports what is allocated now, which is back to the resident
// baseline by the time a compile finishes, and the pool's own `peak_used` is
// reset at every exec, so it describes the last process a test spawned rather
// than the test. Used by the smoke suite to decide which tests are too
// memory-hungry to run in parallel -- see tests/smoke/heavy_tests.txt.

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

// Two labelled decimal values; 128 is well past the worst case.
const BufferSize = 128;
const MemPeakBufferedFile = kernel.fs.BufferedFile(BufferSize);

fn sample_peak_bytes() usize {
    if (!kernel.process.process_manager.is_initialized()) return 0;
    return kernel.process.process_manager.instance
        .get_process_memory_pool()
        .sample_and_clear_watermark();
}

fn used_bytes() usize {
    if (!kernel.process.process_manager.is_initialized()) return 0;
    return kernel.process.process_manager.instance.get_process_memory_pool().get_used_size();
}

pub const MemPeakFile = interface.DeriveFromBase(MemPeakBufferedFile, struct {
    const Self = @This();
    base: MemPeakBufferedFile,

    pub fn create() MemPeakFile {
        var file = MemPeakFile.init(.{
            .base = MemPeakBufferedFile.InstanceType.create("mempeak"),
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        // `used` first: sampling clears the mark down to current occupancy, so
        // reading it afterwards would describe a different instant.
        const used = used_bytes();
        const peak = sample_peak_bytes();

        const buffer = &interface.base(self)._buffer;
        var written: usize = 0;
        var buf = vfmt.print(buffer, "process_peak_bytes {d}\n", .{peak});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "process_used_bytes {d}\n", .{used});
        written += buf.len;
        interface.base(self)._end = written;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "MemPeakFile.ShouldCreateNode" {
    var node = try MemPeakFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("mempeak", node.name());
}

test "MemPeakFile.ShouldReportBothCounters" {
    var sut = try MemPeakFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expect(readed > 0);
    const text = buffer[0..@intCast(readed)];
    try std.testing.expect(std.mem.indexOf(u8, text, "process_peak_bytes ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "process_used_bytes ") != null);
}
