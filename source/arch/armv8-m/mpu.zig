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

// ARMv8-M (PMSAv8) MPU setup that protects the kernel heap and kernel stack from
// unprivileged user processes.
//
// The MPU is enabled with PRIVDEFENA=1, so privileged (kernel) accesses fall back
// to the default background memory map and keep full access to everything.
// Unprivileged accesses have NO background map, so they may only touch addresses
// covered by an enabled region. We therefore create a small fixed set of regions
// granting *unprivileged* access to the memory user code legitimately uses (code
// in flash, the romfs image it XIP-executes, and the user RAM pool), and simply
// leave the kernel RAM (heap/.data/.bss) and kernel MSP stack out of every region
// — unprivileged access to them faults (escalates to HardFault, which the existing
// fault handler turns into process termination), while the privileged kernel keeps
// full access through the background map.

const std = @import("std");
const hal = @import("hal");

const Registers = @TypeOf(hal.cpu).Registers;
const memory = hal.memory;

// Code and rodata live in flash; the embedded romfs is XIP-executed by loaded
// user binaries. Both are provided by the linker script.
extern var __flash_start__: u8;
extern var __flash_end__: u8;
extern var __romfs_start__: u8;
extern var __romfs_end__: u8;

// RBAR field encodings (PMSAv8).
const xn: u32 = 1 << 0; // execute-never
// AP[2:1]: 0b01 = RW any privilege, 0b11 = RO any privilege.
const ap_rw_any: u32 = 0b01 << 1;
const ap_ro_any: u32 = 0b11 << 1;
// SH[4:3] = 0b00 non-shareable (single core, no caches modelled).

// MAIR attribute index 0 holds "Normal memory, Outer/Inner Non-cacheable".
const attr_index_normal: u32 = 0;
const mair0_normal_noncacheable: u32 = 0x44;

fn encode_rbar(base: usize, ap: u32, exec_never: u32) u32 {
    return (@as(u32, @truncate(base)) & 0xFFFF_FFE0) | ap | exec_never;
}

// RLAR holds the address of the last byte of the region in bits [31:5]; the low
// five bits carry the attribute index and the enable bit.
fn encode_rlar(end_exclusive: usize, attr_index: u32) u32 {
    const last = @as(u32, @truncate(end_exclusive - 1)) & 0xFFFF_FFE0;
    return last | (attr_index << 1) | 1; // EN = 1
}

var next_region: u32 = 0;

fn program_region(start: usize, end_exclusive: usize, ap: u32, exec_never: u32) void {
    if (end_exclusive <= start) {
        return;
    }
    const mpu = Registers.mpu;
    const dregion: u32 = mpu.type.read().dregion;
    if (next_region >= dregion) {
        std.log.err("MPU: out of regions, cannot map 0x{x}-0x{x}", .{ start, end_exclusive });
        return;
    }
    mpu.rnr.write_raw(next_region);
    mpu.rbar.write_raw(encode_rbar(start, ap, exec_never));
    mpu.rlar.write_raw(encode_rlar(end_exclusive, attr_index_normal));
    next_region += 1;
}

pub fn enable_kernel_protection() void {
    const mpu = Registers.mpu;

    asm volatile ("dsb");
    asm volatile ("isb");

    // Disable while reprogramming.
    mpu.ctrl.write_raw(0);
    mpu.mair0.write_raw(mair0_normal_noncacheable);
    next_region = 0;

    // Code + rodata (flash): read-only, executable, for both privilege levels.
    program_region(@intFromPtr(&__flash_start__), @intFromPtr(&__flash_end__), ap_ro_any, 0);
    // romfs image (XIP-executed user binaries): read-only, executable.
    program_region(@intFromPtr(&__romfs_start__), @intFromPtr(&__romfs_end__), ap_ro_any, 0);

    // User RAM pools (process RAM + psram): read/write, executable (loaded,
    // non-XIP user code runs from here). Kernel RAM is owned by the kernel and is
    // deliberately NOT mapped, so unprivileged access to it faults.
    for (memory.get_memory_layout()) |region| {
        if (region.owner != .User or region.size == 0) {
            continue;
        }
        program_region(region.start_address, region.start_address + region.size, ap_rw_any, 0);
    }

    // Enable with the privileged default background map so kernel code keeps full
    // access to unmapped (kernel) memory.
    mpu.ctrl.write(.{ .enable = 1, .hfnmiena = 0, .privdefena = 1, .reserved0 = 0 });
    asm volatile ("dsb");
    asm volatile ("isb");

    std.log.info("MPU kernel protection enabled with {d} user regions", .{next_region});
}
