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

const c = @import("libc_imports").c;

const hal = @import("hal");
const interface = @import("interface");

const kernel = @import("../../kernel.zig");

const log = std.log.scoped(.@"mmc/driver");

pub fn MmcFile(comptime DriverType: type) type {
    return interface.DeriveFromBase(kernel.fs.IFile, struct {
        const Self = @This();

        /// VTable for IFile interface
        _allocator: std.mem.Allocator,
        _mmc: *hal.mmc.Mmc,
        _name: []const u8,
        _driver: *DriverType,
        _current_block: u32,

        pub fn create(allocator: std.mem.Allocator, mmc: *hal.mmc.Mmc, filename: []const u8, driver: *DriverType) MmcFile(DriverType) {
            return MmcFile(DriverType).init(.{
                ._allocator = allocator,
                ._mmc = mmc,
                ._name = filename,
                ._driver = driver,
                ._current_block = 0,
            });
        }

        pub fn read(self: *Self, buf: []u8) isize {
            return self._driver.read(self._current_block << 9, buf);
        }

        pub fn write(self: *Self, buf: []const u8) isize {
            return self._driver.write(self._current_block << 9, buf);
        }

        pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
            switch (whence) {
                c.SEEK_SET => {
                    if (offset < 0 or (offset >> 9) > self._driver.size_in_sectors()) {
                        return -1;
                    }

                    self._current_block = @intCast(offset >> 9);
                },
                c.SEEK_END => {
                    // const file_size: c.off_t = @intCast(self.header.size());
                    // if (file_size >= offset) {
                    //     self.position = file_size - @as(c.off_t, @intCast(offset));
                    // } else {
                    //     // set errno
                    //     return -1;
                    // }
                    log.err("SEEK_END is not implemented for MMC disk", .{});
                    return -1;
                },
                c.SEEK_CUR => {
                    const new_position = self._current_block - @as(u32, @intCast((offset >> 9)));
                    if (new_position < 0) {
                        return -1;
                    }
                    self._current_block = @intCast(new_position);
                },
                else => return -1,
            }
            return @as(c.off_t, @intCast(self._current_block)) << 9;
        }

        pub fn close(self: *Self) void {
            _ = self;
        }

        pub fn sync(self: *Self) i32 {
            _ = self;
            return 0;
        }

        pub fn tell(self: *Self) c.off_t {
            _ = self;
            return 0;
        }

        pub fn size(self: *Self) isize {
            _ = self;
            return 0;
        }

        pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
            _ = allocator;
            return kernel.fs.FileName.init(self._name, null);
        }

        pub fn ioctl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            _ = self;
            _ = cmd;
            _ = arg;
            return 0;
        }

        pub fn fcntl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
            _ = self;
            _ = cmd;
            _ = arg;
            return 0;
        }

        pub fn stat(self: *Self, data: *c.struct_stat) void {
            _ = self;
            _ = data;
        }

        pub fn filetype(self: *Self) kernel.fs.FileType {
            _ = self;
            return kernel.fs.FileType.BlockDevice;
        }

        pub fn delete(self: *Self) void {
            _ = self.close();
        }
    });
}
