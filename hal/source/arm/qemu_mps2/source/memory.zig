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

const MemoryInfo = @import("hal_interface").memory.MemoryInfo;

// QEMU MPS2-AN505 has a flat 16 MB SRAM at 0x80000000, carved by the linker
// script into kernel RAM, process RAM, and a large "psram" pool (the equivalent
// of the real board's external PSRAM, but just more on-board RAM here).
extern var __kernel_ram_start__: u8;
extern var __kernel_ram_end__: u8;
extern var __process_ram_start__: u8;
extern var __process_ram_end__: u8;
extern var __psram_start__: u8;
extern var __psram_end__: u8;

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
        memory_layout[0].start_address = @intFromPtr(&__kernel_ram_start__);
        memory_layout[0].size = @intFromPtr(&__kernel_ram_end__) - @intFromPtr(&__kernel_ram_start__);
        memory_layout[1].start_address = @intFromPtr(&__process_ram_start__);
        memory_layout[1].size = @intFromPtr(&__process_ram_end__) - @intFromPtr(&__process_ram_start__);
        memory_layout[2].start_address = @intFromPtr(&__psram_start__);
        memory_layout[2].size = @intFromPtr(&__psram_end__) - @intFromPtr(&__psram_start__);
        return &memory_layout;
    }

    pub fn get_memory_section(self: Memory, selector: anytype) MemoryInfo {
        _ = self;
        return memory_layout[selector];
    }
};
