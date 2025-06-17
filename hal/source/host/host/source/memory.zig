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

const MemoryInfo = @import("hal_interface").memory.MemoryInfo;

var memory_layout: [3]MemoryInfo = [_]MemoryInfo{
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Fast,
        .memory_type = MemoryInfo.MemoryType.SRAM,
        .owner = MemoryInfo.Owner.Kernel,
        .size = 0,
        .start_address = 0,
    },
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Fast,
        .memory_type = MemoryInfo.MemoryType.SRAM,
        .owner = MemoryInfo.Owner.User,
        .size = 0,
        .start_address = 0,
    },
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Slow,
        .memory_type = MemoryInfo.MemoryType.PSRAM,
        .owner = MemoryInfo.Owner.User,
        .size = 0,
        .start_address = 0,
    },
};

pub const Memory = struct {
    pub fn get_memory_layout(self: Memory) []const MemoryInfo {
        _ = self;
        const allocator = std.heap.page_allocator;
        memory_layout[0].size = 0x1000 * 256;
        const kernel_ram = allocator.alloc(u8, memory_layout[0].size) catch unreachable;
        memory_layout[0].start_address = @intFromPtr(kernel_ram.ptr);

        memory_layout[1].size = 0x1000 * 256;
        const user_ram = allocator.alloc(u8, memory_layout[1].size) catch unreachable;
        memory_layout[1].start_address = @intFromPtr(user_ram.ptr);

        memory_layout[2].size = 0x1000 * 0x1000 * 8; // 8MB PSRAM
        const psram = allocator.alloc(u8, memory_layout[2].size) catch unreachable;
        memory_layout[2].start_address = @intFromPtr(psram.ptr);

        return &memory_layout;
    }

    pub fn get_memory_section(self: Memory, selector: anytype) MemoryInfo {
        _ = self;
        return memory_layout[selector];
    }
};
