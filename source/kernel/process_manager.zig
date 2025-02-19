//
// process_manager.zig
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

const RoundRobinScheduler = @import("round_robin.zig").RoundRobin;
const process = @import("process.zig");
const Process = process.Process;

pub const ProcessManager = struct {
    pub const ContainerType = std.DoublyLinkedList(Process);
    pub const ProcessType = Process;
    const Self = @This();

    processes: ContainerType,
    scheduler: RoundRobinScheduler(Self),

    pub fn create() Self {
        return Self{
            .processes = .{},
            .scheduler = .{},
        };
    }

    pub fn set_scheduler(self: *Self, scheduler: RoundRobinScheduler(Self)) void {
        self.scheduler = scheduler;
    }

    pub fn create_process(self: *Self, allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, args: anytype) !void {
        var node = try allocator.create(ContainerType.Node);
        node.data = try Process.create(allocator, stack_size, process_entry, args);
        return self.processes.append(node);
    }

    pub fn delete_process(self: *Self, pid: u32) void {
        for (self.processes) |p| {
            if (p.data.pid == pid) {
                const allocator = p.data.allocator;
                p.data.deinit();
                self.processes.remove(p);
                allocator.destroy(p);
                break;
            }
        }
    }

    pub fn dump_processes(self: Self, out_stream: anytype) void {
        var it = self.processes.first;
        out_stream.print("  PID     STATE      PRIO     STACK    CPU  \n", .{});
        while (it) |node| : (it = node.next) {
            out_stream.print("{d: >5}     {s: <8}   {d: <4}  {d}/{d} B   {d}\n", .{
                node.data.pid,
                std.enums.tagName(Process.State, node.data.state) orelse "?",
                node.data.priority,
                node.data.stack_usage(),
                node.data.stack.len,
                node.data.current_core,
            });
        }
    }

    // This must take asking core into consideration since, more than one processes are going in the parallel
    pub fn get_current_process(self: Self) ?*Process {
        return self.scheduler.get_current();
    }

    pub fn initialize_context_switching(_: Self) void {
        process.initialize_context_switching();
    }
};

pub var instance = ProcessManager.create();

// C interface for context switching assembly code

export fn get_next_task() *const u8 {
    if (instance.scheduler.get_next()) |task| {
        instance.scheduler.update_current();
        return task.stack_pointer();
    }

    @panic("Context switch called without tasks available");
}

export fn update_stack_pointer(ptr: *const u8) void {
    if (instance.scheduler.get_current()) |task| {
        task.set_stack_pointer(ptr);
    }
}
