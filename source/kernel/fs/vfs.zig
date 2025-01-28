//
// vfs.zig
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

const IFileSystem = @import("ifilesystem.zig").IFileSystem;
const MountPoints = @import("mount_points.zig").MountPoints;

pub const VirtualFileSystem = struct {
    mount_points: MountPoints,

    pub fn init(allocator: std.mem.Allocator) VirtualFileSystem {
        return .{
            .mount_points = MountPoints.init(allocator),
        };
    }
    pub fn mount_filesystem(self: *VirtualFileSystem, path: []const u8, fs: IFileSystem) !void {
        try self.mount_points.mount_filesystem(path, fs);
    }
};
