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

const time = @cImport({
    @cInclude("pico/time.h");
});

const core = @import("cortex-m0plus");

pub const Time = struct {
    pub const SysTick = core.SysTick;

    pub fn sleep_ms(ms: u64) void {
        time.sleep_ms(@intCast(ms));
    }

    pub fn sleep_us(us: u64) void {
        time.sleep_us(@intCast(us));
    }
};
