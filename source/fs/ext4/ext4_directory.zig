//
// ext4_directory.zig
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

//! A directory on an ext4 volume, and the iterator getdents walks it with.
//! "." and ".." are left out, as every other filesystem here does.

const std = @import("std");

const interface = @import("interface");
const kernel = @import("kernel");

const ext4fs = @import("ext4fs.zig");
const lwext4 = ext4fs.lwext4;

fn kind_of(inode_type: u8) kernel.fs.FileType {
    return switch (inode_type) {
        lwext4.EXT4_DE_DIR => .Directory,
        lwext4.EXT4_DE_SYMLINK => .SymbolicLink,
        lwext4.EXT4_DE_CHRDEV => .CharDevice,
        lwext4.EXT4_DE_BLKDEV => .BlockDevice,
        lwext4.EXT4_DE_FIFO => .Fifo,
        lwext4.EXT4_DE_SOCK => .Socket,
        else => .File,
    };
}

pub const Ext4Iterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    const Self = @This();
    /// On the heap: lwext4 keeps pointers into it while it is open.
    _dir: *lwext4.ext4_dir,
    _allocator: std.mem.Allocator,
    _name: [256]u8,

    pub fn create(dir: *lwext4.ext4_dir, allocator: std.mem.Allocator) Ext4Iterator {
        return Ext4Iterator.init(.{
            ._dir = dir,
            ._allocator = allocator,
            ._name = undefined,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.DirectoryEntry {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        while (lwext4.ext4_dir_entry_next(self._dir)) |entry| {
            const length = entry.*.name_length;
            const entry_name = entry.*.name[0..length];
            if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
            @memcpy(self._name[0..length], entry_name);
            return .{ .name = self._name[0..length], .kind = kind_of(entry.*.inode_type) };
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        _ = lwext4.ext4_dir_close(self._dir);
        self._allocator.destroy(self._dir);
    }
});

pub const Ext4Directory = interface.DeriveFromBase(kernel.fs.IDirectory, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _name: []const u8,
    _path: [:0]const u8,

    /// `full` is the lwext4 path. The caller holds `ext4fs.lock`.
    pub fn create(allocator: std.mem.Allocator, full: [:0]const u8) !Ext4Directory {
        const path = try allocator.dupeSentinel(u8, full, 0);
        errdefer allocator.free(path);
        return Ext4Directory.init(.{
            ._allocator = allocator,
            ._name = try allocator.dupe(u8, std.fs.path.basename(std.mem.trimEnd(u8, full, "/"))),
            ._path = path,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, full: [:0]const u8) !kernel.fs.Node {
        const dir = try (try create(allocator, full)).interface.new(allocator);
        return kernel.fs.Node.create_directory(dir);
    }

    pub fn get(self: *Self, nodename: []const u8, node: *kernel.fs.Node) anyerror!void {
        _ = self;
        _ = nodename;
        _ = node;
        return error.NotImplemented;
    }

    pub fn iterator(self: *const Self) anyerror!kernel.fs.IDirectoryIterator {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        const dir = try self._allocator.create(lwext4.ext4_dir);
        errdefer self._allocator.destroy(dir);
        try ext4fs.check(lwext4.ext4_dir_open(dir, self._path.ptr));
        return Ext4Iterator.InstanceType.create(dir, self._allocator).interface.new(self._allocator) catch {
            _ = lwext4.ext4_dir_close(dir);
            return error.OutOfMemory;
        };
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn delete(self: *Self) void {
        self._allocator.free(self._name);
        self._allocator.free(self._path);
    }
});
