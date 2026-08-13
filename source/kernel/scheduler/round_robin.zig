//
// round_robin.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//

const std = @import("std");

const kernel = @import("../kernel.zig");
const Process = kernel.process.Process;

const percpu = kernel.sync.percpu;
const Node = std.DoublyLinkedList.Node;

pub const RoundRobin = struct {
    const Self = @This();

    pub const Name = "RoundRobin";

    /// Where one core is in the process list. Per-core: a shared `current`/`next`
    /// pair does not merely schedule badly -- one core's store into `next`
    /// overwrites the other's, and both resume whichever process won the race.
    const Cursor = struct {
        /// What this core is running. Also the round-robin position: the scan
        /// starts from the node after it.
        current: ?*Node = null,
        /// What this core has claimed and not yet switched to. Claimed means
        /// `state == Running` already -- see `try_claim`.
        next: ?*Node = null,
    };

    cursors: percpu.PerCpu(Cursor),

    pub fn init() RoundRobin {
        return RoundRobin{
            .cursors = .init(.{}),
        };
    }

    /// Take ownership of a process for the calling core -- the claim-once point.
    ///
    /// A plain test-and-store rather than a CAS: every caller reaches it through
    /// `ProcessManager.schedule_next`, which holds `proctable_lock` across the
    /// whole scan. A CAS would be weaker, and would suggest the surrounding walk
    /// is safe unlocked, which it is not -- it reads `node.next` while the other
    /// core may be inserting.
    ///
    /// `Ready` is not by itself proof that nobody owns the process, which is why
    /// the cursor test is part of the claim. See `claimed_by_any_core`.
    fn try_claim(self: *Self, node: *Node) bool {
        const process: *Process = @alignCast(@fieldParentPtr("node", node));
        if (process.state != Process.State.Ready) return false;
        if (self.claimed_by_any_core(node)) return false;
        process.state = Process.State.Running;
        process.set_core(@intCast(percpu.current_core()));
        return true;
    }

    /// Whether any core's cursor still stands on this node.
    ///
    /// The state alone cannot answer this. `Running`-is-sticky in
    /// `Process.reevaluate_state` closes the `Running -> Ready` route into a
    /// claimed process, but not the one round through `Blocked`: a process that
    /// blocks itself is `Blocked` while its core still owns it (the cursor is
    /// released in `update_current`, after the context is stored), so a waker on
    /// the other core publishes it `Ready` and that core resumes it from a stack
    /// pointer nobody has written yet. Both then run off the same stack.
    ///
    /// The cursors are the authority because they track ownership rather than
    /// runnability, and are cleared in exactly one place. Not a livelock risk:
    /// the owning core releases the node on its next switch, and a core with
    /// nothing to run switches to its idle process.
    fn claimed_by_any_core(self: *Self, node: *const Node) bool {
        for (0..percpu.core_count) |core| {
            const cursor = self.cursors.of(core);
            if (cursor.current == node or cursor.next == node) return true;
        }
        return false;
    }

    /// Whether the outgoing context has to be saved before the switch. A process
    /// that was never switched in has a freshly prepared frame, and storing over
    /// it would destroy the entry point it is waiting to be resumed at -- which
    /// is also how `exec` hands a reinitialised process to the switch path.
    fn action_for(cursor: *const Cursor) kernel.scheduler.Action {
        if (cursor.current) |current_node| {
            const current_process: *Process = @alignCast(@fieldParentPtr("node", current_node));
            if (current_process.is_initialized()) {
                return .StoreAndSwitch;
            }
        }
        return .Switch;
    }

    /// One lap of the list from just after this core's position, claiming the
    /// first `Ready` process found.
    fn claim_next_ready(self: *Self, cursor: *const Cursor, first_node: *Node) ?*Node {
        var it: ?*Node = if (cursor.current) |current| current.next else first_node;
        while (it) |node| : (it = node.next) {
            if (self.try_claim(node)) return node;
        }

        // Wrap. The lap ends at this core's own position: reaching it means
        // nothing else was runnable, and the process already running here is
        // not a candidate for being switched to.
        it = first_node;
        while (it) |node| : (it = node.next) {
            if (node == cursor.current) break;
            if (self.try_claim(node)) return node;
        }
        return null;
    }

    pub fn schedule_next(self: *Self, first_node: *Node) kernel.scheduler.Action {
        const cursor = self.cursors.current();

        // A pick that has not been consumed yet -- `set_next` forces one for the
        // vfork and exec hand-offs. It is claimed already, so it stands.
        if (cursor.next != null) return action_for(cursor);

        cursor.next = self.claim_next_ready(cursor, first_node) orelse return .NoAction;
        return action_for(cursor);
    }

    /// Forget a process that is leaving the table. Every core's cursor, not just
    /// the caller's: a terminated process may be the other core's `current` or
    /// `next`, and a dangling node there is a walk into freed memory.
    pub fn remove_process(self: *Self, node: *Node) void {
        for (0..percpu.core_count) |core| {
            const cursor = self.cursors.of(core);
            if (cursor.current == node) {
                cursor.current = null;
            }
            if (cursor.next == node) {
                cursor.next = null;
            }
        }
    }

    /// Claim a named process for this core, leaving the switch to be completed
    /// later by PendSV. The scheduler's idle fallback; the claim is the same one
    /// `try_claim` makes, since an unclaimed forced pick is as stealable as an
    /// unclaimed scanned one.
    pub fn claim(self: *Self, node: *Node) kernel.scheduler.Action {
        const cursor = self.cursors.current();
        const process: *Process = @alignCast(@fieldParentPtr("node", node));
        process.state = Process.State.Running;
        process.set_core(@intCast(percpu.current_core()));
        cursor.next = node;
        return action_for(cursor);
    }

    /// Whether any core is on this node, or about to be -- what makes the
    /// terminate-list reaper safe on two cores. The cursors are the authority
    /// because they are updated in `update_current` at the same moment as
    /// `ProcessManager.core`, and unlike that array they are null-initialised on
    /// every core from boot. Same predicate the claim uses; see
    /// `claimed_by_any_core`.
    pub fn is_claimed_by_any_core(self: *Self, node: *const Node) bool {
        return self.claimed_by_any_core(node);
    }

    /// Force a specific process to run next on this core, and switch to it now.
    ///
    /// The vfork/exec/exit hand-offs, which do their own switching in assembly
    /// rather than going through PendSV.
    pub fn set_next(self: *Self, next: ?*Node) void {
        if (next) |node| {
            _ = self.claim(node);
        } else {
            self.cursors.current().next = null;
        }
        self.update_current();
    }

    pub fn get_current(self: *const Self) ?*Process {
        if (self.cursors.current_const().current) |node| {
            return @alignCast(@fieldParentPtr("node", node));
        }
        return null;
    }

    pub fn get_next(self: *Self) ?*Process {
        const cursor = self.cursors.current();
        if (cursor.next) |node| {
            if (cursor.current) |current_node| {
                if (current_node == node) {
                    return null;
                }
            }
            return @alignCast(@fieldParentPtr("node", node));
        }
        return null;
    }

    /// Complete the switch: release the outgoing process and adopt the claimed
    /// one. Called from `process_set_next_task`, after
    /// `arch_store_registers_on_stack` has written the outgoing stack pointer --
    /// which is what makes `release_from_core` safe here, since the process
    /// becomes claimable only once there is a valid context to resume from.
    pub fn update_current(self: *Self) void {
        const cursor = self.cursors.current();
        // Nothing was picked, so nothing is being switched away from either.
        // Releasing `current` here would publish a process as `Ready` while it
        // carries on running on this core.
        const next = cursor.next orelse return;

        if (cursor.current) |current_node| {
            const process: *Process = @alignCast(@fieldParentPtr("node", current_node));
            // Detach the sleeping-mutex ranks before the process stops being
            // this core's: they describe what *it* holds, and it may well come
            // back on the other core. See `locks.migrating_ranks`.
            process._held_lock_ranks = kernel.sync.locks.take_migrating_ranks();
            process.release_from_core();
        }

        const process: *Process = @alignCast(@fieldParentPtr("node", next));
        kernel.sync.locks.restore_migrating_ranks(process._held_lock_ranks);
        process._initialized = true;
        cursor.current = next;
        cursor.next = null;
    }
};

test "RoundRobin.ShouldInitialize" {
    var scheduler = RoundRobin.init();
    // Every core, not just this one: a cursor that starts life pointing at a
    // stale node would be walked by the first `schedule_next` on that core.
    for (0..percpu.core_count) |core| {
        try std.testing.expectEqual(@as(?*Node, null), scheduler.cursors.of(core).current);
        try std.testing.expectEqual(@as(?*Node, null), scheduler.cursors.of(core).next);
    }
}

fn entry() void {}
const ProcessMemoryPool = @import("../memory/heap/process_memory_pool.zig").ProcessMemoryPool;
const test_arg: i32 = 0;
const c = @import("libc_imports").c;

fn create_process(pid: c.pid_t, cwd: []const u8, pool: *ProcessMemoryPool) !*Process {
    return try Process.init(std.testing.allocator, 4096, &entry, &test_arg, cwd, pool, null, pid, false);
}

test "RoundRobin.ShouldScheduleFirstReadyProcess" {
    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};
    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;

    list.append(&process1.node);

    const action = scheduler.schedule_next(list.first.?);
    try std.testing.expectEqual(kernel.scheduler.Action.Switch, action);
    try std.testing.expect(scheduler.cursors.current().next == &process1.node);
    // Claimed as part of the pick, not later: this is what stops the other core
    // from also finding it Ready.
    try std.testing.expectEqual(Process.State.Running, process1.state);
}

test "RoundRobin.ShouldScheduleNextReadyProcess" {
    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};

    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;

    var process2 = try create_process(2, "/proc/2", &pool);
    defer process2.deinit();
    process2.state = .Ready;

    var process3 = try create_process(2, "/proc/2", &pool);
    defer process3.deinit();
    process3.state = .Ready;

    list.append(&process1.node);
    list.append(&process2.node);
    list.append(&process3.node);

    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process1);
    scheduler.update_current();
    var current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process1, current.?);
    try std.testing.expectEqual(.StoreAndSwitch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process2);
    scheduler.update_current();
    current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process2, current.?);
    try std.testing.expectEqual(.StoreAndSwitch, scheduler.schedule_next(list.first.?));
    try std.testing.expectEqual(.StoreAndSwitch, scheduler.schedule_next(list.first.?));

    try std.testing.expect(scheduler.get_next() == process3);
    scheduler.update_current();
    current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process3, current.?);
    // if current process not initialized then just a swithc
    try std.testing.expectEqual(.StoreAndSwitch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process1);
    scheduler.update_current();
    current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process1, current.?);
    process2.state = .Blocked;
    try std.testing.expectEqual(.StoreAndSwitch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process3);

    list.remove(&process2.node);
    scheduler.remove_process(&process2.node);

    scheduler.update_current();
    current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process3, current.?);

    list.remove(&process1.node);
    scheduler.remove_process(&process1.node);

    try std.testing.expectEqual(.NoAction, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == null);

    scheduler.update_current();
    current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process3, current.?);
}

test "RoundRobin.NoActionWhenOthersBlocked" {
    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};

    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;

    var process2 = try create_process(2, "/proc/2", &pool);
    defer process2.deinit();
    process2.state = .Blocked;

    var process3 = try create_process(2, "/proc/2", &pool);
    defer process3.deinit();
    process3.state = .Blocked;

    list.append(&process1.node);
    list.append(&process2.node);
    list.append(&process3.node);

    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process1);
    scheduler.update_current();
    var current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process1, current.?);

    try std.testing.expectEqual(.NoAction, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == null);
    scheduler.update_current();
    current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process1, current.?);
}

test "RoundRobin.ClaimsAProcessForExactlyOneCore" {
    // With the claim outside the scan, both cores pass the `state == Ready` test
    // on the same node and both return it as their `next`.
    if (percpu.core_count < 2) return error.SkipZigTest;

    const Cpu = @import("hal").CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};
    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;
    list.append(&process1.node);

    Cpu.set_coreid(0);
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process1);

    // The only Ready process in the table is spoken for, so the second core has
    // to come away with nothing rather than with the same one.
    Cpu.set_coreid(1);
    try std.testing.expectEqual(.NoAction, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == null);
    try std.testing.expectEqual(@as(u8, 0), process1.current_core);
}

test "RoundRobin.TwoCoresRunDifferentProcesses" {
    if (percpu.core_count < 2) return error.SkipZigTest;

    const Cpu = @import("hal").CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};
    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;
    var process2 = try create_process(2, "/proc/2", &pool);
    defer process2.deinit();
    process2.state = .Ready;
    list.append(&process1.node);
    list.append(&process2.node);

    Cpu.set_coreid(0);
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    scheduler.update_current();

    Cpu.set_coreid(1);
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    scheduler.update_current();

    // Distinct processes, each recording the core that owns it, and each core's
    // cursor holding its own -- the cursors are what a single shared pair used
    // to overwrite.
    try std.testing.expect(scheduler.cursors.of(0).current == &process1.node);
    try std.testing.expect(scheduler.cursors.of(1).current == &process2.node);
    try std.testing.expectEqual(Process.State.Running, process1.state);
    try std.testing.expectEqual(Process.State.Running, process2.state);
    try std.testing.expectEqual(@as(u8, 0), process1.current_core);
    try std.testing.expectEqual(@as(u8, 1), process2.current_core);

    // Nothing left over for either core to steal.
    try std.testing.expectEqual(.NoAction, scheduler.schedule_next(list.first.?));
    Cpu.set_coreid(0);
    try std.testing.expectEqual(.NoAction, scheduler.schedule_next(list.first.?));
}

test "RoundRobin.WakingARunningProcessDoesNotMakeItStealable" {
    // `reevaluate_state` is called on *other* processes by every waker in the
    // tree. If it demoted a running process to Ready, the other core would claim
    // a context that is executing right now on this one.
    if (percpu.core_count < 2) return error.SkipZigTest;

    const Cpu = @import("hal").CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};
    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;
    list.append(&process1.node);

    Cpu.set_coreid(0);
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    scheduler.update_current();
    try std.testing.expectEqual(Process.State.Running, process1.state);

    // What a waker on the other core does.
    process1.reevaluate_state();
    try std.testing.expectEqual(Process.State.Running, process1.state);

    Cpu.set_coreid(1);
    try std.testing.expectEqual(.NoAction, scheduler.schedule_next(list.first.?));

    // The switch is the only thing that moves a core's cursor off a node.
    // `release_from_core` alone would leave the state saying `Ready` and the
    // cursor saying otherwise; `update_current` does both.
    var process2 = try create_process(2, "/proc/2", &pool);
    defer process2.deinit();
    process2.state = .Ready;
    list.append(&process2.node);

    Cpu.set_coreid(0);
    try std.testing.expectEqual(.StoreAndSwitch, scheduler.schedule_next(list.first.?));
    scheduler.update_current();
    try std.testing.expectEqual(Process.State.Ready, process1.state);
    Cpu.set_coreid(1);
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process1);
}

test "RoundRobin.WakingABlockedProcessDoesNotStealItFromItsCore" {
    // A process that blocks itself is `Blocked`, not `Running`, so the sticky
    // test in `reevaluate_state` does not cover it -- but its core still owns it
    // until the switch that stores its context.
    if (percpu.core_count < 2) return error.SkipZigTest;

    const Cpu = @import("hal").CpuStub;
    const restore = Cpu.coreid();
    defer Cpu.set_coreid(@intCast(restore));

    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};
    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;
    // Nothing else runnable, so `.NoAction` below can only mean core 1 declined
    // to take pid 1.
    var process2 = try create_process(2, "/proc/2", &pool);
    defer process2.deinit();
    process2.state = .Blocked;
    list.append(&process1.node);
    list.append(&process2.node);

    Cpu.set_coreid(0);
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    scheduler.update_current();
    try std.testing.expect(scheduler.cursors.of(0).current == &process1.node);

    // Inside a syscall on core 0: pid 1 blocks itself on an empty pipe. Its
    // context is not stored -- core 0 has not reached PendSV.
    process1.state = .Blocked;

    // The pipe's writer, on core 1, drains the wait list and re-evaluates.
    // Nothing left to wait on and the state is `Blocked`, so pid 1 is published
    // `Ready` while core 0 is still executing it.
    process1.reevaluate_state();
    try std.testing.expectEqual(Process.State.Ready, process1.state);

    // The fix. This used to return `.Switch` with pid 1 as core 1's `next`.
    Cpu.set_coreid(1);
    try std.testing.expectEqual(.NoAction, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == null);
    try std.testing.expectEqual(@as(u8, 0), process1.current_core);

    // Once core 0 switches away -- which is where the context gets stored -- it
    // is core 1's to take.
    Cpu.set_coreid(0);
    process2.state = .Ready;
    try std.testing.expectEqual(.StoreAndSwitch, scheduler.schedule_next(list.first.?));
    scheduler.update_current();
    Cpu.set_coreid(1);
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process1);
}

test "RoundRobin.ShouldForceProcessOnDemand" {
    var scheduler = RoundRobin.init();

    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    var list = std.DoublyLinkedList{};

    var process1 = try create_process(1, "/proc/1", &pool);
    defer process1.deinit();
    process1.state = .Ready;

    var process2 = try create_process(2, "/proc/2", &pool);
    defer process2.deinit();
    process2.state = .Ready;

    var process3 = try create_process(2, "/proc/2", &pool);
    defer process3.deinit();
    process3.state = .Ready;

    list.append(&process1.node);
    list.append(&process2.node);
    list.append(&process3.node);

    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    try std.testing.expect(scheduler.get_next() == process1);
    scheduler.update_current();
    var current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process1, current.?);
    process1._initialized = false;
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));
    try std.testing.expectEqual(.Switch, scheduler.schedule_next(list.first.?));

    try std.testing.expect(scheduler.get_next() == process2);
    scheduler.update_current();
    current = scheduler.get_current();
    try std.testing.expect(current != null);
    try std.testing.expectEqual(process2, current.?);

    scheduler.set_next(&process1.node);
    try std.testing.expect(scheduler.get_current() == process1);
    scheduler.set_next(null);
    try std.testing.expect(scheduler.get_current() == process1);
    try std.testing.expect(scheduler.get_next() == null);
    scheduler.cursors.current().current = null;
    try std.testing.expectEqual(null, scheduler.get_current());
}
