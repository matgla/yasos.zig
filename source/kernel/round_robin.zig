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

const Process = @import("process.zig").Process;

pub fn RoundRobin(comptime ManagerType: anytype) type {
    return struct {
        const ProcessManagerType = ManagerType;
        const Self = @This();
        manager: *const ManagerType = undefined,
        current: ?*ProcessManagerType.ContainerType.Node = null,
        next: ?*ProcessManagerType.ContainerType.Node = null,

        pub fn schedule_next(self: *Self) bool {
            if (self.manager.processes.len == 0) {
                return false;
            }

            if (self.current == null) {
                self.next = self.manager.processes.first;
                return true;
            }

            var it = self.current;

            while (it) |node| : (it = node.next) {
                // search for the next ready process
                if (node.data.state == Process.State.Ready) {
                    self.next = it;
                    return true;
                }
            }
            // if not found, try to search from beginning
            it = self.manager.processes.first;
            while (it) |node| : (it = node.next) {
                if (node == self.current) {
                    // only already running process can be executed
                    return false;
                }
                // search for the next ready process
                if (node.data.state == Process.State.Ready) {
                    self.next = it;
                    return true;
                }
            }
            return false;
        }

        pub fn get_current(self: Self) ?*Process {
            if (self.current) |node| {
                return &node.data;
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
                return &node.data;
            }
            return null;
        }

        pub fn update_current(self: *Self) void {
            if (self.current) |current| {
                current.data.state = Process.State.Ready;
            }
            if (self.next) |next| {
                next.data.state = Process.State.Running;
            }
            self.current = self.next;
        }
    };
}
