//
// mount_points.zig
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
const fs = @import("fs.zig");

pub const MountPoint = struct {
    point: std.fs.path,
    filesystem: *fs.FileSystem,
};

pub const MountPoints = struct {
    mount_points: std.DoublyLinkedList(MountPoint),

    pub fn get_best_mount_point(self: MountPoints, path: std.fs.path) ?*const MountPoint {}

    pub fn mount_filesystem(self: MountPoints, path: std.fs.path, filesystem: *fs.FileSystem) !void {
        self.mount_points.append(
            .{
                .filesytem = filesystem,
                .point = path,
            },
        );
    }
};
