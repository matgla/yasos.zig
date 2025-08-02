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
const IDirectoryIterator = @import("../fs/ifilesystem.zig").IDirectoryIterator;
const IFile = @import("../fs/ifile.zig").IFile;
const ReadOnlyFile = @import("../fs/ifile.zig").ReadOnlyFile;

const interface = @import("interface");

const kernel = @import("../kernel.zig");
const FileName = kernel.fs.FileName;
const FileType = kernel.fs.FileType;

const log = std.log.scoped(.@"vfs/procfs");

const ProcFsIterator = @import("procfs_iterator.zig").ProcFsIterator;
const MemInfoFile = @import("meminfo_file.zig").MemInfoFile;
const ProcInfo = @import("procfs_iterator.zig").ProcInfo;
const ProcInfoType = @import("procfs_iterator.zig").ProcInfoType;

pub const ProcDirectory = interface.DeriveFromBase(ReadOnlyFile, struct {
    const Self = @This();

    base: ReadOnlyFile,
    _allocator: std.mem.Allocator,
    _files: std.DoublyLinkedList,

    pub fn create(allocator: std.mem.Allocator) ProcDirectory {
        return ProcDirectory.init(.{
            .base = ReadOnlyFile.init(.{}),
            ._allocator = allocator,
            ._files = std.DoublyLinkedList{},
        });
    }

    pub fn delete(self: *Self) void {
        var it = self._files.pop();
        while (it) |node| {
            const procinfo: *ProcInfo = @fieldParentPtr("node", node);
            self._allocator.destroy(procinfo);
            it = self._files.pop();
        }
    }

    pub fn add_file(self: *Self, file: *std.DoublyLinkedList.Node) void {
        self._files.append(file);
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?kernel.fs.IFile {
        _ = self;
        log.debug("getting file: {s}", .{path});
        const maybe_filetype = std.meta.stringToEnum(ProcInfoType, path);
        if (maybe_filetype) |f| {
            switch (f) {
                .meminfo => {
                    return (MemInfoFile.InstanceType.create()).interface.new(allocator) catch return null;
                },
            }
        }

        return null;
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        _ = self;
        _ = buffer;
        return 0;
    }

    pub fn seek(self: *Self, offset: c.off_t, whence: i32) c.off_t {
        _ = self;
        _ = offset;
        _ = whence;
        return 0;
    }

    pub fn close(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn tell(self: *Self) c.off_t {
        _ = self;
        return @intCast(0);
    }

    pub fn size(self: *Self) isize {
        _ = self;
        return @intCast(0);
    }

    pub fn name(self: *Self, allocator: std.mem.Allocator) FileName {
        _ = self;
        _ = allocator;
        return .{ ._allocator = null, ._name = "/" };
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        _ = cmd;
        _ = data;
        return 0;
    }

    pub fn fcntl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        _ = cmd;
        _ = data;
        return 0;
    }

    pub fn stat(self: *Self, buf: *c.struct_stat) void {
        buf.st_dev = 0;
        buf.st_ino = 0;
        buf.st_mode = 0;
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = 0;
        buf.st_blksize = 1;
        buf.st_blocks = 1;
        _ = self;
    }

    pub fn filetype(self: *Self) FileType {
        _ = self;
        return FileType.Directory;
    }

    pub fn dupe(self: *Self) ?IFile {
        return self.new(self.allocator) catch return null;
    }
});

pub const ProcFs = interface.DeriveFromBase(ReadOnlyFileSystem, struct {
    const Self = @This();
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _root: ProcDirectory,

    pub fn init(allocator: std.mem.Allocator) !ProcFs {
        log.info("created", .{});
        var procfs = ProcFs.init(.{
            .base = ReadOnlyFileSystem.init(.{}),
            ._allocator = allocator,
            ._root = ProcDirectory.InstanceType.create(allocator),
        });
        var meminfo = try allocator.create(ProcInfo);
        meminfo.node = .{};
        meminfo.infotype = .meminfo;
        procfs.data()._root.data().add_file(&meminfo.node);
        return procfs;
    }

    pub fn delete(self: *Self) void {
        log.debug("deinitialization", .{});
        self._root.data().delete();
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

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?IFile {
        log.debug("Getting file: {s}", .{path});
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return self._root.interface.new(self._allocator) catch return null;
        }
        return self._root.data().get(path, allocator);
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
        log.debug("Getting iterator for: {s}", .{path});
        return (ProcFsIterator.InstanceType.create(self._root.data()._files.first, self._allocator)).interface.new(self._allocator) catch return null;
    }
});
