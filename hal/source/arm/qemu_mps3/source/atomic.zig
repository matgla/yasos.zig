//
// atomic.zig
//
// Single-core MPS2-AN505 has no hardware spinlocks; mutual exclusion is
// provided by masking interrupts around the critical section.
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

pub const HardwareAtomic = struct {
    pub fn number_of_spinlocks() usize {
        return 32;
    }

    pub fn lock(comptime id: u32) bool {
        _ = id;
        asm volatile ("cpsid i" ::: .{ .memory = true });
        return true;
    }

    pub fn unlock(comptime id: u32) void {
        _ = id;
        asm volatile ("cpsie i" ::: .{ .memory = true });
    }
};
