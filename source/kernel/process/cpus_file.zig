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

// `/proc/cpus` -- what the cores are doing, and whether the locks between them
// work. "Did core 1 start" is a flag; "is core 1 still running" is not, since a
// core that wedged still reads back online forever, so each core also publishes
// its tick count and two reads a moment apart answer it. The self-test lines
// report the failure that is silent everywhere else: a second core whose
// exclusives do not exclude. See `source/kernel/smp.zig`.

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");
const smp = @import("../smp.zig");

// Ten fixed lines of at most ~40 bytes, plus six lines per core of at most ~28.
// Sized from core_count so a board with more cores cannot truncate its own tail
// -- the smoke test parses by key, so a truncated tail reads as a missing core.
const BufferSize = 512 + 192 * smp.core_count;
const CpusBufferedFile = kernel.fs.BufferedFile(BufferSize);

fn verdict_name(verdict: smp.Verdict) []const u8 {
    return switch (verdict) {
        .skipped => "skipped",
        .pass => "pass",
        .fail => "fail",
    };
}

pub const CpusFile = interface.DeriveFromBase(CpusBufferedFile, struct {
    const Self = @This();
    base: CpusBufferedFile,

    pub fn create() CpusFile {
        var file = CpusFile.init(.{
            .base = CpusBufferedFile.InstanceType.create("cpus"),
        });
        _ = file.data().sync();
        return file;
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create().interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const report = smp.selftest_report();
        const buffer = &interface.base(self)._buffer;
        var written: usize = 0;

        var buf = vfmt.print(buffer, "smp {d}\n", .{@intFromBool(smp.enabled)});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "cpus {d}\n", .{smp.core_count});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "online {d}\n", .{smp.online_count()});
        written += buf.len;
        // Whether an idle core is woken by an interrupt or waits for its next
        // tick -- two very different latencies, and only the rp2350 has SIO
        // doorbells, so a latency figure has to say which path produced it.
        buf = vfmt.print(buffer[written..], "doorbell {d}\n", .{@intFromBool(smp.has_doorbell())});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "selftest {s}\n", .{verdict_name(report.verdict)});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "selftest_atomic_expected {d}\n", .{report.atomic_expected});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "selftest_atomic_counted {d}\n", .{report.atomic_counted});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "selftest_sections {d}\n", .{report.sections});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "selftest_guarded {d}\n", .{report.guarded});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "selftest_overlaps {d}\n", .{report.overlaps});
        written += buf.len;
        buf = vfmt.print(buffer[written..], "selftest_us {d}\n", .{report.duration_us});
        written += buf.len;

        for (0..smp.core_count) |core| {
            buf = vfmt.print(buffer[written..], "cpu{d}_online {d}\n", .{ core, @intFromBool(smp.is_online(core)) });
            written += buf.len;
            buf = vfmt.print(buffer[written..], "cpu{d}_ticks {d}\n", .{ core, smp.ticks_of(core) });
            written += buf.len;
            // A tick count only says the core takes interrupts, which is true of
            // a core parked in WFI. A switch count says it is running the
            // scheduler, and the pid says what it is running right now.
            buf = vfmt.print(buffer[written..], "cpu{d}_scheduling {d}\n", .{ core, @intFromBool(smp.core_schedules(core)) });
            written += buf.len;
            buf = vfmt.print(buffer[written..], "cpu{d}_switches {d}\n", .{ core, smp.switches_of(core) });
            written += buf.len;
            buf = vfmt.print(buffer[written..], "cpu{d}_pid {d}\n", .{ core, kernel.process.process_manager.pid_on_core(core) });
            written += buf.len;
            // So a reader can tell "core 1 is running something" from "core 1 is
            // parked": the idle process is a real process with a real pid, and
            // `cpu1_pid == cpu1_idle_pid` means the core has nothing to do.
            buf = vfmt.print(buffer[written..], "cpu{d}_idle_pid {d}\n", .{ core, kernel.process.process_manager.idle_pid_on_core(core) });
            written += buf.len;
        }

        interface.base(self)._end = written;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});

test "CpusFile.ShouldCreateNode" {
    var node = try CpusFile.InstanceType.create_node(std.testing.allocator);
    defer node.delete();

    try std.testing.expect(node.is_file());
    try std.testing.expectEqualStrings("cpus", node.name());
}

test "CpusFile.ShouldReportOneLinePairPerCore" {
    var sut = try CpusFile.InstanceType.create().interface.new(std.testing.allocator);
    defer sut.interface.delete();

    try std.testing.expectEqual(@as(i32, 0), sut.interface.sync());

    var buffer: [BufferSize]u8 = undefined;
    const readed = sut.interface.read(&buffer);
    try std.testing.expect(readed > 0);
    const text = buffer[0..@intCast(readed)];

    // The header is what the smoke test parses; a core that is missing its own
    // pair of lines is the failure this catches.
    try std.testing.expect(std.mem.indexOf(u8, text, "cpus ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cpu0_online ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cpu0_ticks ") != null);
    if (smp.core_count > 1) {
        try std.testing.expect(std.mem.indexOf(u8, text, "cpu1_online ") != null);
    }
}
