// Copyright (c) 2026 Mateusz Stadnik
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

//! A spinlock for the HAL.
//!
//! The kernel has a much better one -- `source/kernel/sync/spinlock.zig`, with
//! ownership tokens, `assert_held` and the whole lock hierarchy on top. This is
//! not a rival to it; the HAL simply cannot reach it. `hal_common` is wired into
//! each MCU's build as a standalone module (see `hal/source/raspberry/rp2350/
//! build.zig`) and imports nothing but `cmsis`, while the kernel sits *above*
//! the HAL. Duplicating thirty lines is the cheaper of the two wrongs.
//!
//! ## Why there is no owner token
//!
//! The kernel's lock word carries a token identifying the holder, which buys
//! `assert_held` and turns a recursive acquisition into a named panic instead of
//! a hang. This one is a plain flag, and that is a deliberate match to its only
//! use rather than a corner cut.
//!
//! The sole user is the RP2350 UART receive path, whose producers take the lock
//! with `try_lock` and **skip their work entirely** when it fails. For that
//! caller "the other core holds it" and "this core already holds it, further up
//! the stack" have the *same* correct answer -- don't drain, come back later --
//! so a token would distinguish two cases that need no distinguishing. What
//! matters is that no producer ever waits, which is what makes the receive path
//! safe from the fault handler; see `Uart.drain_rx`.
//!
//! ## Interrupt masking is the caller's job
//!
//! No `lock_irqsave` here, unlike the kernel's. Masking is arch-specific and
//! this module is shared by every board, so the two MSR/CPS sequences would have
//! to be imported from somewhere -- and the one caller already has them inline.
//! Mask first, then lock; unlock, then restore. Getting that order backwards
//! re-opens the window it exists to close.

const std = @import("std");

pub const SpinLock = struct {
    const free: u32 = 0;
    const held: u32 = 1;

    state: std.atomic.Value(u32) = .init(free),

    const Self = @This();

    /// Take the lock if it is free right now. Never spins, so it can never
    /// deadlock -- which is the entire reason the receive path can call it from
    /// a context that may have interrupted the holder.
    pub fn try_lock(self: *Self) bool {
        // Acquire on success, so everything the previous holder wrote before its
        // release is visible here. Monotonic on failure: a failed acquire orders
        // nothing and must not pay for a barrier.
        return self.state.cmpxchgStrong(free, held, .acquire, .monotonic) == null;
    }

    /// Take the lock, spinning until it is ours.
    ///
    /// Only safe for a caller that can prove nothing on its own core already
    /// holds the lock -- in practice, thread context that has masked interrupts
    /// first. A handler that spins here on a lock its own core holds hangs
    /// forever; handlers want `try_lock`.
    pub fn lock(self: *Self) void {
        while (self.state.cmpxchgWeak(free, held, .acquire, .monotonic) != null) {
            // `yield` on ARM, which is a hint rather than the `wfe`/`sev` pair
            // the kernel's lock uses. Deliberate: `sev` on release would need an
            // arch import, and every critical section this lock guards is
            // bounded by the 32-byte hardware FIFO -- a few hundred cycles at
            // worst, far too short for the park/wake handshake to pay for
            // itself.
            std.atomic.spinLoopHint();
        }
    }

    /// Release the lock. Release ordering, so everything written under it is
    /// visible to the next holder's acquire.
    pub fn unlock(self: *Self) void {
        self.state.store(free, .release);
    }

    /// Whether anyone holds the lock. Diagnostics only -- by the time a caller
    /// acts on the answer it can already be stale. Use `try_lock` to decide
    /// anything.
    pub fn is_locked(self: *const Self) bool {
        return self.state.load(.monotonic) != free;
    }
};

const testing = std.testing;

test "Hal.Utils.SpinLock.UncontendedAcquireAndRelease" {
    var lock = SpinLock{};
    try testing.expect(!lock.is_locked());

    lock.lock();
    try testing.expect(lock.is_locked());
    lock.unlock();
    try testing.expect(!lock.is_locked());
}

test "Hal.Utils.SpinLock.TryLockRefusesWhileHeldEvenBySameContext" {
    // The property the receive path depends on: a nested caller -- a HardFault
    // that landed on the core already inside the drain -- must be *refused*, not
    // let through and not made to wait. Refusal is what turns the fault path
    // into "skip the drain" instead of "spin on yourself".
    var lock = SpinLock{};
    try testing.expect(lock.try_lock());
    try testing.expect(!lock.try_lock());
    lock.unlock();
    try testing.expect(lock.try_lock());
    lock.unlock();
}

test "Hal.Utils.SpinLock.MutualExclusionUnderRealThreadContention" {
    const Shared = struct {
        lock: SpinLock = .{},
        // Deliberately not atomic: a lost update here is the failure under test,
        // and making it atomic would test nothing.
        counter: u64 = 0,

        const Self = @This();

        fn hammer(self: *Self, iterations: usize) void {
            for (0..iterations) |_| {
                self.lock.lock();
                defer self.lock.unlock();
                self.counter += 1;
            }
        }
    };

    var shared = Shared{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.hammer, .{ &shared, 10_000 });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u64, 4 * 10_000), shared.counter);
    try testing.expect(!shared.lock.is_locked());
}

test "Hal.Utils.SpinLock.TryLockContendersNeverBothEnter" {
    // The producer pattern: every contender either enters or gives up, and the
    // two must never overlap. Counting entries proves exclusion; counting skips
    // proves the give-up path is actually exercised rather than the test just
    // running serially.
    const Shared = struct {
        lock: SpinLock = .{},
        inside: std.atomic.Value(u32) = .init(0),
        overlaps: std.atomic.Value(u32) = .init(0),
        skips: std.atomic.Value(u32) = .init(0),

        const Self = @This();

        fn poll(self: *Self, iterations: usize) void {
            for (0..iterations) |_| {
                if (!self.lock.try_lock()) {
                    _ = self.skips.fetchAdd(1, .monotonic);
                    continue;
                }
                if (self.inside.fetchAdd(1, .acq_rel) != 0) {
                    _ = self.overlaps.fetchAdd(1, .monotonic);
                }
                _ = self.inside.fetchSub(1, .acq_rel);
                self.lock.unlock();
            }
        }
    };

    var shared = Shared{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.poll, .{ &shared, 20_000 });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u32, 0), shared.overlaps.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), shared.inside.load(.monotonic));
}
