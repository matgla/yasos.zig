//
// uart_file.zig
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

const interface = @import("interface");

const c = @import("libc_imports").c;

const IFile = @import("../../fs/ifile.zig").IFile;
const FileName = @import("../../fs/ifile.zig").FileName;
const FileType = @import("../../fs/ifile.zig").FileType;
const IoctlCommonCommands = @import("../../fs/ifile.zig").IoctlCommonCommands;
const FileMemoryMapAttributes = @import("../../fs/ifile.zig").FileMemoryMapAttributes;

const kernel = @import("../../kernel.zig");

const log = std.log.scoped(.@"kernel/fs/driver/flash_file");

pub fn FlashFile(comptime FlashType: anytype) type {
    const Internal = struct {
        const FlashFileImpl = interface.DeriveFromBase(IFile, struct {
            const Self = @This();
            _flash: FlashType,
            _allocator: std.mem.Allocator,
            _current_address: u32,
            _name: []const u8,

            pub fn create(allocator: std.mem.Allocator, flash: FlashType, filename: []const u8) FlashFileImpl {
                return FlashFileImpl.init(.{
                    ._flash = flash,
                    ._allocator = allocator,
                    ._current_address = 0,
                    ._name = filename,
                });
            }

            pub fn create_node(allocator: std.mem.Allocator, flash: FlashType, filename: []const u8) anyerror!kernel.fs.Node {
                const file = try create(allocator, flash, filename).interface.new(allocator);
                return kernel.fs.Node.create_file(file);
            }

            // IFile interface
            pub fn read(self: *Self, buffer: []u8) isize {
                self._flash.read(self._current_address, buffer);
                self._current_address += @intCast(buffer.len);
                return @intCast(buffer.len);
            }

            pub fn write(self: *Self, data: []const u8) isize {
                self._flash.write(self._current_address, data);
                return @intCast(data.len);
            }

            pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
                switch (whence) {
                    c.SEEK_SET => {
                        if (offset < 0) {
                            return -1;
                        }
                        self._current_address = @intCast(offset);
                    },
                    else => return -1,
                }
                return 0;
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

            pub fn name(self: *const Self) []const u8 {
                return self._name;
            }

            pub fn ioctl(self: *Self, cmd: i32, arg: ?*anyopaque) i32 {
                switch (cmd) {
                    @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                        var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(arg));
                        attr.is_memory_mapped = true;
                        attr.mapped_address_r = self._flash.get_physical_address().ptr;
                    },
                    else => {
                        return -1;
                    },
                }
                return 0;
            }

            pub fn fcntl(self: *Self, op: i32, maybe_arg: ?*anyopaque) i32 {
                _ = self;
                _ = op;
                _ = maybe_arg;
                return -1;
            }

            pub fn stat(self: *Self, buf: *c.struct_stat) void {
                buf.st_dev = 0;
                buf.st_ino = 0;
                buf.st_mode = 0;
                buf.st_nlink = 0;
                buf.st_uid = 0;
                buf.st_gid = 0;
                buf.st_rdev = 0;
                buf.st_size = 0;
                buf.st_blksize = FlashType.BlockSize;
                buf.st_blocks = self._flash.get_number_of_blocks();
            }

            pub fn filetype(self: *const Self) FileType {
                _ = self;
                return FileType.BlockDevice;
            }

            pub fn delete(self: *Self) void {
                log.debug("Flash file 0x{x} destruction", .{@intFromPtr(self)});
                _ = self.close();
            }
        });
    };
    return Internal.FlashFileImpl;
}
