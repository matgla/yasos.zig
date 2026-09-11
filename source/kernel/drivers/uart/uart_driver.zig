//
// uart_driver.zig
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

const IDriver = @import("../idriver.zig").IDriver;
const UartFile = @import("uart_file.zig").UartFile;

const kernel = @import("../../kernel.zig");

const interface = @import("interface");
const config = @import("config");

/// Serial console line rate, from CONFIG_CONSOLE_BAUDRATE (menuconfig:
/// Console). Boards may default it differently in their KConfig.
///
/// Both ends have to agree, and the host end is set in two further places:
/// the board's `console_baudrate` in `scripts/remote_smoke_tui.py` (the runner
/// and the remote scripts it generates, which export it to the suite) and the
/// `CONSOLE_BAUDRATE` fallback in `tests/smoke/framework/session.py`. A
/// mismatch does not fail loudly, it just turns the console into garbage.
///
/// 3 Mbaud is the PL011 ceiling here, not a round number picked for ambition:
/// baud is clk_peri/(16*divisor), clk_peri is 48 MHz (`clk_peri_expected_khz`,
/// hal/.../rp2350/startup/crt.zig), and the divisor bottoms out at 1. It is
/// also *exact*, where the 921600 this replaces carried +0.16% error.
///
/// The rate was 460800 until the rig's debug probe was reflashed. At 921600
/// the probe's USB-CDC-to-UART bridge silently dropped 32-48 bytes out of
/// roughly every fourth 736-byte burst during bulk transfers -- measured, not
/// guessed: the target's own counters showed no overrun, no ring drop and no
/// framing error, while host-versus-target byte accounting showed the deficit
/// accumulating on the wire (see docs/remote_smoke_speedup_plan.md). That was
/// debugprobe 2.0.1, which predates the v2.2.1 "regression with long UART TX
/// strings" and v2.2.2 "high uart TX baud rate corruption" fixes.
///
/// What bounds the rate on this end is RX FIFO slack. `uart_set_irqs_enabled`
/// leaves RXIFLSEL=0, so the interrupt trips at 4 of 32 bytes and 28 bytes can
/// still land while the ISR is blocked -- 93 us at 3 Mbaud, against 608 us at
/// 460800. Several kernel `cpsid i` sections (FatFs, MMC/SDIO, __malloc_lock)
/// are the things that have to fit inside that, and `Uart.write` already
/// drains RX inline so the both-directions-at-once case is covered. If this is
/// too fast, the symptom is `ovr` climbing in /proc/uart with `max_overrun_gap_us`
/// naming the critical section responsible; step down through 2000000,
/// 1500000, 1000000 (all exact from 48 MHz).
///
/// A config generated before CONFIG_CONSOLE_BAUDRATE existed has no `console`
/// section; it gets the 3 Mbaud every board ran before the option was added.
pub const console_baudrate: u32 = if (@hasDecl(config, "console"))
    config.console.baudrate
else
    3_000_000;

pub fn UartDriver(comptime UartType: anytype) type {
    const Internal = struct {
        const UartDriverImpl = interface.DeriveFromBase(IDriver, struct {
            pub const Self = @This();
            const uart = UartType;
            _allocator: std.mem.Allocator,
            _node: kernel.fs.Node,

            pub fn create(allocator: std.mem.Allocator, driver_name: []const u8) !UartDriverImpl {
                return UartDriverImpl.init(.{
                    ._allocator = allocator,
                    ._node = try UartFile(uart).InstanceType.create_node(allocator, driver_name),
                });
            }

            pub fn delete(self: *Self) void {
                self._node.delete();
            }

            pub fn load(self: *Self) anyerror!void {
                _ = self;
                uart.flush();
                uart.init(.{
                    .baudrate = console_baudrate,
                }) catch |err| {
                    return err;
                };
            }

            pub fn unload(self: *Self) bool {
                _ = self;
                return true;
            }

            pub fn node(self: *Self) anyerror!kernel.fs.Node {
                return try self._node.clone();
            }

            pub fn name(self: *const Self) []const u8 {
                return self._node.name();
            }
        });
    };
    return Internal.UartDriverImpl;
}

test "UartDriver.ShouldCreateAndDeleteDriver" {
    const UartMock = @import("tests/uart_mock.zig").MockUart;
    defer UartMock.reset();

    var driver = try (try UartDriver(UartMock).InstanceType.create(std.testing.allocator, "uart0")).interface.new(std.testing.allocator);
    defer driver.interface.delete();

    try driver.interface.load();
    try std.testing.expect(driver.interface.unload());
    try std.testing.expectEqualStrings("uart0", driver.interface.name());

    var node = try driver.interface.node();
    defer node.delete();
    try std.testing.expectEqualStrings("uart0", node.name());
    try std.testing.expectEqual(kernel.fs.FileType.CharDevice, node.filetype());

    try std.testing.expectEqual(UartMock.baudrate, console_baudrate);
}
