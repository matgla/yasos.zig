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

// Prefer lock_irqsave() over lock(): most structures here are touched from both
// handler and thread context, and a plain lock() taken in thread mode deadlocks
// the moment an interrupt on the same core reaches for it.

const std = @import("std");

const arch = @import("arch");

const atomic = @import("atomic.zig");
const percpu = @import("percpu.zig");

/// Interrupt state captured by `lock_irqsave`, to be handed back verbatim.
pub const IrqState = usize;

/// Exclusive monitor reservation granule. IMPLEMENTATION DEFINED and
/// undocumented for the RP2350, so this is deliberately larger than any
/// plausible value. Only `Isolated` applies it, for the contended global locks.
pub const reservation_granule_bytes = 32;

const free: u32 = 0;

/// Token identifying the calling execution context, never `free`. The mask
/// keeps the `+ 1` from wrapping a host thread id back onto `free`.
inline fn current_token() u32 {
    if (comptime !percpu.smp) return 1;
    return (arch.sync.owner_id() & 0x7fff_ffff) + 1;
}

/// Whether the ownership assertions and the recursion check are compiled in.
const debug_checks = std.debug.runtime_safety;

pub const SpinLock = struct {
    /// `free`, or the token of the core/thread currently holding the lock.
    state: atomic.Atomic(u32) = .init(free),

    const Self = @This();

    /// Take the lock if it is free right now. Never spins, so the panic and
    /// HardFault paths can use it.
    pub fn try_lock(self: *Self) bool {
        return self.state.cmpxchgStrong(free, current_token(), .acquire, .monotonic) == null;
    }

    /// Take the lock, spinning until it is ours. Prefer `lock_irqsave`.
    pub fn lock(self: *Self) void {
        const token = current_token();

        // Without a second core there is nobody to wait for: an interrupt
        // handler runs to completion before we get the CPU back, so a lock that
        // is held when we ask for it stays held. Waiting is a hang, not a wait.
        if (comptime !percpu.smp) {
            if (self.try_lock()) return;
            @panic("spinlock: contended on a single-core build -- this core already holds it, which can only deadlock");
        }

        while (self.state.cmpxchgWeak(free, token, .acquire, .monotonic) != null) {
            if (debug_checks and self.state.load(.monotonic) == token) {
                @panic("spinlock: recursive acquisition -- this core/thread already holds this lock");
            }
            arch.sync.cpu_relax();
        }
    }

    /// Release the lock.
    pub fn unlock(self: *Self) void {
        if (debug_checks and self.state.load(.monotonic) != current_token()) {
            @panic("spinlock: released by a context that does not hold it");
        }
        self.state.store(free, .release);
        // Wake anyone parked in `cpu_relax`.
        if (comptime percpu.smp) arch.sync.signal_event();
    }

    /// Mask interrupts on this core, then take the lock. The order matters:
    /// acquiring first leaves a window for an interrupt on this core to reach
    /// for the lock this context just took.
    pub fn lock_irqsave(self: *Self) IrqState {
        const flags = arch.sync.save_and_disable_interrupts();
        self.lock();
        return flags;
    }

    /// Release the lock, then restore the interrupt state `lock_irqsave`
    /// returned. Unmasking first would re-open the window it closed.
    pub fn unlock_irqrestore(self: *Self, flags: IrqState) void {
        self.unlock();
        arch.sync.restore_interrupts(flags);
    }

    /// `lock_irqsave` that gives up rather than spinning. Returns null with
    /// interrupts left exactly as they were.
    pub fn try_lock_irqsave(self: *Self) ?IrqState {
        const flags = arch.sync.save_and_disable_interrupts();
        if (self.try_lock()) return flags;
        arch.sync.restore_interrupts(flags);
        return null;
    }

    /// Whether anyone holds the lock. Diagnostics only -- can be stale by the
    /// time the caller acts on it.
    pub fn is_locked(self: *const Self) bool {
        return self.state.load(.monotonic) != free;
    }

    /// Whether *this* context holds the lock. Race-free, unlike `is_locked`.
    pub fn held_by_current(self: *const Self) bool {
        return self.state.load(.monotonic) == current_token();
    }

    /// Assert that the caller holds this lock. Compiled out when safety is off.
    pub fn assert_held(self: *const Self) void {
        if (!debug_checks) return;
        if (!self.held_by_current()) {
            @panic("spinlock: expected to be held by the caller here");
        }
    }
};

/// `T` alone in its exclusive-reservation granule -- see
/// `reservation_granule_bytes`.
pub fn Isolated(comptime T: type) type {
    comptime {
        if (@sizeOf(T) > reservation_granule_bytes) {
            @compileError(std.fmt.comptimePrint(
                "Isolated({s}) is {d} bytes, larger than the {d}-byte reservation granule",
                .{ @typeName(T), @sizeOf(T), reservation_granule_bytes },
            ));
        }
    }
    return struct {
        value: T align(reservation_granule_bytes) = .{},
        _padding: [reservation_granule_bytes - @sizeOf(T)]u8 = @splat(0),
    };
}

const testing = std.testing;

test "Sync.SpinLock.UncontendedAcquireAndRelease" {
    var lock = SpinLock{};
    try testing.expect(!lock.is_locked());

    lock.lock();
    try testing.expect(lock.is_locked());
    try testing.expect(lock.held_by_current());
    lock.assert_held();

    lock.unlock();
    try testing.expect(!lock.is_locked());
    try testing.expect(!lock.held_by_current());
}

test "Sync.SpinLock.TryLockFailsWhileHeld" {
    var lock = SpinLock{};
    try testing.expect(lock.try_lock());
    try testing.expect(!lock.try_lock());
    lock.unlock();
    try testing.expect(lock.try_lock());
    lock.unlock();
}

test "Sync.SpinLock.IrqSavePairRoundTrips" {
    var lock = SpinLock{};
    const flags = lock.lock_irqsave();
    try testing.expect(lock.held_by_current());
    lock.unlock_irqrestore(flags);
    try testing.expect(!lock.is_locked());

    const maybe = lock.try_lock_irqsave();
    try testing.expect(maybe != null);
    lock.unlock_irqrestore(maybe.?);

    try testing.expect(lock.try_lock());
    // A failed acquire must leave the interrupt state untouched.
    try testing.expectEqual(null, lock.try_lock_irqsave());
    lock.unlock();
}

test "Sync.SpinLock.SingleCoreDropsOnlyTheCrossCoreParts" {
    // The contention tests below need CONFIG_PROCESS_SMP=y to exercise the spin
    // path; assert the build shape rather than failing obscurely.
    try testing.expect(percpu.smp);
    try testing.expect(percpu.core_count >= 2);

    // Exclusion against this core's own interrupt handlers survives either way.
    var lock = SpinLock{};
    const flags = lock.lock_irqsave();
    try testing.expect(lock.is_locked());
    try testing.expect(!lock.try_lock());
    lock.unlock_irqrestore(flags);
    try testing.expect(!lock.is_locked());
}

test "Sync.SpinLock.MutualExclusionUnderRealThreadContention" {
    const Shared = struct {
        lock: SpinLock = .{},
        // Deliberately not atomic: a lost update here is the failure under test.
        counter: u64 = 0,

        const Self = @This();

        fn hammer(self: *Self, iterations: usize) void {
            for (0..iterations) |_| {
                const flags = self.lock.lock_irqsave();
                defer self.lock.unlock_irqrestore(flags);
                self.counter += 1;
            }
        }
    };

    var shared = Shared{};
    const thread_count = 4;
    const iterations = 10_000;

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Shared.hammer, .{ &shared, iterations });
    }
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u64, thread_count * iterations), shared.counter);
    try testing.expect(!shared.lock.is_locked());
}

test "Sync.SpinLock.HandsOffBetweenThreads" {
    // A lock taken by one thread must not look held by another, or `assert_held`
    // would pass in the one place it most needs to fail.
    const Probe = struct {
        lock: SpinLock = .{},
        held_elsewhere: atomic.Atomic(bool) = .init(false),
        observed: atomic.Atomic(bool) = .init(false),
        released: atomic.Atomic(bool) = .init(false),

        const Self = @This();

        fn observe(self: *Self) void {
            self.held_elsewhere.store(
                self.lock.is_locked() and !self.lock.held_by_current(),
                .monotonic,
            );
            self.observed.store(true, .release);
            while (!self.released.load(.acquire)) arch.sync.cpu_relax();
        }
    };

    var probe = Probe{};
    probe.lock.lock();
    const thread = try std.Thread.spawn(.{}, Probe.observe, .{&probe});
    while (!probe.observed.load(.acquire)) arch.sync.cpu_relax();
    try testing.expect(probe.held_elsewhere.load(.monotonic));
    probe.released.store(true, .release);
    thread.join();
    probe.lock.unlock();
}

test "Sync.SpinLock.IsolatedOccupiesAWholeGranule" {
    try testing.expectEqual(reservation_granule_bytes, @sizeOf(Isolated(SpinLock)));
    try testing.expectEqual(reservation_granule_bytes, @alignOf(Isolated(SpinLock)));

    // Two adjacent isolated locks must not share a granule.
    var pair: [2]Isolated(SpinLock) = .{ .{}, .{} };
    const first = @intFromPtr(&pair[0].value);
    const second = @intFromPtr(&pair[1].value);
    try testing.expect(second - first >= reservation_granule_bytes);
    try testing.expectEqual(0, first % reservation_granule_bytes);

    pair[0].value.lock();
    try testing.expect(!pair[1].value.is_locked());
    pair[0].value.unlock();
}
