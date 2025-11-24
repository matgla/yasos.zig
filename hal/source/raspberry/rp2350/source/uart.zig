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

const common = @import("hal_common");

const picosdk = @import("picosdk.zig").picosdk;

var buf: [4096]u8 = undefined;
pub fn Uart(comptime index: usize, comptime pins: interface.uart.Pins) type {
    if (!(index == 0 or index == 1)) @compileError("RP2350 supports UART0 or UART1 only");
    if (pins.tx == null or pins.rx == null) @compileError("Pins must be provided for RP2350 UART");

    return struct {
        const Self = @This();
        const Register = get_register_address(index);
        const RegisterVolatile = get_volatile_register_address(index);

        var rx_buffer: common.utils.RingBuffer(u8, 1024) = common.utils.RingBuffer(u8, 1024).init();
        var is_initialized: bool = false;

        fn uart_is_readable() linksection(".time_critical") bool {
            const derived_ptr = &RegisterVolatile.*.fr;
            return (derived_ptr.* & picosdk.UART_UARTFR_RXFE_BITS) == 0;
        }

        fn on_uart_rx_irq() linksection(".time_critical") callconv(.c) void {
            while (uart_is_readable()) {
                const derived_ptr = &RegisterVolatile.*.dr;
                const byte: u32 = derived_ptr.*;
                const error_byte = RegisterVolatile.*.rsr;
                if ((byte & 0x00000f00) != 0 or (error_byte & 0xf) != 0) {
                    RegisterVolatile.*.icr = 0;
                    asm volatile ("bkpt #1");
                }
                rx_buffer.push(@truncate(byte));
            }
        }

        pub fn init(self: Self, config: interface.uart.Config) interface.uart.InitializeError!void {
            if (is_initialized) {
                return;
            }
            _ = picosdk.uart_init(Register, @intCast(config.baudrate.?));
            picosdk.gpio_set_function(@intCast(pins.tx.?), picosdk.GPIO_FUNC_UART);
            picosdk.gpio_set_function(@intCast(pins.rx.?), picosdk.GPIO_FUNC_UART);
            picosdk.uart_set_fifo_enabled(Register, false);
            picosdk.uart_set_translate_crlf(Register, false);
            picosdk.uart_set_hw_flow(Register, false, false);
            picosdk.uart_set_format(Register, 8, 1, picosdk.UART_PARITY_NONE);

            picosdk.irq_set_exclusive_handler(get_rx_interrupt_id(index), on_uart_rx_irq);
            picosdk.irq_set_enabled(get_rx_interrupt_id(index), true);
            picosdk.irq_set_priority(get_rx_interrupt_id(index), 0x01);
            picosdk.uart_set_irq_enables(Register, true, false);
            rx_buffer.clear();
            self.flush();
            is_initialized = true;
        }

        pub fn is_writable(_: Self) bool {
            const derived_ptr = &RegisterVolatile.*.fr;
            return (derived_ptr.* & picosdk.UART_UARTFR_TXFF_BITS) == 0;
        }

        pub fn is_readable(_: Self) bool {
            return rx_buffer.size() != 0;
        }

        pub fn getc(self: Self) !u8 {
            _ = self;
            const byte = rx_buffer.pop();
            if (byte == null) {
                return error.NoData;
            }
            return byte.?;
        }

        pub fn write(self: Self, data: []const u8) !usize {
            const derived_ptr = &RegisterVolatile.*.dr;
            for (data) |byte| {
                while (!self.is_writable()) {}
                derived_ptr.* = byte;
            }
            return data.len;
        }

        pub fn read(self: Self, buffer: []u8) !usize {
            _ = self;
            return rx_buffer.read(buffer);
        }

        pub fn flush(_: Self) void {
            const uart_hw: *volatile picosdk.uart_hw_t = @ptrCast(picosdk.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.fr;
            while ((derived_ptr.* & picosdk.UART_UARTFR_BUSY_BITS) != 0) {}
            rx_buffer.clear();
        }

        pub fn bytes_to_read(self: Self) usize {
            _ = self;
            return rx_buffer.size();
        }

        fn get_rx_interrupt_id(comptime id: u32) u32 {
            if (id == 1) {
                return picosdk.UART1_IRQ;
            }
            return picosdk.UART0_IRQ;
        }

        fn get_register_address(comptime id: u32) *picosdk.uart_inst_t {
            if (id == 1) {
                return @ptrFromInt(picosdk.UART1_BASE);
            }
            return @ptrFromInt(picosdk.UART0_BASE);
        }

        fn get_volatile_register_address(comptime id: u32) *volatile picosdk.uart_hw_t {
            if (id == 1) {
                return @ptrFromInt(picosdk.UART1_BASE);
            }
            return @ptrFromInt(picosdk.UART0_BASE);
        }
    };
}
