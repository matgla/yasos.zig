// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const interface = @import("interface");

const kernel = @import("kernel");

const littlefs = @import("littlefs_cimport.zig").littlefs;
const errno_converter = @import("errno_converter.zig");

const log = std.log.scoped(.littlefs_directory);

pub const LittleFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    const Self = @This();
    _lfs: *littlefs.lfs_t,
    _dir: *littlefs.lfs_dir_t,
    _allocator: std.mem.Allocator,
    _name: ?[]const u8,

    pub fn create(lfs: *littlefs.lfs_t, path: [:0]const u8, allocator: std.mem.Allocator) !LittleFsIterator {
        const dir = try allocator.create(littlefs.lfs_dir_t);
        const result = littlefs.lfs_dir_open(lfs, dir, path);
        if (result < 0) {
            allocator.destroy(dir);
            return errno_converter.lfs_error_to_errno(result);
        }
        return LittleFsIterator.init(.{
            ._lfs = lfs,
            ._dir = dir,
            ._allocator = allocator,
            ._name = null,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        var info: littlefs.lfs_info = undefined;
        const result = littlefs.lfs_dir_read(self._lfs, self._dir, &info);

        if (result <= 0) {
            return null;
        }

        // Skip "." and ".." entries
        const name_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&info.name)));
        if (std.mem.eql(u8, name_slice, ".") or std.mem.eql(u8, name_slice, "..")) {
            return self.next();
        }

        // Free previous name if exists
        if (self._name) |old_name| {
            self._allocator.free(old_name);
        }

        // Duplicate the name
        self._name = self._allocator.dupe(u8, name_slice) catch return null;

        return .{
            .name = self._name.?,
            .kind = if (info.type == littlefs.LFS_TYPE_DIR)
                kernel.fs.FileType.Directory
            else
                kernel.fs.FileType.File,
        };
    }

    pub fn delete(self: *Self) void {
        _ = littlefs.lfs_dir_close(self._lfs, self._dir);
        if (self._name) |name| {
            self._allocator.free(name);
        }
        self._allocator.destroy(self._dir);
    }
});

pub const LittleFsDirectory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    _allocator: std.mem.Allocator,
    _name: []const u8,
    _path: [:0]const u8,
    _lfs: *littlefs.lfs_t,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, path: [:0]const u8, lfs: *littlefs.lfs_t) !LittleFsDirectory {
        const basename = std.fs.path.basename(path);
        return LittleFsDirectory.init(.{
            ._allocator = allocator,
            ._name = basename,
            ._path = path,
            ._lfs = lfs,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, path: [:0]const u8, lfs: *littlefs.lfs_t) !kernel.fs.Node {
        const dir = try (try create(allocator, path, lfs)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn get(self: *Self, nodename: []const u8, node: *kernel.fs.Node) anyerror!void {
        // Build the full path
        const full_path = if (std.mem.eql(u8, self._path, "/"))
            try std.fmt.allocPrintSentinel(self._allocator, "/{s}", .{nodename}, 0)
        else
            try std.fmt.allocPrintSentinel(self._allocator, "{s}/{s}", .{ self._path, nodename }, 0);
        defer self._allocator.free(full_path);

        // Get info about the entry
        var info: littlefs.lfs_info = undefined;
        const result = littlefs.lfs_stat(self._lfs, full_path, &info);
        if (result < 0) {
            return errno_converter.lfs_error_to_errno(result);
        }

        // Create appropriate node based on type
        const node_path = try self._allocator.dupeZ(u8, full_path);
        if (info.type == littlefs.LFS_TYPE_DIR) {
            node.* = try create_node(self._allocator, node_path, self._lfs);
        } else {
            const LittleFsFile = @import("littlefs_file.zig").LittleFsFile;
            node.* = try LittleFsFile.InstanceType.create_node(self._allocator, node_path, self._lfs);
        }
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        return try (try LittleFsIterator.InstanceType.create(self._lfs, self._path, self._allocator)).interface.new(self._allocator);
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn delete(self: *Self) void {
        self._allocator.free(self._path);
    }
});
