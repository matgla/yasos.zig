//
// devicefs.zig
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

const IFileSystem = @import("../fs/fs.zig").IFileSystem;
const IFile = @import("../fs/fs.zig").IFile;
const IDriver = @import("idriver.zig").IDriver;

const std = @import("std");

pub const DriverFs = struct {
    const VTable = IFileSystem.VTable{
        .mount = mount,
        .umount = umount,
        .create = create,
        .mkdir = mkdir,
        .remove = remove,
        .name = name,
        .traverse = traverse,
        .get = get,
        .has_path = has_path,
    };

    allocator: std.mem.Allocator,
    container: std.DoublyLinkedList(IDriver),

    pub fn init(allocator: std.mem.Allocator) ?DriverFs {
        return .{
            .allocator = allocator,
            .container = .{},
        };
    }

    pub fn ifilesystem(self: *DriverFs) IFileSystem {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn mount(_: *anyopaque) i32 {
        // nothing to do
        return 0;
    }

    fn umount(_: *anyopaque) i32 {
        return 0;
    }

    fn create(_: *anyopaque, _: []const u8, _: i32) i32 {
        // read-only filesystem
        return -1;
    }

    fn mkdir(_: *anyopaque, _: []const u8, _: i32) i32 {
        // read-only filesystem
        return -1;
    }

    fn remove(_: *anyopaque, _: []const u8) i32 {
        // read-only filesystem
        return -1;
    }

    fn name(_: *const anyopaque) []const u8 {
        return "devicefs";
    }

    fn traverse(_: *anyopaque, _: []const u8, _: *const fn (file: *IFile, context: *anyopaque) bool, _: *anyopaque) i32 {
        return -1;
    }

    fn get(_: *anyopaque, _: []const u8) ?IFile {
        return null;
    }

    fn has_path(_: *anyopaque, _: []const u8) bool {
        return false;
    }

    // driverfs interface, not IFileSystem
    pub fn append(self: *DriverFs, driver: IDriver) !void {
        var node = try self.allocator.create(std.DoublyLinkedList(IDriver).Node);
        node.data = driver;
        self.container.append(node);
    }
};
