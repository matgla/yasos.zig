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

    /// Pretend to be a different core.
    ///
    /// This is what makes per-CPU code testable on the host at all: the unit
    /// tests drive `coreid()` by hand and check that a write on one core is not
    /// visible in the other's slot. Restore it with a `defer` -- it is process
    /// global.
    pub fn set_coreid(id: u8) void {
        _coreid = id;
    }

    pub fn coreid() u8 {
        return _coreid;
    }

    /// Two, matching the RP2350, not the host machine.
    ///
    /// The unit-test target exists to stand in for the device, and this number
    /// sizes every per-CPU array in the kernel. Reporting 1 here would compile
    /// all the per-CPU code down to a single slot, so the tests would exercise
    /// array-of-one and the device would run array-of-two -- and the second slot
    /// is exactly where the bugs are.
    pub fn number_of_cores() u8 {
        return 2;
    }
};
