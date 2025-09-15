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
const c = @import("libc_imports").c;

const interface = @import("interface");

const kernel = @import("../../kernel.zig");

const UartFile = @import("uart_file.zig").UartFile;

pub fn UartNode(comptime UartType: anytype) type {
    const Internal = struct {
        const UartNodeImpl = interface.DeriveFromBase(kernel.fs.INode, struct {
            const Self = @This();
            const uart = UartType;
            _allocator: std.mem.Allocator,
            _name: []const u8,

            pub fn delete(self: *Self) void {
                _ = self;
            }

            pub fn create(allocator: std.mem.Allocator, filename: []const u8) UartNodeImpl {
                return UartNodeImpl.init(.{
                    ._allocator = allocator,
                    ._name = filename,
                });
            }

            pub fn name(self: *Self, allocator: std.mem.Allocator) kernel.fs.FileName {
                _ = allocator;
                return kernel.fs.FileName.init(self._name, null);
            }

            pub fn get_file(self: *Self) ?kernel.fs.IFile {
                return (UartFile(uart).InstanceType.create(self._allocator, self._name)).interface.new(self._allocator) catch {
                    return null;
                };
            }

            pub fn get_directory(self: *Self) ?kernel.fs.IDirectory {
                _ = self;
                return null;
            }

            pub fn filetype(self: *Self) kernel.fs.FileType {
                _ = self;
                return kernel.fs.FileType.CharDevice;
            }
        });
    };
    return Internal.UartNodeImpl;
}
