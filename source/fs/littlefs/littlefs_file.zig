//
// ramfs_file.zig
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

///! This module provides file handler implementation for ramfs filesystem
const std = @import("std");

const interface = @import("interface");
const littlefs = @import("littlefs_cimport.zig").littlefs;

const c = @import("libc_imports").c;

const kernel = @import("kernel");

const log = kernel.log;

pub const LittleFsFile = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    _file: littlefs.lfs_file_t,
    _lfs: *littlefs.lfs_t,
    _allocator: std.mem.Allocator,
    _is_open: bool,
    _name: []const u8,
    _path: [:0]const u8,
    _filetype: kernel.fs.FileType,

    pub fn create(allocator: std.mem.Allocator, path: [:0]const u8, lfs: *littlefs.lfs_t) !LittleFsFile {
        const filename = std.fs.path.basename(path);

        return LittleFsFile.init(.{
            ._file = undefined,
            ._lfs = lfs,
            ._allocator = allocator,
            ._is_open = true,
            ._name = filename,
            ._path = path,
            ._filetype = .File,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, path: [:0]const u8, lfs: *littlefs.lfs_t) anyerror!kernel.fs.Node {
        const file = try (try create(allocator, path, lfs)).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        return littlefs.lfs_file_read(self._lfs, &self._file, buffer.ptr, buffer.len);
    }

    pub fn write(self: *Self, buffer: []const u8) isize {
        return littlefs.lfs_file_write(self._lfs, &self._file, buffer.ptr, buffer.len);
    }

    pub fn seek(self: *Self, offset: u64, whence: i32) anyerror!u64 {
        return @intCast(littlefs.lfs_file_seek(self._lfs, &self._file, @intCast(offset), whence));
    }

    pub fn sync(self: *Self) i32 {
        return littlefs.lfs_file_sync(self._lfs, &self._file);
    }

    pub fn tell(self: *Self) u64 {
        return @intCast(littlefs.lfs_file_tell(self._lfs, &self._file));
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        switch (cmd) {
            @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus) => {
                if (data == null) {
                    return -1;
                }
                var attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(data.?));
                attr.is_memory_mapped = false;
            },
            else => {
                return -1;
            },
        }
        return 0;
    }

    pub fn fcntl(self: *Self, _: i32, _: ?*anyopaque) i32 {
        _ = self;
        return 0;
    }

    pub fn filetype(self: *const Self) kernel.fs.FileType {
        return self._filetype;
    }

    pub fn delete(self: *Self) void {
        if (!self._is_open) {
            return;
        }
        self._is_open = false;
        self._allocator.free(self._path);
        _ = littlefs.lfs_file_close(self._lfs, &self._file);
        self._allocator.free(self._name);
    }

    pub fn size(self: *const Self) u64 {
        // var info: littlefs.lfs_info = undefined;
        // if (littlefs.lfs_stat(self._lfs, self._path, &info) < 0) {
        //     return 0;
        // }

        // return info.size;
        _ = self;
        return 0;
    }
});
