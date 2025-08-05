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

export fn irq0() void {
    Time.timer_fired();
}

pub const Time = struct {
    pub const SysTick = core.SysTick;
    var is_initialized: bool = false;
    var fired: bool = false;
    var firedptr: *volatile bool = @ptrCast(&fired);

    pub fn sleep_ms(ms: u64) void {
        var left = ms;
        while (left > 0) {
            sleep_us(1000);
            left -= 1;
        }
    }

    pub fn sleep_us(us: u64) void {
        if (!is_initialized) {
            init();
            is_initialized = true;
        }
        firedptr.* = false;
        const target: u64 = picosdk.timer0_hw.*.timerawl + us;
        picosdk.timer0_hw.*.alarm[0] = @intCast(target);
        while (!firedptr.*) {}
    }

    fn init() void {
        picosdk.hw_set_bits(&picosdk.timer0_hw.*.inte, @as(u32, 1) << 0);
        const irq = picosdk.timer_hardware_alarm_get_irq_num(picosdk.timer0_hw, 0);
        picosdk.irq_set_enabled(irq, true);
    }

    fn timer_fired() void {
        picosdk.hw_clear_bits(&picosdk.timer0_hw.*.intr, @as(u32, 1) << 0);
        fired = true;
    }
};
