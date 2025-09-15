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

const ProcFsDirectory = struct {
    _nodes: std.DoublyLinkedList,
    _allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) ProcFsDirectory {
        return ProcFsDirectory{
            ._nodes = std.DoublyLinkedList{},
            ._allocator = allocator,
        };
    }

    pub fn append(self: *ProcFsDirectory, node: *std.DoublyLinkedList.Node) void {
        self._nodes.append(node);
    }

    pub fn delete(self: *ProcFsDirectory) void {
        var next = self._nodes.pop();
        while (next) |node| {
            const proc_node: *ProcFsNode = @fieldParentPtr("_node", node);
            proc_node.delete();
            next = self._nodes.pop();
        }
    }

    pub fn get(self: *ProcFsDirectory, name: []const u8) ?*ProcFsNode {
        var it = self._nodes.first;
        while (it) |node| {
            const proc_node: *ProcFsNode = @fieldParentPtr("_node", node);
            if (std.mem.eql(u8, proc_node._name.get_name(), name)) {
                return proc_node;
            }
            it = node.next;
        }
        return null;
    }

    pub fn stat(self: ProcFsDirectory, data: *c.struct_stat) i32 {
        log.err("Stating directory", .{});
        _ = self;
        data.st_mode = 0;
        data.st_nlink = 0;
        data.st_size = 0;
        data.st_blksize = 4096;
        data.st_blocks = 0;
        data.st_atim.tv_sec = 0;
        data.st_atim.tv_nsec = 0;
        data.st_mtim.tv_sec = 0;
        data.st_mtim.tv_nsec = 0;
        data.st_ctim.tv_sec = 0;
        data.st_ctim.tv_nsec = 0;
        return -1;
    }
};

const ProcFsNode = struct {
    const Type = union(enum) {
        directory: ProcFsDirectory,
        file: IFile,
    };

    _name: FileName,
    _data: Type,
    _node: std.DoublyLinkedList.Node,

    pub fn delete(self: *ProcFsNode) void {
        switch (self._data) {
            .directory => {
                self._data.directory.delete();
            },
            .file => {
                self._data.file.interface.delete();
            },
        }
    }

    pub fn create_file(name: FileName, file: IFile) ProcFsNode {
        return ProcFsNode{
            ._name = name,
            ._data = .{ .file = file },
            ._node = std.DoublyLinkedList.Node{},
        };
    }

    pub fn create_directory(name: FileName, allocator: std.mem.Allocator) ProcFsNode {
        return ProcFsNode{
            ._name = name,
            ._data = .{ .directory = ProcFsDirectory.create(allocator) },
            ._node = std.DoublyLinkedList.Node{},
        };
    }

    pub fn get_name(self: ProcFsNode, allocator: std.mem.Allocator) FileName {
        _ = allocator;
        return FileName.init(self._name.get_name(), null);
    }

    pub fn filetype(self: *ProcFsNode) FileType {
        return switch (self._data) {
            .directory => FileType.Directory,
            .file => self._data.file.interface.filetype(),
        };
    }

    pub fn get_directory(self: *ProcFsNode) ?*ProcFsDirectory {
        return switch (self._data) {
            .directory => &self._data.directory,
            .file => null,
        };
    }

    pub fn get_file(self: *ProcFsNode) ?IFile {
        return switch (self._data) {
            .directory => null,
            .file => self._data.file,
        };
    }

    fn stat_file(self: *ProcFsNode, data: *c.struct_stat) i32 {
        log.err("Stating file: '{s}'", .{self._name.get_name()});
        data.st_mode = 0;
        data.st_nlink = 0;
        data.st_size = 0;
        data.st_blksize = 0;
        data.st_blocks = 0;
        data.st_atim.tv_sec = 0;
        data.st_atim.tv_nsec = 0;
        data.st_mtim.tv_sec = 0;
        data.st_mtim.tv_nsec = 0;
        data.st_ctim.tv_sec = 0;
        data.st_ctim.tv_nsec = 0;
        return 0;
    }

    pub fn stat(self: *ProcFsNode, data: *c.struct_stat) i32 {
        log.err("Stating node: '{s}', for 0x{x}", .{ self._name.get_name(), @intFromPtr(data) });
        data.st_mode = c.S_IFDIR;
        data.st_nlink = 0;
        data.st_size = 0;
        data.st_blksize = 0;
        data.st_blocks = 0;
        data.st_atim.tv_sec = 0;
        data.st_atim.tv_nsec = 0;
        data.st_mtim.tv_sec = 0;
        data.st_mtim.tv_nsec = 0;
        data.st_ctim.tv_sec = 0;
        data.st_ctim.tv_nsec = 0;
        // return switch (self._data) {
        // .directory => self._data.directory.stat(data),
        // .file => self.stat_file(data),
        // };
        return -1;
    }
};

pub const ProcFs = interface.DeriveFromBase(ReadOnlyFileSystem, struct {
    const Self = @This();
    base: ReadOnlyFileSystem,
    _allocator: std.mem.Allocator,
    _root: ProcFsNode,

    pub fn init(allocator: std.mem.Allocator) !ProcFs {
        var procfs = ProcFs.init(.{
            .base = ReadOnlyFileSystem.init(.{}),
            ._allocator = allocator,
            ._root = ProcFsNode.create_directory(FileName.init("/", null), allocator),
        });

        var meminfo = ProcFsNode.create_file(FileName.init("meminfo", null), try MemInfoFile.InstanceType.create().interface.new(allocator));
        procfs.data()._root.get_directory().?.append(&meminfo._node);

        return procfs;
    }

    pub fn delete(self: *Self) void {
        log.debug("deinitialization", .{});
        self._root.delete();
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

    fn get_node(self: *Self, path: []const u8) ?*ProcFsNode {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return &self._root;
        }
        var iter = std.fs.path.componentIterator(path) catch return null;
        var node = &self._root;
        while (iter.next()) |component| {
            const maybe_dir = node.get_directory();
            if (maybe_dir) |dir| {
                node = dir.get(component.name) orelse return null;
            } else {
                return null;
            }
        }
        return node;
    }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?IFile {
        _ = allocator;
        log.err("Getting file: {s}", .{path});
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return null;
        }
        var iter = std.fs.path.componentIterator(path) catch return null;
        var node = &self._root;
        while (iter.next()) |component| {
            const maybe_dir = node.get_directory();
            if (maybe_dir) |dir| {
                node = dir.get(component.name) orelse return null;
            } else {
                return null;
            }
        }
        // last node must be a file
        const maybe_file = node.get_file();
        if (maybe_file) |file| {
            return file.clone() catch return null;
        }
        return null;
    }

    pub fn has_path(self: *Self, path: []const u8) bool {
        _ = self;
        _ = path;
        return false;
    }

    pub fn iterator(self: *Self, path: []const u8) ?IDirectoryIterator {
        log.debug("Getting iterator for: {s}", .{path});
        const dir = self.get_node(path) orelse return null;
        return ProcFsIterator.InstanceType.create(&dir._node, self._allocator).interface.new(self._allocator) catch return null;
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        // ProcDirectory is read-only, so formatting is not applicable
        return error.NotSupported;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat) i32 {
        log.err("Stating path: '{s}'", .{path});
        var node = self.get_node(path) orelse return -1;
        return node.stat(data);
    }
});

pub const ProcFsIterator = interface.DeriveFromBase(kernel.fs.IDirectoryIterator, struct {
    pub const Self = @This();
    _node: ?*std.DoublyLinkedList.Node,
    _allocator: std.mem.Allocator,

    pub fn create(first_node: ?*std.DoublyLinkedList.Node, allocator: std.mem.Allocator) ProcFsIterator {
        return ProcFsIterator.init(.{
            ._node = first_node,
            ._allocator = allocator,
        });
    }

    pub fn next(self: *Self) ?kernel.fs.INode {
        if (self._node) |node| {
            self._node = node.next;
            const proc_node: *ProcFsNode = @fieldParentPtr("_node", node);
            return proc_node.get_node();
        }
        return null;
    }

    pub fn delete(self: *Self) void {
        _ = self;
    }
});
