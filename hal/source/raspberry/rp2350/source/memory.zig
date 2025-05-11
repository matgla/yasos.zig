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

const external_memory = &@import("../rp2350.zig").external_memory;

// RP2350 has possible 3 memory sections
// 1. Kernel RAM determined by the linker script
// 2. Processe RAM determined by the linker script
// 3. PSRAM determined by the detection of external hardware

extern var __process_ram_start__: u8;
extern var __process_ram_end__: u8;
extern var __kernel_ram_start__: u8;
extern var __kernel_ram_end__: u8;

var memory_layout: [3]MemoryInfo = [_]MemoryInfo{
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Fast,
        .memory_type = MemoryInfo.MemoryType.SRAM,
        .size = 0,
        .start_address = 0,
    },
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Fast,
        .memory_type = MemoryInfo.MemoryType.SRAM,
        .size = 0,
        .start_address = 0,
    },
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Slow,
        .memory_type = MemoryInfo.MemoryType.PSRAM,
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
        memory_layout[2].start_address = 0x1d000000;
        memory_layout[2].size = external_memory.get_memory_size();
        return &memory_layout;
    }
};
