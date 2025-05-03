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
    if (!(index == 0 or index == 1)) @compileError("RP2350 supports UART0 or UART1 only");
    if (pins.tx == null or pins.rx == null) @compileError("Pins must be provided for RP2350 UART");

    return struct {
        const Self = @This();
        const Register = get_register_address(index);
        pub fn init(_: Self, config: interface.uart.Config) interface.uart.InitializeError!void {
            _ = uart.uart_init(Register, @intCast(config.baudrate.?));
            uart.gpio_set_function(@intCast(pins.tx.?), uart.GPIO_FUNC_UART);
            uart.gpio_set_function(@intCast(pins.rx.?), uart.GPIO_FUNC_UART);
        }

        pub fn is_writable(_: Self) bool {
            const uart_hw: *volatile uart.uart_hw_t = @ptrCast(uart.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.fr;
            return (derived_ptr.* & uart.UART_UARTFR_TXFF_BITS) == 0;
        }

        pub fn is_readable(_: Self) bool {
            const uart_hw: *volatile uart.uart_hw_t = @ptrCast(uart.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.fr;
            return (derived_ptr.* & uart.UART_UARTFR_RXFE_BITS) == 0;
        }

        pub fn getc(self: Self) !u8 {
            const uart_hw: *volatile uart.uart_hw_t = @ptrCast(uart.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.dr;
            while (!self.is_readable()) {}
            return @intCast(derived_ptr.*);
        }

        pub fn write(self: Self, data: []const u8) !usize {
            const uart_hw: *volatile uart.uart_hw_t = @ptrCast(uart.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.dr;
            for (data) |byte| {
                while (!self.is_writable()) {}
                derived_ptr.* = byte;
            }
            return data.len;
        }

        pub fn read(self: Self, buffer: []u8) !usize {
            for (buffer) |*byte| {
                const uart_hw: *volatile uart.uart_hw_t = @ptrCast(uart.uart_get_hw(Register));
                while (!self.is_readable()) {}
                const derived_ptr = &uart_hw.*.dr;
                byte.* = @intCast(derived_ptr.*);
            }
            return buffer.len;
        }

        pub fn flush(self: Self) void {
            const uart_hw: *volatile uart.uart_hw_t = @ptrCast(uart.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.fr;
            while ((derived_ptr.* & uart.UART_UARTFR_BUSY_BITS) != 0) {}
            while (self.is_readable()) {
                const dptr = &uart_hw.*.dr;
                _ = dptr.*;
            }
        }

        fn get_register_address(comptime id: u32) *uart.uart_inst_t {
            if (id == 1) {
                return @ptrFromInt(uart.UART1_BASE);
            }
            return @ptrFromInt(uart.UART0_BASE);
        }

        fn get_volatile_register_address(comptime id: u32) *volatile uart.uart_hw_t {
            if (id == 1) {
                return @ptrFromInt(uart.UART1_BASE);
            }
            return @ptrFromInt(uart.UART0_BASE);
        }
    };
}
