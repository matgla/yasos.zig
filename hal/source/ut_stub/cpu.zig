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

pub const CpuStub = struct {
    var _coreid: u8 = 0;

    /// Pretend to be a different core, which is what makes per-CPU code testable
    /// on the host. Restore it with a `defer` -- it is process global.
    pub fn set_coreid(id: u8) void {
        _coreid = id;
    }

    pub fn coreid() u8 {
        return _coreid;
    }

    /// Two, matching the RP2350, not the host machine: this sizes every per-CPU
    /// array, and reporting 1 would compile them down to a single slot so the
    /// tests never exercise the second one.
    pub fn number_of_cores() u8 {
        return 2;
    }
};
