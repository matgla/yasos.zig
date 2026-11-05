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

// The kernel's sleeping mutex: a contender blocks and yields instead of
// spinning, so it can be held across filesystem and device I/O. Not recursive,
// and the blocking path refuses handler context and preemption-disabled
// callers. Unlock wakes every waiter and lets them re-contend.

const std = @import("std");

const arch = @import("arch");
const hal = @import("hal");

const locks = @import("locks.zig");
const percpu = @import("percpu.zig");
const spinlock = @import("spinlock.zig");

const preempt = @import("preempt.zig");
const process_manager = @import("../process_manager.zig");
const Process = @import("../process.zig").Process;

/// A sleeping mutex at a fixed point in the lock hierarchy.
pub fn RankedMutex(comptime rank: locks.Rank) type {
    return struct {
        /// Guards `held` and `owner` only. Never held across the yield.
        guard: spinlock.SpinLock align(spinlock.reservation_granule_bytes) = .{},
        held: bool = false,
        /// The holder, or null when taken before the scheduler existed. Only
        /// meaningful while `held`, which is why the two are separate fields.
        owner: ?*Process = null,
        /// Stack a holder may need, for a lock over state that outlives the
        /// process: dying inside would leave it half updated for everyone, and
        /// on disk. A caller without this much is killed before taking the lock.
        /// Syscalls run on the process stack, so this is reachable from any of
        /// them. Zero for locks where that is not worth a kill.
        stack_needed: u16 = 0,
        /// This mutex on `owner`'s list of what it holds. See `release_held_by`.
        held_link: locks.HeldMutex = .{ .release = &release_for_dead_owner },

        const Self = @This();
        pub const lock_rank = rank;

        /// The process that would own an acquire made right now, or null during
        /// boot -- the kernel mounts filesystems before anything is scheduled.
        fn current_process() ?*Process {
            if (!process_manager.is_initialized()) return null;
            return process_manager.instance.try_current_process();
        }

        pub fn lock(self: *Self) void {
            if (self.stack_needed != 0) arch.sync.require_stack(self.stack_needed);
            const me = current_process();
            locks.enter_rank(rank);

            while (true) {
                const blocked = blk: {
                    const flags = self.guard.lock_irqsave();
                    defer self.guard.unlock_irqrestore(flags);

                    if (!self.held) {
                        self.take(me);
                        break :blk false;
                    }
                    if (me != null and self.owner == me) {
                        @panic("sleeping mutex already held by this process -- recursive acquire, or a handler that interrupted the holder");
                    }
                    // These two checks belong on the blocking path, not at the
                    // top of `lock`: an uncontended acquire from a handler
                    // blocks nothing, and the shutdown sequence legitimately
                    // runs with IPSR non-zero (the main task is resumed from
                    // inside the SVCall handler).
                    if (arch.sync.in_handler_mode()) {
                        @panic("sleeping mutex would block in an exception handler -- no filesystem or device I/O may be initiated from handler context");
                    }
                    // The yield needs a reschedule to return from, and
                    // `do_context_switch` refuses to switch while preemption is
                    // off -- so this would spin against a holder that can never
                    // run.
                    if (preempt.preempt_disabled()) {
                        @panic("sleeping mutex would block with preemption disabled -- the yield could never run; the caller is holding a block_context_switch window across filesystem or device I/O");
                    }
                    if (me) |process| {
                        // Marked blocked under the guard, so a racing unlock
                        // cannot decide there is nobody to wake.
                        process.block_on(self);
                        break :blk true;
                    }
                    @panic("sleeping mutex contended before the scheduler exists");
                };

                if (!blocked) return;

                // Yield until somebody wakes us, with interrupts enabled. The
                // condition is "still blocked on this mutex", not "still
                // blocked": `reevaluate_state` also reports Blocked for a
                // pending `waitpid`, which would spin here forever.
                const process = me.?;
                while (process.is_blocked_on(self)) {
                    hal.irq.trigger(.pendsv);
                    process.reevaluate_state();
                }
            }
        }

        pub fn unlock(self: *Self) void {
            const me = current_process();
            {
                const flags = self.guard.lock_irqsave();
                defer self.guard.unlock_irqrestore(flags);

                if (!self.held) @panic("sleeping mutex released without being held");
                if (me != null and self.owner != null and self.owner != me) {
                    @panic("sleeping mutex released by a process that does not hold it");
                }
                self.give_up();
            }
            locks.leave_rank(rank);
        }

        /// Caller holds `guard`.
        fn take(self: *Self, me: ?*Process) void {
            self.held = true;
            self.owner = me;
            if (me) |process| {
                self.held_link.next = process._held_mutexes;
                process._held_mutexes = &self.held_link;
            }
        }

        /// Caller holds `guard`.
        fn give_up(self: *Self) void {
            if (self.owner) |process| {
                var link = &process._held_mutexes;
                while (link.*) |entry| : (link = &entry.next) {
                    if (entry == &self.held_link) {
                        link.* = entry.next;
                        break;
                    }
                }
            }
            self.held = false;
            self.owner = null;
            self.wake_waiters();
        }

        /// `HeldMutex.release`. The rank goes with `forget_sleeping_ranks`, which
        /// also covers the mutexes this thread was still waiting for.
        fn release_for_dead_owner(link: *locks.HeldMutex) void {
            const self: *Self = @alignCast(@fieldParentPtr("held_link", link));
            const flags = self.guard.lock_irqsave();
            defer self.guard.unlock_irqrestore(flags);
            self.give_up();
        }

        /// Take the mutex only if it is free. Never blocks, so it is safe from
        /// anywhere, including a fault handler.
        pub fn try_lock(self: *Self) bool {
            const flags = self.guard.lock_irqsave();
            defer self.guard.unlock_irqrestore(flags);
            if (self.held) return false;
            self.take(current_process());
            locks.enter_rank_untracked(rank);
            return true;
        }

        pub fn is_locked(self: *const Self) bool {
            return self.held;
        }

        pub fn held_by_current(self: *const Self) bool {
            if (!self.held) return false;
            const me = current_process();
            if (me == null or self.owner == null) return true;
            return self.owner == me;
        }

        /// Assert the caller holds this mutex.
        pub fn assert_held(self: *const Self) void {
            if (!locks.checked) return;
            if (!self.held_by_current()) {
                @panic("sleeping mutex: expected to be held by the caller here");
            }
        }

        /// Wake every process blocked on this mutex. Caller holds `guard`.
        fn wake_waiters(self: *Self) void {
            if (!process_manager.is_initialized()) return;
            var next = process_manager.instance.processes.first;
            while (next) |node| {
                const process: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                process.wake_from(self);
            }
        }
    };
}

/// Release everything `process` holds, for a thread that will never reach its
/// `unlock`s: it was killed inside a syscall and resumes at `_exit` on a fresh
/// frame. What those locks protected may be half updated, which is the price of
/// keeping the rest of the system up; a lock nobody releases is a certain hang.
/// Safe from a fault handler, since nothing here blocks. The caller has
/// established that this core holds no spinlock, so no guard can be ours.
pub fn release_held_by(process: *Process) void {
    while (process._held_mutexes) |link| link.release(link);
    process.waiting_for = null;
    process.reevaluate_state();
    locks.forget_sleeping_ranks();
}

const testing = std.testing;

const TestMutex = RankedMutex(.fs);

test "Sync.Mutex.UncontendedAcquireAndRelease" {
    locks.reset();
    defer locks.reset();

    var mutex = TestMutex{};
    try testing.expect(!mutex.is_locked());

    mutex.lock();
    try testing.expect(mutex.is_locked());
    try testing.expect(mutex.held_by_current());
    mutex.assert_held();

    mutex.unlock();
    try testing.expect(!mutex.is_locked());
}

test "Sync.Mutex.TryLockRefusesWhileHeld" {
    locks.reset();
    defer locks.reset();

    var mutex = TestMutex{};
    try testing.expect(mutex.try_lock());
    try testing.expect(!mutex.try_lock());
    mutex.unlock();
    try testing.expect(mutex.try_lock());
    mutex.unlock();
}

test "Sync.Mutex.ParticipatesInTheLockHierarchy" {
    locks.reset();
    defer locks.reset();

    // A mutex is an outer rank, so a spinlock may be taken under it but not the
    // other way round.
    var mutex = TestMutex{};
    var inner = locks.Ranked(.kheap){};

    mutex.lock();
    try testing.expect(mutex.held_by_current());
    try testing.expectEqual(
        if (locks.checked) locks.rank_bit(TestMutex.lock_rank) else 0,
        locks.held_ranks(),
    );
    const flags = inner.lock_irqsave();
    inner.unlock_irqrestore(flags);
    mutex.unlock();
    try testing.expectEqual(@as(locks.HeldSet, 0), locks.held_ranks());
}

test "Sync.Mutex.ADeadProcessGivesUpEverythingItHeld" {
    locks.reset();
    defer locks.reset();
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    defer hal.irq.impl().clear();
    var arg: usize = 0;
    try process_manager.instance.create_process(1024, &blocked_entry, &arg, "holder");
    _ = process_manager.instance.schedule_next();
    _ = process_manager.process_set_next_task();
    const process = process_manager.instance.get_current_process();

    var outer = RankedMutex(.mount){};
    var inner = TestMutex{};
    outer.lock();
    inner.lock();
    try testing.expect(process._held_mutexes != null);

    // Never reaches its unlocks: killed inside the syscall.
    release_held_by(process);
    try testing.expect(!outer.is_locked());
    try testing.expect(!inner.is_locked());
    try testing.expect(process._held_mutexes == null);
    try testing.expectEqual(@as(locks.HeldSet, 0), locks.held_ranks());

    // The next process in can take them, in order, without lockdep objecting.
    outer.lock();
    inner.lock();
    inner.unlock();
    outer.unlock();
}

test "Sync.Mutex.HeldListSurvivesReleaseOutOfOrder" {
    locks.reset();
    defer locks.reset();
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    defer hal.irq.impl().clear();
    var arg: usize = 0;
    try process_manager.instance.create_process(1024, &blocked_entry, &arg, "holder");
    _ = process_manager.instance.schedule_next();
    _ = process_manager.process_set_next_task();
    const process = process_manager.instance.get_current_process();

    var first = RankedMutex(.mount){};
    var second = TestMutex{};
    first.lock();
    second.lock();
    first.unlock();
    try testing.expect(process._held_mutexes == &second.held_link);
    second.unlock();
    try testing.expect(process._held_mutexes == null);
}

test "Sync.Mutex.BootContextTakesItWithoutAProcess" {
    locks.reset();
    defer locks.reset();

    // The kernel mounts filesystems before any process is scheduled.
    try testing.expect(!process_manager.is_initialized());

    var mutex = TestMutex{};
    mutex.lock();
    try testing.expect(mutex.is_locked());
    // With no process to compare against, "held by the caller" is the only
    // answer available, and boot is single-threaded, so it is right.
    try testing.expect(mutex.held_by_current());
    mutex.unlock();
    try testing.expect(!mutex.is_locked());
}

test "Sync.Mutex.BootWithAManagerButNothingScheduledHasNoOwner" {
    locks.reset();
    defer locks.reset();

    // main() creates the process manager and then mounts: the manager exists, but
    // no core has a process yet. The board faulted here, reading the held list
    // through whatever an unset core slot contained. An unset slot reads as zero
    // on the host, so what is pinned is the answer the mutex relies on.
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    try testing.expect(process_manager.instance.try_current_process() == null);

    var mutex = TestMutex{};
    mutex.lock();
    try testing.expect(mutex.is_locked());
    try testing.expect(mutex.owner == null);
    try testing.expect(mutex.held_by_current());
    mutex.unlock();
    try testing.expect(!mutex.is_locked());
}

fn blocked_entry() void {}

/// The first process in the table that is not `exclude`. The same traversal
/// `wake_waiters` uses, for a test that needs two distinct process identities.
fn other_than(exclude: *Process) *Process {
    var next = process_manager.instance.processes.first;
    while (next) |node| : (next = node.next) {
        const process: *Process = @alignCast(@fieldParentPtr("node", node));
        if (process != exclude) return process;
    }
    unreachable;
}

test "Sync.Mutex.OwnershipFollowsTheProcessAcrossACoreMigration" {
    // The owner is a process, not a core: a holder that blocks and resumes on
    // the other core still passes `assert_held` and is still the one allowed to
    // release. What breaks that in practice is not the comparison but the read
    // behind it -- `get_current_process()` is `core[coreid()]`, two separate
    // instructions, and a PendSV between them answers with the process running
    // on the core the caller just left. A wrong answer in `lock` stores the
    // wrong `owner`; a wrong answer in `unlock` or `assert_held` fails against
    // the right one; the board reports either as one of this file's two panics.
    //
    // `arch/ut` masking is a no-op and there is no PendSV to land in that
    // window, so this pins the contract, not the race -- board smoke stays the
    // gate for that. It does catch the wrong repair: keying ownership on the
    // core id instead of the process.
    if (comptime percpu.core_count < 2) return error.SkipZigTest;

    const Cpu = hal.CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    for (0..percpu.core_count) |core| {
        Cpu.set_coreid(@intCast(core));
        locks.reset();
    }
    defer for (0..percpu.core_count) |core| {
        Cpu.set_coreid(@intCast(core));
        locks.reset();
    };

    Cpu.set_coreid(0);
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    defer hal.irq.impl().clear();

    var arg: usize = 0;
    try process_manager.instance.create_process(1024, &blocked_entry, &arg, "holder");
    try process_manager.instance.create_process(1024, &blocked_entry, &arg, "other");
    _ = process_manager.instance.schedule_next();
    _ = process_manager.process_set_next_task();

    const holder = process_manager.instance.get_current_process();
    const other = other_than(holder);

    var mutex = TestMutex{};
    mutex.lock();
    try testing.expect(mutex.held_by_current());

    // Switching away hands the rank to the process; the scheduler half of that
    // is covered in locks.zig. Here it only has to be in place so the release
    // on the other core has something to clear.
    const carried = locks.take_migrating_ranks();

    // Resumed on the other core: its slot names the same process, so nothing
    // about the mutex has changed.
    Cpu.set_coreid(1);
    process_manager.instance.core[1] = holder;
    locks.restore_migrating_ranks(carried);
    try testing.expect(mutex.held_by_current());
    mutex.assert_held();

    // And it really is the process that decides. Put a different one in this
    // core's slot -- which is exactly what a torn read returns -- and the mutex
    // says it is not held by the caller, the answer behind both panics.
    process_manager.instance.core[1] = other;
    try testing.expect(!mutex.held_by_current());

    process_manager.instance.core[1] = holder;
    mutex.unlock();
    try testing.expect(!mutex.is_locked());
}

test "Sync.Mutex.ContenderBlocksAndIsWokenByTheUnlock" {
    locks.reset();
    defer locks.reset();
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    defer hal.irq.impl().clear();

    var arg: usize = 0;
    try process_manager.instance.create_process(1024, &blocked_entry, &arg, "holder");
    try process_manager.instance.create_process(1024, &blocked_entry, &arg, "waiter");
    _ = process_manager.instance.schedule_next();
    _ = process_manager.process_set_next_task();

    var mutex = TestMutex{};
    mutex.lock();

    // Mark the running process blocked the way `lock` would, without yielding:
    // a unit test has no second thread of control to run the holder.
    const waiter = process_manager.instance.get_current_process();
    waiter.block_on(&mutex);
    try testing.expectEqual(Process.State.Blocked, waiter.state);

    mutex.unlock();
    try testing.expectEqual(Process.State.Ready, waiter.state);
    try testing.expect(!mutex.is_locked());
}
