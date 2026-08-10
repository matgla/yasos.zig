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

//! The kernel's sleeping mutex.
//!
//! A contender **blocks and yields** instead of spinning, which is the whole
//! point: this is the lock for things held across filesystem and device I/O,
//! where spinning with interrupts masked for milliseconds would blow the ~93 µs
//! UART RX-FIFO budget documented in `hal/.../uart_driver.zig:51-59` and starve
//! the console at 3 Mbaud.
//!
//! It is the primitive phases 3(B), 4 and 5 were all waiting on. Ranks 20 (`fs`)
//! and 30 (`dev`) are sleeping mutexes for exactly this reason, and that is why
//! they sit *outside* every spinlock in the hierarchy.
//!
//! ## Two rules it enforces rather than documents
//!
//!   * **No blocking in handler context.** Blocking from an exception handler
//!     would deschedule whatever the handler interrupted -- not the handler --
//!     in the middle of an interrupt that then never returns.
//!     `arch.sync.in_handler_mode()` makes that a panic, on the blocking path
//!     only: an *uncontended* acquire from a handler blocks nothing, and this
//!     kernel resumes its main task from inside the SVCall handler, so the
//!     entire shutdown sequence legitimately runs with IPSR non-zero.
//!   * **Not recursive.** A second acquire by the owner would block on itself
//!     forever; it panics instead.
//!   * **No blocking with preemption disabled.** The yield needs a reschedule to
//!     return from, and `do_context_switch` refuses to switch while preemption
//!     is off -- so it would spin against a holder that can never run. Both of
//!     these fire only on the *blocking* path, so an uncontended acquire from
//!     either context stays legal.
//!
//! ## How it blocks
//!
//! It reuses the machinery the semaphore already proved: `Process.block_on`
//! marks the caller blocked on the mutex's own address, and `reevaluate_state`
//! keeps it out of the scheduler until an unlock scans the process list and
//! wakes it. The scan is O(processes), which is a handful, and it is the same
//! shape as `KernelSemaphore.release`.
//!
//! Unlock wakes **every** waiter and lets them re-contend rather than handing
//! the lock to one of them. A handoff would be fewer wake-ups, but it also has
//! to be undone whenever the chosen waiter dies first; with a wait queue this
//! short the retry loop is the cheaper correctness.

const std = @import("std");

const arch = @import("arch");
const hal = @import("hal");

const locks = @import("locks.zig");
const spinlock = @import("spinlock.zig");

const preempt = @import("preempt.zig");
const process_manager = @import("../process_manager.zig");
const Process = @import("../process.zig").Process;

/// A sleeping mutex at a fixed point in the lock hierarchy.
pub fn RankedMutex(comptime rank: locks.Rank) type {
    return struct {
        /// Guards `held` and `owner` only, for the few instructions either is
        /// touched. Never held across the yield.
        /// Granule-aligned for the same reason as `locks.Ranked`: adjacent
        /// named locks must not share an exclusive reservation.
        guard: spinlock.SpinLock align(spinlock.reservation_granule_bytes) = .{},
        held: bool = false,
        /// The holder, or null when the mutex was taken before the scheduler
        /// existed -- see `current_process` below. Only meaningful while `held`.
        owner: ?*Process = null,

        const Self = @This();
        pub const lock_rank = rank;

        /// The process that would own an acquire made right now, or null during
        /// boot.
        ///
        /// The kernel mounts filesystems in `main()` before any process is
        /// scheduled, so this lock is genuinely taken with no current process.
        /// That is safe without further thought -- boot is single-threaded, so
        /// the mutex cannot be contended there -- but it does mean `owner` may
        /// legitimately be null while `held` is true, which is why the two are
        /// separate fields rather than `owner: ?*Process` alone.
        fn current_process() ?*Process {
            if (!process_manager.is_initialized()) return null;
            return process_manager.instance.get_current_process();
        }

        pub fn lock(self: *Self) void {
            const me = current_process();
            locks.enter_rank(rank);

            while (true) {
                const blocked = blk: {
                    const flags = self.guard.lock_irqsave();
                    defer self.guard.unlock_irqrestore(flags);

                    if (!self.held) {
                        self.held = true;
                        self.owner = me;
                        break :blk false;
                    }
                    if (me != null and self.owner == me) {
                        // Either a genuine recursive acquire, or an exception
                        // handler that interrupted the holder and reached for
                        // the same lock. Both deadlock, and on one core they
                        // are indistinguishable from here.
                        @panic("sleeping mutex already held by this process -- recursive acquire, or a handler that interrupted the holder");
                    }
                    // The check belongs *here*, on the blocking path, not at the
                    // top of `lock`.
                    //
                    // What is forbidden from an exception handler is **blocking**:
                    // it would deschedule whatever the handler interrupted, and
                    // the handler would never return. Merely taking an
                    // uncontended mutex from handler context blocks nothing and
                    // is harmless -- which matters, because this kernel resumes
                    // its main task from *inside* the SVCall handler
                    // (`switch_to_main_task` ends in `pop {r0, pc}`, a plain
                    // return, not an exception return). The whole shutdown
                    // sequence -- unmounting filesystems, flushing the card --
                    // therefore runs with IPSR non-zero, and rejecting it at the
                    // door panicked the board after every otherwise-green run.
                    if (arch.sync.in_handler_mode()) {
                        @panic("sleeping mutex would block in an exception handler -- no filesystem or device I/O may be initiated from handler context");
                    }
                    // Blocking needs a reschedule to ever come back, and with
                    // preemption disabled `do_context_switch` refuses to switch
                    // -- so the yield below would spin forever against a holder
                    // that can never be scheduled to release.
                    //
                    // This is reachable today, on one core: `sys_read` releases
                    // its `block_context_switch` window *before* touching the
                    // file, so it can hold `fs_lock` while preemptible, while
                    // `sys_open` holds its window *across* the filesystem call.
                    // B parked holding the lock plus A contending with
                    // preemption off is a hang, and a very narrow one -- 4543
                    // hardware tests did not hit it.
                    //
                    // The real fix is phase 3(B): those syscalls should be
                    // holding a named lock, not refusing to be preempted. Until
                    // then this makes the failure a named panic instead of a
                    // dead board.
                    if (preempt.preempt_disabled()) {
                        @panic("sleeping mutex would block with preemption disabled -- the yield could never run; the caller is holding a block_context_switch window across filesystem or device I/O");
                    }
                    if (me) |process| {
                        // Marked blocked *under the guard*, so an unlock racing
                        // with this cannot scan the process list, decide there
                        // is nobody to wake, and leave us asleep forever.
                        process.block_on(self);
                        break :blk true;
                    }
                    // Contended with no current process: impossible, boot is
                    // single-threaded, and there would be nothing to yield to.
                    @panic("sleeping mutex contended before the scheduler exists");
                };

                if (!blocked) return;

                // Yield until somebody wakes us. Interrupts are enabled again
                // here -- this is the part a spinlock cannot do.
                //
                // The condition is "still blocked **on this mutex**", not "still
                // blocked". `Process.state` has two independent sources:
                // `waiting_for` (what this mutex sets) and `_blocked_by` (the
                // wait-for-a-child list that `waitpid` and `vfork` use), and
                // `reevaluate_state` reports Blocked if *either* is live. So a
                // process that is waiting on a child and then contends for this
                // lock would be woken by `unlock`, find itself still Blocked on
                // the other account, and spin here forever -- never returning to
                // take the lock it was just handed.
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
                self.held = false;
                self.owner = null;
                self.wake_waiters();
            }
            locks.leave_rank(rank);
        }

        /// Take the mutex only if it is free. Never blocks, so it is safe from
        /// anywhere -- including a fault handler that wants to look at a
        /// structure without risking a hang.
        pub fn try_lock(self: *Self) bool {
            const flags = self.guard.lock_irqsave();
            defer self.guard.unlock_irqrestore(flags);
            if (self.held) return false;
            self.held = true;
            self.owner = current_process();
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

        /// Assert the caller holds this mutex. Goes at the head of every
        /// function that touches the structure it guards.
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

    // A mutex is an *outer* rank, so a spinlock may be taken under it but not
    // the other way round -- that ordering is what encodes "never take a
    // sleeping mutex while holding a spinlock".
    var mutex = TestMutex{};
    var inner = locks.Ranked(.kheap){};

    mutex.lock();
    try testing.expect(locks.held_ranks() != 0);
    const flags = inner.lock_irqsave();
    inner.unlock_irqrestore(flags);
    mutex.unlock();
    try testing.expectEqual(@as(u16, 0), locks.held_ranks());
}

test "Sync.Mutex.BootContextTakesItWithoutAProcess" {
    locks.reset();
    defer locks.reset();

    // The kernel mounts filesystems before any process is scheduled, so this is
    // not a hypothetical path: `current_process()` is null and the mutex still
    // has to work.
    try testing.expect(!process_manager.is_initialized());

    var mutex = TestMutex{};
    mutex.lock();
    try testing.expect(mutex.is_locked());
    // With no process to compare against, "held by the caller" is the only
    // answer that can be given -- and boot is single-threaded, so it is right.
    try testing.expect(mutex.held_by_current());
    mutex.unlock();
    try testing.expect(!mutex.is_locked());
}

fn blocked_entry() void {}

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

    // Simulate the contender: mark the running process blocked on the mutex the
    // way `lock` would, without actually yielding (there is no second thread of
    // control in a unit test to run the holder).
    const waiter = process_manager.instance.get_current_process();
    waiter.block_on(&mutex);
    try testing.expectEqual(Process.State.Blocked, waiter.state);

    // The property under test: the unlock's scan finds it and makes it runnable
    // again. A missed wake-up here is a process that sleeps forever.
    mutex.unlock();
    try testing.expectEqual(Process.State.Ready, waiter.state);
    try testing.expect(!mutex.is_locked());
}
