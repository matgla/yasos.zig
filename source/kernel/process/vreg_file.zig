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

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.hardfault);

/// Whether the core regulator says it is in regulation, sampled once per
/// system tick. The RP2350's POWMAN drops VOUT_OK while the rail sits below
/// ~87% of its setpoint (84-90% across parts), so this sees only a deep sag --
/// at 1900 mV the trip point is about 1650 mV -- and only one still low at the
/// instant a tick looks. A zero count is weak evidence against droop; a
/// non-zero one is strong evidence for it.
///
/// Kept as a function pointer for the same reason as /proc/xip: the file builds
/// and tests on the host, and a board without the flag reports zeros.
var sampler: ?*const fn () bool = null;
var setpoint_mv: u16 = 0;

// One writer -- the timekeeper core's system tick -- so plain increments are
// enough. A reader can see the fields from two different ticks; every field is
// its own 32-bit word, so none of them tears.
var samples: u32 = 0;
var low_samples: u32 = 0;
var low_events: u32 = 0;
var low_run: u32 = 0;
var low_max_run: u32 = 0;
var last_low_tick: u32 = 0;

pub const Stats = struct {
    setpoint_mv: u16 = 0,
    samples: u32 = 0,
    /// Ticks that found the regulator out of regulation.
    low_samples: u32 = 0,
    /// Separate sags: runs of consecutive low samples.
    low_events: u32 = 0,
    /// The longest such run, in ticks (milliseconds).
    low_max_run: u32 = 0,
    /// System tick of the most recent low sample, to line a sag up against a
    /// test log or a fault.
    last_low_tick: u32 = 0,
};

/// Start sampling. `voltage_mv` is the setpoint the regulator was programmed
/// to, reported next to the counters so a reader can tell what "low" meant.
pub fn set_sampler(source: *const fn () bool, voltage_mv: u16) void {
    setpoint_mv = voltage_mv;
    sampler = source;
}

pub fn clear_sampler() void {
    sampler = null;
    setpoint_mv = 0;
}

/// The nominal VOUT_OK threshold for a setpoint. Nominal only: the part-to-part
/// spread is 84-90%.
pub fn trip_mv(voltage_mv: u16) u16 {
    return @intCast(@as(u32, voltage_mv) * 87 / 100);
}

pub fn accumulate(tick: u64) void {
    const read = sampler orelse return;
    const in_regulation = read();

    const count: *volatile u32 = &samples;
    const low: *volatile u32 = &low_samples;
    const events: *volatile u32 = &low_events;
    const run: *volatile u32 = &low_run;
    const max_run: *volatile u32 = &low_max_run;
    const last: *volatile u32 = &last_low_tick;

    count.* +%= 1;
    if (in_regulation) {
        run.* = 0;
        return;
    }
    if (run.* == 0) {
        events.* +%= 1;
    }
    run.* +%= 1;
    low.* +%= 1;
    if (run.* > max_run.*) {
        max_run.* = run.*;
    }
    last.* = @truncate(tick);
}

pub fn read_stats() Stats {
    const count: *const volatile u32 = &samples;
    const low: *const volatile u32 = &low_samples;
    const events: *const volatile u32 = &low_events;
    const max_run: *const volatile u32 = &low_max_run;
    const last: *const volatile u32 = &last_low_tick;
    return .{
        .setpoint_mv = setpoint_mv,
        .samples = count.*,
        .low_samples = low.*,
        .low_events = events.*,
        .low_max_run = max_run.*,
        .last_low_tick = last.*,
    };
}

pub fn reset() void {
    samples = 0;
    low_samples = 0;
    low_events = 0;
    low_run = 0;
    low_max_run = 0;
    last_low_tick = 0;
}

/// Called from the HardFault handler: a fault that takes the board down still
/// says whether the regulator dropped out before it, and whether it is out now.
export fn dump_vreg_status() void {
    const read = sampler orelse return;
    const stats = read_stats();
    log.err("  VREG: setpoint={d}mV in_regulation_now={d} low_samples={d} low_events={d} low_max_run={d}ms last_low_at={d}ms samples={d}", .{
        stats.setpoint_mv,
        @intFromBool(read()),
        stats.low_samples,
        stats.low_events,
        stats.low_max_run,
        stats.last_low_tick,
        stats.samples,
    });
}

// Eight labelled fields, the widest a ten-digit count: 320 leaves room.
const BufferSize = 320;
const VregBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const VregFile = interface.DeriveFromBase(VregBufferedFile, struct {
    const Self = @This();
    base: VregBufferedFile,

    pub fn create() VregFile {
        var file = VregFile.init(.{
            .base = VregBufferedFile.InstanceType.create("vreg"),
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
        const now_ok: u1 = if (sampler) |read| @intFromBool(read()) else 0;
        const buffer = &interface.base(self)._buffer;
        const buf = vfmt.print(
            buffer,
            "vreg_setpoint_mv {d}\nvreg_trip_nominal_mv {d}\nvreg_in_regulation {d}\n" ++
                "vreg_samples {d}\nvreg_low_samples {d}\nvreg_low_events {d}\n" ++
                "vreg_low_max_run_ms {d}\nvreg_last_low_ms {d}\n",
            .{
                stats.setpoint_mv,
                trip_mv(stats.setpoint_mv),
                now_ok,
                stats.samples,
                stats.low_samples,
                stats.low_events,
                stats.low_max_run,
                stats.last_low_tick,
            },
        );
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "VregFile.ShouldCreateNode" {
    clear_sampler();
    reset();
    var node = try VregFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("vreg", node.name());
}

test "VregFile.ShouldReportZerosWithoutASampler" {
    clear_sampler();
    reset();

    accumulate(5);

    var sut = try VregFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "vreg_setpoint_mv 0\nvreg_trip_nominal_mv 0\nvreg_in_regulation 0\n" ++
            "vreg_samples 0\nvreg_low_samples 0\nvreg_low_events 0\n" ++
            "vreg_low_max_run_ms 0\nvreg_last_low_ms 0\n",
        buffer[0..@intCast(readed)],
    );
}

test "VregFile.ShouldCountEachSagOnceAndItsLongestRun" {
    const Source = struct {
        const pattern = [_]bool{ true, false, false, true, false, true };
        var index: usize = 0;
        fn get() bool {
            const value = pattern[index];
            index += 1;
            return value;
        }
    };
    set_sampler(&Source.get, 1900);
    defer clear_sampler();
    reset();

    for (0..Source.pattern.len) |tick| accumulate(100 + tick);

    const stats = read_stats();
    try std.testing.expectEqual(@as(u32, 6), stats.samples);
    try std.testing.expectEqual(@as(u32, 3), stats.low_samples);
    try std.testing.expectEqual(@as(u32, 2), stats.low_events);
    try std.testing.expectEqual(@as(u32, 2), stats.low_max_run);
    try std.testing.expectEqual(@as(u32, 104), stats.last_low_tick);
}

test "VregFile.ShouldPutTheNominalTripPointAtEightySevenPercent" {
    try std.testing.expectEqual(@as(u16, 1653), trip_mv(1900));
    try std.testing.expectEqual(@as(u16, 1740), trip_mv(2000));
}

test "VregFile.ShouldReportTheCounters" {
    const Source = struct {
        fn get() bool {
            return false;
        }
    };
    set_sampler(&Source.get, 2000);
    defer clear_sampler();
    reset();

    accumulate(7);
    accumulate(8);

    var sut = try VregFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "vreg_setpoint_mv 2000\nvreg_trip_nominal_mv 1740\nvreg_in_regulation 0\n" ++
            "vreg_samples 2\nvreg_low_samples 2\nvreg_low_events 1\n" ++
            "vreg_low_max_run_ms 2\nvreg_last_low_ms 8\n",
        buffer[0..@intCast(readed)],
    );
}
