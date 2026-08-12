//
// cpu.zig
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

const clock = @cImport({
    @cInclude("hardware/clocks.h");
});

pub const Cpu = struct {
    pub fn name() []const u8 {
        return "HOST";
    }

    pub fn frequency() u64 {
        return 123000000;
    }

    /// One, not the host machine's core count: this sizes `ProcessManager.core[]`
    /// and bounds every `percpu[coreid()]` array, and the host schedules on one
    /// core.
    pub fn number_of_cores() u8 {
        return 1;
    }

    /// Zero, matching `number_of_cores()`. `coreid()` must always be a valid
    /// index into an array sized by it; 1 was out of bounds the moment the count
    /// became honest.
    pub fn coreid() u8 {
        return 0;
    }
};
