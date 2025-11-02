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

pub fn Flash(comptime FlashImpl: anytype) type {
    return struct {
        impl: FlashImpl,
        pub const BlockSize = FlashImpl.BlockSize;

        const Self = @This();

        pub fn create(id: u32) Self {
            return .{
                .impl = FlashImpl.create(id),
            };
        }

        pub fn init(self: *Self) !void {
            return self.impl.init();
        }

        pub fn deinit(self: *Self) void {
            return self.impl.deinit();
        }

        pub fn read(self: *Self, address: u32, buffer: []u8) void {
            return self.impl.read(address, buffer);
        }

        pub fn write(self: *Self, address: u32, data: []const u8) void {
            return self.impl.write(address, data);
        }

        pub fn erase(self: *Self, address: u32) void {
            return self.impl.erase(address);
        }

        pub fn get_number_of_blocks(self: *const Self) u32 {
            return self.impl.get_number_of_blocks();
        }

        pub fn get_physical_address(self: *const Self) []const u8 {
            return self.impl.get_physical_address();
        }
    };
}
