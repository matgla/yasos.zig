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

pub fn Cpu(comptime cpu: anytype) type {
    const CpuImplementation = cpu;
    return struct {
        const Self = @This();
        pub const Registers = CpuImplementation.Registers;

        impl: CpuImplementation,

        pub fn create() Self {
            return Self{
                .impl = CpuImplementation{},
            };
        }

        pub fn name(_: Self) []const u8 {
            return CpuImplementation.name();
        }

        pub fn frequency(_: Self) u64 {
            return CpuImplementation.frequency();
        }

        pub fn number_of_cores(_: Self) u8 {
            return CpuImplementation.number_of_cores();
        }

        pub fn coreid(_: Self) u8 {
            return CpuImplementation.coreid();
        }
    };
}
