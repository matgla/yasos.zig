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
const kernel_sync = @import("../sync/sync.zig");

/// One conversion of the on-chip temperature sensor as the raw 12-bit ADC code,
/// or null when the conversion failed. Set by whoever owns the ADC; unset
/// reports zeros, which is every board but the RP2350.
var provider: ?*const fn () ?u16 = null;

/// ADC full scale. The RP2350's ADC is referenced to ADC_AVDD, which both boards
/// tie to the 3.3 V rail. A board with another reference reads proportionally
/// wrong, which is why the value is printed next to the result.
pub const reference_mv: u32 = 3300;

/// Conversions averaged per read: 2 us each, so 32 us with the lock held.
const samples_per_read = 16;

/// A conversion is select, start, poll, read; two readers interleaving those on
/// two cores would each take the other's result.
var adc_lock: kernel_sync.SpinLock = .{};

pub const Reading = struct {
    raw_sum: u32 = 0,
    samples: u32 = 0,
    errors: u32 = 0,
};

pub fn set_provider(source: *const fn () ?u16) void {
    provider = source;
}

pub fn clear_provider() void {
    provider = null;
}

pub fn read() Reading {
    const convert = provider orelse return .{};
    var reading = Reading{};
    const flags = adc_lock.lock_irqsave();
    defer adc_lock.unlock_irqrestore(flags);
    for (0..samples_per_read) |_| {
        if (convert()) |raw| {
            reading.raw_sum += raw;
            reading.samples += 1;
        } else {
            reading.errors += 1;
        }
    }
    return reading;
}

/// Sensor voltage in microvolts for the mean of `samples` conversions summing
/// to `raw_sum`.
pub fn microvolts(raw_sum: u32, samples: u32) i64 {
    if (samples == 0) return 0;
    return @divTrunc(@as(i64, raw_sum) * reference_mv * 1000, @as(i64, samples) * 4096);
}

/// RP2350 datasheet: T = 27 - (V - 0.706) / 0.001721, in degrees C for V in
/// volts. The sensor is uncalibrated and the datasheet gives the slope and
/// offset only as typical values, so treat the absolute figure as good to a
/// few degrees and the trend as the useful part.
pub fn millicelsius(uv: i64) i32 {
    return @intCast(27_000 - @divTrunc((uv - 706_000) * 1000, 1721));
}

// Six labelled fields: 192 clears the worst case.
const BufferSize = 192;
const TempBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const TempFile = interface.DeriveFromBase(TempBufferedFile, struct {
    const Self = @This();
    base: TempBufferedFile,

    pub fn create() TempFile {
        var file = TempFile.init(.{
            .base = TempBufferedFile.InstanceType.create("temp"),
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const reading = read();
        const uv = microvolts(reading.raw_sum, reading.samples);
        const mc: i32 = if (reading.samples == 0) 0 else millicelsius(uv);
        const mean_raw: u32 = if (reading.samples == 0) 0 else reading.raw_sum / reading.samples;
        const buffer = &interface.base(self)._buffer;
        const buf = vfmt.print(
            buffer,
            "temp_mc {d}\ntemp_mv {d}\ntemp_raw {d}\ntemp_samples {d}\ntemp_errors {d}\ntemp_reference_mv {d}\n",
            .{ mc, @divTrunc(uv, 1000), mean_raw, reading.samples, reading.errors, reference_mv },
        );
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "TempFile.ShouldCreateNode" {
    clear_provider();
    var node = try TempFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("temp", node.name());
}

test "TempFile.ShouldReportZerosWithoutAProvider" {
    clear_provider();

    var sut = try TempFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "temp_mc 0\ntemp_mv 0\ntemp_raw 0\ntemp_samples 0\ntemp_errors 0\ntemp_reference_mv 3300\n",
        buffer[0..@intCast(readed)],
    );
}

test "TempFile.ShouldPutTheDatasheetPointAtTwentySevenDegrees" {
    // 0.706 V is 876.3 codes at 3.3 V full scale; the truncation to 876 is the
    // 0.14 degrees above 27.
    try std.testing.expectEqual(@as(i32, 27_138), millicelsius(microvolts(876, 1)));
    // Averaging must not move the result.
    try std.testing.expectEqual(@as(i32, 27_138), millicelsius(microvolts(876 * 16, 16)));
    // Warmer is a lower voltage.
    try std.testing.expectEqual(@as(i32, 53_354), millicelsius(microvolts(820, 1)));
}

test "TempFile.ShouldReportTheMeanOfTheProvidersConversions" {
    const Source = struct {
        fn get() ?u16 {
            return 876;
        }
    };
    set_provider(&Source.get);
    defer clear_provider();

    var sut = try TempFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expectEqualStrings(
        "temp_mc 27138\ntemp_mv 705\ntemp_raw 876\ntemp_samples 16\ntemp_errors 0\ntemp_reference_mv 3300\n",
        buffer[0..@intCast(readed)],
    );
}

test "TempFile.ShouldCountFailedConversionsInsteadOfAveragingThem" {
    const Source = struct {
        fn get() ?u16 {
            return null;
        }
    };
    set_provider(&Source.get);
    defer clear_provider();

    const reading = read();
    try std.testing.expectEqual(@as(u32, 0), reading.samples);
    try std.testing.expectEqual(@as(u32, 16), reading.errors);
}
