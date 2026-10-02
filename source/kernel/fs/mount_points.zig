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

const kernel = @import("../kernel.zig");
const IFileSystem = kernel.fs.IFileSystem;
const IDirectoryIterator = kernel.fs.IDirectoryIterator;
const IFile = kernel.fs.IFile;

const config = @import("config");

/// Guards the shape of the mount tree: `find_longest_matching_point` walks it on
/// every `open`, `stat` and `unlink` while `umount` frees nodes underneath, and
/// there is no refcount to stop a walk following a freed pointer.
///
/// Rank `mount` (10), and a sleeping mutex rather than a spin rwlock: it is
/// acquired before `fs` (20), which is itself sleeping, so a spinlock here would
/// be illegal the moment it were held across a filesystem call.
///
/// This makes the walk safe, not the result: the VFS calls into
/// `node.point.filesystem` after the lock is dropped, so a umount in that gap
/// can still free the point. Closing that needs a reference on the returned
/// point -- holding this lock across the call is not an option, because RamFs's
/// tier spills back through `kernel.fs.get_ivfs()` and would re-enter it.
pub var mount_lock: kernel.sync.RankedMutex(.mount) = .{};
const interface = @import("interface");

const log = std.log.scoped(.@"kernel/fs/mount_points");

/// What `/proc/mounts` says about a mount: the first, third and fourth fields
/// of an fstab line. Kept by value, truncated to fit -- it is a description for
/// people and for `umount`'s lookup by device, never something the VFS itself
/// resolves.
pub const MountInfo = struct {
    source_buffer: [48]u8 = undefined,
    source_len: u8 = 0,
    fstype_buffer: [12]u8 = undefined,
    fstype_len: u8 = 0,
    options_buffer: [64]u8 = undefined,
    options_len: u8 = 0,

    pub fn init(source_name: []const u8, fstype_name: []const u8, options_text: []const u8) MountInfo {
        var info: MountInfo = .{};
        info.source_len = copy_truncated(&info.source_buffer, source_name);
        info.fstype_len = copy_truncated(&info.fstype_buffer, fstype_name);
        info.options_len = copy_truncated(&info.options_buffer, if (options_text.len == 0) "rw" else options_text);
        return info;
    }

    fn copy_truncated(buffer: []u8, text: []const u8) u8 {
        const len = @min(buffer.len, text.len);
        @memcpy(buffer[0..len], text[0..len]);
        return @intCast(len);
    }

    pub fn source(self: *const MountInfo) []const u8 {
        return self.source_buffer[0..self.source_len];
    }

    pub fn fstype(self: *const MountInfo) []const u8 {
        return self.fstype_buffer[0..self.fstype_len];
    }

    pub fn options(self: *const MountInfo) []const u8 {
        return self.options_buffer[0..self.options_len];
    }

    /// Mounted with `ro`: the VFS refuses every change under it.
    pub fn read_only(self: *const MountInfo) bool {
        var it = std.mem.splitScalar(u8, self.options(), ',');
        while (it.next()) |option| {
            if (std.mem.eql(u8, option, "ro")) return true;
        }
        return false;
    }
};

pub const MountPoint = struct {
    pub const List = std.DoublyLinkedList;
    path_buffer: [config.fs.max_mount_point_size]u8,
    path: []u8,
    filesystem: IFileSystem,
    info: MountInfo,
    children: List,
    list_node: List.Node,

    pub fn appendChild(self: *MountPoint, allocator: std.mem.Allocator, path: []const u8, filesystem: IFileSystem, info: MountInfo) !void {
        const point = try allocator.create(MountPoint);
        point.* = .{
            .path_buffer = undefined,
            .path = undefined,
            .filesystem = filesystem,
            .info = info,
            .children = .{},
            .list_node = .{},
        };
        @memcpy(point.path_buffer[0..path.len], path);
        point.path = point.path_buffer[0..path.len];
        self.children.append(&point.list_node);
    }

    pub fn removeChild(self: *MountPoint, allocator: std.mem.Allocator, child_path: []const u8) void {
        var next = self.children.first;
        while (next) |node| {
            const child: *MountPoint = @fieldParentPtr("list_node", node);
            next = node.next;
            if (std.mem.eql(u8, child_path, child.path)) {
                self.children.remove(&child.list_node);
                allocator.destroy(child);
                return;
            }
        }
    }

    pub fn deinit(self: *MountPoint, allocator: std.mem.Allocator) void {
        log.debug("destroying '{s}'", .{self.path});
        var it = self.children.pop();
        while (it) |node| {
            const child: *MountPoint = @fieldParentPtr("list_node", node);
            child.deinit(allocator);
            it = self.children.pop();
            allocator.destroy(child);
        }

        self.filesystem.interface.delete();
    }
};

pub const MountPointError = error{
    PathTooLong,
    MountPointNotAbsolutePath,
    RootNotMounted,
    MountPointInUse,
    PathNotExists,
    NotMounted,
};

/// One line of `/proc/mounts` per mount, parents before children, in the
/// Linux format: `source target type options 0 0`.
/// The first four columns are padded to their widest entry, so the file reads
/// as a table; every parser of it (getmntent, toybox, fdisk, mkfs) splits on runs
/// of blanks, as fstab(5) allows.
const MountColumns = struct {
    widths: [4]usize = .{ 0, 0, 0, 0 },

    fn fields(point: *const MountPoint, path: []const u8) [4][]const u8 {
        return .{ point.info.source(), path, point.info.fstype(), point.info.options() };
    }

    fn measure(self: *MountColumns, point: *const MountPoint, path: []const u8) void {
        for (fields(point, path), &self.widths) |field, *width| {
            width.* = @max(width.*, field.len);
        }
    }

    fn write(self: *MountColumns, point: *const MountPoint, path: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (fields(point, path), self.widths) |field, width| {
            try writer.writeAll(field);
            try writer.splatByteAll(' ', width - field.len + 1);
        }
        try writer.writeAll("0 0\n");
    }
};

/// Every mount, parents before children, with its full path: measured into
/// `columns` without a writer, written with one.
fn walk_mounts(point: *const MountPoint, prefix: []const u8, columns: *MountColumns, writer: ?*std.Io.Writer) std.Io.Writer.Error!void {
    var path_buffer: [config.fs.max_mount_point_size * 2]u8 = undefined;
    const full_path = if (prefix.len == 0)
        "/"
    else
        prefix;
    if (writer) |out| {
        try columns.write(point, full_path, out);
    } else {
        columns.measure(point, full_path);
    }
    var next = point.children.first;
    while (next) |node| {
        const child: *const MountPoint = @fieldParentPtr("list_node", node);
        next = node.next;
        const child_path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ prefix, child.path }) catch continue;
        try walk_mounts(child, child_path, columns, writer);
    }
}

fn write_mount_lines(root: *const MountPoint, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var columns: MountColumns = .{};
    try walk_mounts(root, "", &columns, null);
    try walk_mounts(root, "", &columns, writer);
}

pub const MountPoints = struct {
    allocator: std.mem.Allocator,
    root: ?MountPoint = null,

    pub fn init(allocator: std.mem.Allocator) MountPoints {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MountPoints) void {
        if (self.root) |*root| {
            root.deinit(self.allocator);
        }
    }

    /// Named rather than anonymous so the locked and unlocked halves below
    /// share one return type; two `?struct { ... }` literals are two distinct
    /// types even when spelled identically.
    pub fn Match(comptime T: type) type {
        return struct {
            left: []const u8,
            point: T,
            parent: ?T,
        };
    }

    pub fn find_longest_matching_point(self: anytype, T: type, path: []const u8) ?Match(T) {
        mount_lock.lock();
        defer mount_lock.unlock();
        return find_locked(self, T, path);
    }

    /// The walk itself, with `mount_lock` already held. Split out because the
    /// mutators below look points up before changing them, and the lock is
    /// deliberately not recursive.
    pub fn find_locked(self: anytype, T: type, path: []const u8) ?Match(T) {
        mount_lock.assert_held();
        if (self.root == null) {
            return null;
        }
        var maybe_node: ?T = &self.root.?;
        var last_matched_point: T = &self.root.?;
        var parent: T = &self.root.?;
        // skip root searching, already checked
        var left: []const u8 = std.mem.trim(u8, path, "/");
        while (maybe_node) |mountpoint| {
            // already finished
            if (left.len == 0) {
                break;
            }

            // traverse children
            var next = mountpoint.children.first;
            var bestchild: ?*MountPoint = null;

            while (next) |node| {
                const child: *MountPoint = @fieldParentPtr("list_node", node);
                next = node.next;
                // A whole path component, not a string prefix: a mount at
                // /var must not swallow /variable.
                if (std.mem.startsWith(u8, left, child.path) and
                    (left.len == child.path.len or left[child.path.len] == '/'))
                {
                    if (bestchild == null) {
                        bestchild = child;
                        continue;
                    }
                    if (child.path.len > bestchild.?.path.len) {
                        bestchild = child;
                    }
                }
            }

            if (bestchild) |child| {
                parent = mountpoint;
                left = std.mem.trimStart(u8, left[child.path.len..], "/");
                last_matched_point = child;
            }
            maybe_node = bestchild;
        }
        return .{
            .left = left,
            .point = last_matched_point,
            .parent = parent,
        };
    }

    fn mount_root(self: *MountPoints, path: []const u8, filesystem: IFileSystem, info: MountInfo) !void {
        if (!std.mem.eql(u8, path, "/")) {
            return MountPointError.RootNotMounted;
        }
        self.root = .{
            .path_buffer = undefined,
            .path = undefined,
            .filesystem = filesystem,
            .info = info,
            .children = .{},
            .list_node = .{},
        };
        @memcpy(self.root.?.path_buffer[0..path.len], path);
        self.root.?.path = self.root.?.path_buffer[0..path.len];
    }

    pub fn mount_filesystem(self: *MountPoints, path: []const u8, filesystem: IFileSystem) !void {
        return self.mount_filesystem_with_info(path, filesystem, MountInfo.init("none", "none", ""));
    }

    /// Attach `filesystem` at `path`. On success the tree owns it (`umount`
    /// deletes it); on any error it stays the caller's to delete -- nothing is
    /// left behind in the tree, so a failed mount can simply be retried or
    /// replaced by a fallback.
    pub fn mount_filesystem_with_info(self: *MountPoints, path: []const u8, filesystem: IFileSystem, info: MountInfo) !void {
        if (path.len + 1 > config.fs.max_mount_point_size) {
            return error.PathTooLong;
        }

        // Three steps, the lock held only for the first and the last. The
        // middle one calls into filesystems -- the parent to check the target
        // exists, the new one to mount -- and those may come back into the VFS
        // (a bind mount resolves its source through it), which takes this
        // lock again.
        var parent_filesystem: IFileSystem = undefined;
        var left_buffer: [config.fs.max_mount_point_size]u8 = undefined;
        var left: []const u8 = undefined;
        {
            mount_lock.lock();
            defer mount_lock.unlock();
            if (self.root == null) {
                try self.mount_root(path, filesystem, info);
                return;
            }
            if (path.len == 0 or path[0] != '/') {
                return MountPointError.MountPointNotAbsolutePath;
            }
            const match = find_locked(self, *MountPoint, path) orelse return MountPointError.RootNotMounted;
            if (match.left.len == 0) {
                return MountPointError.MountPointInUse;
            }
            parent_filesystem = match.point.filesystem;
            @memcpy(left_buffer[0..match.left.len], match.left);
            left = left_buffer[0..match.left.len];
        }

        // The target has to exist in the filesystem it is mounted over.
        var n = try parent_filesystem.interface.get(left);
        n.delete();

        // Mount first, attach second: a filesystem that refuses the medium
        // (no FAT on the partition, a blank card) must not leave a dead mount
        // point shadowing the directory underneath.
        var fs = filesystem;
        if (fs.interface.mount() < 0) {
            return MountPointError.NotMounted;
        }

        mount_lock.lock();
        defer mount_lock.unlock();
        // Somebody may have mounted the same place in the meantime.
        const match = find_locked(self, *MountPoint, path) orelse {
            _ = fs.interface.umount();
            return MountPointError.RootNotMounted;
        };
        if (match.left.len == 0) {
            _ = fs.interface.umount();
            return MountPointError.MountPointInUse;
        }
        match.point.appendChild(self.allocator, match.left, filesystem, info) catch |err| {
            _ = fs.interface.umount();
            return err;
        };
    }

    /// Whether anything is mounted from `source` (as recorded in its
    /// `MountInfo`), so a partition table is not rewritten under a live
    /// filesystem.
    pub fn is_source_mounted(self: *MountPoints, source: []const u8) bool {
        mount_lock.lock();
        defer mount_lock.unlock();
        if (self.root) |*root| {
            return point_uses_source(root, source);
        }
        return false;
    }

    fn point_uses_source(point: *const MountPoint, source: []const u8) bool {
        if (std.mem.eql(u8, point.info.source(), source)) return true;
        var next = point.children.first;
        while (next) |node| {
            const child: *const MountPoint = @fieldParentPtr("list_node", node);
            next = node.next;
            if (point_uses_source(child, source)) return true;
        }
        return false;
    }

    /// The `/proc/mounts` text.
    pub fn write_mounts(self: *MountPoints, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        mount_lock.lock();
        defer mount_lock.unlock();
        if (self.root) |*root| {
            try write_mount_lines(root, writer);
        }
    }

    pub fn umount(self: *MountPoints, path: []const u8) !void {
        mount_lock.lock();
        defer mount_lock.unlock();
        const maybe_longest_matching_point = find_locked(self, *MountPoint, path);
        if (maybe_longest_matching_point == null) {
            return MountPointError.NotMounted;
        }
        const longest_matching_point = maybe_longest_matching_point.?;
        if (longest_matching_point.left.len != 0) {
            return MountPointError.NotMounted;
        }
        // Something is mounted below it: taking this one away would take those
        // along, silently. Linux answers EBUSY; so does this.
        if (longest_matching_point.point.children.first != null) {
            return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
        }

        longest_matching_point.point.deinit(self.allocator);
        if (longest_matching_point.parent) |parent| {
            parent.removeChild(self.allocator, longest_matching_point.point.path);
        }

        if (std.mem.eql(u8, path, "/")) {
            self.root = null;
        }
    }
};

test "MountPoints.ShouldErrorWhenRootNotMounted" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    var filesystem_mock = try FileSystemMock.create(std.testing.allocator);
    var fs = filesystem_mock.get_interface();
    defer fs.interface.delete();

    try std.testing.expectError(MountPointError.RootNotMounted, sut.mount_filesystem("/a", fs));
}

test "MountPoints.MountRoot" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    var filesystem_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = filesystem_mock.get_interface();

    try sut.mount_filesystem("/", fs);
    try std.testing.expect(sut.root != null);
    try std.testing.expectEqualStrings("/", sut.root.?.path);
}

test "MountPoints.RejectTooLongPath" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    var filesystem_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = filesystem_mock.get_interface();

    try sut.mount_filesystem("/", fs);
    try std.testing.expectError(MountPointError.PathTooLong, sut.mount_filesystem(&@as([config.fs.max_mount_point_size + 1]u8, @splat('/')), fs));
}

test "MountPoints.RejectRootIfAlreadyMounted" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    var filesystem_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = filesystem_mock.get_interface();

    try sut.mount_filesystem("/", fs);
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/", fs));
}

fn create_filesystem_mock(context: anytype) !kernel.fs.IFileSystem {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    const ReturnSharedMock = struct {
        pub fn call(ctx: ?*const anyopaque, args: @Tuple(&[_]type{[]const u8})) anyerror!anyerror!kernel.fs.Node {
            _ = args;
            const c: @TypeOf(context) = @ptrCast(@alignCast(ctx.?));
            return c.file.share();
        }
    };
    _ = fs2_mock.expectCall("get")
        .withArgs(.{interface.mock.any{}})
        .invoke(&ReturnSharedMock.call, context)
        .times(interface.mock.any{});

    _ = fs2_mock.expectCall("mount")
        .withArgs(.{})
        .willReturn(0)
        .times(interface.mock.any{});
    return fs2;
}

test "MountPoints.MountChilds" {
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    var file_mock = try FileMock.create(std.testing.allocator);
    var file = file_mock.get_interface();
    defer file.interface.delete();

    var file_to_return: kernel.fs.Node = kernel.fs.Node.create_file(file);

    const CallContext = struct {
        file: *kernel.fs.Node,
    };
    const context = CallContext{
        .file = &file_to_return,
    };

    const fs = try create_filesystem_mock(&context);

    var maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/b/x/d");
    try std.testing.expect(maybe_child == null);

    try sut.mount_filesystem("/", fs);

    const fs2 = try create_filesystem_mock(&context);
    try sut.mount_filesystem("/a/b", fs2);

    try std.testing.expect(sut.root != null);
    try std.testing.expectEqual(1, sut.root.?.children.len());
    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/b/x/d");

    try std.testing.expect(maybe_child != null);
    var child = maybe_child.?;
    try std.testing.expectEqualStrings("x/d", child.left);
    try std.testing.expectEqualStrings("a/b", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c");
    try std.testing.expect(maybe_child != null);

    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c", child.left);
    try std.testing.expectEqualStrings("/", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/d", child.left);
    try std.testing.expectEqualStrings("/", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    const fs3 = try create_filesystem_mock(&context);
    try sut.mount_filesystem("/a/c", fs3);
    maybe_child = sut.find_longest_matching_point(*const MountPoint, "a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("d", child.left);
    try std.testing.expectEqualStrings("a/c", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);

    const fs4 = try create_filesystem_mock(&context);
    try sut.mount_filesystem("/a/c/a/c/", fs4);
    maybe_child = sut.find_longest_matching_point(*const MountPoint, "a/c/a");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a", child.left);
    try std.testing.expectEqualStrings("a/c", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("/", child.parent.?.path);
    maybe_child = sut.find_longest_matching_point(*const MountPoint, "a/c/a/c/d/u/p");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("d/u/p", child.left);
    try std.testing.expectEqualStrings("a/c", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("a/c", child.parent.?.path);

    const fs5 = try create_filesystem_mock(&context);
    try sut.mount_filesystem("/a/c/a/c/e", fs5);
    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/a/c/e/deep/path/is/here");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("deep/path/is/here", child.left);
    try std.testing.expectEqualStrings("e", child.point.path);
    try std.testing.expect(child.parent != null);
    try std.testing.expectEqualStrings("a/c", child.parent.?.path);

    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/", fs));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c", fs));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/b", fs));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c", fs));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c/a/c", fs));
    try std.testing.expectError(MountPointError.MountPointInUse, sut.mount_filesystem("/a/c/a/c/e", fs));
}

test "MountPoints.ReportErrorWhenTryingToMountRelativePath" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    try sut.mount_filesystem("/", fs);
    try std.testing.expectError(MountPointError.MountPointNotAbsolutePath, sut.mount_filesystem("otherfs/smth", fs));
    try std.testing.expectError(MountPointError.MountPointNotAbsolutePath, sut.mount_filesystem("", fs));
}

test "MountPoints.HandleNotExistingPath" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    const fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    try sut.mount_filesystem("/", fs);
    _ = fs_mock
        .expectCall("get")
        .withArgs(.{ interface.mock.any{}, interface.mock.any{} })
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.mount_filesystem("/a/c", fs));

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();

    const fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();
    _ = fs_mock
        .expectCall("get")
        .withArgs(.{ interface.mock.any{}, interface.mock.any{} })
        .willReturn(kernel.fs.Node.create_file(file));

    _ = fs2_mock
        .expectCall("mount")
        .withArgs(.{})
        .willReturn(0)
        .times(interface.mock.any{});

    try sut.mount_filesystem("/a/c", fs2);

    _ = fs2_mock
        .expectCall("get")
        .withArgs(.{ interface.mock.any{}, interface.mock.any{} })
        .willReturn(kernel.errno.ErrnoSet.NoEntry);
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.mount_filesystem("/a/c/d", fs2));
}

test "MountPoints.RemoveChilds" {
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    var file_mock = try FileMock.create(std.testing.allocator);
    var file = file_mock.get_interface();
    defer file.interface.delete();

    var file_to_return: kernel.fs.Node = kernel.fs.Node.create_file(file);

    const CallContext = struct {
        file: *kernel.fs.Node,
    };
    const context = CallContext{
        .file = &file_to_return,
    };

    const fs1 = try create_filesystem_mock(&context);
    const fs2 = try create_filesystem_mock(&context);
    const fs3 = try create_filesystem_mock(&context);
    const fs4 = try create_filesystem_mock(&context);
    const fs5 = try create_filesystem_mock(&context);
    const fs6 = try create_filesystem_mock(&context);

    try sut.mount_filesystem("/", fs1);
    try sut.mount_filesystem("/a/b", fs2);
    try sut.mount_filesystem("/a/c", fs3);
    try sut.mount_filesystem("/a/c/a/c/", fs4);
    try sut.mount_filesystem("/a/c/e", fs5);
    try sut.mount_filesystem("/a/c/e/c/f", fs6);

    var maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/e/c/f/deep/path");
    try std.testing.expect(maybe_child != null);
    var child = maybe_child.?;
    try std.testing.expectEqualStrings("deep/path", child.left);
    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/b/c");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("c", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("d", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/a/c/x");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("x", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/e/f");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("f", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/b");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("", child.left);

    // Busy while anything is mounted below it; children go first.
    try std.testing.expectError(kernel.errno.ErrnoSet.DeviceOrResourceBusy, sut.umount("/a/c"));
    try std.testing.expectError(kernel.errno.ErrnoSet.DeviceOrResourceBusy, sut.umount("/a/c/e"));
    _ = try sut.umount("/a/c/e/c/f");
    _ = try sut.umount("/a/c/e");
    _ = try sut.umount("/a/c/a/c");
    _ = try sut.umount("/a/c");

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/e/c/f/deep/path");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/e/c/f/deep/path", child.left);
    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/b/c");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("c", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/d");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/d", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/a/c/x");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/a/c/x", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/c/e/f");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("a/c/e/f", child.left);

    maybe_child = sut.find_longest_matching_point(*const MountPoint, "/a/b");
    try std.testing.expect(maybe_child != null);
    child = maybe_child.?;
    try std.testing.expectEqualStrings("", child.left);
}

test "MountPoints.MatchesWholeComponentsOnly" {
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var sut = MountPoints.init(std.testing.allocator);
    defer sut.deinit();

    var file_mock = try FileMock.create(std.testing.allocator);
    var file = file_mock.get_interface();
    defer file.interface.delete();
    var file_to_return: kernel.fs.Node = kernel.fs.Node.create_file(file);
    const context = struct { file: *kernel.fs.Node }{ .file = &file_to_return };

    try sut.mount_filesystem("/", try create_filesystem_mock(&context));
    try sut.mount_filesystem_with_info("/var", try create_filesystem_mock(&context), MountInfo.init("/dev/mmc0p2", "vfat", "rw"));

    const exact = sut.find_longest_matching_point(*const MountPoint, "/var/log").?;
    try std.testing.expectEqualStrings("var", exact.point.path);
    try std.testing.expectEqualStrings("log", exact.left);

    // A sibling that merely starts with the same letters stays on the root.
    const sibling = sut.find_longest_matching_point(*const MountPoint, "/variable/x").?;
    try std.testing.expectEqualStrings("/", sibling.point.path);
    try std.testing.expectEqualStrings("variable/x", sibling.left);

    try std.testing.expect(sut.is_source_mounted("/dev/mmc0p2"));
    try std.testing.expect(!sut.is_source_mounted("/dev/mmc0p3"));

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try sut.write_mounts(&writer);
    try std.testing.expectEqualStrings(
        "none        /    none rw 0 0\n" ++
            "/dev/mmc0p2 /var vfat rw 0 0\n",
        writer.buffered(),
    );
}
