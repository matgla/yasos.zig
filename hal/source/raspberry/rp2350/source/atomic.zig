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

const sio = @import("sio.zig").sio;

const std = @import("std");

pub const HardwareAtomic = struct {
    // RP2350 has hardware bug in spinlocks (errata RP2350-E2), this comptime array maps ids to correct spinlocks
    const bugfree_spinlocks = [_]u32{
        5, 6, 7, 10, 11, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    };

    pub fn number_of_spinlocks() usize {
        return bugfree_spinlocks.len;
    }

    pub fn lock(comptime id: u32) void {
        if (id < bugfree_spinlocks.len) {
            while (sio.spinlocks[bugfree_spinlocks[id]].read() == 0) {}
        } else {
            @compileError(std.fmt.comptimePrint("RP2350 supports only {d} non-buggy hardware spinlocks. Trying to lock: {d}", .{ bugfree_spinlocks.len, id }));
        }
    }

    pub fn unlock(comptime id: u32) void {
        if (id < bugfree_spinlocks.len) {
            sio.spinlocks[bugfree_spinlocks[id]].write(1);
        } else {
            @compileError(std.fmt.comptimePrint("RP2350 supports only {d} non-buggy hardware spinlocks. Trying to lock: {d}", .{ bugfree_spinlocks.len, id }));
        }
    }
};
