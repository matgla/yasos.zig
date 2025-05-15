//
// file_header.zig
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

const FileType = @import("../../kernel/fs/ifile.zig").FileType;

const alignment: u32 = 16;

pub const Type = enum(u4) {
    HardLink = 0,
    Directory = 1,
    RegularFile = 2,
    SymbolicLink = 3,
    BlockDevice = 4,
    CharDevice = 5,
    Socket = 6,
    Fifo = 7,
};

pub const FileHeader = struct {
    memory: []const u8,
    start_index: usize,

    pub fn init(memory: []const u8, start_index: usize) FileHeader {
        return .{
            .memory = memory,
            .start_index = start_index,
        };
    }

    inline fn read(comptime T: type, buffer: []const u8) T {
        return std.mem.bigToNative(T, std.mem.bytesToValue(T, buffer));
    }

    fn convert_filetype(ft: Type) FileType {
        switch (ft) {
            Type.HardLink => return FileType.HardLink,
            Type.Directory => return FileType.Directory,
            Type.RegularFile => return FileType.File,
            Type.SymbolicLink => return FileType.SymbolicLink,
            Type.BlockDevice => return FileType.BlockDevice,
            Type.CharDevice => return FileType.CharDevice,
            Type.Socket => return FileType.Socket,
            Type.Fifo => return FileType.Fifo,
        }
    }

    pub fn filetype(self: FileHeader) FileType {
        const file = FileHeader.read(u32, self.memory[self.start_index .. self.start_index + 4]) & 0x00000007;
        return FileHeader.convert_filetype(@enumFromInt(file));
    }

    pub fn specinfo(self: FileHeader) u32 {
        return FileHeader.read(u32, self.memory[self.start_index + 4 .. self.start_index + 8]);
    }

    pub fn size(self: FileHeader) u32 {
        return FileHeader.read(u32, self.memory[self.start_index + 8 .. self.start_index + 12]);
    }

    pub fn name(self: FileHeader) []const u8 {
        return std.mem.sliceTo(self.memory[self.start_index + 16 ..], 0);
    }

    pub fn data(self: FileHeader) []const u8 {
        const data_index = (self.start_index + self.name().len + 1 + 16 + (alignment - 1)) & ~(alignment - 1);
        return self.memory[data_index .. data_index + self.size()];
    }

    // genromfs sets checksum field as 0 before calculation and returns -sum as a result
    // if result is equal to 0, then checksum is correct
    pub fn validate_checksum(self: FileHeader) bool {
        const length = @min(self.memory.len, 512);
        var i: u32 = 0;
        var checksum_value: u32 = 0;
        while (i < length) {
            checksum_value +%= FileHeader.read(u32, self.memory[i .. i + 4]);
            i += 4;
        }
        return checksum_value == 0;
    }

    pub fn next(self: FileHeader) ?FileHeader {
        const next_file_header = FileHeader.read(u32, self.memory[self.start_index .. self.start_index + 4]) & 0xfffffff0;
        if (next_file_header == 0) {
            return null;
        }
        return FileHeader.init(self.memory, next_file_header);
    }
};
