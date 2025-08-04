//
// time.zig
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

const log = std.log.scoped(.@"hal/time");

const picosdk = @import("picosdk.zig").picosdk;

const core = @import("cortex-m");

pub const Time = struct {
    pub const SysTick = core.SysTick;
    var is_initialized: bool = false;
    var fired = false;

    pub fn sleep_ms(ms: u64) void {
        log.info("sleeping for: {d} ms", .{ms});
        var left = ms;
        while (left > 0) {
            sleep_us(1000);
            left -= 1;
        }
    }

    pub fn sleep_us(us: u64) void {
        log.info("sleeping for: {d} us", .{us});
        if (!is_initialized) {
            init();
            is_initialized = true;
        }
        fired = false;
        picosdk.timer0_hw.*.alarm[2] = @intCast(us);
        log.info("Waiting for timeout", .{});
        while (!fired) {}
        log.info("Timer finished", .{});
    }

    fn init() void {
        log.info("initialization started ", .{});
        picosdk.hw_set_bits(&picosdk.timer0_hw.*.inte, @as(u32, 1) << 2);
        const irq = picosdk.timer_hardware_alarm_get_irq_num(picosdk.timer0_hw, 2);

        picosdk.irq_set_exclusive_handler(irq, &Time.timer_fired);
        picosdk.irq_set_enabled(irq, true);
        log.info("initialization finished", .{});
    }

    fn timer_fired() callconv(.C) void {
        log.info("Timer fired", .{});
        picosdk.hw_clear_bits(&picosdk.timer0_hw.*.intr, @as(u32, 1) << 2);
        fired = true;
    }
};
