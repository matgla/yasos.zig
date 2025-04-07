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
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) Self {
        return Self{
            .processes = .{},
            .scheduler = .{},
            .allocator = allocator,
        };
    }

    pub fn set_scheduler(self: *Self, scheduler: RoundRobinScheduler(Self)) void {
        self.scheduler = scheduler;
    }

    pub fn create_process(self: *Self, stack_size: u32, process_entry: anytype, args: anytype) !void {
        var node = try self.allocator.create(ContainerType.Node);
        node.data = try Process.create(self.allocator, stack_size, process_entry, args);
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

    pub fn fork(self: *Self, lr: usize) i32 {
        var node = self.allocator.create(ContainerType.Node) catch {
            return -1;
        };
        const maybe_current_process = self.scheduler.get_current();
        if (maybe_current_process) |current_process| {
            node.data = current_process.clone(lr) catch {
                return -1;
            };

            // node.data.stack_position = context_switch_push_registers_to_stack(node.data.stack_position);
            self.processes.append(node);
            return @intCast(node.data.pid);
        }
        return -1;
    }

    pub fn waitpid(_: Self, _: i32, _: *i32) i32 {
        return -1;
    }

    // This must take asking core into consideration since, more than one processes are going in the parallel
    pub fn get_current_process(self: Self) ?*Process {
        return self.scheduler.get_current();
    }

    pub fn initialize_context_switching(_: Self) void {
        process.initialize_context_switching();
    }
};

extern fn context_switch_get_psp() usize;
extern fn context_switch_push_registers_to_stack(stack_pointer: *u8) *u8;

pub var instance: ProcessManager = undefined;

pub fn initialize_process_manager(allocator: std.mem.Allocator) void {
    instance = ProcessManager.create(allocator);
}

export fn get_next_task() *const u8 {
    if (instance.scheduler.get_next()) |task| {
        instance.scheduler.update_current();
        return task.stack_pointer();
    }

    @panic("Context switch called without tasks available");
}

export fn update_stack_pointer(ptr: *u8) void {
    if (instance.scheduler.get_current()) |task| {
        task.set_stack_pointer(ptr);
    }
}
