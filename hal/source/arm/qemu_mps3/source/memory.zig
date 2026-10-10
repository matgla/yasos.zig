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
const time = @import("time.zig");

// QEMU MPS2-AN505 RAM (see linker_script.ld): the fast "process_ram" user pool
// is the tail of the ssram-0 bank (0x10100000, after the 1 MB code "flash"); the
// "slow" psram user pool is the ssram-1+2 bank at 0x28000000 (the equivalent of
// the real board's external PSRAM, but just more on-board RAM here); the 16 MB
// block at 0x80000000 holds the romfs image and kernel RAM; `temp_ram` is the
// arena of the hybrid /tmp, carved off the tail of the fast pool. All four
// memory_layout entries are filled from linker symbols below.
extern var __kernel_ram_start__: u8;
extern var __kernel_ram_end__: u8;
extern var __process_ram_start__: u8;
extern var __process_ram_end__: u8;
extern var __psram_start__: u8;
extern var __psram_end__: u8;
extern var __temp_ram_start__: u8;
extern var __temp_ram_end__: u8;

var memory_layout: [4]MemoryInfo = [_]MemoryInfo{
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
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Fast,
        .memory_type = MemoryInfo.MemoryType.SRAM,
        .owner = MemoryInfo.Owner.Temp,
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
        memory_layout[3].start_address = @intFromPtr(&__temp_ram_start__);
        memory_layout[3].size = @intFromPtr(&__temp_ram_end__) - @intFromPtr(&__temp_ram_start__);
        return &memory_layout;
    }

    pub fn get_memory_section(self: Memory, selector: anytype) MemoryInfo {
        _ = self;
        return memory_layout[selector];
    }

    /// Under the RP2350 board model (tools/board_model) a PSRAM page is cleared
    /// the way the rp2350 clears it -- around its XIP cache, through the
    /// uncached mirror -- by word stores the plugin recognises by their PC
    /// (yasos_uncached_zero).  Otherwise a plain memset.
    pub fn zero_pages(self: Memory, slice: []u8) void {
        _ = self;
        const start = @intFromPtr(slice.ptr);
        const modeled = @as(*volatile u64, &time.yasos_modeled_clock_ns).* != 0;
        if (modeled and start >= @intFromPtr(&__psram_start__) and
            start + slice.len <= @intFromPtr(&__psram_end__) and (start & 3) == 0 and (slice.len & 3) == 0)
        {
            yasos_uncached_zero(@ptrCast(@alignCast(slice.ptr)), slice.len / 4);
            return;
        }
        @memset(slice, 0);
    }
};

/// The board model's uncached page clear: kept out of line so its stores have
/// one PC range the rp2350_timing plugin can tell apart.
export fn yasos_uncached_zero(words: [*]volatile u32, count: usize) callconv(.c) void {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (i < count) : (i += 1) words[i] = 0;
}
