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

//! The kernel spinlock.
//!
//! One implementation for every target. The arch layer supplies four small
//! hooks -- `cpu_relax`, `signal_event`, `owner_id` and the interrupt
//! save/restore pair -- and everything above them is portable, so this exact
//! code is what `zig build test` exercises under genuine `std.Thread`
//! contention and what runs on the M33.
//!
//! ## Use `lock_irqsave`, not `lock`
//!
//! Almost every structure this kernel needs to protect is touched from *both*
//! handler and thread context. A plain `lock()` taken in thread mode is a
//! deadlock the moment an interrupt lands on the same core and reaches for the
//! same lock -- on one core that is a hang, and no amount of SMP correctness
//! elsewhere saves it. `lock_irqsave()` closes that window by masking first.
//!
//! `lock()` is still exported, for the two situations where it is right: a lock
//! only ever taken from thread context with interrupts already masked by an
//! enclosing `lock_irqsave`, and the panic/fault paths that use `try_lock`.
//!
//! ## What a single-core build keeps, and what it drops
//!
//! `CONFIG_PROCESS_SMP` off does **not** make this a no-op, because the
//! scheduler is preemptive: a read-modify-write shared between thread and
//! handler context on one core races exactly as it does across two, and
//! `lock_irqsave` is what closes that. So the atomic acquire, the release
//! ordering and the interrupt masking all stay.
//!
//! What goes is only what needs a second core to mean anything: the wait/wake
//! back-off. With one core, whoever holds the lock cannot make progress while
//! we spin -- an interrupt handler runs to completion before we get the CPU
//! back -- so a contended `lock()` is a hang. It reports that instead.
//!
//! ## Ownership tracking
//!
//! The lock word is not a 0/1 flag: it holds a token identifying the holder.
//! That costs nothing on the acquire path and buys two things -- `assert_held`,
//! which phase 3 leans on heavily to prove a caller really did take the lock it
//! believed a caller above it took, and an immediate panic naming a recursive
//! acquisition instead of a silent hang.

const std = @import("std");

const arch = @import("arch");

const atomic = @import("atomic.zig");
const percpu = @import("percpu.zig");

/// Interrupt state captured by `lock_irqsave`, to be handed back verbatim.
pub const IrqState = usize;

/// Conservative bound on the global exclusive monitor's reservation granule.
///
/// The granule is IMPLEMENTATION DEFINED, and the RP2350 datasheet does not
/// state it. It matters because a STREX by one core clears every reservation in
/// the granule it touches: two lock words sharing one granule make each core's
/// release steal the other's in-flight acquire. That does not corrupt anything
/// -- the loop retries -- but it turns into an unbounded-retry throughput cliff
/// that is very hard to attribute back to a layout decision.
///
/// So this is deliberately larger than any plausible granule rather than exact.
/// `Isolated` applies it; the base `SpinLock` does not, because per-file and
/// per-process locks would pay 32 bytes each for a hazard they will never hit.
/// Use `Isolated` for the contended global locks.
pub const reservation_granule_bytes = 32;

const free: u32 = 0;

/// Token identifying the calling execution context, never `free`.
///
/// The mask keeps the `+ 1` from wrapping a host thread id back onto `free`;
/// `owner_id()` is a small core number on the device and an arbitrary 32-bit
/// thread id on the host.
///
/// Without SMP it is a constant, and that is not a shortcut: there is only one
/// context that can hold a lock, so the token has nothing to distinguish and
/// "state == my token" still means exactly what it has to -- somebody on this
/// core holds it, which for `lock()` is a deadlock and for `assert_held` is the
/// thing being asserted. It removes the SIO CPUID load *and* the bounds check
/// on its `@intCast` from every acquire and every release.
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

    /// Take the lock if it is free right now. Never spins.
    ///
    /// This is the acquire the panic and HardFault paths use: a garbled log line
    /// beats a hung panic, so those print whether or not they got the lock.
    pub fn try_lock(self: *Self) bool {
        // Acquire on success so everything the previous holder wrote before its
        // release is visible here; monotonic on failure because a failed
        // acquire orders nothing.
        return self.state.cmpxchgStrong(free, current_token(), .acquire, .monotonic) == null;
    }

    /// Take the lock, spinning until it is ours.
    ///
    /// Prefer `lock_irqsave` -- see the module comment. Panics rather than hangs
    /// if this context already holds the lock.
    pub fn lock(self: *Self) void {
        const token = current_token();

        // Without a second core there is nobody to wait *for*. Every context
        // that could hold this lock -- this thread, or an interrupt handler
        // that preempted it -- is on this core, and an interrupt handler runs
        // to completion before we get the CPU back. So a lock that is held when
        // we ask for it stays held for as long as we spin: waiting is a hang,
        // not a wait.
        //
        // Reporting it is strictly better than spinning, and the acquire itself
        // still has to be atomic -- the race against this core's own handlers
        // is real whatever `CONFIG_PROCESS_SMP` says.
        if (comptime !percpu.smp) {
            if (self.try_lock()) return;
            @panic("spinlock: contended on a single-core build -- this core already holds it, which can only deadlock");
        }

        while (self.state.cmpxchgWeak(free, token, .acquire, .monotonic) != null) {
            if (debug_checks and self.state.load(.monotonic) == token) {
                // Only the holder ever writes its own token, and release writes
                // `free`, so an observed match cannot be stale: this context
                // really does hold the lock and is about to wait on itself.
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
        // Release so every write made under the lock is visible to the next
        // holder's acquire. Still required without SMP: this orders the critical
        // section against an interrupt handler on this core that takes the lock
        // straight after.
        self.state.store(free, .release);
        // Wake anyone parked in `cpu_relax`. Nobody can be parked without a
        // second core, and `lock` does not park there either, so this compiles
        // out entirely.
        if (comptime percpu.smp) arch.sync.signal_event();
    }

    /// Mask interrupts on this core, then take the lock.
    ///
    /// The order is the whole point and it is not interchangeable: acquiring
    /// first would leave a window in which an interrupt on this core can arrive
    /// holding nothing and reach for the lock this context just took.
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

    /// Whether anyone holds the lock. Only meaningful for diagnostics -- by the
    /// time a caller acts on it the answer can already be stale.
    pub fn is_locked(self: *const Self) bool {
        return self.state.load(.monotonic) != free;
    }

    /// Whether *this* context holds the lock. Unlike `is_locked` this one is
    /// race-free for the caller: nothing but this context can make it true.
    pub fn held_by_current(self: *const Self) bool {
        return self.state.load(.monotonic) == current_token();
    }

    /// Assert that the caller holds this lock.
    ///
    /// Goes at the head of every function that mutates a guarded structure. The
    /// bug it catches is the one a review cannot: a function that is correct
    /// only because *some* caller was believed to hold the lock, and one caller
    /// does not. Compiled out when safety is off.
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
    // Same context, so this is the "already ours" case rather than contention;
    // `try_lock` must still refuse, which is what makes it usable from a fault
    // handler that may have interrupted the holder.
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
    // Failing to acquire must leave the interrupt state untouched, not
    // half-restored -- a caller that gets null carries on with its own masking.
    try testing.expectEqual(null, lock.try_lock_irqsave());
    lock.unlock();
}

test "Sync.SpinLock.SingleCoreDropsOnlyTheCrossCoreParts" {
    // The unit-test target builds with CONFIG_PROCESS_SMP=y precisely so the
    // contention tests below exercise the spin path. If that ever gets turned
    // off here, those tests would take the single-core branch and panic on the
    // first contended acquire rather than testing anything -- so assert the
    // build shape instead of letting it fail obscurely.
    try testing.expect(percpu.smp);
    try testing.expect(percpu.core_count >= 2);

    // And the part that must survive either way: exclusion against this core's
    // own interrupt handlers, which is what `lock_irqsave` is for and what a
    // preemptive kernel needs on one core.
    var lock = SpinLock{};
    const flags = lock.lock_irqsave();
    try testing.expect(lock.is_locked());
    try testing.expect(!lock.try_lock());
    lock.unlock_irqrestore(flags);
    try testing.expect(!lock.is_locked());
}

test "Sync.SpinLock.MutualExclusionUnderRealThreadContention" {
    // The reason the primitive is arch-independent: this is a genuine race, run
    // on real cores, against the same code the M33 gets.
    const Shared = struct {
        lock: SpinLock = .{},
        // Deliberately *not* atomic. A lost update here is the failure being
        // tested for; making it atomic would test nothing.
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
    // Ownership is per-context, so a lock taken by one thread must not look held
    // by another -- otherwise `assert_held` would pass in the one place it most
    // needs to fail.
    // Handshaking on plain atomic flags rather than a std event type: this Zig's
    // `std.Thread` no longer carries one, and the flags are exactly the
    // primitive under test one layer down.
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

    // Two adjacent isolated locks must not share a granule -- that is the entire
    // reason the wrapper exists.
    var pair: [2]Isolated(SpinLock) = .{ .{}, .{} };
    const first = @intFromPtr(&pair[0].value);
    const second = @intFromPtr(&pair[1].value);
    try testing.expect(second - first >= reservation_granule_bytes);
    try testing.expectEqual(0, first % reservation_granule_bytes);

    pair[0].value.lock();
    try testing.expect(!pair[1].value.is_locked());
    pair[0].value.unlock();
}
