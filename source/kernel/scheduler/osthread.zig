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
const Process = @import("../process.zig").Process;

const cpu = @import("hal").cpu;

pub fn OSThread(comptime ManagerType: anytype) type {
    return struct {
        const Self = @This();
        manager: *const ManagerType = undefined,
        current: ?*std.DoublyLinkedList.Node = null,

        pub fn schedule_next(self: *Self) bool {
            _ = self;
            std.Thread.yield() catch {
                return false;
            };
            return true;
        }

        pub fn get_current(self: Self) ?*Process {
            var next = self.manager.processes.first;
            while (next) |node| {
                const process: *Process = @fieldParentPtr("node", node);
                if (process.pid == Process.ImplType.get_process_id()) {
                    return process;
                }
                next = node.next;
            }
            return null;
        }

        pub fn get_next(self: Self) ?*Process {
            _ = self;
            return null;
        }

        pub fn update_current(self: *Self) void {
            _ = self;
        }
    };
}
