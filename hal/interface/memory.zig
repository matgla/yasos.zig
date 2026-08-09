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
        // A region reserved for the hybrid /tmp arena (source/fs/ramfs +
        // source/main.zig). Kernel-owned in the MPU sense — it is deliberately
        // NOT mapped for unprivileged code — but kept out of the process memory
        // pool's tiers so a growing process image can never eat it.
        Temp,
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

        /// Zero a run of pages on its way out of the page pool.
        ///
        /// Semantically just `@memset(slice, 0)`. It exists because a board can
        /// know a cheaper route to the same result: on the rp2350 the PSRAM
        /// tier lives behind a write-allocate cache, so the obvious memset
        /// fetches every line it is about to overwrite and evicts the running
        /// process's code doing it. Boards that do not implement it get the
        /// memset, resolved at compile time.
        pub fn zero_pages(self: Self, slice: []u8) void {
            if (comptime @hasDecl(MemoryImpl, "zero_pages")) {
                self.impl.zero_pages(slice);
            } else {
                @memset(slice, 0);
            }
        }
    };
}
