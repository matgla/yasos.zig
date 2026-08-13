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
const vfmt = @import("../vfmt.zig");

const c = @import("libc_imports").c;

const IFileSystem = @import("ifilesystem.zig").IFileSystem;
const IDirectoryIterator = @import("idirectory.zig").IDirectoryIterator;
const IFile = @import("ifile.zig").IFile;
const MountPoints = @import("mount_points.zig").MountPoints;
const MountPoint = @import("mount_points.zig").MountPoint;

const kernel = @import("../kernel.zig");
const perf = @import("../interrupts/perf_profile.zig");

const interface = @import("interface");

const log = std.log.scoped(.vfs);

// Maximum number of symbolic links resolved while walking a single path before
// giving up with ELOOP.
const max_symlink_depth = 16;
// Working buffer size for symlink targets. Generous headroom over PATH_MAX (128).
const symlink_target_buffer = 256;

/// Does this mount, or anything mounted under it, hold a filesystem that can
/// represent a symbolic link?
fn mount_subtree_supports_symlinks(point: *const MountPoint) bool {
    var mutable_filesystem = point.filesystem;
    if (mutable_filesystem.interface.supports_symlinks()) return true;
    var next = point.children.first;
    while (next) |node| : (next = node.next) {
        const child: *const MountPoint = @fieldParentPtr("list_node", node);
        if (mount_subtree_supports_symlinks(child)) return true;
    }
    return false;
}

pub const VirtualFileSystem = interface.DeriveFromBase(IFileSystem, struct {
    const Self = @This();
    mount_points: MountPoints,

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn umount(self: *Self) i32 {
        _ = self;
        return 0;
    }

    // ------------------------------------------------------------------
    // Raw delegation helpers — route a path to the owning mounted filesystem
    // WITHOUT any symbolic-link resolution. The public methods below add
    // failure-triggered resolution on top of these.
    // ------------------------------------------------------------------
    fn raw_create(self: *Self, path: []const u8, mode: i32) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.create(node.left, mode);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.mkdir(node.left, mode);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_unlink(self: *Self, path: []const u8) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return node.point.filesystem.interface.unlink(node.left);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        const t_mount = if (perf.enabled) perf.read_cycles() else 0;
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        const t_fsget = if (perf.enabled) perf.read_cycles() else 0;
        if (perf.enabled) perf.vfs_mount(t_fsget -% t_mount);
        if (maybe_node) |*node| {
            defer if (perf.enabled) perf.vfs_fsget(perf.read_cycles() -% t_fsget);
            return try node.point.filesystem.interface.get(node.left);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            const trimmed_path = std.mem.trim(u8, node.left, "/ ");
            return try node.point.filesystem.interface.stat(trimmed_path, data, follow_symlinks);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.access(node.left, mode, flags);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.readlink(node.left, buffer);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, linkpath);
        if (maybe_node) |*node| {
            return try node.point.filesystem.interface.symlink(target, node.left);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    // Walk `path` left to right; whenever a path component is a symbolic link,
    // splice in its target (crossing mount points) and restart. Returns a newly
    // allocated, fully-resolved absolute path if any link was followed, or null
    // if the path contained no symlink components (caller keeps the original).
    // `follow_final` controls whether the last component is resolved — false for
    // create/mkdir/unlink/lstat (operate on the link itself), true for get/stat.
    //
    // This is only ever called after a raw_* call has already failed -- which
    // is not as rare as it sounds: a library or include search is a sequence of
    // deliberate misses, and each one arrives here. The pass itself is not free
    // either, since every component it examines costs a `stat`, and on FAT a
    // stat is a directory walk. Hence `prefix_can_hold_symlink` below.
    ///
    /// Can the filesystem holding `prefix` represent a symbolic link at all?
    ///
    /// The mount owning the longest matching prefix is the one that would have
    /// to store it. A FAT or littlefs mount answers no for its whole subtree,
    /// so every component under it can be skipped without a stat. Unmounted
    /// paths answer no as well: there is nothing there to resolve.
    fn prefix_can_hold_symlink(self: *Self, prefix: []const u8) bool {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, prefix);
        if (maybe_node) |node| {
            return node.point.filesystem.interface.supports_symlinks();
        }
        return false;
    }

    fn resolve_symlinks(self: *Self, path: []const u8, follow_final: bool) anyerror!?[]u8 {
        const allocator = self.mount_points.allocator;
        var cur = try allocator.dupe(u8, path);
        errdefer allocator.free(cur);
        var changed = false;
        var depth: usize = 0;

        outer: while (true) {
            var i: usize = 0;
            var comp_start: usize = 0;
            while (i <= cur.len) : (i += 1) {
                if (i < cur.len and cur[i] != '/') continue;
                if (i == comp_start) {
                    comp_start = i + 1;
                    continue;
                }
                const prefix = cur[0..i];
                // Is this the last non-empty component?
                var j = i;
                while (j < cur.len and cur[j] == '/') j += 1;
                const is_final = j >= cur.len;
                if (is_final and !follow_final) break;

                // Nothing to find here, so do not pay a directory walk asking.
                if (!self.prefix_can_hold_symlink(prefix)) {
                    comp_start = i + 1;
                    continue;
                }

                var st: c.struct_stat = undefined;
                self.raw_stat(prefix, &st, false) catch break;

                if ((st.st_mode & c.S_IFMT) == c.S_IFLNK) {
                    depth += 1;
                    if (depth > max_symlink_depth) return kernel.errno.ErrnoSet.TooManySymbolicLinks;

                    var target_buffer: [symlink_target_buffer]u8 = undefined;
                    const n = self.raw_readlink(prefix, target_buffer[0..]) catch break;
                    const target = target_buffer[0..n];
                    const remainder = cur[i..];
                    // Absolute target replaces from root; relative target resolves
                    // against the link's parent directory (cur[0..comp_start]).
                    const base = if (target.len > 0 and target[0] == '/') "" else cur[0..comp_start];
                    const joined = try vfmt.allocPrint(allocator, "{s}{s}{s}", .{ base, target, remainder });
                    defer allocator.free(joined);
                    const normalized = try std.fs.path.resolve(allocator, &.{joined});
                    allocator.free(cur);
                    cur = normalized;
                    changed = true;
                    continue :outer;
                }
                comp_start = i + 1;
            }
            break;
        }

        if (!changed) {
            allocator.free(cur);
            return null;
        }
        return cur;
    }

    pub fn create(self: *Self, path: []const u8, mode: i32) anyerror!void {
        return self.raw_create(path, mode) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_create(resolved, mode);
            }
            return err;
        };
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        return self.raw_mkdir(path, mode) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_mkdir(resolved, mode);
            }
            return err;
        };
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        return self.raw_unlink(path) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_unlink(resolved);
            }
            return err;
        };
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "vfs";
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        return self.raw_get(path) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, true) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_get(resolved);
            }
            return err;
        };
    }

    pub fn delete(self: *Self) void {
        self.mount_points.deinit();
    }

    pub fn format(self: *Self) anyerror!void {
        // VirtualFileSystem does not support formatting
        _ = self;
        return error.NotSupported;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        return self.raw_stat(path, data, follow_symlinks) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, follow_symlinks) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_stat(resolved, data, follow_symlinks);
            }
            return err;
        };
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        return self.raw_readlink(path, buffer) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_readlink(resolved, buffer);
            }
            return err;
        };
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        return self.raw_symlink(target, linkpath) catch |err| {
            const maybe_resolved = self.resolve_symlinks(linkpath, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_symlink(target, resolved);
            }
            return err;
        };
    }

    /// True when any mounted filesystem can hold a link, since a path handed
    /// to the VFS may land on any of them. Callers wanting a finer answer ask
    /// per path, which is what `prefix_can_hold_symlink` does internally.
    pub fn supports_symlinks(self: *const Self) bool {
        const root = &(self.mount_points.root orelse return false);
        return mount_subtree_supports_symlinks(root);
    }

    // Below are part of VirtualFileSystem interface, not IFileSystem
    pub fn init(allocator: std.mem.Allocator) VirtualFileSystem {
        return VirtualFileSystem.init(.{
            .mount_points = MountPoints.init(allocator),
        });
    }

    pub fn deinit(self: *Self) void {
        log.info("Virtual file system deinitialization", .{});
        self.mount_points.deinit();
    }

    pub fn mount_filesystem(self: *Self, path: []const u8, fs: IFileSystem) !void {
        try self.mount_points.mount_filesystem(path, fs);
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return error.NotSupported;
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        return self.raw_access(path, mode, flags) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, true) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.mount_points.allocator.free(resolved);
                return self.raw_access(resolved, mode, flags);
            }
            return err;
        };
    }
});

var vfs_instance: ?VirtualFileSystem = null;
var vfs_object: ?IFileSystem = null;

pub fn vfs_init(allocator: std.mem.Allocator) void {
    log.info("initialization...", .{});
    vfs_instance = VirtualFileSystem.InstanceType.init(allocator);
    vfs_object = vfs_instance.?.interface.create();
}

pub fn vfs_deinit() void {
    log.info("deinitialization...", .{});
    if (vfs_object) |*instance| {
        instance.interface.delete();
        vfs_object = null;
    }
    vfs_instance = null;
}

pub fn get_ivfs() *IFileSystem {
    if (vfs_object) |*vfs| {
        return vfs;
    }
    @panic("vfs not initialized");
}

pub fn get_vfs() *VirtualFileSystem.InstanceType {
    if (vfs_instance) |*instance| {
        return instance.data();
    }
    @panic("vfs not initialized");
}

test "VirtualFileSystem.ShouldRedirectFileCreation" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("create")
        .withArgs(.{ "dir", @as(u32, 0) });

    try sut.create("/dir", 0);

    _ = fs_mock
        .expectCall("create")
        .withArgs(.{ "dir/x/y", @as(u32, 0) });

    try sut.create("/dir/x/y", 0);
}

test "VirtualFileSystem.ShouldRedirectFileCreationToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"mnt"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/mnt", fs2);

    _ = fs2_mock
        .expectCall("create")
        .withArgs(.{ "subdir/file.txt", @as(u32, 0o644) });

    try sut.create("/mnt/subdir/file.txt", 0o644);
}

test "VirtualFileSystem.CreateShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.create("/file.txt", 0));
}

test "VirtualFileSystem.ShouldRedirectDirectoryCreation" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("mkdir")
        .withArgs(.{ "dir", @as(u32, 0) });

    try sut.mkdir("/dir", 0);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"dir"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/dir", fs2);

    _ = fs2_mock
        .expectCall("mkdir")
        .withArgs(.{ "x/y", @as(u32, 0) });

    try sut.mkdir("/dir/x/y", 0);
}

test "VirtualFileSystem.ShouldRedirectDirectoryCreationToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"data"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/data", fs2);

    _ = fs2_mock
        .expectCall("mkdir")
        .withArgs(.{ "subdir/nested", @as(u32, 0o755) });

    try sut.mkdir("/data/subdir/nested", 0o755);
}

test "VirtualFileSystem.MkdirShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.mkdir("/newdir", 0));
}

test "VirtualFileSystem.ShouldRedirectUnlink" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("unlink")
        .withArgs(.{"file.txt"});

    try sut.unlink("/file.txt");

    _ = fs_mock
        .expectCall("unlink")
        .withArgs(.{"dir/x/file.txt"});

    try sut.unlink("/dir/x/file.txt");
}

test "VirtualFileSystem.ShouldRedirectUnlinkToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"mnt"})
        .willReturn(file_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/mnt", fs2);

    _ = fs2_mock
        .expectCall("unlink")
        .withArgs(.{"nested/file.txt"});

    try sut.unlink("/mnt/nested/file.txt");
}

test "VirtualFileSystem.UnlinkShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.unlink("/nonexistent.txt"));
}

test "VirtualFileSystem.ShouldReturnCorrectName" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    const fs_name = sut.name();
    try std.testing.expectEqualStrings("vfs", fs_name);
}

test "VirtualFileSystem.ShouldRedirectGet" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"file.txt"})
        .willReturn(file_node);

    var node = try sut.get("/file.txt");
    defer node.delete();
    try std.testing.expect(node.is_file());
}

test "VirtualFileSystem.ShouldRedirectGetToNestedFilesystem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    var fs2_mock = try FileSystemMock.create(std.testing.allocator);
    const fs2 = fs2_mock.get_interface();

    var mount_filemock = try FileMock.create(std.testing.allocator);
    const mount_file = mount_filemock.get_interface();
    const mount_node = kernel.fs.Node.create_file(mount_file);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"data"})
        .willReturn(mount_node);

    _ = fs2_mock
        .expectCall("mount")
        .willReturn(@as(u32, 0));

    try sut.mount_filesystem("/data", fs2);

    var filemock = try FileMock.create(std.testing.allocator);
    const file = filemock.get_interface();
    const file_node = kernel.fs.Node.create_file(file);

    _ = fs2_mock
        .expectCall("get")
        .withArgs(.{"test/file.txt"})
        .willReturn(file_node);

    var node = try sut.get("/data/test/file.txt");
    defer node.delete();
    try std.testing.expect(node.is_file());
}

test "VirtualFileSystem.DoesNotProbeForSymlinksOnAFilesystemThatCannotHoldThem" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"missing/file.txt"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(false);

    // Deliberately no `stat` expectation: a failed lookup normally walks the
    // path component by component looking for a link, and each of those stats
    // is a directory walk. A filesystem whose format has no link to find must
    // not be asked -- the mock panics on an unexpected call, so this passing
    // is the proof.
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.get("/missing/file.txt"));
}

test "VirtualFileSystem.StillProbesForSymlinksWhereTheyArePossible" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;

    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();

    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try sut.mount_filesystem("/", fs);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"missing/file.txt"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(true);

    // The capability is not a licence to skip the work where it can pay: a
    // filesystem that says yes is still walked.
    _ = fs_mock
        .expectCall("stat")
        .withArgs(.{ interface.mock.any{}, interface.mock.any{}, interface.mock.any{} })
        .times(interface.mock.any{})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.get("/missing/file.txt"));
}

test "VirtualFileSystem.GetShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.get("/file.txt"));
}
