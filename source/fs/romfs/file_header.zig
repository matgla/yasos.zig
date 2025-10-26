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

const kernel = @import("kernel");

const FileType = kernel.fs.FileType;
const IFile = kernel.fs.IFile;
const FileName = kernel.fs.FileName;

const c = @import("libc_imports").c;

const log = std.log.scoped(.fileheader);

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
    _filesystem_offset: c.off_t,
    _filetype: kernel.fs.FileType,
    _name: []const u8,
    _size: u32,
    _specinfo: u32,

    pub fn init(device_file: IFile, start_offset: c.off_t, filesystem_offset: c.off_t, mapped_address: ?*const anyopaque, allocator: std.mem.Allocator) !FileHeader {
        var reader = try FileReader.init(device_file, start_offset);
        const fileheader = try reader.read(u32, 0);
        const ft = FileHeader.convert_filetype(@enumFromInt(fileheader & 0x7));
        const name_buffer = reader.read_string(allocator, 16) catch "";
        const specinfo_data = try reader.read(u32, 4);
        const size_data = try reader.read(u32, 8);

        return .{
            ._reader = reader,
            ._device_file = device_file,
            ._mapped_memory = mapped_address,
            ._allocator = allocator,
            ._filesystem_offset = filesystem_offset,
            ._filetype = ft,
            ._name = name_buffer,
            ._size = size_data,
            ._specinfo = specinfo_data,
        };
    }

    pub fn deinit(self: *FileHeader) void {
        self._allocator.free(self._name);
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

    pub fn filetype(self: *const FileHeader) FileType {
        return self._filetype;
    }

    pub fn specinfo(self: *const FileHeader) u32 {
        return self._specinfo;
    }

    pub fn size(self: *const FileHeader) u32 {
        return self._size;
    }

    pub fn name(self: *const FileHeader) []const u8 {
        return self._name;
    }

    pub fn read(self: *FileHeader, comptime T: anytype, offset: c.off_t) !T {
        return try self._reader.read(T, self._reader.get_data_offset() + offset);
    }
    pub fn read_bytes(self: *FileHeader, buffer: []u8, offset: c.off_t) !void {
        try self._reader.read_bytes(buffer, self._reader.get_data_offset() + offset);
    }

    pub fn read_string(self: *FileHeader, allocator: std.mem.Allocator, offset: u32) ?[]u8 {
        return self._reader.read_string(allocator, self._reader.get_data_offset() + offset) catch {
            return null;
        };
    }

    pub fn read_name_at_offset(self: *FileHeader, allocator: std.mem.Allocator, offset: c.off_t) ?FileName {
        const name_buffer = self._reader.read_string(allocator, self._reader.get_data_offset() + offset) catch {
            return null;
        };
        return FileName.init(name_buffer, allocator);
    }

    pub fn get_mapped_address(self: FileHeader) ?*const anyopaque {
        return @ptrFromInt(@intFromPtr(self._mapped_memory) + @as(usize, @intCast((self._reader.get_offset() - self._filesystem_offset + self._reader.get_data_offset()))));
    }

    // genromfs sets checksum field as 0 before calculation and returns -sum as a result
    // if result is equal to 0, then checksum is correct
    pub fn validate_checksum(self: *FileHeader) !bool {
        const length = std.mem.alignBackward(u32, @min(self.size(), 512), 4);
        var i: u32 = 0;
        var checksum_value: u32 = 0;
        while (i < length) {
            const word = try self._reader.read(u32, i);
            checksum_value +%= word;
            i += 4;
        }
        return checksum_value == 0;
    }

    pub fn next(self: *FileHeader) !?FileHeader {
        const next_file_header: c.off_t = @intCast(try self._reader.read(u32, 0) & 0xfffffff0);
        if (next_file_header == 0) {
            return null;
        }
        return try FileHeader.init(self._device_file, next_file_header + self._filesystem_offset, self._filesystem_offset, self._mapped_memory, self._allocator);
    }

    fn filetype_to_mode(ftype: FileType) c.mode_t {
        switch (ftype) {
            FileType.HardLink => unreachable,
            FileType.Directory => return c.S_IFDIR,
            FileType.File => return c.S_IFREG,
            FileType.SymbolicLink => return c.S_IFLNK,
            FileType.BlockDevice => return c.S_IFBLK,
            FileType.CharDevice => return c.S_IFCHR,
            FileType.Socket => return c.S_IFSOCK,
            FileType.Fifo => return c.S_IFIFO,
            FileType.Unknown => return 0,
        }
        return 0;
    }

    pub fn stat(self: *FileHeader, buf: *c.struct_stat) void {
        buf.st_dev = 0;
        buf.st_ino = @intCast(self._reader.get_offset());
        buf.st_mode = @intCast(filetype_to_mode(self.filetype()));
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = @intCast(self.size());
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }

    pub fn dupe(self: *const FileHeader) !FileHeader {
        return try FileHeader.init(self._device_file, self._reader.get_offset(), self._filesystem_offset, self._mapped_memory, self._allocator);
    }
};
