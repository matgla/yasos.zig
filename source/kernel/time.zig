//
// time.zig
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

const systick = @import("interrupts/systick.zig");
const process_manager = @import("process_manager.zig");

const hal = @import("hal");
const c = @import("libc_imports").c;

const kernel = @import("kernel.zig");
const log = kernel.log;

/// Wall-clock time, kept as an offset from the monotonic boot clock.
///
/// None of these boards has a battery-backed RTC, so there is nothing to read
/// the date out of at reset: `hal.time.get_time_us()` counts microseconds since
/// this boot and knows nothing about the epoch. The wall clock is therefore
/// that counter plus an offset somebody supplied -- `settimeofday(2)`, which in
/// practice means the smoke harness at session setup, or `date -s` typed at the
/// shell.
///
/// Until someone does, the offset is `default_epoch_us` -- the build time of
/// this image -- so the clock reads "as of the build, plus the uptime". That is
/// a wrong *instant*, but it is not a wrong *ordering*: it still moves forward
/// at one second per second, so a file written after another file has a larger
/// timestamp, which is the only property `make` needs. Setting the clock
/// sharpens the instant without changing that.
///
/// A seqlock rather than an atomic: this is 64 bits on a 32-bit core, so a
/// plain two-word read can tear across a `settimeofday` on the other core and
/// hand back an instant that never existed. `Seq64`'s writer is wait-free, so a
/// reader in an interrupt handler cannot be held up by one.
var realtime_offset_us: kernel.sync.Seq64 = .init(default_epoch_us);

/// Where the clock starts: the build time of the image this kernel embeds, from
/// `rootfs.img`'s mtime at build time (see `rootfs_build_epoch` in build.zig).
///
/// Not 1970, because the mount points are created during boot and a filesystem
/// that stores an absolute instant -- ramfs does, so that `touch -d` means what
/// it says -- would carry that date for the rest of the boot no matter what the
/// clock was set to afterwards. `/tmp` and `/root` are the visible cases. The
/// build time is a real instant, orders correctly before everything written
/// since, and is the closest thing to a date this system knows without being
/// told one.
///
/// Zero when the build had no image to read, which puts it back at 1970.
const default_epoch_us: u64 = blk: {
    const seconds = @import("build_info").default_epoch_seconds;
    break :blk if (seconds > 0) @as(u64, @intCast(seconds)) * 1_000_000 else 0;
};

/// Whether `settimeofday` has ever run. Only advisory -- `realtime_us` answers
/// either way -- but it lets a caller tell "1970 because nobody said" from
/// "1970 because that is genuinely the date".
var realtime_was_set: kernel.sync.Atomic(bool) = .init(false);

/// Microseconds since the Unix epoch, as far as this board knows.
pub fn realtime_us() u64 {
    // Wrapping: `settimeofday` stores `wanted - uptime`, which is a very large
    // u64 when the clock is set backwards past the uptime. Adding the uptime
    // back wraps it to the value that was asked for.
    return hal.time.get_time_us() +% realtime_offset_us.load();
}

/// Seconds since the Unix epoch.
pub fn realtime_seconds() u64 {
    return realtime_us() / 1_000_000;
}

/// Move the wall clock so that `now_us` is the current time. The monotonic
/// clock behind it is untouched, so nothing that measures a duration
/// (`sleep_for_us`, the scheduler, `apps/time`) sees a jump.
pub fn set_realtime_us(now_us: u64) void {
    realtime_offset_us.store(now_us -% hal.time.get_time_us());
    realtime_was_set.store(true, .monotonic);
}

/// Whether anything has set the wall clock this boot.
pub fn realtime_is_set() bool {
    return realtime_was_set.load(.monotonic);
}

/// Microseconds since this boot -- the monotonic clock, unshifted.
pub fn uptime_us() u64 {
    return hal.time.get_time_us();
}

/// What the wall clock *would have said* at `uptime`, given what it says now.
///
/// For anything that happened before `settimeofday` ran and has to be dated
/// afterwards. Something stamped at boot with the then-current wall clock keeps
/// its 1970 date forever, even once the board learns what year it is; recording
/// the uptime instead and re-dating it here moves it along with the clock, so
/// it stays a real date and stays correctly ordered against everything written
/// since. See `RomFs.mount_uptime_us`, which is what this is for.
pub fn realtime_of_uptime_us(uptime: u64) u64 {
    return uptime +% realtime_offset_us.load();
}

/// `realtime_of_uptime_us` as a `struct timespec`.
pub fn timespec_of_uptime_us(uptime: u64) c.struct_timespec {
    const stamp = realtime_of_uptime_us(uptime);
    return .{
        .tv_sec = @intCast(stamp / 1_000_000),
        .tv_nsec = @intCast((stamp % 1_000_000) * 1000),
    };
}

/// `realtime_us` as a `struct timespec`, which is what every filesystem
/// timestamp and every `stat` field wants.
pub fn now_timespec() c.struct_timespec {
    const now = realtime_us();
    return .{
        .tv_sec = @intCast(now / 1_000_000),
        .tv_nsec = @intCast((now % 1_000_000) * 1000),
    };
}

pub fn sleep_ms(ms: u32) void {
    const process = process_manager.instance.get_current_process();
    process.sleep_for_ms(ms);
}

pub fn sleep_us(us: u32) void {
    const process = process_manager.instance.get_current_process();
    process.sleep_for_us(us);
}

const std = @import("std");
const irq_systick = @import("interrupts/systick.zig").irq_systick;
const irq_handlers = @import("arch").irq_handlers;
const system_call = @import("interrupts/system_call.zig");

fn test_entry() void {}

test "Time.WallClockIsTheBootCounterPlusWhateverTheOffsetHolds" {
    // No RTC and nobody has said otherwise: with the offset zeroed the clock is
    // the boot counter, and every date on the system is 1970 plus the uptime.
    realtime_offset_us.store(0);
    realtime_was_set.store(false, .monotonic);
    hal.time.impl.set_time(5_000_000);

    try std.testing.expect(!realtime_is_set());
    try std.testing.expectEqual(@as(u64, 5_000_000), realtime_us());
    try std.testing.expectEqual(@as(u64, 5), realtime_seconds());
}

test "Time.DefaultOffsetIsTheImageBuildTimeRatherThanTheEpoch" {
    // What the offset actually starts at, which is what keeps `/tmp` and
    // `/root` -- mounted during boot, before anything can set the clock -- from
    // carrying a 1970 date for the rest of the boot.
    const configured = @import("build_info").default_epoch_seconds;
    if (configured <= 0) {
        // A tree with no rootfs.img yet. Nothing to assert beyond the fallback.
        try std.testing.expectEqual(@as(u64, 0), default_epoch_us);
        return;
    }
    try std.testing.expectEqual(@as(u64, @intCast(configured)) * 1_000_000, default_epoch_us);

    // And it is a real date rather than a placeholder: after the Unix epoch by
    // a margin no plausible build time is inside.
    try std.testing.expect(configured > 1_000_000_000);
}

test "Time.SettingTheClockShiftsItWithoutDisturbingTheMonotonicOne" {
    realtime_offset_us.store(0);
    realtime_was_set.store(false, .monotonic);
    hal.time.impl.set_time(5_000_000);

    // 2001-09-09T01:46:40Z.
    const wanted: u64 = 1_000_000_000 * 1_000_000;
    set_realtime_us(wanted);
    try std.testing.expect(realtime_is_set());
    try std.testing.expectEqual(wanted, realtime_us());

    // The uptime the offset was computed against is still the uptime: a
    // duration measured across the set has to come out as the time that
    // actually passed, not as the size of the jump.
    hal.time.impl.set_time(9_000_000);
    try std.testing.expectEqual(wanted + 4_000_000, realtime_us());
    try std.testing.expectEqual(@as(u64, 9_000_000), uptime_us());
}

test "Time.SettingTheClockBackwardsPastTheUptimeStillReadsBack" {
    // The offset is stored unsigned, so "wanted minus uptime" wraps when the
    // clock is set behind the boot counter. Adding the uptime back has to wrap
    // it the other way rather than leaving a huge number.
    realtime_offset_us.store(0);
    hal.time.impl.set_time(60_000_000);
    set_realtime_us(1_000_000);
    try std.testing.expectEqual(@as(u64, 1_000_000), realtime_us());
}

test "Time.PastInstantsAreRedatedAgainstTheClockAsItStandsNow" {
    // What romfs does with its mount time: recorded at boot with no clock,
    // and asked for after one arrives.
    realtime_offset_us.store(0);
    realtime_was_set.store(false, .monotonic);
    hal.time.impl.set_time(2_000_000);
    const mounted_at = uptime_us();

    // Before the clock is set, the mount dates to 1970 plus two seconds.
    try std.testing.expectEqual(@as(u64, 2_000_000), realtime_of_uptime_us(mounted_at));

    hal.time.impl.set_time(30_000_000);
    const now: u64 = 1_000_000_000 * 1_000_000;
    set_realtime_us(now);

    // After it is set, the same instant reads as 28 seconds ago -- a real
    // date, and still before anything stamped since.
    try std.testing.expectEqual(now - 28_000_000, realtime_of_uptime_us(mounted_at));
    try std.testing.expect(realtime_of_uptime_us(mounted_at) < realtime_us());
}

test "Time.TimespecSplitsMicrosecondsIntoSecondsAndNanoseconds" {
    realtime_offset_us.store(0);
    hal.time.impl.set_time(3_000_250);
    const stamp = now_timespec();
    try std.testing.expectEqual(@as(c_long, 3), @as(c_long, @intCast(stamp.tv_sec)));
    try std.testing.expectEqual(@as(c_long, 250_000), @as(c_long, @intCast(stamp.tv_nsec)));
}

var call_count: usize = 0;

test "Time.ProcessShoulSleep" {
    kernel.process.process_manager.initialize_process_manager(std.testing.allocator);
    defer kernel.process.process_manager.deinitialize_process_manager();
    defer hal.irq.impl().clear();

    var arg: usize = 0;
    try kernel.process.process_manager.instance.create_process(1024, &test_entry, &arg, "test");
    try kernel.process.process_manager.instance.create_process(1024, &test_entry, &arg, "test2");
    _ = kernel.process.process_manager.instance.schedule_next();
    _ = kernel.process.process_manager.process_set_next_task();
    system_call.init(std.testing.allocator);

    hal.time.impl.set_time(0);

    const PendSvAction = struct {
        pub fn call() void {
            // One second per switch, on both clocks -- `sleep_for_us` waits on
            // the microsecond wall clock, and the stub's only advances when a
            // test advances it.
            hal.time.impl.set_time(hal.time.get_time_us() + 1000 * 1000);
            hal.time.systick.set_ticks(hal.time.systick.get_system_tick() + 1000);
            for (0..1000) |_| irq_systick();
            _ = irq_handlers.call_context_switch_handler(0);
            call_count += 1;
        }
    };

    hal.irq.impl().set_irq_action(.pendsv, &PendSvAction.call);

    call_count = 0;
    sleep_ms(400);
    try std.testing.expectEqual(1, call_count);
}
