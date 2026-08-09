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

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

/// Console receive-path loss counters, so a serial transfer that comes out
/// corrupted can say *where* the bytes went instead of leaving it to be
/// inferred: `overruns` means the hardware FIFO overflowed while the receive
/// interrupt was masked, `dropped` means the software ring overflowed because
/// nothing read it fast enough, and neither being set means the bytes never
/// reached this machine at all.
pub const Stats = struct {
    bytes: u32 = 0,
    overruns: u32 = 0,
    dropped: u32 = 0,
    fifo_full: u32 = 0,
    framing_errors: u32 = 0,
    max_overrun_gap_us: u32 = 0,
    max_late_gap_us: u32 = 0,
};

/// Set by whoever owns the console UART. Kept as a function pointer rather than
/// a direct HAL call so this file builds -- and is testable -- on the host,
/// where there is no UART; unset simply reports zeros.
var provider: ?*const fn () Stats = null;

pub fn set_provider(source: *const fn () Stats) void {
    provider = source;
}

pub fn clear_provider() void {
    provider = null;
}

// Seven counters, each up to ten digits with its label: 256 clears the worst
// case with room for another field.
const BufferSize = 256;
const UartStatBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const UartStatFile = interface.DeriveFromBase(UartStatBufferedFile, struct {
    const Self = @This();
    base: UartStatBufferedFile,

    pub fn create() UartStatFile {
        var file = UartStatFile.init(.{
            .base = UartStatBufferedFile.InstanceType.create("uart"),
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const stats = if (provider) |source| source() else Stats{};
        const buffer = &interface.base(self)._buffer;
        const buf = vfmt.print(
            buffer,
            "rx_bytes {d}\nrx_overruns {d}\nrx_dropped {d}\nrx_fifo_full {d}\n" ++
                "rx_framing_errors {d}\nmax_overrun_gap_us {d}\nmax_late_gap_us {d}\n",
            .{
                stats.bytes,        stats.overruns,
                stats.dropped,      stats.fifo_full,
                stats.framing_errors, stats.max_overrun_gap_us,
                stats.max_late_gap_us,
            },
        );
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "UartStatFile.ShouldCreateNode" {
    clear_provider();
    var node = try UartStatFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("uart", node.name());
}

test "UartStatFile.ShouldReportZerosWithoutAProvider" {
    clear_provider();
    var sut = try UartStatFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "rx_bytes 0\nrx_overruns 0\nrx_dropped 0\nrx_fifo_full 0\n" ++
            "rx_framing_errors 0\nmax_overrun_gap_us 0\nmax_late_gap_us 0\n",
        buffer[0..@intCast(readed)],
    );
}

test "UartStatFile.ShouldReportTheProvidersCounters" {
    const Source = struct {
        fn get() Stats {
            return .{
                .bytes = 4096,
                .overruns = 7,
                .dropped = 3,
                .fifo_full = 11,
                .framing_errors = 2,
                .max_overrun_gap_us = 812,
                .max_late_gap_us = 940,
            };
        }
    };
    set_provider(&Source.get);
    defer clear_provider();

    var sut = try UartStatFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "rx_bytes 4096\nrx_overruns 7\nrx_dropped 3\nrx_fifo_full 11\n" ++
            "rx_framing_errors 2\nmax_overrun_gap_us 812\nmax_late_gap_us 940\n",
        buffer[0..@intCast(readed)],
    );
}
