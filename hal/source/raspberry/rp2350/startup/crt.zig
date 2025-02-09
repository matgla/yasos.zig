//
// system_stubs.zig
//
// Copyright (C) 2024 Mateusz Stadnik <matgla@live.com>
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

const c = @cImport({
    @cInclude("hardware/regs/resets.h");
    @cInclude("hardware/resets.h");
    @cInclude("pico/runtime_init.h");
});

const sio = @import("../source/sio.zig").sio;

extern var __data_start__: u8;
extern var __data_end__: u8;
extern var __data_start_flash__: u8;

extern var __bss_start__: u8;
extern var __bss_end__: u8;

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
    const bss_length = @intFromPtr(bss_end) - @intFromPtr(bss_start);
    @memset(bss_start[0..bss_length], 0);
}

extern fn __libc_init_array() void;

fn initialize_libc_constructors() void {
    __libc_init_array();
}

export fn _init() void {}

export fn crt_init() void {
    c.reset_block(~(c.RESETS_RESET_IO_QSPI_BITS | c.RESETS_RESET_PADS_QSPI_BITS |
        c.RESETS_RESET_PLL_USB_BITS | c.RESETS_RESET_USBCTRL_BITS | c.RESETS_RESET_SYSCFG_BITS |
        c.RESETS_RESET_PLL_SYS_BITS));

    c.unreset_block_wait(c.RESETS_RESET_BITS &
        ~(c.RESETS_RESET_ADC_BITS | c.RESETS_RESET_HSTX_BITS | c.RESETS_RESET_SPI0_BITS |
        c.RESETS_RESET_SPI1_BITS | c.RESETS_RESET_UART0_BITS |
        c.RESETS_RESET_UART1_BITS | c.RESETS_RESET_USBCTRL_BITS));

    initialize_data();
    initialize_bss();
    initialize_libc_constructors();

    c.runtime_init_clocks();
    // release all spinlocks
    for (&sio.spinlocks) |*lock| {
        lock.write(1);
    }
}
