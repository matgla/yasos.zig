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
const MaxProcFile = @import("maxproc_file.zig").MaxProcFile;

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
            ._root = try (try ProcFsDirectory.InstanceType.create(allocator, "/", true)).interface.new(allocator),
        });

        var root_directory = procfs.data()._root.as(ProcFsDirectory);
        const meminfo = try MemInfoFile.InstanceType.create_node(allocator);

        var sys_directory_node = try ProcFsDirectory.InstanceType.create_node(allocator, "sys", false);
        var maybe_sys_directory = sys_directory_node.as_directory();
        if (maybe_sys_directory) |*sys_dir| {
            var sys_directory = sys_dir.as(ProcFsDirectory);
            const kernel_directory_node = try ProcFsDirectory.InstanceType.create_node(allocator, "kernel", false);
            var maybe_kernel_directory = kernel_directory_node.as_directory();
            if (maybe_kernel_directory) |*kernel_dir| {
                var kernel_directory = kernel_dir.as(ProcFsDirectory);
                const maxpid_file = try MaxProcFile.InstanceType.create_node(allocator);
                try kernel_directory.data().append(maxpid_file);
            }
            try sys_directory.data().append(kernel_directory_node);
        }

        try root_directory.data().append(meminfo);
        try root_directory.data().append(sys_directory_node);
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

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!i32 {
        _ = flags;
        var maybe_node = self.get(path, self._allocator);
        defer if (maybe_node) |*n| n.delete();
        if ((mode & c.F_OK) != 0) {
            if (maybe_node == null) {
                return kernel.errno.ErrnoSet.NoEntry;
            }
        }

        if ((mode & c.X_OK) != 0) {
            return kernel.errno.ErrnoSet.PermissionDenied;
        }

        if ((mode & c.W_OK) != 0) {
            return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
        }
        return 0;
    }

    // fn sync(self: *Self) void {
    //     const pidmap = kernel.process.process_manager.instance().get_pidmap();
    //     var it = pidmap.iterator(.{
    //         .kind = .unset,
    //     });
    //     while (it.next()) |pid| {
    //         self._root.
    //     }
    // }

    pub fn get(self: *Self, path: []const u8, allocator: std.mem.Allocator) ?kernel.fs.Node {
        _ = allocator;

        if (path.len == 0) {
            return kernel.fs.Node.create_directory(self._root.share());
        }

        const resolved_path = std.fs.path.resolve(self._allocator, &.{path}) catch return null;
        defer self._allocator.free(resolved_path);
        var it = try std.fs.path.componentIterator(resolved_path);
        var current_directory = self._root;
        var node_to_remove: ?kernel.fs.Node = null;
        while (it.next()) |component| {
            var next_node: kernel.fs.Node = undefined;
            current_directory.interface.get(component.name, &next_node) catch {
                if (node_to_remove) |*node| {
                    node.delete();
                }
                return null;
            };
            if (it.peekNext() != null) {
                // defer next_node.delete();
                if (node_to_remove) |*node| {
                    node.delete();
                }
                node_to_remove = next_node;
                if (!next_node.is_directory()) {
                    if (node_to_remove) |*node| {
                        node.delete();
                    }
                    return null;
                }

                current_directory = next_node.as_directory().?;
            } else {
                if (node_to_remove) |*node| {
                    node.delete();
                }
                return next_node;
            }
        }

        if (node_to_remove) |*node| {
            node.delete();
        }
        return null;
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
            return 0;
        }
        return -1;
    }
});
