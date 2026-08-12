// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// Shared reference counts. `release` returns whether the caller must destroy,
// rather than leaving it to re-read the counter and race another dropper.
//
// A deliberate duplicate of `libs/oop`'s `refcount`, which cannot import the
// kernel; the two must stay semantically identical. A counter allocated from a
// process heap may land in PSRAM, which the exclusive monitor does not cover --
// call `placement.assert_coherent` there. The counters here are kernel-heap.

const std = @import("std");

const atomic = @import("atomic.zig");

fn Counter(comptime Pointer: type) type {
    const info = @typeInfo(Pointer);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("refcount takes a single-item pointer, got " ++ @typeName(Pointer));
    }
    const T = info.pointer.child;
    if (@typeInfo(T) != .int) {
        @compileError("refcount takes a pointer to an integer, got " ++ @typeName(T));
    }
    if (!atomic.fits_lock_free(T, atomic.lock_free_bits)) {
        @compileError("refcount on " ++ @typeName(T) ++ " would not be lock-free on this target");
    }
    return T;
}

/// A counter with exactly one owner. Plain: nothing else can reach a counter
/// that has not been published yet.
pub fn init(counter: anytype) void {
    comptime _ = Counter(@TypeOf(counter));
    counter.* = 1;
}

/// Take a reference. Monotonic is enough: the caller already holds one, so the
/// object is provably alive across the increment.
pub fn acquire(counter: anytype) void {
    const T = Counter(@TypeOf(counter));
    _ = @atomicRmw(T, counter, .Add, 1, .monotonic);
}

/// Drop a reference. Returns true if this was the last one and the caller must
/// now destroy the object. `acq_rel` both ways: release so this context's writes
/// reach the destructor, acquire so every other context's writes are visible to
/// it.
pub fn release(counter: anytype) bool {
    const T = Counter(@TypeOf(counter));
    return @atomicRmw(T, counter, .Sub, 1, .acq_rel) == 1;
}

/// The current count. Diagnostics only -- stale by the time the caller can act
/// on it. The meaningful answer is what `release` returned.
pub fn get(counter: anytype) Counter(@TypeOf(counter)) {
    const T = Counter(@TypeOf(counter));
    return @atomicLoad(T, counter, .monotonic);
}

const testing = std.testing;

test "Sync.RefCount.CountsAcquireAndReleaseAcrossWidths" {
    // Explicit widths, not `usize`: on the host that is 64 bits and is rejected,
    // correctly, since the M33 has no LDREXD.
    inline for (.{ i16, i32, u32, u16 }) |T| {
        var counter: T = 0;
        init(&counter);
        try testing.expectEqual(@as(T, 1), get(&counter));

        acquire(&counter);
        acquire(&counter);
        try testing.expectEqual(@as(T, 3), get(&counter));

        try testing.expect(!release(&counter));
        try testing.expect(!release(&counter));
        try testing.expect(release(&counter));
        try testing.expectEqual(@as(T, 0), get(&counter));
    }
}

test "Sync.RefCount.NoReferenceIsLostUnderContention" {
    // A plain `r += 1` can drop a concurrent increment; an interrupt between the
    // load and the store is enough, no second core required.
    var counter: i32 = 0;
    init(&counter);

    const Hammer = struct {
        fn run(target: *i32, iterations: usize) void {
            for (0..iterations) |_| {
                acquire(target);
                std.debug.assert(!release(target));
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Hammer.run, .{ &counter, 20_000 });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(i32, 1), get(&counter));
    try testing.expect(release(&counter));
}

test "Sync.RefCount.ExactlyOneReleaserIsToldToDestroy" {
    // A separate decrement and zero test lets two contexts both see zero (double
    // free) or neither see it (leak).
    const holders = 8;

    var counter: i32 = 0;
    init(&counter);
    for (1..holders) |_| acquire(&counter);

    var destroyers = std.atomic.Value(u32).init(0);

    const Dropper = struct {
        fn run(target: *i32, tally: *std.atomic.Value(u32)) void {
            if (release(target)) _ = tally.fetchAdd(1, .monotonic);
        }
    };

    var threads: [holders]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Dropper.run, .{ &counter, &destroyers });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u32, 1), destroyers.load(.monotonic));
    try testing.expectEqual(@as(i32, 0), get(&counter));
}
