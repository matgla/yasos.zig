//
// uart.zig
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

const std = @import("std");

const interface = @import("hal_interface");

const uart = @cImport({
    @cInclude("hardware/uart.h");
    @cInclude("hardware/gpio.h");
});

pub fn Uart(comptime index: usize, comptime pins: interface.uart.Pins) type {
    if (!(index == 0 or index == 1)) @compileError("RP2040 supports UART0 or UART1 only");
    if (pins.tx == null or pins.rx == null) @compileError("Pins must be provided for RP2040 UART");

    return struct {
        const Self = @This();
        const Register = getRegisterAddress(index);
        pub fn init(_: Self, config: interface.uart.Config) interface.uart.InitializeError!void {
            _ = uart.uart_init(Register, @intCast(config.baudrate.?));
            uart.gpio_set_function(@intCast(pins.tx.?), uart.GPIO_FUNC_UART);
            uart.gpio_set_function(@intCast(pins.rx.?), uart.GPIO_FUNC_UART);
        }

        pub fn write(self: Self, data: []const u8) !usize {
            //@call(.never_inline, uart.uart_write_blocking, .{ Register, data.ptr, data.len });
            const ptr: *volatile uart.uart_hw_t = uart.uart_get_hw(Register);
            for (data) |byte| {
                while (!self.is_writable()) {}
                ptr.dr = byte;
            }
            return data.len;
        }

        pub fn is_writable(_: Self) bool {
            const ptr: *volatile uart.uart_hw_t = uart.uart_get_hw(Register);
            return ptr.fr & uart.UART_UARTFR_TXFF_BITS == 0;
        }

        fn getRegisterAddress(comptime id: u32) *uart.uart_inst_t {
            if (id == 1) {
                return @ptrFromInt(uart.UART1_BASE);
            }
            return @ptrFromInt(uart.UART0_BASE);
        }
    };
}
