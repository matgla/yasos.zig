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

pub const MemoryInfo = struct {
    pub const MemorySpeed = enum {
        Slow,
        Fast,
    };

    pub const MemoryType = enum {
        PSRAM,
        SRAM,
    };

    pub const Owner = enum {
        Kernel,
        User,
    };

    speed: MemorySpeed,
    memory_type: MemoryType,
    owner: Owner,
    size: usize,
    start_address: usize,
};

pub fn Memory(comptime MemoryImpl: anytype) type {
    return struct {
        const MemoryInterface = MemoryImpl.Impl;
        const Self = @This();
        impl: MemoryImpl,

        pub fn create() Self {
            return Self{
                .impl = .{},
            };
        }

        pub fn get_memory_layout(self: Self) []const MemoryInfo {
            return self.impl.get_memory_layout();
        }

        pub fn get_memory_section(self: Self, selector: anytype) MemoryInfo {
            return self.impl.get_memory_section(selector);
        }
    };
}
