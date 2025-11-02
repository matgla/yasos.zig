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

const cpu = @import("hal").cpu;

pub const RoundRobin = struct {
    const Self = @This();

    pub const Name = "RoundRobin";
    current: ?*std.DoublyLinkedList.Node = null,
    next: ?*std.DoublyLinkedList.Node = null,

    pub fn init() RoundRobin {
        return RoundRobin{
            .current = null,
            .next = null,
        };
    }

    pub fn schedule_next(self: *Self, first_node: *std.DoublyLinkedList.Node) kernel.scheduler.Action {
        var next: ?*std.DoublyLinkedList.Node = first_node;
        if (self.current != null) {
            next = self.current.?.next;
        }

        if (self.next) |node| {
            const process: *Process = @alignCast(@fieldParentPtr("node", node));
            if (process.state == Process.State.Ready) {
                if (self.current) |current_node| {
                    const current_process: *Process = @alignCast(@fieldParentPtr("node", current_node));
                    if (current_process.is_initialized()) {
                        return .StoreAndSwitch;
                    }
                }
                return .Switch;
            }
        }

        while (next) |node| {
            // search for the next ready process
            const process: *Process = @alignCast(@fieldParentPtr("node", node));
            if (process.state == Process.State.Ready) {
                process.set_core(@intCast(cpu.coreid()));
                self.next = node;
                if (self.current) |current_node| {
                    const current_process: *Process = @alignCast(@fieldParentPtr("node", current_node));
                    if (current_process.is_initialized()) {
                        return .StoreAndSwitch;
                    }
                }
                return .Switch;
            }

            next = node.next;
        }
        // if not found, try to search from beginning
        next = first_node;
        while (next) |node| {
            const process: *Process = @alignCast(@fieldParentPtr("node", node));

            if (node == self.current) {
                // only already running process can be executed
                return .NoAction;
            }

            // search for the next ready process
            if (process.state == Process.State.Ready) {
                process.set_core(@intCast(cpu.coreid()));
                self.next = node;

                if (self.current) |current_node| {
                    const current_process: *Process = @alignCast(@fieldParentPtr("node", current_node));
                    if (current_process.is_initialized()) {
                        return .StoreAndSwitch;
                    }
                }
                return .Switch;
            }
            next = node.next;
        }
        return .NoAction;
    }

    pub fn remove_process(self: *Self, node: *std.DoublyLinkedList.Node) void {
        if (self.current == node) {
            self.current = null;
        }
        if (self.next == node) {
            self.next = null;
        }
    }

    pub fn set_next(self: *Self, next: ?*std.DoublyLinkedList.Node) void {
        self.next = next;
        self.update_current();
    }

    pub fn get_current(self: *const Self) ?*Process {
        if (self.current) |node| {
            return @alignCast(@fieldParentPtr("node", node));
        }
        return null;
    }

    pub fn get_next(self: Self) ?*Process {
        if (self.next) |node| {
            if (self.current) |current_node| {
                if (current_node == node) {
                    return null;
                }
            }
            return @alignCast(@fieldParentPtr("node", node));
        }
        return null;
    }

    pub fn update_current(self: *Self) void {
        if (self.current) |current| {
            const process: *Process = @alignCast(@fieldParentPtr("node", current));
            process.reevaluate_state();
        }

        if (self.next) |next| {
            const process: *Process = @alignCast(@fieldParentPtr("node", next));
            process.state = Process.State.Running;
            process._initialized = true;
            self.current = self.next;
            self.next = null;
        }
    }
};

test "RoundRobin.ShouldInitialize" {
    const scheduler = RoundRobin.init();
    try std.testing.expectEqual(@as(?*std.DoublyLinkedList.Node, null), scheduler.current);
    try std.testing.expectEqual(@as(?*std.DoublyLinkedList.Node, null), scheduler.next);
}

fn entry() void {}
const ProcessMemoryPool = @import("../memory/heap/process_memory_pool.zig").ProcessMemoryPool;
const test_arg: i32 = 0;
const c = @import("libc_imports").c;

fn create_process(pid: c.pid_t, cwd: []const u8, pool: *ProcessMemoryPool) !*Process {
    return try Process.init(std.testing.allocator, 4096, &entry, &test_arg, cwd, pool, null, pid);
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
    try std.testing.expect(scheduler.next == &process1.node);
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
    scheduler.current = null;
    try std.testing.expectEqual(null, scheduler.get_current());
}
