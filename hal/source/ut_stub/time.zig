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

const std = @import("std");
const hal = @import("hal");

pub const SysTickStub = struct {
    const Self = @This();
    var systicks: u32 = 0;

    pub fn init(_: SysTickStub, ticks: u32) !void {
        systicks = ticks;
        return;
    }

    pub fn set_ticks(_: SysTickStub, ticks: u32) void {
        systicks = ticks;
    }

    pub fn disable(_: SysTickStub) void {}

    pub fn enable(_: SysTickStub) void {}

    pub fn get_system_tick(_: SysTickStub) u32 {
        return systicks;
    }
};

pub const TimeStub = struct {
    const Self = @This();

    pub const SysTick = SysTickStub;

    var current_time: u64 = 0;

    pub fn init() Self {
        return .{
            .current_time = 0,
        };
    }

    pub fn get_time_us() u64 {
        return current_time;
    }

    pub fn sleep_ms(ms: u64) void {
        _ = ms;
        // Do nothing in stub
    }

    pub fn sleep_us(us: u64) void {
        _ = us;
        // Do nothing in stub
    }

    pub fn set_time(self: Self, time: u64) void {
        _ = self;
        current_time = time;
    }
};
