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

pub fn Uart(comptime index: usize, comptime pins: Pins, comptime uart: anytype) type {
    const UartImplementation = uart(index, pins);
    return struct {
        const Self = @This();
        impl: UartImplementation,

        pub fn create() Self {
            return Self{
                .impl = UartImplementation{},
            };
        }

        pub fn init(self: Self, config: Config) InitializeError!void {
            try self.impl.init(config);
        }

        pub const Writer = std.io.Writer(Self, WriteError, write_some);

        pub fn writer(self: Self) Writer {
            return Writer{ .context = self };
        }

        pub fn write_some(self: Self, buffer: []const u8) WriteError!usize {
            return self.impl.write(buffer) catch return WriteError.WriteFailure;
        }

        pub fn write_some_opaque(self: *const anyopaque, buffer: []const u8) anyerror!usize {
            const realSelf: *const Self = @ptrCast(@alignCast(self));
            return realSelf.*.impl.write(buffer) catch {
                return 0;
            };
        }

        pub fn read(self: Self, buffer: []u8) !usize {
            return try self.impl.read(buffer);
        }

        pub fn flush(self: Self) void {
            return self.impl.flush();
        }

        pub fn set_baudrate(self: Self, baudrate: u32) void {
            self.impl.set_baudrate(baudrate);
        }

        pub fn is_readable(self: Self) bool {
            return self.impl.is_readable();
        }

        pub fn bytes_to_read(self: Self) usize {
            return self.impl.bytes_to_read();
        }

        /// Receive-path loss accounting. Backends that do not track it report
        /// zeros rather than failing to compile, so a diagnostic reader can be
        /// written once and built for every board.
        pub fn rx_stats(self: Self) RxStats {
            if (@hasDecl(UartImplementation, "get_rx_stats")) {
                return self.impl.get_rx_stats();
            }
            return .{};
        }
    };
}

/// Where received bytes are lost, counted separately because the fixes differ.
///
/// `overruns` is the hardware FIFO overflowing while the receive interrupt was
/// masked; `dropped` is the software ring above it overflowing because the
/// reader could not keep up; `fifo_full` is how often the interrupt arrived to
/// find the FIFO already full, which catches the same lateness without relying
/// on the overrun flag being where we expect it. `framing_errors` separates a
/// corrupted line from a merely congested one. The two `max_*_gap_us` values
/// are how long the interrupt had been away when it happened, which sizes the
/// critical section responsible.
///
/// `drain_skips` is not a loss counter: it is how often a core found another
/// already draining the FIFO and declined to join in, leaving those bytes for
/// the holder. Skips climbing while `overruns` and `dropped` stay flat is the
/// serialisation working.
pub const RxStats = struct {
    bytes: u32 = 0,
    overruns: u32 = 0,
    dropped: u32 = 0,
    fifo_full: u32 = 0,
    framing_errors: u32 = 0,
    max_overrun_gap_us: u32 = 0,
    max_late_gap_us: u32 = 0,
    drain_skips: u32 = 0,
};

pub const WriteError = error{
    WriteFailure,
};

pub const InitializeError = error{};

pub const Pins = struct {
    tx: ?u32 = null,
    rx: ?u32 = null,
};

pub const Config = struct {
    baudrate: ?u32,
};
