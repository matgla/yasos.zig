// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// based sd_card.c from Raspberry Pi Pico Extrasa
//
//  Copyright (c) 2020 Raspberry Pi (Trading) Ltd.
//
//  SPDX-License-Identifier: BSD-3-Clause
//

const std = @import("std");

const interface = @import("hal_interface");

const picosdk = @import("picosdk.zig").picosdk;

const MmcSpi = @import("mmc/mmc_spi.zig").MmcSpi;

pub const Mmc = union(enum) {
    const Self = @This();
    spi: MmcSpi,

    pub fn create(comptime config: interface.mmc.MmcConfig) Mmc {
        switch (config.mode) {
            .SPI => return .{
                .spi = MmcSpi.create(config),
            },
            else => unreachable,
        }
    }

    pub fn init(self: *Self) !void {
        try self.spi.init();
    }

    pub fn get_config(self: Self) interface.mmc.MmcConfig {
        return self.spi._config;
    }

    pub fn build_command(self: Self, command: u6, argument: u32) [6]u8 {
        return self.spi.build_command(command, argument);
    }

    pub fn transmit_blocking(self: Self, src: []const u8, dest: ?[]u8) void {
        return self.spi.transmit_blocking(src, dest);
    }

    pub fn receive_blocking(self: Self, dest: []u8) void {
        return self.spi.receive_blocking(dest);
    }

    pub fn chip_select(self: Self, select: bool) void {
        return self.spi.chip_select(select);
    }

    pub fn change_speed_to(self: Self, speed_hz: u32) void {
        return self.spi.change_speed_to(speed_hz);
    }
};

// pub fn Mmc(comptime pio_index: usize, comptime clk_pio_sm: usize, comptime data_pio_sm: usize, comptime cmd_pio_sm: usize, comptime pins: interface.mmc.Pins) type {
//     return struct {
//         const Self = @This();
//         const EncodedCommand = struct {
//             command: u32,
//             argument: u32,
//             cycles: u32,
//         };

//         const pioid = get_pio(pio_index);
//         cmd_or_dat_offset: u32 = 0,
//         clk_program_offset: u32 = 0,

//         fn get_pio(comptime index: usize) picosdk.PIO {
//             switch (index) {
//                 0 => return picosdk.pio0,
//                 1 => return picosdk.pio1,
//                 2 => return picosdk.pio2,
//                 3 => return picosdk.pio3,
//                 else => @compileError("Invalid PIO index"),
//             }
//         }

//         pub fn init(self: *Self, comptime config: interface.mmc.Config) interface.mmc.InitializeError!void {
//             _ = data_pio_sm;
//             self.initialize_pio(config);
//         }

//         fn get_response_cycles(cmd: u32) u32 {
//             return if (cmd == 41) 64 else 48;
//         }

//         fn encode_command(cmd: u32, arg: u32) EncodedCommand {
//             var buffer: [2]u32 = undefined;
//             buffer[0] = ((0x40 | (cmd & 0x3f)) << 24) | ((arg >> 8) & 0xffffff);
//             var calc = std.hash.crc.Crc7Mmc.init();
//             buffer[1] = ((arg & 0xff) << 8) << 16;
//             calc.update(std.mem.sliceAsBytes(buffer[0..1])[0..6]);
//             const crc = calc.final();
//             buffer[1] |= (((@as(u32, crc) << 1) | 1) << 16);
//             return .{
//                 .command = buffer[0],
//                 .argument = buffer[1] | 0xffff,
//                 .cycles = 48 + get_response_cycles(cmd) - 1,
//             };
//         }

//         fn transmit_command(command: EncodedCommand) void {
//             std.mem.doNotOptimizeAway(mmc_program.mmc_transmit_command(@ptrCast(pioid), cmd_pio_sm, clk_pio_sm, command.command, command.argument, command.cycles));
//         }

//         fn initialize_pio(self: *Self, comptime config: interface.mmc.Config) void {
//             _ = self;
//             _ = config;
//             var offset: c_int = 0;
//             picosdk.gpio_set_function(@intCast(pins.clk), picosdk.GPIO_FUNC_PIO0);
//             picosdk.gpio_set_function(@intCast(pins.cmd), picosdk.GPIO_FUNC_PIO0);
//             picosdk.gpio_set_function(@intCast(pins.d0), picosdk.GPIO_FUNC_PIO0);
//             picosdk.gpio_set_function(@intCast(pins.d0 + 1), picosdk.GPIO_FUNC_PIO0);
//             picosdk.gpio_set_function(@intCast(pins.d0 + 2), picosdk.GPIO_FUNC_PIO0);
//             picosdk.gpio_set_function(@intCast(pins.d0 + 3), picosdk.GPIO_FUNC_PIO0);
//             picosdk.gpio_set_pulls(@intCast(pins.clk), true, false);
//             picosdk.gpio_set_pulls(@intCast(pins.cmd), true, false);
//             picosdk.gpio_set_pulls(@intCast(pins.d0), true, false);
//             picosdk.gpio_set_pulls(@intCast(pins.d0 + 1), true, false);
//             picosdk.gpio_set_pulls(@intCast(pins.d0 + 2), true, false);
//             picosdk.gpio_set_pulls(@intCast(pins.d0 + 3), true, false);

//             // _ = picosdk.pio_claim_free_sm_and_add_program_for_gpio_range(@ptrCast(&mmc_program.mmc_command_program), &pio, &sm, &offset, pins.clk, 1, true);
//             offset = picosdk.pio_add_program(@ptrCast(pioid), @ptrCast(&mmc_program.mmc_command_program));
//             mmc_program.mmc_command_program_init(@ptrCast(pioid), clk_pio_sm, @intCast(offset), pins.clk);
//             picosdk.pio_sm_set_clkdiv_int_frac(@ptrCast(pioid), clk_pio_sm, 200, 0);

//             // _ = picosdk.pio_claim_free_sm_and_add_program_for_gpio_range(@ptrCast(&mmc_program.mmc_command_transmit_program), &pio_cmd, &sm_cmd, &offset_cmd, pins.cmd, 1, true);
//             offset = picosdk.pio_add_program(pioid, @ptrCast(&mmc_program.mmc_command_transmit_program));
//             mmc_program.mmc_command_transmit_program_init(@ptrCast(pioid), cmd_pio_sm, @intCast(offset), pins.cmd);
//             picosdk.pio_sm_set_clkdiv_int_frac(pioid, cmd_pio_sm, 200, 0);

//             picosdk.pio_enable_sm_mask_in_sync(pioid, (1 << clk_pio_sm) | (1 << cmd_pio_sm));
//             // picosdk.pio_sm_set_enabled(pioid, cmd_pio_sm, true);

//             transmit_command(encode_command(0, 0)); // CMD0
//             transmit_command(encode_command(17, 0)); // CMD0

//             // mmc_program.mmc_transmit_command(@ptrCast(pioid), cmd_pio_sm, clk_pio_sm, 0x30415555, 0xffaadfff, 48 - 1); // CMD0
//             // delay_ticks(100000); // wait for PIO to be ready
//             // picosdk.pio_sm_put(pioid, cmd_pio_sm, 32);

//             // std.mem.doNotOptimizeAway(picosdk.pio_sm_put(pioid, cmd_pio_sm, 0x30410001));
//             // std.mem.doNotOptimizeAway(picosdk.pio_sm_put(pioid, cmd_pio_sm, 0xff00ffff));
//             // picosdk.pio_sm_put(pioid, cmd_pio_sm, 0xff5555ff); // send CMD55

//             // picosdk.pio_sm_put(pioid, cmd_pio_sm, 0xad);
//             // picosdk.pio_sm_put(pioid, clk_pio_sm, 64); // additonal 1 dummy cycle to synchronize
//         }
//     };
// }
