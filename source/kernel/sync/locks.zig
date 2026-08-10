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

//! The lock hierarchy, and the runtime check that keeps it honest.
//!
//! Locks are acquired in **increasing rank** and released in reverse. That is
//! the whole rule, and `Ranked` enforces it at runtime rather than leaving it as
//! a comment somebody will contradict at 2am.
//!
//! ## Why sleeping mutexes are *outer* and spinlocks are *inner*
//!
//! It reads backwards until you see what it encodes:
//!
//! > **Never take a sleeping mutex while holding a spinlock.**
//!
//! Ranks run mutexes-before-spinlocks, so "acquire in increasing rank" makes
//! that rule free -- a mutex acquisition with any spinlock held is a rank
//! inversion and panics. The consequence is the constraint worth internalising:
//! **no filesystem or device I/O may ever be initiated from handler context**,
//! because handler context is where the spinlocks live.
//!
//! ## Why `console` is the innermost leaf
//!
//! So that anything -- including code inside `kheap` or `rq` -- can log. In
//! exchange the allocator must never log at a rank at or above its own, and the
//! panic and HardFault paths use `try_lock` and print regardless: a garbled
//! panic beats a hung one.

const std = @import("std");

const spinlock = @import("spinlock.zig");
const percpu = @import("percpu.zig");

const SpinLock = spinlock.SpinLock;
const IrqState = spinlock.IrqState;
const reservation_granule = spinlock.reservation_granule_bytes;

const log = std.log.scoped(.lockdep);

/// Every lock in the kernel, in acquisition order.
///
/// The numbers are the plan's and are deliberately sparse: inserting a lock
/// between two existing ones must not renumber the others, because the ordering
/// is the contract and a renumber silently rewrites it.
pub const Rank = enum(u8) {
    /// Transitional. One recursive spinlock at every kernel entry, so core 1
    /// can be launched (phase 6) with the whole existing smoke suite running on
    /// two cores while FatFs, SDIO, the loader and the mount tree stay trivially
    /// safe. Peeled away one subsystem per change in phase 8, then deleted.
    bkl = 5,
    /// `modules.zig` + `loader.zig` tables, and the image load itself.
    ///
    /// **Rank 8, not the 40 the plan's table first gave it.** The loader reads
    /// the executable *through the VFS*, so holding it across a load takes
    /// `mount` (10), `fs` (20) and `dev` (30) underneath -- which at rank 40
    /// would be an inversion on every single exec. It also cannot be the
    /// `spin_irq` the table specified: an image load is milliseconds, against a
    /// ~93 us console budget.
    ///
    /// So: a sleeping mutex, outermost of the real locks. That matches the
    /// plan's own intent for v1 -- "don't run the dynamic loader concurrently"
    /// -- by serialising the whole load rather than just the tables, which is
    /// also the only way to close `get_shared_data`'s check-then-act.
    loader = 8,
    /// The `MountPoints` tree.
    mount = 10,
    /// Per-filesystem. FatFs, littlefs, romfs, ramfs, procfs, driverfs.
    fs = 20,
    /// Per-device seek/DMA state: `g_sdio`, `aligned_buf`, the FatFs line cache.
    dev = 30,
    /// Process table, parent/child links, wait lists, `Semaphore.counter`.
    proctable = 50,
    /// Per-process `_fds`.
    fd = 55,
    /// Per-core runqueue and `Thread.state` transitions.
    runqueue = 60,
    /// `_pid_map`.
    pidmap = 70,
    /// `ProcessMemoryPool`.
    pagepool = 80,
    /// newlib's free list + `malloc.zig` accounting + `_sbrk`.
    kheap = 90,
    /// `stdout.zig`, UART TX, the `file_log` ring.
    console = 95,
};

const ranks = std.enums.values(Rank);

/// Bit position of `rank` in the held-set. Not the enum value -- that is sparse
/// on purpose (see `Rank`), and a bitmask wants a dense index.
fn bit(comptime rank: Rank) u16 {
    inline for (ranks, 0..) |candidate, index| {
        if (candidate == rank) return @as(u16, 1) << @intCast(index);
    }
    unreachable;
}

/// Every rank at or above `rank`, i.e. the set that must be empty before it may
/// be acquired. "At", not "above": two locks of the same rank taken together is
/// a deadlock waiting for a second core, since nothing orders the two holders.
fn bits_at_or_above(comptime rank: Rank) u16 {
    comptime var mask: u16 = 0;
    inline for (ranks) |candidate| {
        if (@intFromEnum(candidate) >= @intFromEnum(rank)) mask |= bit(candidate);
    }
    return mask;
}

/// Whether the hierarchy is checked at runtime. Debug and ReleaseSafe.
pub const checked = std.debug.runtime_safety;

/// Ranks currently held, per core. Per-CPU and not atomic: a core only ever
/// reads and writes its own, always with interrupts masked by the lock it is
/// taking.
var held: percpu.PerCpu(u16) = .init(0);

/// The ranks this core currently holds, as a bitmask. Diagnostics.
pub fn held_ranks() u16 {
    return held.current().*;
}

/// Drop this core's held-set. Test support and core bring-up only.
pub fn reset() void {
    held.current().* = 0;
}

/// `enter` for locks implemented outside this file (the sleeping mutex).
pub fn enter_rank(comptime rank: Rank) void {
    enter(rank);
}

/// Record a rank as held without checking the order -- for `try_lock`, which
/// cannot deadlock because it never waits.
pub fn enter_rank_untracked(comptime rank: Rank) void {
    if (comptime !checked) return;
    held.current().* |= comptime bit(rank);
}

/// `leave` for locks implemented outside this file.
pub fn leave_rank(comptime rank: Rank) void {
    leave(rank);
}

fn enter(comptime rank: Rank) void {
    if (comptime !checked) return;
    const slot = held.current();
    const offenders = slot.* & comptime bits_at_or_above(rank);
    if (offenders != 0) {
        log.err(
            "lock order violation: taking {s} (rank {d}) while holding ranks 0x{x}",
            .{ @tagName(rank), @intFromEnum(rank), offenders },
        );
        @panic("lock order violation -- see docs/smp_plan.md for the hierarchy");
    }
    slot.* |= comptime bit(rank);
}

fn leave(comptime rank: Rank) void {
    if (comptime !checked) return;
    const slot = held.current();
    if ((slot.* & comptime bit(rank)) == 0) {
        log.err("releasing {s} (rank {d}), which this core does not hold", .{
            @tagName(rank), @intFromEnum(rank),
        });
        @panic("lock release without a matching acquire");
    }
    slot.* &= ~(comptime bit(rank));
}

/// A spinlock that knows where it sits in the hierarchy.
///
/// Use the `_irqsave` pair unless you can prove no interrupt handler on this
/// core reaches this lock -- see `spinlock.zig`.
pub fn Ranked(comptime rank: Rank) type {
    return struct {
        // Aligned to the reservation granule, which also rounds `@sizeOf` up to
        // a multiple of it -- so two named locks declared next to each other can
        // never share a granule. Without that, core A's `strex` on one lock
        // clears core B's reservation on the other: not a correctness bug (the
        // loop retries) but an unbounded-retry throughput cliff that is very
        // hard to attribute back to a declaration order.
        //
        // Carried by the *ranked* types rather than applied at each use site, so
        // it cannot be forgotten. The bare `SpinLock` stays small on purpose:
        // per-file and per-process locks would pay 32 bytes each for a hazard
        // they will never see.
        inner: SpinLock align(reservation_granule) = .{},

        const Self = @This();
        pub const lock_rank = rank;

        pub fn lock_irqsave(self: *Self) IrqState {
            // Order matters: the hierarchy is checked *before* the acquire, so a
            // violation is reported at the offending call rather than after it
            // has already deadlocked against the lock it should not be taking.
            enter(rank);
            return self.inner.lock_irqsave();
        }

        pub fn unlock_irqrestore(self: *Self, flags: IrqState) void {
            leave(rank);
            self.inner.unlock_irqrestore(flags);
        }

        /// Acquire without masking interrupts.
        ///
        /// The exception, and there is exactly one legitimate user: the console
        /// (rank 95). It is held across a blocking per-byte UART write --
        /// milliseconds -- so masking interrupts for it would blow the ~93 us
        /// RX-FIFO budget the console itself is trying to meet. It excludes the
        /// other core; same-core handlers use `try_lock_no_irq` and write
        /// regardless.
        ///
        /// Safe only for a lock no interrupt handler on this core ever *waits*
        /// on. Anything else wants `lock_irqsave`, or it deadlocks the first
        /// time a handler lands on a core that holds it.
        pub fn lock_no_irq(self: *Self) void {
            enter(rank);
            self.inner.lock();
        }

        pub fn unlock_no_irq(self: *Self) void {
            leave(rank);
            self.inner.unlock();
        }

        /// `lock_no_irq` that gives up rather than waiting. Returns whether it
        /// was acquired.
        pub fn try_lock_no_irq(self: *Self) bool {
            if (!self.inner.try_lock()) return false;
            if (comptime checked) held.current().* |= comptime bit(rank);
            return true;
        }

        pub fn try_lock_irqsave(self: *Self) ?IrqState {
            // No hierarchy check: a try-lock that fails takes nothing, and one
            // that succeeds cannot deadlock -- it never waits. This is what lets
            // the panic and HardFault paths grab the console at any rank.
            const flags = self.inner.try_lock_irqsave() orelse return null;
            if (comptime checked) held.current().* |= comptime bit(rank);
            return flags;
        }

        pub fn is_locked(self: *const Self) bool {
            return self.inner.is_locked();
        }

        pub fn held_by_current(self: *const Self) bool {
            return self.inner.held_by_current();
        }

        /// Assert the caller holds this lock.
        ///
        /// Goes at the head of every function that mutates the structure this
        /// lock guards. It catches the bug review cannot: a function that is
        /// correct only because *some* caller was believed to hold the lock, and
        /// one caller does not.
        pub fn assert_held(self: *const Self) void {
            self.inner.assert_held();
        }
    };
}

/// A spinlock the holder may take again.
///
/// There are exactly two of these and there must never be a third, because a
/// lock you can take twice is a lock whose invariants you cannot state:
///
///   * the **BKL** (`.bkl`), which is transitional and gets deleted in phase 8;
///   * the **kernel heap** (`.kheap`), where recursion is not a design choice
///     but newlib's API: `realloc` takes `__malloc_lock` and then calls the
///     also-locking `_malloc_r` / `_free_r`. (The plan used to claim the BKL
///     was the only recursive lock in the system. It was wrong; this is why.)
pub fn RecursiveRanked(comptime rank: Rank) type {
    return struct {
        inner: SpinLock align(reservation_granule) = .{},
        /// Nesting depth. Only ever touched by the holder, under the lock.
        depth: u32 = 0,
        /// Interrupt state captured by the outermost acquire.
        outer_flags: IrqState = 0,

        const Self = @This();
        pub const lock_rank = rank;

        pub fn lock_irqsave(self: *Self) void {
            if (self.inner.held_by_current()) {
                self.depth += 1;
                return;
            }
            const flags = self.inner.lock_irqsave();
            self.outer_flags = flags;
            self.depth = 1;
            // Only the outermost acquire enters the rank; a re-entry would
            // otherwise trip the "same rank already held" check against itself.
            if (comptime checked) held.current().* |= comptime bit(rank);
        }

        pub fn unlock_irqrestore(self: *Self) void {
            if (self.depth == 0) @panic("recursive lock released without being held");
            self.depth -= 1;
            if (self.depth != 0) return;
            if (comptime checked) held.current().* &= ~(comptime bit(rank));
            const flags = self.outer_flags;
            self.outer_flags = 0;
            self.inner.unlock_irqrestore(flags);
        }

        pub fn held_by_current(self: *const Self) bool {
            return self.inner.held_by_current();
        }

        pub fn nesting(self: *const Self) u32 {
            return self.depth;
        }
    };
}

/// The big kernel lock.
///
/// Taken at every kernel entry -- both SVC paths, PendSV, SysTick, device IRQs.
/// With it in place core 1 can be launched and the entire existing smoke suite
/// runs on two cores while every subsystem underneath stays trivially safe, and
/// then subsystems are peeled out from under it one at a time. Converting every
/// subsystem *and* bringing up core 1 in one change is how this project fails.
///
/// Aliased distinctly so it stays greppable and deletable.
pub const RecursiveSpinLock = RecursiveRanked(.bkl);

const testing = std.testing;

test "Sync.Locks.NamedLocksDoNotShareAReservationGranule" {
    // The property: two locks declared adjacently must be at least a granule
    // apart, or each one's release steals the other's in-flight acquire.
    try testing.expectEqual(0, @sizeOf(Ranked(.fs)) % reservation_granule);
    try testing.expectEqual(reservation_granule, @alignOf(Ranked(.fs)));
    try testing.expectEqual(reservation_granule, @alignOf(RecursiveRanked(.kheap)));

    var pair: [2]Ranked(.dev) = .{ .{}, .{} };
    const first = @intFromPtr(&pair[0].inner);
    const second = @intFromPtr(&pair[1].inner);
    try testing.expect(second - first >= reservation_granule);

    // And the bare SpinLock stays small -- it is what per-file and per-process
    // locks are made of.
    try testing.expect(@sizeOf(SpinLock) < reservation_granule);
}

test "Sync.Locks.RanksAreOrderedAndDense" {
    // The bit index is positional, so the enum's declaration order *is* the
    // hierarchy. A reordering that left the numbers alone would silently
    // reverse two locks.
    var previous: u8 = 0;
    for (ranks) |rank| {
        try testing.expect(@intFromEnum(rank) > previous);
        previous = @intFromEnum(rank);
    }
    try testing.expect(ranks.len <= 16); // held-set is a u16
}

test "Sync.Locks.IncreasingRankIsAllowed" {
    reset();
    defer reset();

    var outer = Ranked(.mount){};
    var inner = Ranked(.kheap){};

    const a = outer.lock_irqsave();
    const b = inner.lock_irqsave();
    try testing.expect(outer.held_by_current());
    try testing.expect(inner.held_by_current());
    inner.unlock_irqrestore(b);
    outer.unlock_irqrestore(a);

    try testing.expectEqual(@as(u16, 0), held_ranks());
}

test "Sync.Locks.HeldSetTracksAcquireAndRelease" {
    reset();
    defer reset();

    var pool = Ranked(.pagepool){};
    try testing.expectEqual(@as(u16, 0), held_ranks());

    const flags = pool.lock_irqsave();
    try testing.expect(held_ranks() != 0);
    pool.unlock_irqrestore(flags);
    try testing.expectEqual(@as(u16, 0), held_ranks());
}

test "Sync.Locks.TryLockSkipsTheOrderCheckButStillTracks" {
    // A try-lock cannot deadlock -- it never waits -- which is what lets a
    // HardFault handler grab the console while holding anything at all.
    reset();
    defer reset();

    var console = Ranked(.console){};
    var mount = Ranked(.mount){};

    const c = console.lock_irqsave();
    // mount is an *outer* rank, so this would be a violation for a blocking
    // acquire. As a try-lock it is permitted.
    const m = mount.try_lock_irqsave();
    try testing.expect(m != null);
    mount.unlock_irqrestore(m.?);
    console.unlock_irqrestore(c);
    try testing.expectEqual(@as(u16, 0), held_ranks());
}

test "Sync.Locks.BklNestsAndOnlyReleasesAtDepthZero" {
    reset();
    defer reset();

    var bkl = RecursiveSpinLock{};
    try testing.expectEqual(@as(u32, 0), bkl.nesting());

    bkl.lock_irqsave();
    try testing.expect(bkl.held_by_current());
    try testing.expectEqual(@as(u32, 1), bkl.nesting());

    // The property that makes it usable at every kernel entry: an SVC handler
    // that re-enters through a path which also takes it must not self-deadlock.
    bkl.lock_irqsave();
    try testing.expectEqual(@as(u32, 2), bkl.nesting());

    bkl.unlock_irqrestore();
    try testing.expect(bkl.held_by_current());
    bkl.unlock_irqrestore();
    try testing.expect(!bkl.held_by_current());
    try testing.expectEqual(@as(u16, 0), held_ranks());
}

test "Sync.Locks.BklIsReleasedByOtherCoresSeeingItFree" {
    reset();
    defer reset();

    var bkl = RecursiveSpinLock{};
    bkl.lock_irqsave();
    bkl.lock_irqsave();
    bkl.unlock_irqrestore();
    // Still held at depth 1 -- another core must not see it free yet.
    try testing.expect(bkl.inner.is_locked());
    bkl.unlock_irqrestore();
    try testing.expect(!bkl.inner.is_locked());
}
