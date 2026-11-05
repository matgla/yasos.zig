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

const external_memory = &@import("../rp2350.zig").external_memory;

// RP2350 has possible 4 memory sections
// 1. Kernel RAM determined by the linker script
// 2. Processe RAM determined by the linker script
// 3. PSRAM determined by the detection of external hardware
// 4. Temp RAM determined by the linker script (arena of the hybrid /tmp)
// 5. The kernel's slow heap, carved out of PSRAM

extern var __process_ram_start__: u8;
extern var __process_ram_end__: u8;
extern var __kernel_ram_start__: u8;
extern var __kernel_ram_end__: u8;
extern var __temp_ram_start__: u8;
extern var __temp_ram_end__: u8;

var memory_layout: [5]MemoryInfo = [_]MemoryInfo{
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
    MemoryInfo{
        .speed = MemoryInfo.MemorySpeed.Slow,
        .memory_type = MemoryInfo.MemoryType.PSRAM,
        .owner = MemoryInfo.Owner.KernelSlow,
        .size = 0,
        .start_address = 0,
    },
};

/// The /tmp arena in PSRAM. Larger than in SRAM because it is cheap there, and the
/// file tree lives in it at 256 bytes an allocation, a file costing about 1.3 KB.
const temp_size_in_psram: usize = 128 * 1024;

/// With PSRAM, the /tmp arena moves to its top end and the SRAM it had goes to the
/// processes: a compile's IR is what wants fast memory, and /tmp holds a few KB
/// during one. Called on the layout as the linker script has it. Without PSRAM, or
/// if the two SRAM regions stop being neighbours, nothing changes.
fn move_temp_to_psram(layout: *[5]MemoryInfo) void {
    const process = &layout[1];
    const psram = &layout[2];
    const temp = &layout[3];
    if (psram.size <= temp_size_in_psram) return;
    if (temp.start_address + temp.size != process.start_address) return;

    process.start_address = temp.start_address;
    process.size += temp.size;
    psram.size -= temp_size_in_psram;
    temp.start_address = psram.start_address + psram.size;
    temp.size = temp_size_in_psram;
    temp.speed = .Slow;
    temp.memory_type = .PSRAM;
}

/// The kernel's slow heap: fds, pipes, filesystem objects, the cold half of each
/// process. Peaks far below this, and running out only fails requests.
const kernel_slow_size: usize = 512 * 1024;

/// Off the top of what is left of PSRAM. Called after `move_temp_to_psram`, and
/// without PSRAM there is nothing to carve: the kernel heap stays the only one.
fn carve_kernel_slow(layout: *[5]MemoryInfo) void {
    const psram = &layout[2];
    const slow = &layout[4];
    slow.size = 0;
    if (psram.size <= kernel_slow_size) return;
    psram.size -= kernel_slow_size;
    slow.start_address = psram.start_address + psram.size;
    slow.size = kernel_slow_size;
}

comptime {
    const assert = std.debug.assert;
    const board = struct {
        fn layout(psram_size: usize, temp_start: usize) [5]MemoryInfo {
            const region = MemoryInfo{
                .speed = .Fast,
                .memory_type = .SRAM,
                .owner = .User,
                .size = 0,
                .start_address = 0,
            };
            var result: [5]MemoryInfo = @splat(region);
            result[1].start_address = 0x20018000;
            result[1].size = 400 * 1024;
            result[2].start_address = 0x11000000;
            result[2].size = psram_size;
            result[3].start_address = temp_start;
            result[3].size = 32 * 1024;
            return result;
        }
    };

    var with_psram = board.layout(8 * 1024 * 1024, 0x20010000);
    move_temp_to_psram(&with_psram);
    carve_kernel_slow(&with_psram);
    assert(with_psram[1].start_address == 0x20010000 and with_psram[1].size == 432 * 1024);
    assert(with_psram[2].size == 8 * 1024 * 1024 - 128 * 1024 - 512 * 1024);
    assert(with_psram[3].start_address == 0x117E0000 and with_psram[3].size == 128 * 1024);
    assert(with_psram[3].memory_type == .PSRAM);
    assert(with_psram[4].start_address == 0x11760000 and with_psram[4].size == 512 * 1024);

    var without_psram = board.layout(0, 0x20010000);
    move_temp_to_psram(&without_psram);
    carve_kernel_slow(&without_psram);
    assert(without_psram[1].start_address == 0x20018000 and without_psram[3].start_address == 0x20010000);
    assert(without_psram[3].memory_type == .SRAM);
    assert(without_psram[4].size == 0);

    var apart = board.layout(8 * 1024 * 1024, 0x20000000);
    move_temp_to_psram(&apart);
    assert(apart[3].start_address == 0x20000000 and apart[2].size == 8 * 1024 * 1024);
}

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
        memory_layout[3].speed = .Fast;
        memory_layout[3].memory_type = .SRAM;
        move_temp_to_psram(&memory_layout);
        carve_kernel_slow(&memory_layout);
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
