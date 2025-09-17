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
const fatfs = @import("zfat");

const c = @import("libc_imports").c;

const kernel = @import("kernel");

const log = kernel.log;

pub const FatFsFile = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    _file: ?fatfs.File,
    _allocator: std.mem.Allocator,
    _path: [:0]const u8,
    _is_open: bool,

    pub fn create(allocator: std.mem.Allocator, path: [:0]const u8) !FatFsFile {
        // try top open directory
        var dir: ?fatfs.Dir = fatfs.Dir.open(path) catch blk: {
            break :blk null;
        };
        if (dir) |*d| {
            d.close();
            return FatFsFile.init(.{
                ._file = null,
                ._allocator = allocator,
                ._path = path,
                ._is_open = true,
            });
        } else {
            const file = try fatfs.File.open(path, .{ .access = .read_write, .mode = .open_existing });
            return FatFsFile.init(.{
                ._file = file,
                ._allocator = allocator,
                ._path = path,
                ._is_open = true,
            });
        }
        return error.UnknownError;
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        if (self._file) |*file| {
            const s = file.read(buffer) catch return -1;
            return @as(isize, @intCast(s));
        }
        return 0;
    }

    pub fn write(self: *Self, data: []const u8) isize {
        if (self._file) |*file| {
            log.info("Writing {d} bytes to file: {s}", .{ data.len, self._path });
            const s = file.write(data) catch return -1;
            return @as(isize, @intCast(s));
        }

        return 0;
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
        if (self._file) |*file| {
            switch (whence) {
                c.SEEK_SET => {
                    file.seekTo(@intCast(offset)) catch return -1;
                    return self.tell();
                },
                c.SEEK_END => {
                    const file_size: c.off_t = @intCast(file.size());
                    if (file_size >= offset) {
                        file.seekTo(@intCast(file_size - @as(c.off_t, @intCast(offset)))) catch return -1;
                        return self.tell();
                    } else {
                        // set errno
                        return -1;
                    }
                },
                c.SEEK_CUR => {
                    const new_position = @as(c.off_t, @intCast(file.tell())) + offset;
                    if (new_position < 0) {
                        return -1;
                    }
                    file.seekTo(@intCast(new_position)) catch return -1;
                    return self.tell();
                },
                else => return -1,
            }
            return -1;
        }
        return 0;
    }

    pub fn close(self: *Self) void {
        if (!self._is_open) {
            return 0;
        }
        self._is_open = false;
        self._allocator.free(self._path);
        if (self._file) |*file| {
            file.close();
            self._file = null;
        }
    }

    pub fn dupe(self: *Self) ?kernel.fs.IFile {
        const new_file = self._allocator.create(Self) catch return null;
        new_file.* = self.*;
        return new_file.ifile();
    }

    pub fn sync(self: *Self) i32 {
        if (self._file) |*file| {
            file.sync() catch return -1;
        }
        return 0;
    }

    pub fn tell(self: *Self) c.off_t {
        if (self._file) |*file| {
            return @intCast(file.tell());
        }
        return 0;
    }

    pub fn size(self: *Self) isize {
        if (self._file) |*file| {
            return @intCast(file.size());
        }
        return 0;
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
        const s = fatfs.stat(self._path) catch return kernel.fs.FileName.init("", null);
        const s_dup = allocator.dupe(u8, s.name()) catch return kernel.fs.FileName.init("", null);
        return kernel.fs.FileName.init(s_dup, allocator);
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        switch (cmd) {
            @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus) => {
                var attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(data));
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

    pub fn filetype(self: *Self) kernel.fs.FileType {
        if (self._file == null) {
            return kernel.fs.FileType.Directory;
        }
        return kernel.fs.FileType.File;
    }

    pub fn delete(self: *Self) void {
        _ = self.close();
    }
});
