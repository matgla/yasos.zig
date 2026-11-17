//
// uart.zig
//
// ARM CMSDK APB UART driver for the MPS2-AN505 (QEMU `cmsdk-apb-uart`).
// Polling TX/RX — sufficient for the kernel console + interactive shell.
//
// Register map (offsets from the UART base):
//   0x00 DATA   (W: TX byte, R: RX byte)
//   0x04 STATE  (b0: TX buffer full, b1: RX buffer full, b2/3: overruns)
//   0x08 CTRL   (b0: TX enable, b1: RX enable, b2: TX irq, b3: RX irq)
//   0x0C INTSTATUS/INTCLEAR
//   0x10 BAUDDIV (must be >= 16)
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

const std = @import("std");

const interface = @import("hal_interface");

pub fn Uart(comptime index: usize, comptime pins: interface.uart.Pins) type {
    _ = pins;
    const base: usize = switch (index) {
        0 => 0x40200000,
        1 => 0x40201000,
        2 => 0x40202000,
        3 => 0x40203000,
        4 => 0x40204000,
        else => @compileError("MPS2-AN505 exposes UART0..UART4 only"),
    };

    return struct {
        const Self = @This();

        const DATA: *volatile u32 = @ptrFromInt(base + 0x00);
        const STATE: *volatile u32 = @ptrFromInt(base + 0x04);
        const CTRL: *volatile u32 = @ptrFromInt(base + 0x08);
        const BAUDDIV: *volatile u32 = @ptrFromInt(base + 0x10);

        const STATE_TX_FULL: u32 = 1 << 0;
        const STATE_RX_FULL: u32 = 1 << 1;
        const CTRL_TX_ENABLE: u32 = 1 << 0;
        const CTRL_RX_ENABLE: u32 = 1 << 1;

        // Bound on the per-byte TX-full poll; see the MPS3 driver for why this
        // must not spin forever (chardev backpressure / flow control vs a
        // fault handler that runs with interrupts masked).
        const tx_poll_limit: usize = 100_000_000;

        pub fn init(_: Self, config: interface.uart.Config) interface.uart.InitializeError!void {
            _ = config;
            // QEMU ignores the actual rate but requires BAUDDIV >= 16.
            BAUDDIV.* = 16;
            CTRL.* = CTRL_TX_ENABLE | CTRL_RX_ENABLE;
        }

        pub fn set_baudrate(_: Self, baudrate: u32) void {
            _ = baudrate;
        }

        pub fn is_writable(_: Self) bool {
            return (STATE.* & STATE_TX_FULL) == 0;
        }

        /// The CMSDK UART raises no receive interrupt here, so a byte waits in
        /// its one-byte data register until something reads it.  `poll_rx`
        /// (the tick) takes it into `stash` -- unless it is the interrupt
        /// character, which goes to the kernel -- so ^C is seen while nobody
        /// reads the console.  Readers take the stash first.  Masked and under
        /// `rx_lock` around the stash and the data register: the tick runs on
        /// core 0 while a reader may be on core 1, and two readers of the one
        /// register reorder and repeat bytes.
        var stash: ?u8 = null;
        var rx_lock: std.atomic.Value(u32) = .init(0);

        fn lock_rx() void {
            while (rx_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {}
        }

        fn unlock_rx() void {
            rx_lock.store(0, .release);
        }
        var interrupt_char: u8 = 0;
        var interrupt_handler: ?*const fn () void = null;

        inline fn mask() usize {
            return asm volatile (
                \\ mrs %[ret], PRIMASK
                \\ cpsid i
                : [ret] "=r" (-> usize),
                :
                : .{ .memory = true });
        }

        inline fn unmask(primask: usize) void {
            asm volatile (
                \\ msr PRIMASK, %[m]
                :
                : [m] "r" (primask),
                : .{ .memory = true });
        }

        /// The next byte for a reader, or null: the stash, then the line, the
        /// interrupt character diverted on the way.
        fn take() ?u8 {
            const primask = mask();
            defer unmask(primask);
            lock_rx();
            defer unlock_rx();
            if (stash) |b| {
                stash = null;
                return b;
            }
            while ((STATE.* & STATE_RX_FULL) != 0) {
                const b: u8 = @truncate(DATA.*);
                if (interrupt_handler) |handler| {
                    if (b == interrupt_char) {
                        handler();
                        continue;
                    }
                }
                return b;
            }
            return null;
        }

        pub fn poll_rx(_: Self) void {
            const primask = mask();
            defer unmask(primask);
            // A reader holding the line is draining it anyway.
            if (rx_lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) return;
            defer unlock_rx();
            if (stash != null or (STATE.* & STATE_RX_FULL) == 0) return;
            const b: u8 = @truncate(DATA.*);
            if (interrupt_handler) |handler| {
                if (b == interrupt_char) {
                    handler();
                    return;
                }
            }
            stash = b;
        }

        pub fn set_interrupt_char(_: Self, ch: ?u8, handler: ?*const fn () void) void {
            const primask = mask();
            defer unmask(primask);
            lock_rx();
            defer unlock_rx();
            interrupt_char = ch orelse 0;
            interrupt_handler = if (ch != null) handler else null;
        }

        pub fn is_readable(_: Self) bool {
            return stash != null or (STATE.* & STATE_RX_FULL) != 0;
        }

        pub fn getc(self: Self) !u8 {
            _ = self;
            return take() orelse error.NoData;
        }

        pub fn write(self: Self, data: []const u8) !usize {
            for (data) |byte| {
                var polls: usize = 0;
                while (!self.is_writable()) {
                    polls += 1;
                    if (polls == tx_poll_limit) return error.WriteTimedOut;
                }
                DATA.* = byte;
            }
            return data.len;
        }

        pub fn read(self: Self, buffer: []u8) !usize {
            _ = self;
            var n: usize = 0;
            while (n < buffer.len) : (n += 1) {
                buffer[n] = take() orelse break;
            }
            return n;
        }

        pub fn flush(_: Self) void {}

        pub fn bytes_to_read(self: Self) usize {
            return if (self.is_readable()) 1 else 0;
        }
    };
}
