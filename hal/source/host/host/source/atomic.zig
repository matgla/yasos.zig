//
// atomic.zig
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
// <https://www.gnu.org|/licenses/>.
//

const std = @import("std");

var mutexes: [32]?std.Thread.Mutex = undefined;

pub const HardwareAtomic = struct {
    pub fn lock(comptime id: u32) void {
        if (id >= 32) @compileError("Host supports only 32 hardware spinlocks");
        if (mutexes[id] == null) {
            mutexes[id] = .{};
        }
        mutexes[id].?.lock();
    }

    pub fn unlock(comptime id: u32) void {
        if (id >= 32) @compileError("Host supports only 32 hardware spinlocks");
        if (mutexes[id]) |*mutex| {
            mutex.unlock();
        }
    }
};
