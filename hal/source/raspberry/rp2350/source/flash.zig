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

pub fn Flash(comptime mapping_address: usize, comptime size: usize) type {
    return struct {
        pub const Self = @This();
        pub const BlockSize = 1;
        memory: []const u8,

        pub fn init(self: Self) void {
            _ = self;
        }

        fn slicify(ptr: [*]u8, memory_size: usize) []const u8 {
            return ptr[0..memory_size];
        }

        pub fn create(comptime id: u32) Self {
            _ = id;
            return .{
                .memory = slicify(@ptrFromInt(mapping_address), size),
            };
        }

        pub fn read(self: Self, address: u32, buffer: []u8) void {
            @memcpy(buffer, self.memory[address .. address + buffer.len]);
        }

        pub fn write(self: Self, address: u32, data: []const u8) void {
            _ = data;
            _ = self;
            _ = address;
        }

        pub fn erase(self: Self, address: u32) void {
            _ = self;
            _ = address;
        }

        pub fn get_number_of_blocks(self: Self) u32 {
            _ = self;
            return 1024;
        }

        pub fn get_physical_address(self: Self) []const u8 {
            return self.memory;
        }
    };
}
