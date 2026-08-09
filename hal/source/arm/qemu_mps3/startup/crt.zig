//
// crt.zig
//
// Minimal C runtime init for the MPS2-AN505 (QEMU): copy .data from its flash
// load address into RAM, zero .bss, run libc constructors, and enable the FPU.
// Called from startup.S `_start` before `main`.
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

const cpu = @import("arch").Registers;
const config = @import("config").cpu;

extern var __data_start__: u8;
extern var __data_end__: u8;
extern var __data_start_flash__: u8;

extern var __bss_start__: u8;
extern var __bss_end__: u8;

extern fn __libc_init_array() void;

fn initialize_data() void {
    const data_start: [*]u8 = @ptrCast(&__data_start__);
    const data_end: [*]u8 = @ptrCast(&__data_end__);
    const data_len = @intFromPtr(data_end) - @intFromPtr(data_start);
    const data_src: [*]const u8 = @ptrCast(&__data_start_flash__);
    @memcpy(data_start[0..data_len], data_src[0..data_len]);
}

fn initialize_bss() void {
    const bss_start: [*]u8 = @ptrCast(&__bss_start__);
    const bss_end: [*]u8 = @ptrCast(&__bss_end__);
    const bss_len = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..bss_len], 0);
}

export fn _init() void {}

export fn crt_init() void {
    initialize_data();
    initialize_bss();
    __libc_init_array();

    // Enable the FPU (full access to CP10/CP11) before any FP instruction.
    if (config.has_fpu and config.use_fpu) {
        cpu.cpacr.cpacr.update(.{
            .cp10 = 0x3,
            .cp11 = 0x3,
        });
    }
}
