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
const c = @import("../../../libc_imports.zig").c;

const IFile = @import("../../fs/ifile.zig").IFile;
const FileName = @import("../../fs/ifile.zig").FileName;
const FileType = @import("../../fs/ifile.zig").FileType;

const interface = @import("interface");

pub fn UartFile(comptime UartType: anytype) type {
    return struct {
        const Self = @This();
        pub usingnamespace interface.DeriveFromBase(IFile, Self);
        const uart = UartType;
        _icanonical: bool,
        _echo: bool,
        _nonblock: bool,
        _allocator: std.mem.Allocator,

        pub fn delete(self: *Self) void {
            self._allocator.destroy(self);
        }

        pub fn create(allocator: std.mem.Allocator) Self {
            return .{
                ._icanonical = true,
                ._echo = true,
                ._nonblock = false,
                ._allocator = allocator,
            };
        }

        pub fn read(self: *Self, buffer: []u8) isize {
            var index: usize = 0;
            var ch: [1]u8 = .{0};
            while (index < buffer.len) {
                if (self._nonblock) {
                    if (!Self.uart.is_readable()) {
                        return @intCast(index);
                    }
                }
                const result = Self.uart.read(ch[0..1]) catch {
                    continue;
                };
                if (result == 0) {
                    return @intCast(index);
                }

                if (ch[0] == '\r') {
                    ch[0] = '\n';
                }
                buffer[index] = ch[0];
                if (self._echo) {
                    _ = uart.write_some(ch[0..1]) catch {};
                }
                index += 1;
                if (self._icanonical) {
                    if (ch[0] == 0 or ch[0] == '\n' or ch[0] == -1) {
                        break;
                    }
                }
                return @intCast(index);
            }
            return 0;
        }

        pub fn write(self: *Self, data: []const u8) isize {
            _ = self;
            const result = uart.write_some(data) catch return 0;
            return @intCast(result);
        }

        pub fn seek(self: *Self, _: c.off_t, _: i32) c.off_t {
            _ = self;
            return 0;
        }

        pub fn close(self: *Self) i32 {
            _ = self;
            return 0;
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

        pub fn name(self: *Self) FileName {
            _ = self;
            return FileName.init("uart", null);
        }

        pub fn ioctl(self: *Self, op: i32, arg: ?*anyopaque) i32 {
            if (arg) |termios_arg| {
                const termios: *c.termios = @ptrCast(@alignCast(termios_arg));
                switch (op) {
                    c.TCSETS => {
                        self._icanonical = (termios.c_lflag & c.ICANON) != 0;
                        self._echo = (termios.c_lflag & c.ECHO) != 0;
                        return 0;
                    },
                    c.TCSETSW => {
                        return -1;
                    },
                    c.TCSETSF => {
                        return -1;
                    },
                    c.TCGETS => {
                        termios.c_iflag = 0;
                        termios.c_oflag = 0;
                        termios.c_cflag = 0;
                        termios.c_lflag = 0;
                        termios.c_line = 0;
                        termios.c_cc[0] = 0;
                        termios.c_cc[1] = 0;
                        termios.c_cc[2] = 0;
                        termios.c_cc[3] = 0;
                        return 0;
                    },
                    else => {
                        return -1;
                    },
                }
            }
            return -1;
        }

        pub fn fcntl(self: *Self, op: i32, maybe_arg: ?*anyopaque) i32 {
            var result: i32 = 0;
            if (maybe_arg) |arg| {
                const flags: *c_int = @ptrCast(@alignCast(arg));
                switch (op) {
                    c.F_GETFL => {
                        if (self._nonblock) {
                            result |= c.O_NONBLOCK;
                        }
                        return result;
                    },
                    c.F_SETFL => {
                        self._nonblock = (flags.* & c.O_NONBLOCK) != 0;
                        return 0;
                    },
                    else => {
                        return -1;
                    },
                }
            }
            return -1;
        }

        pub fn stat(self: *Self, buf: *c.struct_stat) void {
            _ = self;
            buf.st_dev = 0;
            buf.st_ino = 0;
            buf.st_mode = 0;
            buf.st_nlink = 0;
            buf.st_uid = 0;
            buf.st_gid = 0;
            buf.st_rdev = 0;
            buf.st_size = 0;
            buf.st_blksize = 1;
            buf.st_blocks = 1;
        }

        pub fn filetype(self: *Self) FileType {
            _ = self;
            return FileType.CharDevice;
        }
    };
}
