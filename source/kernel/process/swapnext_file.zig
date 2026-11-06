// Copyright (c) 2026 Mateusz Stadnik
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

// /proc/swapnext: reading it makes the next heap allocation by any process
// behave as if the process pool were full -- swap a process waiting in waitpid
// out first (process_memory_pool.zig `force_swap_once`). Swap otherwise happens
// only when the pool is full, which a test cannot arrange on a QEMU board with
// megabytes to spare. Nothing is swapped here: this read holds procfs's lock,
// and swap I/O goes through a filesystem; the allocation holds nothing.

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

const BufferedFile = kernel.fs.BufferedFile(64);

pub const SwapNextFile = interface.DeriveFromBase(BufferedFile, struct {
    const Self = @This();
    base: BufferedFile,

    pub fn create(allocator: std.mem.Allocator) SwapNextFile {
        return SwapNextFile.init(.{
            .base = BufferedFile.InstanceType.create(allocator, "swapnext"),
        });
    }

    pub fn create_node(allocator: std.mem.Allocator) anyerror!kernel.fs.Node {
        const file = try create(allocator).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const armed = kernel.memory.swap.active();
        kernel.memory.heap.ProcessMemoryPool.force_swap_once = armed;
        const buffer = interface.base(self).buffer() orelse return -1;
        const buf = vfmt.print(buffer, "swap_armed {d}\n", .{@intFromBool(armed)});
        interface.base(self)._end = buf.len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        interface.base(self).delete();
    }
});
