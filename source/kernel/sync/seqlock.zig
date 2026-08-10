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

//! Seqlocks: reading a value too wide to load atomically.
//!
//! The M33 has no `LDREXD`, so a `u64` cannot be read or written atomically --
//! and `Atomic(u64)` is refused at comptime for exactly that reason. A reader
//! that simply loads both halves can catch a writer between them and see a
//! value that never existed, which at a 32-bit carry boundary is not a small
//! error: `0x0000_0000_FFFF_FFFF` incrementing to `0x0000_0001_0000_0000` can
//! be read as `0x0000_0001_FFFF_FFFF`, four billion ticks in the future.
//!
//! The protocol is the classic one. The writer bumps a sequence number to odd
//! before touching the value and to even after; a reader samples the sequence,
//! reads the value, and retries unless the sequence is unchanged and was even.
//! Readers never block a writer, which is what makes it right for a value
//! written from an interrupt handler.
//!
//! **One writer only.** Two concurrent writers would interleave their odd/even
//! transitions and let a reader through mid-update. Every use here is a value
//! owned by a single core or a single handler; if that ever stops being true,
//! the writer side needs a lock of its own on top.
//!
//! The tree's existing hand-rolled seqlock (`process/xipstat_file.zig`) uses a
//! plain `sequence +%=` with no barriers -- correct against preemption on one
//! core, and nothing at all across two. It should move onto this.

const std = @import("std");

const atomic = @import("atomic.zig");

/// A 64-bit value published by one writer and read by many.
///
/// Stored as two `u32` halves, each accessed atomically, and **not** as a plain
/// `u64` field. That is not belt-and-braces: a plain read of the value can be
/// reordered by the compiler around the sequence checks that are supposed to
/// bracket it, at which point the protocol guarantees nothing. The first
/// version of this did exactly that, and the contention test below caught it
/// immediately -- which is the reason that test exists.
///
/// `Atomic(u64)` is not an option either: it is refused at comptime, because on
/// an M33 it lowers to a lock-taking `__atomic_*` libcall.
pub const Seq64 = struct {
    /// Even means stable, odd means a write is in progress.
    sequence: atomic.Atomic(u32) = .init(0),
    low: atomic.Atomic(u32) = .init(0),
    high: atomic.Atomic(u32) = .init(0),

    const Self = @This();

    pub fn init(initial: u64) Self {
        return .{
            .sequence = .init(0),
            .low = .init(@truncate(initial)),
            .high = .init(@truncate(initial >> 32)),
        };
    }

    /// Publish a new value. Single writer -- see the module comment.
    pub fn store(self: *Self, new: u64) void {
        const start = self.sequence.load(.monotonic);
        // Odd first, so any reader in flight retries. `seq_cst` on every
        // sequence access is what keeps the halves from drifting outside the
        // bracket; the halves themselves need no ordering of their own.
        self.sequence.store(start +% 1, .seq_cst);
        self.low.store(@truncate(new), .monotonic);
        self.high.store(@truncate(new >> 32), .monotonic);
        self.sequence.store(start +% 2, .seq_cst);
    }

    /// Read the value, retrying while a write is in flight.
    ///
    /// Wait-free for the writer, which is what makes this usable for a value
    /// written from an interrupt handler: a reader can never hold the tick up.
    pub fn load(self: *const Self) u64 {
        while (true) {
            const before = self.sequence.load(.seq_cst);
            if (before % 2 != 0) continue;
            const low = self.low.load(.monotonic);
            const high = self.high.load(.monotonic);
            const after = self.sequence.load(.seq_cst);
            if (before == after) return (@as(u64, high) << 32) | low;
        }
    }
};

const testing = std.testing;

test "Sync.SeqLock.ReadsWhatWasWritten" {
    var clock = Seq64.init(0);
    try testing.expectEqual(@as(u64, 0), clock.load());

    clock.store(1);
    try testing.expectEqual(@as(u64, 1), clock.load());

    // The value the plain two-halves read gets wrong: crossing the 32-bit
    // boundary.
    clock.store(0xFFFF_FFFF);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), clock.load());
    clock.store(0x1_0000_0000);
    try testing.expectEqual(@as(u64, 0x1_0000_0000), clock.load());
}

test "Sync.SeqLock.NeverReturnsAValueThatWasNeverWritten" {
    // The property, under genuine contention: a reader may see an old value or
    // a new one, never a mixture. The writer walks a sequence whose two halves
    // are always derivable from each other, so a torn read is detectable.
    // Seeded to satisfy the invariant, not to zero: the readers start before
    // the writer's first store, and `high == ~low` does not hold for 0.
    const seed: u64 = @as(u64, ~@as(u32, 0)) << 32;

    const Shared = struct {
        clock: Seq64 = .init(seed),
        stop: atomic.Atomic(bool) = .init(false),
        torn: atomic.Atomic(u32) = .init(0),

        const Self = @This();

        fn writer(self: *Self, iterations: usize) void {
            for (0..iterations) |i| {
                // High half is the low half's complement, so any mixture of an
                // old high with a new low fails the check below.
                const low: u32 = @truncate(i);
                const value = (@as(u64, ~low) << 32) | low;
                self.clock.store(value);
            }
            self.stop.store(true, .release);
        }

        fn reader(self: *Self) void {
            while (!self.stop.load(.acquire)) {
                const seen = self.clock.load();
                const low: u32 = @truncate(seen);
                const high: u32 = @truncate(seen >> 32);
                if (high != ~low) _ = self.torn.fetchAdd(1, .monotonic);
            }
        }
    };

    var shared = Shared{};
    var readers: [3]std.Thread = undefined;
    for (&readers) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.reader, .{&shared});
    }
    const writer = try std.Thread.spawn(.{}, Shared.writer, .{ &shared, 200_000 });
    writer.join();
    for (readers) |thread| thread.join();

    try testing.expectEqual(@as(u32, 0), shared.torn.load(.monotonic));
}

test "Sync.SeqLock.SequenceIsEvenWhenIdle" {
    var clock = Seq64.init(7);
    try testing.expectEqual(@as(u32, 0), clock.sequence.load(.monotonic) % 2);
    clock.store(8);
    // Back to even, so a reader is never left spinning against a finished write.
    try testing.expectEqual(@as(u32, 0), clock.sequence.load(.monotonic) % 2);
}
