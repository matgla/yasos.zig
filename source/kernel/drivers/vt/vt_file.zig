//
// vt_file.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

const IFile = @import("../../fs/ifile.zig").IFile;

pub fn VtFile() type {
    const Internal = struct {
        const VtFileImpl = @import("interface").DeriveFromBase(IFile, struct {
            pub const Self = @This();
            _allocator: std.mem.Allocator,
            _driver_name: []const u8,

            pub fn create_node(allocator: std.mem.Allocator, driver_name: []const u8) !VtFileImpl {
                return VtFileImpl.init(.{
                    ._allocator = allocator,
                    ._driver_name = driver_name,
                });
            }

            pub fn delete(self: *Self) void {
                _ = self;
            }

            pub fn read(self: *Self, buffer: []u8) !usize {
                _ = self;
                _ = buffer;
                return 0;
            }

            pub fn write(self: *Self, buffer: []const u8) !usize {
                _ = self;
                _ = buffer;
                return 0;
            }
        });
    };
    return Internal.VtFileImpl;
}
