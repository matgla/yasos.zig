//
// idriver.zig
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

const kernel = @import("../kernel.zig");
pub const IFile = kernel.fs.IFile;

const interface = @import("interface");

fn DriverInterface(comptime SelfType: type) type {
    return struct {
        pub const Self = SelfType;

        pub fn load(self: *Self) anyerror!void {
            return interface.VirtualCall(self, "load", .{}, anyerror!void);
        }

        pub fn unload(self: *Self) bool {
            return interface.VirtualCall(self, "unload", .{}, bool);
        }

        pub fn ifile(self: *Self, allocator: std.mem.Allocator) ?IFile {
            return interface.VirtualCall(self, "ifile", .{allocator}, ?IFile);
        }

        pub fn name(self: *const Self) []const u8 {
            return interface.VirtualCall(self, "name", .{}, []const u8);
        }

        pub fn delete(self: *Self) void {
            interface.VirtualCall(self, "delete", .{}, void);
        }
    };
}

pub const IDriver = interface.ConstructInterface(DriverInterface);
