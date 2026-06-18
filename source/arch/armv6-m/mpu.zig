//
// mpu.zig
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

// ARMv6-M (PMSAv6) MPU setup that protects the kernel heap and kernel stack from
// unprivileged user processes (present on the RP2040 Cortex-M0+).
//
// Same model as the ARMv8-M port (see ../armv8-m/mpu.zig): PRIVDEFENA=1 gives the
// privileged kernel full background access, and we map only the user-accessible
// memory so the kernel RAM/stack stay unmapped and fault for unprivileged code.
//
// PMSAv6 regions must be naturally-aligned power-of-two spans, so each linker/HAL
// span is decomposed into the minimal set of aligned power-of-two MPU regions.
//
// NOTE: the ARMv6-M context switch does not yet drive unprivileged execution
// (no per-process CONTROL.nPRIV handling exists for this arch), so on RP2040 this
// region map is in place but enforcement also needs that wiring; it is to be
// validated on hardware. The decomposition logic below is exercised by the
// in-file tests.

const std = @import("std");
const hal = @import("hal");

const Registers = @TypeOf(hal.cpu).Registers;
const memory = hal.memory;

extern var __flash_start__: u8;
extern var __flash_end__: u8;
extern var __romfs_start__: u8;
extern var __romfs_end__: u8;

// RASR access permission AP[2:0] (bits [26:24]).
const ap_rw_any: u32 = 0b011; // full access, both privilege levels
const ap_ro_any: u32 = 0b110; // read-only, both privilege levels
// Normal memory, cacheable write-back (C=1, B=1, TEX=0, S=0).
const mem_attr_normal: u32 = (1 << 17) | (1 << 16);

const Block = struct {
    base: usize,
    size_log2: u5, // region size = 2^size_log2
};

// Decompose [start, end) into at most out.len naturally-aligned power-of-two
// blocks (minimum 32 bytes). Returns the number of blocks written.
fn decompose(start: usize, end_exclusive: usize, out: []Block) usize {
    const min_log2: u5 = 5; // 32 bytes
    var addr = std.mem.alignForward(usize, start, 1 << min_log2);
    const end = std.mem.alignBackward(usize, end_exclusive, 1 << min_log2);
    var count: usize = 0;
    while (addr < end and count < out.len) {
        // Largest power of two that the current address is aligned to.
        var size_log2: u5 = if (addr == 0) 31 else @intCast(@ctz(addr));
        // Do not exceed the remaining span.
        while ((@as(usize, 1) << size_log2) > (end - addr) and size_log2 > min_log2) {
            size_log2 -= 1;
        }
        out[count] = .{ .base = addr, .size_log2 = size_log2 };
        count += 1;
        addr += @as(usize, 1) << size_log2;
    }
    return count;
}

var next_region: u32 = 0;

fn program_blocks(start: usize, end_exclusive: usize, ap: u32, exec_never: u32) void {
    if (end_exclusive <= start) {
        return;
    }
    var blocks: [8]Block = undefined;
    const n = decompose(start, end_exclusive, &blocks);
    const mpu = Registers.mpu;
    const dregion: u32 = mpu.type.read().dregion;
    for (blocks[0..n]) |block| {
        if (next_region >= dregion) {
            std.log.err("MPU: out of regions at 0x{x}", .{block.base});
            return;
        }
        const rbar = (@as(u32, @truncate(block.base)) & 0xFFFF_FFE0) | (1 << 4) | next_region;
        const rasr = (@as(u32, 1)) | // ENABLE
            (@as(u32, block.size_log2 - 1) << 1) | // SIZE = log2(size) - 1
            mem_attr_normal |
            (ap << 24) |
            (exec_never << 28);
        mpu.rbar.write_raw(rbar);
        mpu.rasr.write_raw(rasr);
        next_region += 1;
    }
}

pub fn enable_kernel_protection() void {
    const mpu = Registers.mpu;

    asm volatile ("dsb");
    asm volatile ("isb");

    mpu.ctrl.write_raw(0);
    next_region = 0;

    program_blocks(@intFromPtr(&__flash_start__), @intFromPtr(&__flash_end__), ap_ro_any, 0);
    program_blocks(@intFromPtr(&__romfs_start__), @intFromPtr(&__romfs_end__), ap_ro_any, 0);

    for (memory.get_memory_layout()) |region| {
        if (region.owner != .User or region.size == 0) {
            continue;
        }
        program_blocks(region.start_address, region.start_address + region.size, ap_rw_any, 0);
    }

    mpu.ctrl.write(.{ .enable = 1, .hfnmiena = 0, .privdefena = 1, .reserved0 = 0 });
    asm volatile ("dsb");
    asm volatile ("isb");

    std.log.info("MPU kernel protection enabled with {d} regions", .{next_region});
}

test "decompose aligned power-of-two span is a single block" {
    var out: [8]Block = undefined;
    const n = decompose(0x20000000, 0x20008000, &out); // 32K aligned
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(usize, 0x20000000), out[0].base);
    try std.testing.expectEqual(@as(u5, 15), out[0].size_log2); // 2^15 = 32K
}

test "decompose RP2040 process RAM into aligned blocks" {
    var out: [8]Block = undefined;
    // process_ram: 0x20008000 .. +220K (0x37000) -> 0x2003F000
    const n = decompose(0x20008000, 0x20008000 + 220 * 1024, &out);
    try std.testing.expect(n >= 1);
    // Each block must be naturally aligned and within the span.
    var addr: usize = 0x20008000;
    for (out[0..n]) |b| {
        try std.testing.expectEqual(addr, b.base);
        try std.testing.expectEqual(@as(usize, 0), b.base % (@as(usize, 1) << b.size_log2));
        addr += @as(usize, 1) << b.size_log2;
    }
    try std.testing.expect(addr <= 0x20008000 + 220 * 1024);
}
