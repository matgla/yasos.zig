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

pub fn RoundRobin(comptime ManagerType: anytype) type {
    return struct {
        const Self = @This();
        pub const Name = "RoundRobin";
        manager: *const ManagerType = undefined,
        current: ?*std.DoublyLinkedList.Node = null,
        next: ?*std.DoublyLinkedList.Node = null,

        pub fn schedule_next(self: *Self) bool {
            if (self.manager.processes.len() == 0) {
                return false;
            }

            if (self.current == null) {
                if (self.manager.processes.first) |node| {
                    const process: *kernel.process.Process = @fieldParentPtr("node", node);
                    process.set_core(@intCast(cpu.coreid()));
                }
                self.next = self.manager.processes.first;
                return true;
            }

            var next = self.current.?.next;

            while (next) |node| {
                // search for the next ready process
                const process: *Process = @fieldParentPtr("node", node);

                if (process.state == Process.State.Ready) {
                    process.set_core(@intCast(cpu.coreid()));
                    self.next = node;
                    return true;
                }

                next = node.next;
            }
            // if not found, try to search from beginning
            next = self.manager.processes.first;
            while (next) |node| {
                const process: *Process = @fieldParentPtr("node", node);

                if (node == self.current) {
                    // only already running process can be executed
                    return false;
                }
                // search for the next ready process
                if (process.state == Process.State.Ready) {
                    process.set_core(@intCast(cpu.coreid()));
                    self.next = node;
                    return true;
                }
                next = node.next;
            }
            return false;
        }

        pub fn get_current(self: Self) ?*Process {
            if (self.current) |node| {
                return @fieldParentPtr("node", node);
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
                return @fieldParentPtr("node", node);
            }
            return null;
        }

        pub fn update_current(self: *Self) void {
            if (self.current) |current| {
                const process: *Process = @fieldParentPtr("node", current);
                process.state = Process.State.Ready;
            }
            if (self.next) |next| {
                const process: *Process = @fieldParentPtr("node", next);
                process.state = Process.State.Running;
            }
            self.current = self.next;
        }
    };
}
