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

// The lock hierarchy. Locks are acquired in increasing rank and released in
// reverse; `Ranked` enforces it at runtime. Ranks run mutexes-before-spinlocks,
// so "never take a sleeping mutex while holding a spinlock" falls out of the
// ordering, which also means no filesystem or device I/O from handler context.
// `console` is the innermost leaf so anything can log.

const std = @import("std");

const arch = @import("arch");
const hal = @import("hal");
const spinlock = @import("spinlock.zig");
const percpu = @import("percpu.zig");
const preempt = @import("preempt.zig");

const SpinLock = spinlock.SpinLock;
const IrqState = spinlock.IrqState;
const reservation_granule = spinlock.reservation_granule_bytes;

const log = std.log.scoped(.lockdep);

/// Every lock in the kernel, in acquisition order. The numbers are sparse so a
/// new lock can be inserted without renumbering -- the ordering is the contract.
pub const Rank = enum(u8) {
    /// Transitional big kernel lock, taken at every kernel entry. Peeled away
    /// one subsystem at a time, then deleted.
    bkl = 5,
    /// `modules.zig` + `loader.zig` tables, and the image load itself. A
    /// sleeping mutex outside `mount`/`fs`/`dev`, because the loader reads the
    /// executable through the VFS.
    loader = 8,
    /// The `MountPoints` tree.
    mount = 10,
    /// Per-filesystem. FatFs, littlefs, romfs, ramfs, procfs, driverfs.
    fs = 20,
    /// Per-device seek/DMA state: `g_sdio`, `aligned_buf`, the FatFs line cache.
    dev = 30,
    /// The SD/SDIO controller, for one whole transfer. Below `dev` so a caller
    /// holding `dev` may take it, while `/dev/mmc` (which holds nothing) is
    /// still excluded. A sleeping mutex: a multi-block transfer is milliseconds,
    /// far past the ~93 us console RX-FIFO budget.
    sdio = 35,
    /// One `Pipe`'s ring buffer and its open-end counts. Below `proctable`,
    /// because a pipe wakes waiters by walking the process table afterwards.
    pipe = 40,
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

/// Bit position of `rank` in the held-set -- a dense index, not the sparse enum
/// value.
fn bit(comptime rank: Rank) u16 {
    inline for (ranks, 0..) |candidate, index| {
        if (candidate == rank) return @as(u16, 1) << @intCast(index);
    }
    unreachable;
}

/// Every rank at or above `rank`: the set that must be empty before it may be
/// acquired. "At" too, since nothing orders two holders of the same rank.
fn bits_at_or_above(comptime rank: Rank) u16 {
    comptime var mask: u16 = 0;
    inline for (ranks) |candidate| {
        if (@intFromEnum(candidate) >= @intFromEnum(rank)) mask |= bit(candidate);
    }
    return mask;
}

/// Whether the hierarchy is checked at runtime. Debug and ReleaseSafe.
pub const checked = std.debug.runtime_safety;

const core_count = percpu.core_count;

/// Ranks currently held, per core. Not atomic: a core only touches its own,
/// always with interrupts masked by the lock it is taking.
var held: percpu.PerCpu(u16) = .init(0);

/// The ranks this core holds, as a bitmask. Diagnostics only; always zero when
/// `checked` is false, which means "unknown" rather than "none".
pub fn held_ranks() u16 {
    return held.current().*;
}

/// `rank`'s position in the held-set. Only ever set when `checked`.
pub fn rank_bit(comptime rank: Rank) u16 {
    return comptime bit(rank);
}

/// The guarantee the `_no_irq` entry points below need and cannot provide for
/// themselves. They record the rank -- and take a spinlock whose owner token is
/// `coreid()` -- with interrupts on, so a PendSV that migrates the caller
/// mid-acquire strands both on the core it left. Masking is what `lock_irqsave`
/// does and is exactly what these cannot do, so the caller owes it instead:
/// handler context, or preemption already disabled. `stdout.zig` pays it with
/// `preempt_disable`, one line before the acquire -- which is easy to miss when
/// reading the acquire alone, hence an assertion rather than a comment.
fn assert_unpreemptible(comptime what: []const u8) void {
    if (comptime !checked) return;
    // A handler runs to completion on the core that took it.
    if (arch.sync.in_handler_mode()) return;
    if (preempt.preempt_disabled()) return;
    // No `log.err` line first, unlike every other check in this file. This one
    // can fire from inside the console's own section, where the console lock is
    // already held -- logging would re-enter `console_acquire`, hit
    // `SpinLock.lock` with this core's token already in it, and report
    // "recursive acquisition" instead of the real problem. Everything the
    // reader needs is comptime-known, so it all goes in the panic string.
    @panic(what ++ " from preemptible thread context -- an unmasked acquire records the rank, and takes an owner token that is coreid(), only safely if the caller cannot migrate mid-acquire; disable preemption across it, as stdout.zig's console_acquire does");
}

/// Drop this core's held-set. Test support and core bring-up only.
pub fn reset() void {
    held.current().* = 0;
}

/// Ranks that belong to a thread rather than to a core: the sleeping mutexes,
/// whose holder may block and resume on the other core. These bits travel with
/// the process across a switch -- see `RoundRobin.update_current`. Every other
/// rank is a spin_irq, held with interrupts masked, so it cannot migrate.
pub const migrating_ranks: u16 =
    bit(.loader) | bit(.mount) | bit(.fs) | bit(.dev) | bit(.sdio);

/// Detach the migrating ranks from this core, for storing on the process being
/// switched away from. Leaves the spin ranks, which belong to the core.
pub fn take_migrating_ranks() u16 {
    if (comptime !checked) return 0;
    const slot = held.current();
    const taken = slot.* & migrating_ranks;
    slot.* &= ~migrating_ranks;
    return taken;
}

/// Reattach the migrating ranks of the process being switched to.
pub fn restore_migrating_ranks(mask: u16) void {
    if (comptime !checked) return;
    const slot = held.current();
    slot.* = (slot.* & ~migrating_ranks) | (mask & migrating_ranks);
}

/// `enter` for locks implemented outside this file (the sleeping mutex).
///
/// Masks interrupts across the update, which the spin ranks get for free from
/// `Ranked.lock_irqsave`. A sleeping mutex records its rank with interrupts on,
/// and the held-set is per-core: `enter` reads `coreid()`, derives the slot
/// address, then read-modify-writes it. A PendSV anywhere in that window
/// migrates the caller, and the store lands in the slot of the core it left --
/// so the rank is stranded there while `leave` on the new core finds nothing
/// held and panics "releasing <rank>, which this core does not hold". Masking
/// makes the whole read-modify-write atomic against the switch, after which the
/// bit is either fully recorded (and travels correctly via
/// `take_migrating_ranks`) or not recorded at all.
pub fn enter_rank(comptime rank: Rank) void {
    if (comptime !checked) return;
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
    enter(rank);
}

/// Record a rank as held without checking the order -- for `try_lock`, which
/// cannot deadlock because it never waits. No masking of its own: the only
/// caller runs under the mutex's guard spinlock, which already holds them off.
pub fn enter_rank_untracked(comptime rank: Rank) void {
    if (comptime !checked) return;
    held.current().* |= comptime bit(rank);
}

/// `leave` for locks implemented outside this file. Masked for the same reason
/// as `enter_rank` -- the clear must not land on the core the caller left.
pub fn leave_rank(comptime rank: Rank) void {
    if (comptime !checked) return;
    const flags = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(flags);
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

/// A spinlock that knows where it sits in the hierarchy. Use the `_irqsave`
/// pair unless no interrupt handler on this core can reach the lock.
pub fn Ranked(comptime rank: Rank) type {
    return struct {
        // Granule-aligned so two adjacent named locks never share a reservation
        // granule and steal each other's in-flight acquires.
        inner: SpinLock align(reservation_granule) = .{},

        const Self = @This();
        pub const lock_rank = rank;

        pub fn lock_irqsave(self: *Self) IrqState {
            // Mask first, then record the rank: recording first leaves a window
            // in which a PendSV can migrate the caller, stranding a per-core
            // rank bit on the core it left. The order check still runs before
            // the acquire, so a violation is reported at the offending call.
            const flags = arch.sync.save_and_disable_interrupts();
            enter(rank);
            self.inner.lock();
            return flags;
        }

        pub fn unlock_irqrestore(self: *Self, flags: IrqState) void {
            leave(rank);
            self.inner.unlock_irqrestore(flags);
        }

        /// Acquire without masking interrupts. The only legitimate user is the
        /// console (rank 95), held across a blocking per-byte UART write that
        /// would otherwise blow its own ~93 us RX-FIFO budget. Safe only for a
        /// lock no interrupt handler on this core ever waits on.
        ///
        /// The caller must additionally be unpreemptible -- see
        /// `assert_unpreemptible`, which is why this is a checked precondition
        /// and not just a comment.
        pub fn lock_no_irq(self: *Self) void {
            assert_unpreemptible("lock_no_irq");
            // Rank recorded after the acquire, since this cannot mask first.
            // That gives up the pre-acquire order check, which costs nothing at
            // rank 95 -- the innermost leaf has nothing to invert against.
            self.inner.lock();
            if (comptime checked) held.current().* |= comptime bit(rank);
        }

        /// Preemption must still be off here, not re-enabled first: the clear
        /// and the spinlock release are exposed exactly as the acquire was.
        pub fn unlock_no_irq(self: *Self) void {
            assert_unpreemptible("unlock_no_irq");
            leave(rank);
            self.inner.unlock();
        }

        /// `lock_no_irq` that gives up rather than waiting. Returns whether it
        /// was acquired. Same caller contract: not waiting removes the deadlock,
        /// not the migration window around the bookkeeping.
        pub fn try_lock_no_irq(self: *Self) bool {
            assert_unpreemptible("try_lock_no_irq");
            if (!self.inner.try_lock()) return false;
            if (comptime checked) held.current().* |= comptime bit(rank);
            return true;
        }

        pub fn try_lock_irqsave(self: *Self) ?IrqState {
            // No hierarchy check: a try-lock never waits, so it cannot deadlock.
            // That is what lets the fault paths grab the console at any rank.
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
        pub fn assert_held(self: *const Self) void {
            self.inner.assert_held();
        }
    };
}

/// A spinlock the holder may take again. There are exactly two: the BKL, which
/// is transitional, and the kernel heap, where newlib's API forces it --
/// `realloc` takes `__malloc_lock` and then calls the also-locking `_malloc_r`.
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

/// The big kernel lock, taken at every kernel entry -- both SVC paths, PendSV,
/// SysTick, device IRQs. Aliased distinctly so it stays greppable and deletable.
pub const RecursiveSpinLock = RecursiveRanked(.bkl);

const testing = std.testing;

test "Sync.Locks.NamedLocksDoNotShareAReservationGranule" {
    try testing.expectEqual(0, @sizeOf(Ranked(.fs)) % reservation_granule);
    try testing.expectEqual(reservation_granule, @alignOf(Ranked(.fs)));
    try testing.expectEqual(reservation_granule, @alignOf(RecursiveRanked(.kheap)));

    var pair: [2]Ranked(.dev) = .{ .{}, .{} };
    const first = @intFromPtr(&pair[0].inner);
    const second = @intFromPtr(&pair[1].inner);
    try testing.expect(second - first >= reservation_granule);

    // The bare SpinLock stays small.
    try testing.expect(@sizeOf(SpinLock) < reservation_granule);
}

test "Sync.Locks.RanksAreOrderedAndDense" {
    // The bit index is positional, so declaration order is the hierarchy.
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
    // The acquire is real in every build; only the bookkeeping is conditional.
    try testing.expect(pool.held_by_current());
    try testing.expectEqual(if (checked) rank_bit(.pagepool) else 0, held_ranks());
    pool.unlock_irqrestore(flags);
    try testing.expectEqual(@as(u16, 0), held_ranks());
}

test "Sync.Locks.ASleepingRankTravelsToTheCoreTheHolderResumesOn" {
    // The contract `enter_rank`/`leave_rank` mask interrupts to protect: a
    // sleeping-mutex rank is recorded against a core, so the only way it may be
    // released on a different one is the explicit hand-off through the process.
    // Nothing else may move it -- least of all a half-finished update landing in
    // the slot of the core the holder just left.
    if (comptime core_count < 2) return error.SkipZigTest;
    const Cpu = hal.CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    Cpu.set_coreid(0);
    reset();
    Cpu.set_coreid(1);
    reset();
    defer {
        Cpu.set_coreid(0);
        reset();
        Cpu.set_coreid(1);
        reset();
    }

    Cpu.set_coreid(0);
    enter_rank(.mount);
    try testing.expectEqual(if (checked) rank_bit(.mount) else 0, held_ranks());

    // Switching away hands the rank to the process...
    const carried = take_migrating_ranks();
    try testing.expectEqual(if (checked) rank_bit(.mount) else 0, carried);
    try testing.expectEqual(@as(u16, 0), held_ranks());

    // ...which resumes on the other core, and only then may release it.
    Cpu.set_coreid(1);
    try testing.expectEqual(@as(u16, 0), held_ranks());
    restore_migrating_ranks(carried);
    try testing.expectEqual(if (checked) rank_bit(.mount) else 0, held_ranks());
    leave_rank(.mount);
    try testing.expectEqual(@as(u16, 0), held_ranks());

    // The core it left keeps nothing behind: a bit stranded there is what makes
    // the next `leave` on it report a release with no matching acquire.
    Cpu.set_coreid(0);
    try testing.expectEqual(@as(u16, 0), held_ranks());
}

test "Sync.Locks.NoIrqAcquireNeedsAnUnpreemptibleCaller" {
    reset();
    defer reset();

    var console = Ranked(.console){};

    // The legal shape, and the only one in the tree: `stdout.zig` disables
    // preemption, acquires, releases, then re-enables -- the clear lands before
    // a switch can become possible again, which is why `console` is correctly
    // absent from `migrating_ranks`. The illegal shape panics in
    // `assert_unpreemptible` and a unit test cannot catch that; what this does
    // catch is a future caller reordering the enable ahead of the release.
    //
    // Against the count on entry rather than zero: the shared test binary
    // reaches here with a `preempt_disable` leaked by an earlier case, and the
    // property wanted here is only that the pair below is balanced.
    const refused_on_entry = preempt.preempt_disabled();

    preempt.preempt_disable();
    console.lock_no_irq();
    try testing.expectEqual(if (checked) rank_bit(.console) else 0, held_ranks());
    console.unlock_no_irq();
    try testing.expectEqual(@as(u16, 0), held_ranks());
    preempt.preempt_enable();
    try testing.expectEqual(refused_on_entry, preempt.preempt_disabled());
}

test "Sync.Locks.TryLockSkipsTheOrderCheckButStillTracks" {
    reset();
    defer reset();

    var console = Ranked(.console){};
    var mount = Ranked(.mount){};

    const c = console.lock_irqsave();
    // An outer rank: a violation for a blocking acquire, permitted for a try.
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

    // Re-entry through a path that also takes it must not self-deadlock.
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
