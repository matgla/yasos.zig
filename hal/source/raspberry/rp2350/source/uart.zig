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

var buf: [64]u8 = undefined;
pub fn Uart(comptime index: usize, comptime pins: interface.uart.Pins) type {
    if (!(index == 0 or index == 1)) @compileError("RP2350 supports UART0 or UART1 only");
    if (pins.tx == null or pins.rx == null) @compileError("Pins must be provided for RP2350 UART");

    return struct {
        const Self = @This();
        const Register = get_register_address(index);
        const RegisterVolatile = get_volatile_register_address(index);
        // Timer block, reached the same way the UART registers are: a *volatile
        // struct pointer that field reads derive from.
        const Timer: *volatile picosdk.timer_hw_t = @ptrFromInt(picosdk.TIMER0_BASE);

        // Sized to the largest burst a reader can be handed at once. The
        // original 512 was sized for a shell command line; zmodem sends 1 KiB
        // sub-packets, which arrive as one uninterrupted burst and can reach
        // ~2 KiB on the wire once every byte needs ZDLE escaping. 4096 covers
        // that with margin, so a reader that is momentarily slower than the
        // line -- raw mode with VMIN=1 returns as soon as the ring runs dry, so
        // it pays a syscall per byte or two while it keeps up -- cannot lose
        // data inside a single burst.
        //
        // Note this is NOT what caused the zmodem sub-packet CRC failures.
        // Those bytes are lost upstream of the ring, in the 32-byte PL011 FIFO,
        // whenever the RX interrupt is masked for longer than the FIFO can
        // cover (see on_uart_rx_irq).
        var rx_buffer: common.utils.RingBuffer(u8, 4096) = common.utils.RingBuffer(u8, 4096).init();
        var is_initialized: bool = false;

        // Loss accounting, split by where the byte died, because the two have
        // completely different fixes: `overruns` is the hardware FIFO filling
        // up before the interrupt could run, `dropped` is the ring above it
        // filling up because the reader was too slow. `max_overrun_gap_us` is
        // how long the interrupt had been away when a byte was last lost --
        // i.e. the length of the critical section responsible.
        var stats: interface.uart.RxStats = .{};
        var last_irq_us: u32 = 0;

        fn uart_is_readable() linksection(".time_critical") bool {
            const derived_ptr = &RegisterVolatile.*.fr;
            return (derived_ptr.* & picosdk.UART_UARTFR_RXFE_BITS) == 0;
        }

        pub fn get_rx_stats(_: Self) interface.uart.RxStats {
            var snapshot = stats;
            snapshot.dropped = rx_buffer.dropped;
            return snapshot;
        }

        fn on_uart_rx_irq() linksection(".time_critical") callconv(.c) void {
            // Through a derived pointer, like every other register read here:
            // `picosdk.timer0_hw.*.timerawl` does not reliably keep its
            // volatile-ness in this compiler, and an optimised build is then
            // free to fold or hoist it.
            const raw_low = &Timer.*.timerawl;
            const now: u32 = raw_low.*;
            const gap = now -% last_irq_us;
            last_irq_us = now;

            // A full FIFO on arrival means we were already late -- the next byte
            // to land has nowhere to go. This is the honest "fell behind"
            // signal, and unlike the overrun flag it does not depend on which
            // register the hardware chooses to surface OE in.
            const fr_ptr = &RegisterVolatile.*.fr;
            if ((fr_ptr.* & picosdk.UART_UARTFR_RXFF_BITS) != 0) {
                stats.fifo_full +%= 1;
                if (gap > stats.max_late_gap_us)
                    stats.max_late_gap_us = gap;
            }

            check_receive_errors(gap);

            while (uart_is_readable()) {
                const derived_ptr = &RegisterVolatile.*.dr;
                const byte: u32 = derived_ptr.*;
                rx_buffer.push(@truncate(byte));
                stats.bytes +%= 1;
            }

            // Again on the way out: the FIFO can just as easily overrun while
            // we are draining it as before we arrived.
            check_receive_errors(gap);
        }

        /// Count and clear latched receive errors.
        ///
        /// Overrun is a FIFO-level status and UARTRSR is where it is defined to
        /// appear -- the copy in UARTDR is not tied to a character the way
        /// FE/PE/BE are. Counting it from UARTDR alone while clearing UARTRSR
        /// is how the first version of this reported a confident zero: it
        /// destroyed the evidence one line after failing to read it.
        fn check_receive_errors(gap: u32) linksection(".time_critical") void {
            const rsr_ptr = &RegisterVolatile.*.rsr;
            const status = rsr_ptr.*;
            if ((status & 0xf) == 0)
                return;
            if ((status & picosdk.UART_UARTRSR_OE_BITS) != 0) {
                stats.overruns +%= 1;
                // Only recorded on a loss: between bursts the line is idle for
                // seconds, so an unconditional maximum would just measure how
                // long nobody was talking.
                if (gap > stats.max_overrun_gap_us)
                    stats.max_overrun_gap_us = gap;
            }
            if ((status & picosdk.UART_UARTRSR_FE_BITS) != 0)
                stats.framing_errors +%= 1;
            // UARTRSR doubles as UARTECR: a write of any value clears the
            // latched FE/PE/BE/OE.
            rsr_ptr.* = 0;
        }

        pub fn init(self: Self, config: interface.uart.Config) interface.uart.InitializeError!void {
            if (is_initialized) {
                return;
            }
            _ = picosdk.uart_init(Register, @intCast(config.baudrate.?));
            picosdk.gpio_set_function(@intCast(pins.tx.?), picosdk.GPIO_FUNC_UART);
            picosdk.gpio_set_function(@intCast(pins.rx.?), picosdk.GPIO_FUNC_UART);
            picosdk.uart_set_fifo_enabled(Register, true);
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

        pub fn set_baudrate(_: Self, baudrate: u32) void {
            _ = picosdk.uart_set_baudrate(Register, baudrate);
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
            asm volatile ("cpsid i" ::: .{ .memory = true });
            const derived_ptr = &RegisterVolatile.*.dr;
            for (data) |byte| {
                while (!self.is_writable()) {
                    // PRIMASK is set, so on_uart_rx_irq cannot fire while we
                    // busy-wait for TX FIFO space. The PL011 RX FIFO is only 32
                    // bytes deep; for any write longer than that the host can
                    // push inbound bytes (command echo is half-duplex) faster
                    // than they drain, overflowing the HW FIFO and silently
                    // dropping characters. Drain it inline so it never overruns.
                    on_uart_rx_irq();
                }
                derived_ptr.* = byte;
            }
            // Mop up anything that landed in the HW FIFO during the final byte's
            // transmit before we unmask and return to the caller.
            on_uart_rx_irq();
            asm volatile ("cpsie i" ::: .{ .memory = true });
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
