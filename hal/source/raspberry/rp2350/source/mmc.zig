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

const mmc_pio = @cImport({
    @cInclude("mmc.pio.h");
});

pub fn Mmc(comptime pio_index: usize, comptime clk_pio_sm: usize, comptime data_pio_sm: usize, comptime cmd_pio_sm: usize, comptime pins: interface.mmc.Pins) type {
    return struct {
        const Self = @This();

        const pioid = get_pio(pio_index);
        cmd_or_dat_offset: u32 = 0,
        clk_program_offset: u32 = 0,

        fn get_pio(comptime index: usize) picosdk.PIO {
            switch (index) {
                0 => return picosdk.pio0,
                1 => return picosdk.pio1,
                2 => return picosdk.pio2,
                3 => return picosdk.pio3,
                else => @compileError("Invalid PIO index"),
            }
        }

        pub fn init(self: *Self, comptime config: interface.mmc.Config) interface.mmc.InitializeError!void {
            _ = self;
            _ = config;
            _ = cmd_pio_sm;
            _ = data_pio_sm;
            _ = clk_pio_sm;
            _ = pins;
            // self.initialize_gpio(config);
        }

        // fn initialize_gpio(self: *Self, comptime config: interface.mmc.Config) void {
        // picosdk.gpio_set_function(@intCast(pins.clk), picosdk.GPIO_FUNC_PIO1);
        // picosdk.gpio_set_function(@intCast(pins.cmd), picosdk.GPIO_FUNC_PIO1);
        // picosdk.gpio_set_function(@intCast(pins.d0), picosdk.GPIO_FUNC_PIO1);
        // picosdk.gpio_set_pulls(@intCast(pins.clk), false, true);
        // picosdk.gpio_set_pulls(@intCast(pins.cmd), true, false);
        // picosdk.gpio_set_pulls(@intCast(pins.d0), true, false);
        // picosdk.gpio_set_function(@intCast(pins.d0 + 1), picosdk.GPIO_FUNC_PIO1);
        // picosdk.gpio_set_function(@intCast(pins.d0 + 2), picosdk.GPIO_FUNC_PIO1);
        // picosdk.gpio_set_function(@intCast(pins.d0 + 3), picosdk.GPIO_FUNC_PIO1);

        // self.cmd_or_dat_offset = @intCast(picosdk.pio_add_program(pioid, @ptrCast(&mmc_pio.mmc_cmd_or_dat_program)));
        // self.clk_program_offset = @intCast(picosdk.pio_add_program(pioid, @ptrCast(&mmc_pio.mmc_clk_program)));

        // var c = mmc_pio.mmc_clk_program_get_default_config(self.clk_program_offset);
        // picosdk.sm_config_set_sideset_pins(@ptrCast(&c), pins.clk);
        // _ = picosdk.pio_sm_init(pioid, clk_pio_sm, self.clk_program_offset, @ptrCast(&c));

        // c = mmc_pio.mmc_cmd_or_dat_program_get_default_config(self.cmd_or_dat_offset);
        // picosdk.sm_config_set_out_pins(@ptrCast(&c), pins.cmd, 1);
        // picosdk.sm_config_set_set_pins(@ptrCast(&c), pins.cmd, 1);
        // picosdk.sm_config_set_in_pins(@ptrCast(&c), pins.cmd);
        // picosdk.sm_config_set_in_shift(@ptrCast(&c), false, true, 32);
        // picosdk.sm_config_set_out_shift(@ptrCast(&c), false, true, 32);
        // _ = picosdk.pio_sm_init(pioid, cmd_pio_sm, self.cmd_or_dat_offset, @ptrCast(&c));

        // c = mmc_pio.mmc_cmd_or_dat_program_get_default_config(self.cmd_or_dat_offset);
        // picosdk.sm_config_set_out_pins(@ptrCast(&c), pins.d0, config.bus_width);
        // picosdk.sm_config_set_set_pins(@ptrCast(&c), pins.d0, config.bus_width);
        // picosdk.sm_config_set_in_pins(@ptrCast(&c), pins.d0);
        // picosdk.sm_config_set_in_shift(@ptrCast(&c), false, true, 32);
        // picosdk.sm_config_set_out_shift(@ptrCast(&c), false, true, 32);
        // _ = picosdk.pio_sm_init(pioid, data_pio_sm, self.cmd_or_dat_offset, @ptrCast(&c));

        // // just for initialization we must set slow clock
        // self.set_clock_divider_for(50);

        // picosdk.pio_sm_exec(pioid, cmd_pio_sm, picosdk.pio_encode_jmp(mmc_pio.mmc_cmd_or_dat_offset_no_arg_state_wait_high));
        // picosdk.pio_sm_exec(pioid, data_pio_sm, picosdk.pio_encode_jmp(mmc_pio.mmc_cmd_or_dat_offset_no_arg_state_waiting_for_cmd));
        // const data_pin_mask = (1 << config.bus_width) - 1;
        // const all_pin_mask = @as(u64, @intCast(data_pin_mask << pins.d0)) | (1 << pins.cmd) | (1 << pins.clk);
        // picosdk.pio_sm_set_pindirs_with_mask64(pioid, clk_pio_sm, all_pin_mask, all_pin_mask);
        // picosdk.pio_sm_exec(pioid, data_pio_sm, picosdk.pio_encode_set(picosdk.pio_pins, data_pin_mask));

        // picosdk.pio_sm_put(pioid, cmd_pio_sm, mmc_pio_cmd(mmc_pio.mmc_cmd_or_dat_offset_state_send_bits, 80 - 1));
        // picosdk.pio_sm_put(pioid, cmd_pio_sm, 0xffffffff);
        // picosdk.pio_sm_put(pioid, cmd_pio_sm, 0xffffffff);
        // picosdk.pio_sm_put(pioid, cmd_pio_sm, 0xffff0000 | picosdk.pio_encode_jmp(mmc_pio.mmc_cmd_or_dat_offset_no_arg_state_wait_high));
        // picosdk.pio_enable_sm_mask_in_sync(pioid, (1 << clk_pio_sm) | (1 << data_pio_sm) | (1 << cmd_pio_sm));

        // var response_buffer: [5]u32 = {};
        // }

        // fn mmc_command(packed_command: u64, buffer: []u32, length: u32) i32 {
        //     var rc: u32 = acquiesce_sm(@intCast(cmd_pio_sm));
        //     if (rc < 0) {
        //         return rc;
        //     }
        //     picosdk.pio_sm_set_enabled(pioid, @intCast(cmd_pio_sm), false);
        //     picosdk.pio_sm_put(pioid, @intCast(cmd_pio_sm), mmc_pio_cmd(mmc_pio.mmc_cmd_or_dat_offset_state_send_bits, 48 - 1));
        //     picosdk.pio_sm_put(pioid, @intCast(cmd_pio_sm), @intCast(packed_command));
        //     picosdk.pio_sm_put(pioid, @intCast(cmd_pio_sm), @intCast(packed_command >> 32));
        //     if (length > 0) {
        //         rc =
        //     }
        // }

        // fn safe_wait_tx_empty(pio: picosdk.PIO, sm: u32) i32 {
        //     var wobble: i32 = 0;
        //     while (!picosdk.pio_sm_is_tx_fifo_empty(pio, sm)) {
        //         wobble += 1;
        //         if (wobble > 1000000) {
        //             return -1;
        //         }
        //     }
        //     return 0;
        // }

        // fn acquiesce_sm(sm: i32) i32 {
        //     const rc = safe_wait_tx_empty(pioid, @intCast(sm));
        //     if (rc < 0) {
        //         return rc;
        //     }
        //     var foo: u32 = 0;
        //     var timeout: u32 = 1000000;
        //     while (timeout > 0) {
        //         timeout -= 1;
        //         const addr: u32 = pioid.*.sm[sm].addr;
        //         foo |= 1 << addr;
        //         if (addr == mmc_pio.mmc_cmd_or_dat_offset_no_arg_state_waiting_for_cmd) {
        //             break;
        //         }
        //     }
        //     if (timeout == 0) {
        //         return -1;
        //     }
        //     return 0;
        // }

        // fn mmc_pio_cmd(cmd: u32, param: u32) u32 {
        //     return (picosdk.pio_encode_jmp(cmd) << 16) | param;
        // }
        // fn set_clock_divider_for(_: *Self, div: u16) void {
        //     picosdk.pio_sm_set_clkdiv_int_frac(pioid, clk_pio_sm, div, 0);
        //     picosdk.pio_sm_set_clkdiv_int_frac(pioid, data_pio_sm, div, 0);
        //     picosdk.pio_sm_set_clkdiv_int_frac(pioid, cmd_pio_sm, div, 0);
        //     picosdk.pio_clkdiv_restart_sm_mask(pioid, (1 << clk_pio_sm) | (1 << data_pio_sm) | (1 << cmd_pio_sm));
        // }

        // fn start_single_dma(dma_channel: u32, sm: u32, buffer: []u32, byte_length: u32, bswap: bool, sniff: bool) i32 {
        //     picosdk.gpio_set_mask(1);
        //     const word_length: u32 = (byte_length + 3) / 4;
        //     var c = picosdk.dma_channel_get_default_config(dma_channel);
        //     picosdk.channel_config_set_bswap(@ptrCast(&c), bswap);
        //     picosdk.channel_config_set_read_increment(@ptrCast(&c), false);
        //     picosdk.channel_config_set_write_increment(@ptrCast(&c), true);
        //     picosdk.channel_config_set_dreq(@ptrCast(&c), picosdk.pio_get_dreq(pioid, sm, false));
        //     picosdk.dma_channel_configure(
        //         dma_channel,
        //         @ptrCast(&c),
        //         buffer.ptr,
        //         @ptrCast(&pioid.*.rxf[sm]),
        //         word_length,
        //         false
        //     );
        //     if (sniff) {
        //         picosdk.dma_sniffer_enable(dma_channel, picosdk.DMA_SNIFF_CTRL_CALC_VALUE_CRC16, true);
        //         picosdk.dma_hw.*.sniff_data = 0;
        //     }
        //     picosdk.dma_channel_start(dma_channel);
        //     picosdk.gpio_clr_mask(1);
        //     return 0;
        // }
    };
}
