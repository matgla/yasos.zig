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
const kernel_sync = @import("../sync/sync.zig");

/// One read of a machine's XIP cache counters, covering the window since the
/// previous read. `hit` counts accesses served from cached data, `acc` counts
/// every access whether it hit or not; `saturated` says the hardware counter
/// pinned at its maximum during this window, so the numbers are a floor rather
/// than a count.
pub const Sample = struct {
    hit: u32 = 0,
    acc: u32 = 0,
    saturated: bool = false,
};

/// Totals since boot, which is what `/proc/xip` serves. `saturated` counts the
/// samples that arrived pinned — any non-zero value means `hit`/`acc` undercount
/// by an unknown amount and the run should not be compared against another.
pub const Stats = struct {
    hit: u64 = 0,
    acc: u64 = 0,
    saturated: u32 = 0,
};

/// Set by whoever owns the XIP controller. Kept as a function pointer rather
/// than a direct HAL call so this file builds -- and is testable -- on the host
/// and on targets that have no such cache; unset simply reports zeros and costs
/// the tick a null check.
var sampler: ?*const fn () Sample = null;

var total_hit: u64 = 0;
var total_acc: u64 = 0;
var saturated_samples: u32 = 0;

/// Bumped to odd before a total is touched and back to even after, so a reader
/// in thread mode can tell it caught the tick mid-update. Without it, reading a
/// 64-bit total on a 32-bit core can splice the low word of one value onto the
/// high word of another.
///
/// Atomic with `seq_cst` rather than a plain `+%=` on a `volatile`, which stops
/// the compiler reordering and says nothing to a second core. The protocol stays
/// hand-rolled rather than using `sync/seqlock.zig`, because the totals are
/// three fields read together and `Seq64` does not model that.
var sequence: kernel_sync.Atomic(u32) = .init(0);

/// Eight is far past what could ever be needed: losing a race costs one retry
/// of a read that takes well under a microsecond, against a sampler that runs
/// once a millisecond.
const max_read_attempts = 8;

pub fn set_sampler(source: *const fn () Sample) void {
    sampler = source;
}

pub fn clear_sampler() void {
    sampler = null;
}

/// Drain the hardware counters into the running totals.
///
/// Has to be called often enough that a counter cannot saturate between calls
/// -- the RP2350's are 32-bit and stick rather than wrap, so one missed window
/// silently truncates the total instead of announcing itself. The system tick
/// is the caller, at 1 kHz against a saturation floor of seconds.
pub fn accumulate() void {
    const read = sampler orelse return;
    const sample = read();

    const hit: *volatile u64 = &total_hit;
    const acc: *volatile u64 = &total_acc;
    const saturated: *volatile u32 = &saturated_samples;

    const start = sequence.load(.monotonic);
    sequence.store(start +% 1, .seq_cst);
    hit.* +%= sample.hit;
    acc.* +%= sample.acc;
    if (sample.saturated) {
        saturated.* +%= 1;
    }
    sequence.store(start +% 2, .seq_cst);
}

pub fn read_stats() Stats {
    const hit: *const volatile u64 = &total_hit;
    const acc: *const volatile u64 = &total_acc;
    const saturated: *const volatile u32 = &saturated_samples;

    var stats = Stats{};
    var attempt: u8 = 0;
    while (attempt < max_read_attempts) : (attempt += 1) {
        const before = sequence.load(.seq_cst);
        if (before & 1 != 0) continue;
        stats = .{ .hit = hit.*, .acc = acc.*, .saturated = saturated.* };
        if (sequence.load(.seq_cst) == before) break;
    }
    // Falling out of the loop hands back the last attempt rather than zeros:
    // a total that may be spliced is still recognisably a total, while zeros
    // would read as "this machine has no XIP traffic".
    return stats;
}

pub fn reset() void {
    total_hit = 0;
    total_acc = 0;
    saturated_samples = 0;
    sequence.store(0, .seq_cst);
}

// Two 20-digit totals and one 10-digit count with their labels come to 83
// bytes; 128 leaves room for another field.
const BufferSize = 128;
const XipStatBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const XipStatFile = interface.DeriveFromBase(XipStatBufferedFile, struct {
    const Self = @This();
    base: XipStatBufferedFile,

    pub fn create() XipStatFile {
        var file = XipStatFile.init(.{
            .base = XipStatBufferedFile.InstanceType.create("xip"),
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const stats = read_stats();
        const buffer = &interface.base(self)._buffer;
        const buf = vfmt.print(
            buffer,
            "xip_hit {d}\nxip_acc {d}\nxip_saturated {d}\n",
            .{ stats.hit, stats.acc, stats.saturated },
        );
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "XipStatFile.ShouldCreateNode" {
    clear_sampler();
    reset();
    var node = try XipStatFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("xip", node.name());
}

test "XipStatFile.ShouldReportZerosWithoutASampler" {
    clear_sampler();
    reset();

    accumulate();

    var sut = try XipStatFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "xip_hit 0\nxip_acc 0\nxip_saturated 0\n",
        buffer[0..@intCast(readed)],
    );
}

test "XipStatFile.ShouldSumTheSamplersWindows" {
    const Source = struct {
        fn get() Sample {
            return .{ .hit = 700, .acc = 1000 };
        }
    };
    set_sampler(&Source.get);
    defer clear_sampler();
    reset();

    for (0..3) |_| accumulate();

    const stats = read_stats();
    try std.testing.expectEqual(@as(u64, 2100), stats.hit);
    try std.testing.expectEqual(@as(u64, 3000), stats.acc);
    try std.testing.expectEqual(@as(u32, 0), stats.saturated);
}

test "XipStatFile.ShouldCarryTotalsPastThirtyTwoBits" {
    const Source = struct {
        fn get() Sample {
            return .{ .hit = 0x8000_0000, .acc = 0xc000_0000 };
        }
    };
    set_sampler(&Source.get);
    defer clear_sampler();
    reset();

    accumulate();
    accumulate();

    const stats = read_stats();
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), stats.hit);
    try std.testing.expectEqual(@as(u64, 0x1_8000_0000), stats.acc);
}

test "XipStatFile.ShouldCountSaturatedWindowsSeparately" {
    const Source = struct {
        fn get() Sample {
            return .{ .hit = 10, .acc = 0xffff_ffff, .saturated = true };
        }
    };
    set_sampler(&Source.get);
    defer clear_sampler();
    reset();

    accumulate();
    accumulate();

    const stats = read_stats();
    try std.testing.expectEqual(@as(u32, 2), stats.saturated);
}

test "XipStatFile.ShouldReportTheAccumulatedTotals" {
    const Source = struct {
        fn get() Sample {
            return .{ .hit = 1234, .acc = 5678, .saturated = true };
        }
    };
    set_sampler(&Source.get);
    defer clear_sampler();
    reset();

    accumulate();

    var sut = try XipStatFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "xip_hit 1234\nxip_acc 5678\nxip_saturated 1\n",
        buffer[0..@intCast(readed)],
    );
}
