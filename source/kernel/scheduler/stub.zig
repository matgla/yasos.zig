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

const std = @import("std");

const kernel = @import("../kernel.zig");

const Process = kernel.process.Process;

pub const StubScheduler = struct {
    pub const Name = "StubScheduler";
    current: ?*std.DoublyLinkedList.Node,
    next: ?*std.DoublyLinkedList.Node,

    const Self = @This();

    pub fn init() StubScheduler {
        return StubScheduler{
            .current = null,
            .next = null,
        };
    }

    pub fn get_next(self: Self) ?*Process {
        if (self.next == null) {
            return null;
        }
        return @fieldParentPtr("node", self.next.?);
    }

    pub fn set_next(self: *Self, process: *std.DoublyLinkedList.Node) void {
        self.next = process;
    }

    pub fn get_current(self: Self) ?*Process {
        if (self.current == null) {
            return null;
        }
        return @fieldParentPtr("node", self.current.?);
    }

    pub fn update_current(self: *Self) void {
        self.current = self.next;
        self.next = null;
    }

    pub fn schedule_next(self: *Self, first: *std.DoublyLinkedList.Node) kernel.scheduler.Action {
        self.next = first;
        if (self.current) |current| {
            if (current.next) |n| {
                self.next = n;
            }
        }
        return .StoreAndSwitch;
    }

    /// Part of the scheduler interface `ProcessManager` expects; see
    /// `RoundRobin.claim`. The stub keeps one cursor rather than one per core,
    /// which is all its callers (the host unit tests) need.
    pub fn claim(self: *Self, node: *std.DoublyLinkedList.Node) kernel.scheduler.Action {
        const process: *Process = @alignCast(@fieldParentPtr("node", node));
        process.state = Process.State.Running;
        self.next = node;
        return .StoreAndSwitch;
    }

    pub fn is_claimed_by_any_core(self: *Self, node: *const std.DoublyLinkedList.Node) bool {
        return self.current == node or self.next == node;
    }

    pub fn remove_process(self: *Self, process: *std.DoublyLinkedList.Node) void {
        if (self.current) |current| {
            if (current == process) {
                self.current = null;
            }
        }

        if (self.next) |next| {
            if (next == process) {
                self.next = null;
            }
        }
    }
};
