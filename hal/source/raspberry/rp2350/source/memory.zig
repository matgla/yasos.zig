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

// RP2350 has possible 4 memory sections
// 1. Kernel RAM determined by the linker script
// 2. Processe RAM determined by the linker script
// 3. PSRAM determined by the detection of external hardware
// 4. Temp RAM determined by the linker script (arena of the hybrid /tmp)

extern var __process_ram_start__: u8;
extern var __process_ram_end__: u8;
extern var __kernel_ram_start__: u8;
extern var __kernel_ram_end__: u8;
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
        memory_layout[2].start_address = 0x11000000;
        memory_layout[2].size = external_memory.get_memory_size();
        memory_layout[3].start_address = @intFromPtr(&__temp_ram_start__);
        memory_layout[3].size = @intFromPtr(&__temp_ram_end__) - @intFromPtr(&__temp_ram_start__);
        return &memory_layout;
    }

    pub fn get_memory_section(self: Memory, selector: anytype) MemoryInfo {
        _ = self;
        return memory_layout[selector];
    }

    // ── Page clearing ─────────────────────────────────────────────────────────
    //
    // PSRAM sits in the XIP window (0x11000000) behind a 16 KiB, 8-byte-line,
    // write-back cache that also *write-allocates*: the datasheet spells this out
    // for the read-only case -- "writes will still cause allocation of an address".
    //
    // So zeroing a cold PSRAM page through the cached alias moves twice the bytes
    // it needs to. Every 8-byte line is first fetched from PSRAM (to be overwritten
    // in full a moment later) and then written back when it is evicted. Against a
    // quad bus that streams ~62 MB/s that predicts ~31 MB/s, and the pool measures
    // 26 MB/s -- the model holds.
    //
    // The second cost does not show up in the clear timing at all: an 8 KiB clear
    // evicts 8 KiB of a 16 KiB cache, and what it evicts is the running compiler's
    // own .text, which is the thing a compile on this board is actually bound on
    // (2.17 MiB of .text through 16 KiB, ~65% of compile time in fetch stalls).
    //
    // Writing through the no-cache/no-allocate mirror (+0x04000000, explicitly
    // writable per XIP_CTRL_WRITABLE_M1: "addresses 0x11000000 through 0x11ffffff,
    // and their uncached mirrors") avoids both. Stale lines for the range may still
    // be sitting in the cache from whoever owned the page last, so they are
    // invalidated first -- discarding a dirty line is exactly right here, its
    // contents are about to become zeroes.
    //
    // ON by default, pending its first hardware run. One thing only the board
    // can answer is still open: whether the QMI keeps CS low across consecutive
    // uncached stores (the `cooldown`/`pagebreak` timing) or pays a fresh
    // command per word. If it does not coalesce, this is *slower* than the
    // cached path despite moving half the bytes, and this should go back to
    // false -- the `poolclear` trace's psram bytes/us is the A/B, and 26 MB/s
    // is the number to beat.
    //
    // Failure modes to expect if the reasoning above is wrong somewhere: pages
    // that read back non-zero (a stale cached line survived the invalidate),
    // which surfaces as arbitrary corruption in whatever was just allocated.
    // Setting this to false restores the plain memset with no other change.
    pub var uncached_psram_clear: bool = true;

    const xip_cached_base: usize = 0x1000_0000;
    const xip_cached_end: usize = 0x1400_0000;
    /// Distance from a cached XIP address to its no-cache/no-allocate mirror.
    const xip_nocache_delta: usize = 0x0400_0000;
    const xip_maintenance_base: usize = 0x1800_0000;
    const xip_cache_line: usize = 8;
    /// XIP_CACHE_INVALIDATE_BY_ADDRESS, from the maintenance op encoding in the
    /// low bits of the maintenance address.
    const xip_op_invalidate: usize = 2;

    /// Zero a freshly allocated run. Equivalent to `@memset(slice, 0)` in every
    /// observable way; only the route differs.
    pub fn zero_pages(self: Memory, slice: []u8) void {
        _ = self;
        const start = @intFromPtr(slice.ptr);
        // Anything but a whole number of cache lines inside the XIP window takes
        // the ordinary path: the maintenance interface works a line at a time, and
        // the mirror write has to cover exactly what was invalidated. Pool runs are
        // page-aligned and page-sized, so the fast path is the common one.
        if (!uncached_psram_clear or
            slice.len == 0 or
            start < xip_cached_base or
            start >= xip_cached_end or
            start + slice.len > xip_cached_end or
            (start & (xip_cache_line - 1)) != 0 or
            (slice.len & (xip_cache_line - 1)) != 0)
        {
            @memset(slice, 0);
            return;
        }

        var offset = start - xip_cached_base;
        const end_offset = offset + slice.len;
        while (offset < end_offset) : (offset += xip_cache_line) {
            @as(*volatile u8, @ptrFromInt(xip_maintenance_base + offset + xip_op_invalidate)).* = 0;
        }
        // The invalidate must be visible before the mirror writes, and the mirror
        // writes before anyone reads the page back through the cached alias.
        asm volatile ("dsb sy" ::: .{ .memory = true });
        asm volatile ("isb" ::: .{ .memory = true });

        const mirror: [*]volatile u32 = @ptrFromInt(start + xip_nocache_delta);
        const words = slice.len / 4;
        var i: usize = 0;
        while (i < words) : (i += 1) {
            mirror[i] = 0;
        }
        asm volatile ("dsb sy" ::: .{ .memory = true });
    }
};
