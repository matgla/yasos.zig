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
const IFile = @import("../../kernel/fs/ifile.zig").IFile;
const FileName = @import("../../kernel/fs/ifile.zig").FileName;

const c = @import("../../libc_imports.zig").c;

const FileReader = @import("file_reader.zig").FileReader;

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
    _reader: FileReader,
    _device_file: IFile,
    _mapped_memory: ?*const anyopaque,
    _allocator: std.mem.Allocator,

    pub fn init(device_file: IFile, start_offset: u32, mapped_address: ?*const anyopaque, allocator: std.mem.Allocator) FileHeader {
        return .{
            ._reader = FileReader.init(device_file, start_offset),
            ._device_file = device_file,
            ._mapped_memory = mapped_address,
            ._allocator = allocator,
        };
    }

    pub fn deinit(self: FileHeader) void {
        if (self._name) |n| {
            self._allocator.free(n);
        }
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

    pub fn filetype(self: *FileHeader) FileType {
        const fileheader = self._reader.read(u32, 0);
        return FileHeader.convert_filetype(@enumFromInt(fileheader & 0xf));
    }

    pub fn specinfo(self: *FileHeader) u32 {
        return self._reader.read(u32, 4);
    }

    pub fn size(self: *FileHeader) u32 {
        return self._reader.read(u32, 8);
    }

    pub fn name(self: *FileHeader) FileName {
        const name_buffer = self._reader.read_string(self._allocator, 16) catch {
            return .{
                .name = "",
                .allocator = null,
            };
        };
        return FileName.init(name_buffer, self._allocator);
    }

    pub fn read(self: *FileHeader, comptime T: anytype, offset: u32) T {
        return self._reader.read(T, offset);
    }
    pub fn read_bytes(self: *FileHeader, buffer: []u8, offset: u32) void {
        self._reader.read_bytes(buffer, offset);
    }

    pub fn read_string(self: *FileHeader, allocator: std.mem.Allocator, offset: u32) ?[]u8 {
        return self._reader.read_string(allocator, offset) catch {
            return null;
        };
    }

    pub fn get_mapped_address(self: FileHeader) ?*const anyopaque {
        return self._mapped_memory;
    }
    // pub fn data(self: FileHeader) []const u8 {
    // const data_index = (self.start_index + self.name().len + 1 + 16 + (alignment - 1)) & ~(alignment - 1);
    // return self.memory[data_index .. data_index + self.size()];
    // }

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

    pub fn next(self: *FileHeader) ?FileHeader {
        const next_file_header = self._reader.read(u32, 0) & 0xfffffff0;
        if (next_file_header == 0) {
            return null;
        }
        var maybe_mapped_address: ?*const anyopaque = self._mapped_memory;
        if (maybe_mapped_address) |address| {
            maybe_mapped_address = @ptrFromInt(@as(usize, @intFromPtr(address)) + next_file_header);
        }
        return FileHeader.init(self._device_file, next_file_header + self._reader.get_offset(), maybe_mapped_address, self._allocator);
    }
};
