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

const hal = @import("../rp2350.zig");

const picosdk = @import("picosdk.zig").picosdk;

const RingBuffer = struct {
    buffer: [128]u8,
    head: usize,
    tail: usize,
    pub fn init() RingBuffer {
        return .{
            .buffer = [_]u8{0} ** 128,
            .head = 0,
            .tail = 0,
        };
    }

    pub fn put(self: *RingBuffer, byte: u8) void {
        const next_head = (self.head + 1) % self.buffer.len;
        if (next_head != self.tail) {
            self.buffer[self.head] = byte;
            self.head = next_head;
        }
    }

    pub fn get(self: *RingBuffer) ?u8 {
        if (self.head == self.tail) {
            return null;
        }
        const byte = self.buffer[self.tail];
        self.tail = (self.tail + 1) % self.buffer.len;
        return byte;
    }

    pub fn read_all(self: *RingBuffer, buffer: []u8) usize {
        var count: usize = 0;
        while (count < buffer.len and self.head != self.tail) {
            buffer[count] = self.buffer[self.tail];
            self.tail = (self.tail + 1) % self.buffer.len;
            count += 1;
        }
        return count;
    }

    pub fn clear(self: *RingBuffer) void {
        self.head = 0;
        self.tail = 0;
    }

    pub fn is_empty(self: *RingBuffer) bool {
        return self.head == self.tail;
    }
};

pub fn Uart(comptime index: usize, comptime pins: interface.uart.Pins) type {
    if (!(index == 0 or index == 1)) @compileError("RP2350 supports UART0 or UART1 only");
    if (pins.tx == null or pins.rx == null) @compileError("Pins must be provided for RP2350 UART");

    return struct {
        const Self = @This();
        const Register = get_register_address(index);
        const RegisterVolatile = get_volatile_register_address(index);
        var rx_buffer: RingBuffer = RingBuffer.init();
        var initialized: bool = false;

        var async_read_context: ?interface.uart.AsyncReadContext = null;

        fn uart_is_readable() bool {
            const derived_ptr = &RegisterVolatile.*.fr;
            return (derived_ptr.* & picosdk.UART_UARTFR_RXFE_BITS) == 0;
        }

        fn on_rx_interrupt() callconv(.c) void {
            while (uart_is_readable()) {
                const dr_ptr = &RegisterVolatile.*.dr;
                const byte: u8 = @intCast(dr_ptr.*);
                Self.rx_buffer.put(byte);
            }

            if (async_read_context) |*ctx| {
                const readed = Self.rx_buffer.read_all(ctx.buffer[ctx.readed..]);
                ctx.readed += readed;
                // if all readed then trigger callback
                if (ctx.readed == ctx.buffer.len) {
                    ctx.callback(ctx.readed);
                    async_read_context = null;
                }
            }
        }

        pub fn init(_: Self, config: interface.uart.Config) interface.uart.InitializeError!void {
            if (initialized) {
                return;
            }
            _ = picosdk.uart_init(Register, @intCast(config.baudrate.?));
            picosdk.gpio_set_function(@intCast(pins.tx.?), picosdk.GPIO_FUNC_UART);
            picosdk.gpio_set_function(@intCast(pins.rx.?), picosdk.GPIO_FUNC_UART);
            picosdk.irq_set_exclusive_handler(get_rx_interrupt_id(index), on_rx_interrupt);
            picosdk.irq_set_priority(get_rx_interrupt_id(index), index + 1);
            picosdk.irq_set_enabled(get_rx_interrupt_id(index), true);
            picosdk.uart_set_irq_enables(Register, true, false);
            initialized = true;
        }

        pub fn is_writable(_: Self) bool {
            const derived_ptr = &RegisterVolatile.*.fr;
            return (derived_ptr.* & picosdk.UART_UARTFR_TXFF_BITS) == 0;
        }

        pub fn is_readable(_: Self) bool {
            lock();
            defer unlock();
            return !rx_buffer.is_empty();
        }

        pub fn getc(self: Self) !u8 {
            lock();
            defer unlock();
            _ = self;
            const byte = rx_buffer.get();
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
            lock();
            defer unlock();
            var already_readed: usize = 0;
            while (already_readed < buffer.len) {
                already_readed += rx_buffer.read_all(buffer[already_readed..]);
            }
            return buffer.len;
        }

        pub fn read_async(self: Self, context: interface.uart.AsyncReadContext) void {
            _ = self;
            lock();
            defer unlock();
            async_read_context = context;
            // read whatever is already in buffer
            on_rx_interrupt();
        }

        pub fn flush(self: Self) void {
            _ = self;
            lock();
            defer unlock();
            const uart_hw: *volatile picosdk.uart_hw_t = @ptrCast(picosdk.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.fr;
            while ((derived_ptr.* & picosdk.UART_UARTFR_BUSY_BITS) != 0) {}
            rx_buffer.clear();
        }

        fn lock() void {
            picosdk.irq_set_enabled(get_rx_interrupt_id(index), false);
        }

        fn unlock() void {
            picosdk.irq_set_enabled(get_rx_interrupt_id(index), true);
        }

        fn get_register_address(comptime id: u32) *picosdk.uart_inst_t {
            if (id == 1) {
                return @ptrFromInt(picosdk.UART1_BASE);
            }
            return @ptrFromInt(picosdk.UART0_BASE);
        }

        fn get_rx_interrupt_id(comptime id: u32) u32 {
            if (id == 1) {
                return picosdk.UART1_IRQ;
            }
            return picosdk.UART0_IRQ;
        }

        fn get_volatile_register_address(comptime id: u32) *volatile picosdk.uart_hw_t {
            if (id == 1) {
                return @ptrFromInt(picosdk.UART1_BASE);
            }
            return @ptrFromInt(picosdk.UART0_BASE);
        }
    };
}
