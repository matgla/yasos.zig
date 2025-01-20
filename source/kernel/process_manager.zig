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

const Process = @import("process.zig").Process;

pub const ProcessManager = struct {
    const ContainerType = std.DoublyLinkedList(Process);
    processes: ContainerType,

    pub fn create() ProcessManager {
        return ProcessManager{
            .processes = {},
        };
    }

    pub fn create_process(self: ProcessManager, allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, args: anytype) !*Process {
        const node = allocator.alloc(ContainerType.Node, 1);
        node.data = Process.create(allocator, stack_size, process_entry, args);
        return try self.processes.append(node);
    }

    pub fn delete_process(self: ProcessManager, pid: u32) void {
        for (self.processes) |process| {
            if (process.data.pid == pid) {
                const allocator = process.data.allocator;
                process.data.deinit();
                self.processes.remove(process);
                allocator.free(process);
                break;
            }
        }
    }
};
