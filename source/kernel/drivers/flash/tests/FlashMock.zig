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

pub const FlashMock = struct {
    id: u32,
    memory: [4096]u8,

    pub const BlockSize: u32 = 4096;

    pub fn create(id: u32) FlashMock {
        return .{
            .id = id,
            .memory = [_]u8{0} ** 4096,
        };
    }

    pub fn init(self: *FlashMock) !void {
        _ = self;
    }

    pub fn deinit(self: *FlashMock) void {
        _ = self;
    }

    pub fn read(self: *FlashMock, address: u32, buffer: []u8) void {
        const addr: usize = @intCast(address);
        for (buffer, 0..) |*byte, i| {
            if (addr + i < self.memory.len) {
                byte.* = self.memory[addr + i];
            }
        }
    }

    pub fn write(self: *FlashMock, address: u32, data: []const u8) void {
        const addr: usize = @intCast(address);
        for (data, 0..) |byte, i| {
            if (addr + i < self.memory.len) {
                self.memory[addr + i] = byte;
            }
        }
    }

    pub fn erase(self: *FlashMock, address: u32) void {
        const addr: usize = @intCast(address);
        if (addr < self.memory.len) {
            self.memory[addr] = 0xFF;
        }
    }

    pub fn get_number_of_blocks(self: *const FlashMock) u32 {
        _ = self;
        return 1;
    }

    pub fn get_physical_address(self: *const FlashMock) []const u8 {
        return &self.memory;
    }
};
