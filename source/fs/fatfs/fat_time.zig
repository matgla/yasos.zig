//
// fat_time.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

//! Between the Unix epoch, which everything above the filesystem speaks, and
//! the broken-down local date FAT keeps in a directory entry.
//!
//! Two things about FAT make this more than a unit conversion:
//!
//!  - **Its epoch is 1980-01-01**, and the year is stored as an unsigned
//!    offset from it. A date before that has no representation at all, and
//!    encoding one underflows rather than saturating -- so anything earlier is
//!    clamped here, at the boundary, rather than left to fault six frames down.
//!    This is not hypothetical: the wall clock reads 1970 until somebody sets
//!    it (see `kernel/time.zig`), so an unclamped write on a freshly booted
//!    board would take that path every time.
//!
//!  - **Its seconds field is two-second granular.** A timestamp written and
//!    read straight back can come back up to one second earlier, and that is
//!    the format, not a bug to paper over. It does mean a `make` comparing a
//!    FAT target against a FAT prerequisite written in the same second cannot
//!    tell them apart, which is exactly why `make` uses `older than` rather
//!    than `not equal`.
//!
//! FAT has no timezone: the date in the entry is local time, and this system
//! has no timezone either (`gettimeofday` reports tz_minuteswest 0), so local
//! and UTC are the same thing here and no conversion is applied.

const std = @import("std");

const fatfs = @import("zfat");

/// 1980-01-01T00:00:00Z, the earliest instant FAT can hold.
pub const fat_epoch_unix_seconds: i64 = 315_532_800;

const seconds_per_day: i64 = 24 * 60 * 60;

pub const BrokenDown = struct {
    date: fatfs.Date,
    time: fatfs.Time,
};

/// Days from 1970-01-01 to `year`-`month`-`day`, proleptic Gregorian.
/// Howard Hinnant's `days_from_civil`, which is exact over the whole range FAT
/// can express and needs no loop over years.
fn days_from_civil(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400; // [0, 399]
    const day_of_year = @divTrunc(153 * (month + (if (month > 2) @as(i64, -3) else @as(i64, 9))) + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

/// A FAT directory entry's date and time as seconds since the Unix epoch.
pub fn to_unix_seconds(date: fatfs.Date, time: fatfs.Time) i64 {
    // A zeroed entry decodes as 1980-00-00, which is not a date. FatFs writes
    // zeroes for an entry it never stamped (a volume made by a tool with no
    // clock), so answer with the epoch rather than a day in December 1979.
    const month = @intFromEnum(date.month);
    if (month < 1 or month > 12 or date.day < 1) {
        return fat_epoch_unix_seconds;
    }
    const days = days_from_civil(@intCast(date.year), month, date.day);
    return days * seconds_per_day +
        @as(i64, time.hour) * 3600 +
        @as(i64, time.minute) * 60 +
        @as(i64, time.second);
}

/// `unix_seconds` as a FAT date and time, clamped up to the FAT epoch and down
/// to the last instant it can represent (2107-12-31T23:59:58).
pub fn from_unix_seconds(unix_seconds: i64) BrokenDown {
    const last_representable: i64 = days_from_civil(2107, 12, 31) * seconds_per_day + 23 * 3600 + 59 * 60 + 58;
    const clamped = std.math.clamp(unix_seconds, fat_epoch_unix_seconds, last_representable);

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(clamped) };
    const year_and_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_and_day = year_and_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return .{
        .date = .{
            .year = year_and_day.year,
            .month = month_and_day.month,
            .day = month_and_day.day_index + 1,
        },
        .time = .{
            .hour = day_seconds.getHoursIntoDay(),
            .minute = day_seconds.getMinutesIntoHour(),
            // Encoding halves this and the decode doubles it back, so the odd
            // second is lost either way; rounding down here keeps a stamped
            // file from claiming to be newer than the instant it was stamped.
            .second = day_seconds.getSecondsIntoMinute() & ~@as(u8, 1),
        },
    };
}

const testing = std.testing;

test "FatTime.RoundTripsAnInstantTheFormatCanHold" {
    // 2026-09-09T12:34:56Z. The seconds land on 56, which survives the
    // two-second granularity unchanged.
    const wanted: i64 = 1_788_957_296;
    const broken = from_unix_seconds(wanted);
    try testing.expectEqual(@as(u16, 2026), broken.date.year);
    try testing.expectEqual(@as(u8, 9), @intFromEnum(broken.date.month));
    try testing.expectEqual(@as(u8, 9), broken.date.day);
    try testing.expectEqual(@as(u8, 12), broken.time.hour);
    try testing.expectEqual(@as(u8, 34), broken.time.minute);
    try testing.expectEqual(@as(u8, 56), broken.time.second);
    try testing.expectEqual(wanted, to_unix_seconds(broken.date, broken.time));
}

test "FatTime.ClampsAnythingBeforeTheFatEpoch" {
    // The default wall clock: 1970 plus a little uptime, which the format
    // cannot hold and whose encoding would underflow.
    const broken = from_unix_seconds(42);
    try testing.expectEqual(@as(u16, 1980), broken.date.year);
    try testing.expectEqual(@as(u8, 1), @intFromEnum(broken.date.month));
    try testing.expectEqual(@as(u8, 1), broken.date.day);
    try testing.expectEqual(fat_epoch_unix_seconds, to_unix_seconds(broken.date, broken.time));

    // And the encoded form is the one FatFs stores, not a wrapped year.
    try testing.expectEqual(@as(u7, 0), @as(fatfs.Date.Encoded, @bitCast(broken.date.encode())).years_from_1980);
}

test "FatTime.ClampsPastTheLastDateTheFormatCanExpress" {
    const far_future: i64 = 32_503_680_000; // 3000-01-01
    const broken = from_unix_seconds(far_future);
    try testing.expectEqual(@as(u16, 2107), broken.date.year);
    try testing.expectEqual(@as(u8, 12), @intFromEnum(broken.date.month));
    try testing.expectEqual(@as(u8, 31), broken.date.day);
}

test "FatTime.LosesTheOddSecondRatherThanGainingOne" {
    const odd: i64 = 1_788_957_297; // ...12:34:57
    const broken = from_unix_seconds(odd);
    try testing.expectEqual(@as(u8, 56), broken.time.second);
    try testing.expect(to_unix_seconds(broken.date, broken.time) < odd);
}

test "FatTime.ReadsAZeroedEntryAsTheEpochRatherThanADayBeforeIt" {
    // fdate == 0 decodes as year 1980, month 0, day 0 -- what a volume written
    // by a tool with no clock leaves behind.
    const zeroed = fatfs.Date.decode(0);
    try testing.expectEqual(fat_epoch_unix_seconds, to_unix_seconds(zeroed, fatfs.Time.decode(0)));
}

test "FatTime.HandlesLeapDaysAndCenturyRules" {
    // 2000 is a leap year (divisible by 400), 2100 is not (divisible by 100).
    const leap_day = from_unix_seconds(951_782_400); // 2000-02-29T00:00:00Z
    try testing.expectEqual(@as(u16, 2000), leap_day.date.year);
    try testing.expectEqual(@as(u8, 2), @intFromEnum(leap_day.date.month));
    try testing.expectEqual(@as(u8, 29), leap_day.date.day);
    try testing.expectEqual(@as(i64, 951_782_400), to_unix_seconds(leap_day.date, leap_day.time));

    const after_2100 = from_unix_seconds(4_107_542_400); // 2100-03-01T00:00:00Z
    try testing.expectEqual(@as(u16, 2100), after_2100.date.year);
    try testing.expectEqual(@as(u8, 3), @intFromEnum(after_2100.date.month));
    try testing.expectEqual(@as(u8, 1), after_2100.date.day);
    try testing.expectEqual(@as(i64, 4_107_542_400), to_unix_seconds(after_2100.date, after_2100.time));
}
