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

const std = @import("std");

const c = @import("libc_imports").c;

const ReadOnlyFileSystem = @import("../fs/ifilesystem.zig").ReadOnlyFileSystem;
const IDirectoryIterator = @import("../fs/idirectory.zig").IDirectoryIterator;
const IFile = @import("../fs/ifile.zig").IFile;
const ReadOnlyFile = @import("../fs/ifile.zig").ReadOnlyFile;

const interface = @import("interface");

const kernel = @import("../kernel.zig");
const FileName = kernel.fs.FileName;
const FileType = kernel.fs.FileType;

const log = std.log.scoped(.@"vfs/procfs");

const MemInfoFile = @import("meminfo_file.zig").MemInfoFile;
const ProcInfo = @import("procfs_iterator.zig").ProcInfo;
const ProcInfoType = @import("procfs_iterator.zig").ProcInfoType;

const ProcFsDirectory = @import("procfs_directory.zig").ProcFsDirectory;

pub const ProcFs = interface.DeriveFromBase(ReadOnlyFileSystem, struct {
    const Self = @This();
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _root: kernel.fs.IDirectory,

    pub fn init(allocator: std.mem.Allocator) !ProcFs {
        var procfs = ProcFs.init(.{
            .base = ReadOnlyFileSystem.init(.{}),
            ._allocator = allocator,
            ._root = try (try ProcFsDirectory.InstanceType.create(allocator, "/")).interface.new(allocator),
        });

        var root_directory = procfs.data()._root.as(ProcFsDirectory);
        const meminfo = try MemInfoFile.InstanceType.create_node(allocator);

        try root_directory.data().append(meminfo);
        return procfs;
    }

    pub fn delete(self: *Self) void {
        log.debug("deinitialization", .{});
        self._root.interface.delete();
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "procfs";
    }

    pub fn traverse(self: *Self, path: []const u8, callback: *const fn (file: *IFile, context: *anyopaque) bool, user_context: *anyopaque) i32 {
        _ = self;
        _ = path;
        _ = callback;
        _ = user_context;
        return -1;
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?kernel.fs.Node {
        _ = allocator;
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return kernel.fs.Node.create_directory(self._root.share());
        }
        var result: kernel.fs.Node = undefined;
        self._root.interface.get(path, &result) catch return null;
        return result;
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        var maybe_node = self.get(path, self._allocator);
        if (maybe_node) |*node| {
            node.delete();
            return true;
        }
        return false;
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        // ProcDirectory is read-only, so formatting is not applicable
        return error.NotSupported;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) i32 {
        var maybe_node = self.get(path, self._allocator);
        if (maybe_node) |*node| {
            defer node.delete();
            if (node.is_directory()) {
                data.st_mode = c.S_IFDIR;
            } else {
                data.st_mode = c.S_IFREG;
            }
        }
        return 0;
    }
});
