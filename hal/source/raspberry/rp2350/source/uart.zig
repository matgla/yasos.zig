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

        // The receive lock. The RX path has two producers on SMP: the RX
        // interrupt, which only core 0 enables, and the inline drain inside
        // `write()`, on whichever core is writing -- a blocking per-byte TX line
        // is far longer than the 32-byte FIFO can cover. `cpsid i` does not help,
        // since it masks only the core that executes it. Unsynchronised, both
        // halves lose bytes silently: UARTDR is a destructive read, and
        // `RingBuffer.push` is read-modify-write on `head`, so a lost byte
        // leaves every loss counter at zero.
        //
        // Producers never wait -- `drain_rx` try-locks and skips on failure --
        // because the fault path logs, so a blocking acquire lets a HardFault
        // land on a core that already holds the lock and spin on itself. Skipping
        // loses nothing: the hardware FIFO is the backing store, the holder is
        // inside the drain loop and will take the byte, and the RX/RTIM interrupt
        // condition stays asserted so a skipping handler re-fires.
        //
        // Consumers (`getc`, `read`, `flush`'s ring clear) take it blocking with
        // interrupts masked first, which cannot deadlock against a producer that
        // never waits.
        //
        // TX is not covered here: serialising two cores in `write()`'s byte loop
        // is the console lock's job one layer up. Ordering is console (rank 95)
        // then this, which stays a leaf.
        var rx_lock: common.utils.SpinLock = .{};

        /// How often a producer found the lock busy and skipped its drain. Kept
        /// out of `stats` and atomic because it is incremented on the path that
        /// did not get the lock. A rising `skip` with `ovr` and `drop` flat is
        /// the design working.
        var drain_skips: std.atomic.Value(u32) = .init(0);

        fn uart_is_readable() linksection(".time_critical") bool {
            const derived_ptr = &RegisterVolatile.*.fr;
            return (derived_ptr.* & picosdk.UART_UARTFR_RXFE_BITS) == 0;
        }

        pub fn get_rx_stats(_: Self) interface.uart.RxStats {
            const flags = rx_lock_acquire();
            defer rx_lock_release(flags);
            var snapshot = stats;
            snapshot.dropped = @truncate(rx_buffer.dropped.load(.monotonic));
            snapshot.drain_skips = drain_skips.load(.monotonic);
            return snapshot;
        }

        /// The interrupt entry. Nothing but a calling-convention wrapper -- the
        /// policy is all in `drain_rx`, which the write path shares.
        fn on_uart_rx_irq() linksection(".time_critical") callconv(.c) void {
            drain_rx();
        }

        /// Drain the hardware FIFO into the ring, or skip if someone else is
        /// already doing it. Never waits; see the block comment on `rx_lock`.
        fn drain_rx() linksection(".time_critical") void {
            // Masked before the try-lock, not after: an interrupt landing in
            // between would reach `drain_rx`, fail the try-lock and skip a drain
            // that was available to it -- harmless, but it turns `skip` into
            // noise.
            const primask = save_and_disable_interrupts();
            defer restore_interrupts(primask);

            if (!rx_lock.try_lock()) {
                _ = drain_skips.fetchAdd(1, .monotonic);
                return;
            }
            defer rx_lock.unlock();

            drain_rx_locked();
        }

        fn drain_rx_locked() linksection(".time_critical") void {
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
            {
                // The interrupt is live from the line above, so even this
                // boot-time clear has a producer to exclude.
                const flags = rx_lock_acquire();
                defer rx_lock_release(flags);
                rx_buffer.clear();
            }
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
            const flags = rx_lock_acquire();
            defer rx_lock_release(flags);
            const byte = rx_buffer.pop();
            if (byte == null) {
                return error.NoData;
            }
            return byte.?;
        }

        /// Save PRIMASK and mask, to be handed back to `restore_interrupts`.
        /// Save/restore, not `cpsid i` / `cpsie i`: a bare `cpsie i` unmasks
        /// unconditionally, so a console write from inside a caller's masked
        /// section silently ends it. Every kernel log line emitted under
        /// `save_and_disable_interrupts()` -- `MmcIo`'s whole-transfer window,
        /// FatFs, `__malloc_lock` -- would return with interrupts back on, which
        /// leaves a spinlock held while PendSV can deschedule the holder.
        inline fn save_and_disable_interrupts() usize {
            return asm volatile (
                \\ mrs %[ret], PRIMASK
                \\ cpsid i
                : [ret] "=r" (-> usize),
                :
                : .{ .memory = true });
        }

        inline fn restore_interrupts(primask: usize) void {
            asm volatile (
                \\ msr PRIMASK, %[mask]
                :
                : [mask] "r" (primask),
                : .{ .memory = true });
        }

        /// Take the receive lock, waiting for it: the consumer side -- `getc`,
        /// `read`, `flush`'s ring clear, and the stats snapshot. Masking first is
        /// what makes waiting safe, since no handler on this core can then hold
        /// the lock or reach for it, so the only holder we can wait for is the
        /// other core, inside a drain bounded by the 32-byte FIFO. Producers must
        /// keep using `drain_rx`'s try-lock.
        fn rx_lock_acquire() linksection(".time_critical") usize {
            const primask = save_and_disable_interrupts();
            rx_lock.lock();
            return primask;
        }

        /// Release, then unmask. Unmasking first would re-open the window the
        /// mask exists to close.
        fn rx_lock_release(primask: usize) linksection(".time_critical") void {
            rx_lock.unlock();
            restore_interrupts(primask);
        }

        pub fn write(self: Self, data: []const u8) !usize {
            const primask = save_and_disable_interrupts();
            const derived_ptr = &RegisterVolatile.*.dr;
            for (data) |byte| {
                while (!self.is_writable()) {
                    // PRIMASK is set, so the RX interrupt cannot fire on this
                    // core while we busy-wait for TX FIFO space, and the PL011
                    // RX FIFO is only 32 bytes deep. Drain it inline so it never
                    // overruns. This is the second producer on SMP; `drain_rx`
                    // skips if core 0's interrupt has the lock. Keeping the call
                    // matters -- while core 0 is deep in a `cpsid i` section it
                    // is the only thing rescuing the FIFO.
                    drain_rx();
                }
                derived_ptr.* = byte;
            }
            // Mop up anything that landed in the HW FIFO during the final byte's
            // transmit before we return to the caller.
            drain_rx();
            restore_interrupts(primask);
            return data.len;
        }

        pub fn read(self: Self, buffer: []u8) !usize {
            _ = self;
            const flags = rx_lock_acquire();
            defer rx_lock_release(flags);
            return rx_buffer.read(buffer);
        }

        pub fn flush(_: Self) void {
            // The BUSY spin is outside the lock: it waits for the TX shift
            // register to empty, bounded by the far end, and holding the receive
            // lock across it would stall the other core's drain. Only the ring
            // clear needs exclusion, and as a producer -- `clear` writes `head`.
            const uart_hw: *volatile picosdk.uart_hw_t = @ptrCast(picosdk.uart_get_hw(Register));
            const derived_ptr = &uart_hw.*.fr;
            while ((derived_ptr.* & picosdk.UART_UARTFR_BUSY_BITS) != 0) {}

            const flags = rx_lock_acquire();
            defer rx_lock_release(flags);
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
