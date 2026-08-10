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

//! Shared reference counts.
//!
//! There were seven of these hand-rolled across the tree -- ramfs data and
//! directories, driverfs, procfs, the mmc driver and its partitions, the loader
//! -- each written as `r += 1` and `r -= 1; if (r == 0) destroy`, in five
//! slightly different spellings, on three different integer widths. Every one of
//! them had the same two defects:
//!
//!   * **The increment is a read-modify-write.** Two contexts can read the same
//!     value and write back the same result, so one reference disappears and the
//!     object is freed while still in use. This does not need a second core: an
//!     interrupt landing between the load and the store is enough, and these
//!     counters are touched from syscall handlers *and* from process teardown.
//!   * **The decrement and the zero test are separate operations.** Two
//!     contexts dropping the last two references can both observe zero and both
//!     destroy, or neither can and the object leaks.
//!
//! `release` fixes the second by construction: it returns the answer rather than
//! leaving the caller to re-read the counter.
//!
//! Deliberately a duplicate of `libs/oop`'s `refcount`, which does the same job
//! for `ConstructCountingInterface`. That one lives in a standalone library that
//! cannot import the kernel; keeping them apart is cheaper than a dependency
//! from `libs/oop` into `source/kernel`. They must stay semantically identical --
//! see the ordering notes below, which apply verbatim to both.
//!
//! ## On placement
//!
//! A counter reached through a heap pointer may be allocated from a *process*
//! heap, and on the rp2350 that can be PSRAM, which the global exclusive monitor
//! does not cover. Call `placement.assert_coherent` where such a counter is
//! created. The kernel-side counters here are all backed by the kernel heap
//! (internal SRAM), so they are safe; the check is wired into `libs/oop`, whose
//! counters are not.

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

/// A counter with exactly one owner.
///
/// Plain: nothing else can reach a counter that has not been published yet, and
/// publishing it is the caller's release.
pub fn init(counter: anytype) void {
    comptime _ = Counter(@TypeOf(counter));
    counter.* = 1;
}

/// Take a reference.
///
/// Monotonic is sufficient and is not an oversight: an increment is only ever
/// performed by a context that already holds a reference, so the object is
/// provably alive across it and there is nothing to order against.
pub fn acquire(counter: anytype) void {
    const T = Counter(@TypeOf(counter));
    _ = @atomicRmw(T, counter, .Add, 1, .monotonic);
}

/// Drop a reference. Returns true if this was the last one and the caller must
/// now destroy the object.
///
/// `acq_rel`, both halves load-bearing: **release** so everything this context
/// wrote through the object is visible to whoever runs the destructor, and
/// **acquire** so that when this is the last reference, every other context's
/// writes are visible here before the destructor reads them.
pub fn release(counter: anytype) bool {
    const T = Counter(@TypeOf(counter));
    return @atomicRmw(T, counter, .Sub, 1, .acq_rel) == 1;
}

/// The current count. Diagnostics only -- any answer is stale by the time the
/// caller can act on it. The one meaningful value is what `release` returned,
/// because that context owns the transition.
pub fn get(counter: anytype) Counter(@TypeOf(counter)) {
    const T = Counter(@TypeOf(counter));
    return @atomicLoad(T, counter, .monotonic);
}

const testing = std.testing;

test "Sync.RefCount.CountsAcquireAndReleaseAcrossWidths" {
    // Explicit widths, not `usize`: this test builds for the host, where `usize`
    // is 64 bits and would be rejected -- correctly, since the M33 has no
    // LDREXD. On the device `usize` is 32 bits and is accepted, which is why
    // yasld's `ThunkHolderData.refcount` may keep it.
    inline for (.{ i16, i32, u32, u16 }) |T| {
        var counter: T = 0;
        init(&counter);
        try testing.expectEqual(@as(T, 1), get(&counter));

        acquire(&counter);
        acquire(&counter);
        try testing.expectEqual(@as(T, 3), get(&counter));

        try testing.expect(!release(&counter));
        try testing.expect(!release(&counter));
        // Only the transition to zero says "destroy".
        try testing.expect(release(&counter));
        try testing.expectEqual(@as(T, 0), get(&counter));
    }
}

test "Sync.RefCount.NoReferenceIsLostUnderContention" {
    // The defect every hand-rolled copy shared: `r += 1` is a load, an add and a
    // store, so a concurrent increment can be dropped and the object freed while
    // it is still in use. An interrupt between the load and the store is enough;
    // a second core is not required.
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
    // The second defect: a separate decrement and zero test lets two contexts
    // both see zero (double free) or neither see it (leak).
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
