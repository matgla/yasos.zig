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
        pub const ActionType = enum {
            StoreAndSwitch,
            Switch,
            NoAction,
        };

        pub fn schedule_next(self: *Self) ActionType {
            if (self.manager.processes.len() == 0) {
                return .NoAction;
            }

            var next: ?*std.DoublyLinkedList.Node = self.manager.processes.first;
            if (self.current != null) {
                next = self.current.?.next;
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
            next = self.manager.processes.first;
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
            }
            self.current = self.next;
            self.next = null;
        }
    };
}
