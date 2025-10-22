//
// flash_node.zig
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

const FlashFile = @import("flash_file.zig").FlashFile;

pub fn FlashNode(comptime FlashType: anytype) type {
    const Internal = struct {
        const FlashNodeImpl = interface.DeriveFromBase(kernel.fs.INodeBase, struct {
            const Self = @This();
            const flash = FlashType;
            base: kernel.fs.INodeBase,
            _allocator: std.mem.Allocator,
            _name: []const u8,

            pub fn delete(self: *Self) void {
                _ = self;
            }

            pub fn create(allocator: std.mem.Allocator, flashnode: FlashType, filename: []const u8) !FlashNodeImpl {
                const flashfile = try (FlashFile(flash).InstanceType.create(allocator, flashnode, filename)).interface.new(allocator);
                return FlashNodeImpl.init(.{
                    .base = kernel.fs.INodeBase.InstanceType.create_file(flashfile),
                    ._allocator = allocator,
                    ._name = filename,
                });
            }

            pub fn name(self: *const Self) []const u8 {
                return self._name;
            }

            pub fn filetype(self: *Self) kernel.fs.FileType {
                _ = self;
                return kernel.fs.FileType.BlockDevice;
            }
        });
    };
    return Internal.FlashNodeImpl;
}
