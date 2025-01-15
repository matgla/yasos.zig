//
// process.zig
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

const config = @import("config");

pub const HardwareStoredRegisters = packed struct {
    r0: usize,
    r1: usize,
    r2: usize,
    r3: usize,
    r12: usize,
    lr: usize,
    pc: usize,
    psr: usize,
};

pub const SoftwareStoredRegisters = packed struct {
    r4: usize,
    r5: usize,
    r6: usize,
    r7: usize,
    r8: usize,
    r9: usize,
    r10: usize,
    r11: usize,
    lr: usize,
};
