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

pub const Time = struct {
    const Self = @This();
    pub const SysTick = struct {
        pub fn init(_: SysTick, ticks: u32) !void {
            _ = ticks;
        }
        pub fn enable(_: SysTick) void {}
        pub fn disable(_: SysTick) void {}
    };

    pub fn sleep_ms(ms: u64) void {
        Time.sleep_us(ms * 1000);
    }

    pub fn sleep_us(us: u64) void {
        std.Thread.sleep(us * 1000);
    }
};
