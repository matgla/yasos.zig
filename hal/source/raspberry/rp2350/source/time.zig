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
        const target: u64 = picosdk.timer0_hw.*.timerawl + us;
        const value: *volatile u32 = @ptrCast(&picosdk.timer0_hw.*.timerawl);
        while (value.* < target) {}
    }

    fn init() void {}
};
