//
// vt_driver.zig
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

const IDriver = @import("../idriver.zig").IDriver;
const VtFile = @import("vt_file.zig").VtFile;

pub fn VtDriver() type {
    const Internal = struct {
        const VtDriverImpl = @import("interface").DeriveFromBase(@import("../idriver.zig").IDriver, struct {
            pub const Self = @This();
            _allocator: std.mem.Allocator,
            _node: @import("vt_file.zig").VtFile().InstanceType,

            pub fn create(allocator: std.mem.Allocator, driver_name: []const u8) !VtDriverImpl {
                return VtDriverImpl.init(.{
                    ._allocator = allocator,
                    ._node = try VtFile().InstanceType.create_node(allocator, driver_name),
                });
            }

            pub fn delete(self: *Self) void {
                self._node.delete();
            }

            pub fn load(self: *Self) anyerror!void {
                _ = self;
            }

            pub fn unload(self: *Self) bool {
                _ = self;
                return true;
            }
        });
    };
    return Internal.VtDriverImpl;
}
