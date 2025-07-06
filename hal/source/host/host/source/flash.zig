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

pub const Flash = struct {
    pub const BlockSize = 1;
    id: u32,
    memory: []const u8,

    fn get_filename_mapping(self: *const Flash) error{UnknownFile}![]const u8 {
        // make this configurable in board file
        switch (self.id) {
            0 => return "flash0.img",
            else => return error.UnknownFile,
        }
        return error.UnknownFile;
    }

    pub fn init(self: *Flash) !void {
        std.debug.print("Initializing flash with ID: {d}\n", .{self.id});
        const filename = try self.get_filename_mapping();
        const file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();
        const file_size = try file.getEndPos();
        self.memory = try file.readToEndAlloc(std.heap.page_allocator, file_size);
        std.debug.print("Flash initialized\n", .{});
    }

    pub fn deinit(self: *Flash) void {
        std.heap.page_allocator.free(self.memory);
        std.debug.print("Flash deinitialized\n", .{});
    }

    pub fn create(id: u32) Flash {
        return .{
            .id = id,
            .memory = &.{},
        };
    }

    pub fn read(self: Flash, address: u32, buffer: []u8) void {
        @memcpy(buffer, self.memory[address .. address + buffer.len]);
    }

    pub fn write(self: Flash, address: u32, data: []const u8) void {
        _ = address;
        _ = data;
        std.debug.print("Writing to flash {x} is not implemented\n", .{self.id});
    }

    pub fn erase(self: Flash, address: u32) void {
        _ = address;
        std.debug.print("Erasing flash {x} is not implemented\n", .{self.id});
    }

    pub fn get_number_of_blocks(self: Flash) u32 {
        _ = self;
        return 1024;
    }

    pub fn get_physical_address(self: *const Flash) []const u8 {
        return self.memory;
    }
};
