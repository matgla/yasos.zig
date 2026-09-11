//
// ramfs.zig
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

const kernel = @import("kernel");

const c = @import("libc_imports").c;

const IFileSystem = kernel.fs.IFileSystem;
const IDirectoryIterator = kernel.fs.IDirectoryIterator;
const IFile = kernel.fs.IFile;
const FileType = kernel.fs.FileType;

const std = @import("std");

const log = kernel.log;

const interface = @import("interface");

const RamFsFile = @import("ramfs_file.zig").RamFsFile;
const RamFsData = @import("ramfs_data.zig").RamFsData;
const RamFsNode = @import("ramfs_node.zig").RamFsNode;
pub const Tier = @import("ramfs_tier.zig").Tier;

const RamFsDirectory = @import("ramfs_directory.zig").RamFsDirectory;

fn initialize_stat_identity(data: *c.struct_stat, path: []const u8) void {
    data.* = std.mem.zeroes(c.struct_stat);

    const normalized_path = if (path.len == 0) "/" else path;
    const device_hash = std.hash.Wyhash.hash(0, "ramfs") | 1;
    const inode_hash = std.hash.Wyhash.hash(device_hash, normalized_path) | 1;

    data.st_dev = @truncate(device_hash);
    data.st_ino = @truncate(inode_hash);
    data.st_nlink = 1;
}

/// Scratch for normalising a path. A stack buffer rather than an allocation, and
/// that is a correctness requirement: a tiered RamFs (the hybrid /tmp) is built
/// over a bounded arena, so normalising through the allocator makes `unlink`
/// fail exactly when the arena is full and the filesystem can never be emptied.
///
/// 4x the system PATH_MAX. `resolvePosix` builds its answer in an ArrayList that
/// grows geometrically and extends in place, so the peak is the first step at or
/// above the result length; the syscall layer admits paths up to 2x PATH_MAX,
/// whose step is 390.
const path_scratch_bytes = 4 * 128;

fn resolve_into(buffer: []u8, path: []const u8) ![]const u8 {
    var scratch = std.heap.FixedBufferAllocator.init(buffer);
    const resolved = try std.fs.path.resolve(scratch.allocator(), &.{path});
    // `resolve` answers "." for anything that reduces to nothing -- the empty
    // string, ".", "./" -- because it is written for a caller that has a
    // working directory. This one does not: a path arrives here already
    // relative to this mount, so "nothing left" means this filesystem's root.
    //
    // The empty string is not a corner case, it is what the VFS passes when the
    // path *is* the mount point: `stat("/tmp")` reaches RamFs as `stat("")`.
    // Left as ".", it became a lookup for an entry named "." in the root, which
    // does not exist -- so /tmp could not be stat'd at all, and `ls -la /`
    // printed a row of question marks in its place.
    if (resolved.len == 0 or std.mem.eql(u8, resolved, ".")) return "/";
    return resolved;
}

pub const RamFs = interface.DeriveFromBase(IFileSystem, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _root: kernel.fs.Node,
    /// Spill policy for file bodies, or null for a RAM-only filesystem. See
    /// ramfs_tier.zig — this is what turns a RamFs over a bounded arena (the
    /// hybrid /tmp) into one that degrades to a backing filesystem instead of
    /// failing when the arena runs out.
    _tier: ?*Tier,

    pub fn init(allocator: std.mem.Allocator) !RamFs {
        return init_tiered(allocator, null);
    }

    pub fn init_tiered(allocator: std.mem.Allocator, tier: ?*Tier) !RamFs {
        return RamFs.init(.{
            ._allocator = allocator,
            ._root = try RamFsDirectory.InstanceType.create_node(allocator, "/"),
            ._tier = tier,
        });
    }

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self.umount();
    }

    pub fn umount(self: *Self) i32 {
        self._root.delete();
        return 0;
    }

    fn get_parent_node(self: *Self, path: []const u8) !kernel.fs.Node {
        var scratch: [path_scratch_bytes]u8 = undefined;
        const resolved_path = try resolve_into(&scratch, path);
        const maybe_dirpath: ?[]const u8 = std.fs.path.dirname(resolved_path);

        if (maybe_dirpath) |dirpath| {
            return try self.get(dirpath);
        }
        return try self._root.clone();
    }

    pub fn create(self: *Self, path: []const u8, _: i32) anyerror!void {
        if (path.len == 0) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }
        var maybe_node: ?kernel.fs.Node = self.get(path) catch |err| blk: {
            if (err != kernel.errno.ErrnoSet.NoEntry) {
                return err;
            }
            break :blk null;
        };
        if (maybe_node) |*node| {
            node.delete();
            return kernel.errno.ErrnoSet.FileExists;
        }
        const basename = std.fs.path.basenamePosix(path);
        var parent_node = try self.get_parent_node(path);
        defer parent_node.delete();
        var maybe_parent_dir = parent_node.as_directory();
        if (maybe_parent_dir) |*parent_dir| {
            const filedata = try self._allocator.create(RamFsData);
            filedata.* = try RamFsData.create_tiered(self._allocator, self._tier);
            const filenode = try self._allocator.create(RamFsNode);
            const filename = try self._allocator.dupe(u8, basename);
            filenode.* = RamFsNode{
                .node = try RamFsFile.InstanceType.create_node(self._allocator, filedata, filename),
                .list_node = std.DoublyLinkedList.Node{},
                .name = filename,
            };
            try parent_dir.as(RamFsDirectory).data().append(filenode);
            return;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn mkdir(self: *Self, path: []const u8, _: i32) anyerror!void {
        if (path.len == 0) {
            // An empty relative path means the filesystem's own mount-point
            // root (e.g. `mkdir /root` when a RamFs is mounted at /root). That
            // directory already exists, so report EEXIST rather than EINVAL —
            // otherwise `mkdir -p /root/a/b` aborts on the first component and
            // never creates the children.
            return kernel.errno.ErrnoSet.FileExists;
        }
        var maybe_node = self.get(path) catch |err| blk: {
            if (err != kernel.errno.ErrnoSet.NoEntry) {
                return err;
            }
            break :blk null;
        };
        if (maybe_node) |*node| {
            node.delete();
            return kernel.errno.ErrnoSet.FileExists;
        }
        const basename = std.fs.path.basenamePosix(path);
        var parent_node = try self.get_parent_node(path);
        defer parent_node.delete();
        var maybe_parent_dir = parent_node.as_directory();
        if (maybe_parent_dir) |*parent_dir| {
            const node = try self._allocator.create(RamFsNode);
            const dirname = try self._allocator.dupe(u8, basename);
            node.* = RamFsNode{
                .node = try RamFsDirectory.InstanceType.create_node(self._allocator, dirname),
                .list_node = std.DoublyLinkedList.Node{},
                .name = dirname,
            };
            try parent_dir.as(RamFsDirectory).data().append(node);
            return;
        } else {
            return kernel.errno.ErrnoSet.NotADirectory;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    /// Walk to the directory at `dirpath`, borrowing every step. `get` returns
    /// an owned Node, which costs an allocation per level -- right for `open`,
    /// whose handle carries its own file position, and wrong for `unlink`, which
    /// has to keep working once a tiered /tmp's arena is full.
    fn borrow_directory(self: *Self, dirpath: []const u8) !kernel.fs.IDirectory {
        var current = self._root.as_directory() orelse
            return kernel.errno.ErrnoSet.NotADirectory;
        var it = std.fs.path.componentIterator(dirpath);
        while (it.next()) |component| {
            const child = current.as(RamFsDirectory).data().get_node(component.name) orelse
                return kernel.errno.ErrnoSet.NoEntry;
            current = child.node.as_directory() orelse
                return kernel.errno.ErrnoSet.NotADirectory;
        }
        return current;
    }

    /// The node at `path`, borrowed -- no clone, and so no allocation. The
    /// result aliases the one the tree owns: read it and drop it, never
    /// `delete()` it. Callers that need to hold a node must use `get`.
    fn borrow_node(self: *Self, path: []const u8) !kernel.fs.Node {
        var scratch: [path_scratch_bytes]u8 = undefined;
        const resolved_path = try resolve_into(&scratch, path);
        if (resolved_path.len == 0 or std.mem.eql(u8, resolved_path, "/")) {
            return self._root;
        }
        const dirpath = std.fs.path.dirname(resolved_path) orelse "/";
        var parent = try self.borrow_directory(dirpath);
        const child = parent.as(RamFsDirectory).data().get_node(
            std.fs.path.basename(resolved_path),
        ) orelse return kernel.errno.ErrnoSet.NoEntry;
        return child.node;
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        // Allocates nothing, deliberately -- see borrow_directory. The existence
        // check a `get` would stand for is one the parent's own unlink already
        // makes: it answers NoEntry for a name it does not hold.
        var scratch: [path_scratch_bytes]u8 = undefined;
        const resolved_path = try resolve_into(&scratch, path);
        const nodename = std.fs.path.basename(resolved_path);
        const dirpath = std.fs.path.dirname(resolved_path) orelse "/";
        var parent = try self.borrow_directory(dirpath);
        return parent.as(RamFsDirectory).data().unlink(nodename);
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "ramfs";
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self.umount();
        self._root = try RamFsDirectory.InstanceType.create_node(self._allocator, "/");
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        _ = follow_symlinks;
        initialize_stat_identity(data, path);
        // Borrowed, because `rm` stats before it unlinks: a stat that allocates
        // makes a full /tmp unremovable even though the unlink itself would have
        // worked. Nothing here needs a handle — the node is only read.
        var node = try self.borrow_node(path);
        data.st_mode = switch (node.filetype()) {
            .File => c.S_IFREG,
            .Directory => c.S_IFDIR,
            .SymbolicLink => c.S_IFLNK,
            else => return,
        };
        data.st_blksize = 1;
        if (node.as_file()) |file| {
            var handle = file;
            const body = handle.as(RamFsFile).data()._data;
            data.st_size = @intCast(body.len());
            // The body's own number, not the path hash the identity default
            // uses: two names for one body are one file, and `cp`, `mv` and
            // `find` all decide that from dev/ino.
            data.st_ino = body.inode;
            body.times.write_into(data);
        } else if (node.as_directory()) |directory| {
            var handle = directory;
            handle.as(RamFsDirectory).data().times().write_into(data);
        }
        return;
    }

    pub fn utimens(self: *Self, path: []const u8, times: kernel.fs.TimeStamps, follow_symlinks: bool) anyerror!void {
        _ = follow_symlinks;
        // Borrowed for the same reason `stat` borrows: `touch` on a full /tmp
        // has to keep working, and it changes no allocation of its own.
        var node = try self.borrow_node(path);
        const current = kernel.time.now_timespec();
        if (node.as_file()) |file| {
            var handle = file;
            handle.as(RamFsFile).data()._data.times.apply(times, current);
        } else if (node.as_directory()) |directory| {
            var handle = directory;
            handle.as(RamFsDirectory).data().times().apply(times, current);
        }
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        if (linkpath.len == 0) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }
        var maybe_node: ?kernel.fs.Node = self.get(linkpath) catch |err| blk: {
            if (err != kernel.errno.ErrnoSet.NoEntry) {
                return err;
            }
            break :blk null;
        };
        if (maybe_node) |*node| {
            node.delete();
            return kernel.errno.ErrnoSet.FileExists;
        }
        const basename = std.fs.path.basenamePosix(linkpath);
        var parent_node = try self.get_parent_node(linkpath);
        defer parent_node.delete();
        var maybe_parent_dir = parent_node.as_directory();
        if (maybe_parent_dir) |*parent_dir| {
            // A symbolic link's body always stays in memory: it is a handful of
            // bytes, and resolving one must not depend on the backing store.
            const filedata = try self._allocator.create(RamFsData);
            filedata.* = try RamFsData.create(self._allocator);
            // The link target is stored verbatim as the file content.
            _ = try filedata.write_at(0, target);
            const filenode = try self._allocator.create(RamFsNode);
            const filename = try self._allocator.dupe(u8, basename);
            filenode.* = RamFsNode{
                .node = try RamFsFile.InstanceType.create_symlink_node(self._allocator, filedata, filename),
                .list_node = std.DoublyLinkedList.Node{},
                .name = filename,
            };
            try parent_dir.as(RamFsDirectory).data().append(filenode);
            return;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn supports_symlinks(self: *const Self) bool {
        _ = self;
        // Nodes carry a FileType, SymbolicLink included, and symlink() creates
        // them.
        return true;
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        var node = try self.get(path);
        defer node.delete();
        if (node.filetype() != FileType.SymbolicLink) {
            return kernel.errno.ErrnoSet.InvalidArgument; // not a symbolic link
        }
        var file = node.as_file() orelse return kernel.errno.ErrnoSet.InvalidArgument;
        _ = file.interface.seek(0, c.SEEK_SET) catch {};
        const n = file.interface.read(buffer);
        if (n < 0) {
            return kernel.errno.ErrnoSet.InputOutputError;
        }
        return @intCast(n);
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        if (path.len == 0 or std.mem.eql(u8, path, "/")) {
            return try self._root.clone();
        }

        const resolved_path = try std.fs.path.resolve(self._allocator, &.{path});
        defer self._allocator.free(resolved_path);

        var it = std.fs.path.componentIterator(resolved_path);
        var current_directory: kernel.fs.IDirectory = self._root.as_directory().?;
        while (it.next()) |component| {
            if (it.peekNext() != null) {
                // Intermediate component, must be a directory
                var next_node: kernel.fs.Node = undefined;
                try current_directory.interface.get(component.name, &next_node);
                defer next_node.delete();
                if (next_node.filetype() != FileType.Directory) {
                    return kernel.errno.ErrnoSet.NoEntry;
                }
                current_directory = next_node.as_directory().?;
            } else {
                // Last component, can be file or directory
                var next_node: kernel.fs.Node = undefined;
                try current_directory.interface.get(component.name, &next_node);
                return next_node;
            }
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        var node = try self.get(old_path);
        defer node.delete();
        if (node.filetype() == FileType.Directory) {
            return kernel.errno.ErrnoSet.IsADirectory;
        }

        var parent_node = try self.get_parent_node(new_path);
        defer parent_node.delete();
        var maybe_parent_dir = parent_node.as_directory();
        if (maybe_parent_dir) |*parent_dir| {
            const filename = try self._allocator.dupe(u8, std.fs.path.basename(new_path));
            const new_node = try self._allocator.create(RamFsNode);
            var file = node.as_file().?;
            const new_file = try RamFsFile.InstanceType.create_node(
                self._allocator,
                file.as(RamFsFile).data()._data.share(),
                filename,
            );

            new_node.* = RamFsNode{
                .node = new_file,
                .list_node = std.DoublyLinkedList.Node{},
                .name = filename,
            };
            try parent_dir.as(RamFsDirectory).data().append(new_node);
            return;
        }
        return kernel.errno.ErrnoSet.NotADirectory;
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        _ = flags;
        // Borrowed for the same reason as `stat`: asking whether a path exists
        // must not be a thing a full filesystem can refuse to answer.
        const n = try self.borrow_node(path);

        if ((mode & c.W_OK) != 0 or (mode & c.X_OK) != 0) {
            if (n.filetype() == FileType.Directory) {
                return kernel.errno.ErrnoSet.IsADirectory;
            }
        }
    }
});

fn has_path(sut: *kernel.fs.IFileSystem, path: []const u8) bool {
    var node = sut.interface.get(path) catch return false;
    defer node.delete();
    return true;
}

// ----------------------------------------------------------------------------
// Tiered (hybrid /tmp) fixtures — a RamFs whose file bodies spill into a second
// RamFs standing in for the SD-backed spill directory.
// ----------------------------------------------------------------------------
const TieredFixture = struct {
    const spill_directory = "/spill";

    backing_fs: *RamFs,
    // Heap-allocated because the tier holds a pointer to it, and the fixture
    // itself is returned by value.
    backing: *kernel.fs.IFileSystem,
    tier: *Tier,
    fs: *RamFs,
    sut: kernel.fs.IFileSystem,

    fn init(allocator: std.mem.Allocator, arena: std.mem.Allocator, max_file_bytes: usize) !TieredFixture {
        const backing_fs = try allocator.create(RamFs);
        backing_fs.* = try RamFs.InstanceType.init(allocator);
        const backing = try allocator.create(kernel.fs.IFileSystem);
        backing.* = backing_fs.interface.create();
        try backing.interface.mkdir(spill_directory, 0);

        const tier = try allocator.create(Tier);
        tier.* = Tier.init(backing, spill_directory, max_file_bytes);

        const fs = try allocator.create(RamFs);
        fs.* = try RamFs.InstanceType.init_tiered(arena, tier);

        return .{
            .backing_fs = backing_fs,
            .backing = backing,
            .tier = tier,
            .fs = fs,
            .sut = fs.interface.create(),
        };
    }

    fn deinit(self: *TieredFixture, allocator: std.mem.Allocator) void {
        _ = self.sut.interface.delete();
        _ = self.backing.interface.delete();
        allocator.destroy(self.fs);
        allocator.destroy(self.tier);
        allocator.destroy(self.backing);
        allocator.destroy(self.backing_fs);
    }

    fn spilled_body_count(self: *TieredFixture) usize {
        var node = self.backing.interface.get(spill_directory) catch return 0;
        defer node.delete();
        var directory = node.as_directory() orelse return 0;
        var it = directory.interface.iterator() catch return 0;
        defer it.interface.delete();
        var count: usize = 0;
        while (it.interface.next()) |_| {
            count += 1;
        }
        return count;
    }

    fn write(self: *TieredFixture, path: []const u8, position: i64, bytes: []const u8) !void {
        var node = try self.sut.interface.get(path);
        defer node.delete();
        var file = node.as_file() orelse return error.NotAFile;
        _ = try file.interface.seek(position, c.SEEK_SET);
        try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), file.interface.write(bytes));
    }

    fn expect_content(self: *TieredFixture, path: []const u8, expected: []const u8) !void {
        var node = try self.sut.interface.get(path);
        defer node.delete();
        var file = node.as_file() orelse return error.NotAFile;
        try std.testing.expectEqual(@as(u64, expected.len + @sizeOf(RamFsData)), file.interface.size());
        const buffer = try std.testing.allocator.alloc(u8, expected.len + 8);
        defer std.testing.allocator.free(buffer);
        _ = try file.interface.seek(0, c.SEEK_SET);
        const read_bytes = file.interface.read(buffer);
        try std.testing.expectEqual(@as(isize, @intCast(expected.len)), read_bytes);
        try std.testing.expectEqualSlices(u8, expected, buffer[0..expected.len]);
    }
};

test "RamFs.Tiered.ShouldStillUnlinkWhenTheArenaIsFull" {
    // A full arena must not make /tmp permanently full: path lookup resolves on
    // the stack, so `unlink` still works once nothing can be allocated.
    //
    // Metadata is what fills the arena here, deliberately: file bodies spill to
    // the backing store when it runs low, but the tree -- names, entries,
    // refcounters -- has nowhere to go and never spills.
    var arena_memory: [4096]u8 align(256) = undefined;
    var pool = try kernel.memory.heap.TmpMemoryPool(256).init(std.testing.allocator, &arena_memory);
    defer pool.deinit();
    var page_allocator = kernel.memory.heap.TmpPageAllocator(@TypeOf(pool)).init(&pool);

    // A threshold far above the arena, so nothing spills for size reasons and
    // the arena fills with tree metadata as the device's did.
    var fixture = try TieredFixture.init(std.testing.allocator, page_allocator.allocator(), 1024 * 1024);
    defer fixture.deinit(std.testing.allocator);

    var created: usize = 0;
    while (created < 512) : (created += 1) {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/f{d}", .{created});
        fixture.sut.interface.create(path, 0) catch break;
    }

    // The premise of the test: the arena really did run out. If a future change
    // makes creation cheap enough that 512 files fit, this needs more of them —
    // it must not quietly become a test of an arena with room to spare.
    try std.testing.expect(created < 512);
    try std.testing.expect(created > 0);

    // The whole `rm` sequence, not just the unlink: toybox's rm stats a path
    // before removing it, so a stat that allocates makes a full /tmp unremovable
    // even when the unlink itself would have worked.
    const full = pool.get_used_size();
    var info: c.struct_stat = undefined;
    try fixture.sut.interface.stat("/f0", &info, false);
    try fixture.sut.interface.access("/f0", c.F_OK, 0);
    try fixture.sut.interface.unlink("/f0");
    try std.testing.expect(pool.get_used_size() < full);

    // And `rm -f` on a path that is not there must answer NoEntry rather than
    // ENOMEM: with the arena full it used to answer the latter for every path,
    // existing or not, which is what made a wedged /tmp look bottomless.
    try std.testing.expectError(
        kernel.errno.ErrnoSet.NoEntry,
        fixture.sut.interface.unlink("/never-existed"),
    );

    // And having freed some, the filesystem is usable again rather than wedged.
    try fixture.sut.interface.create("/after", 0);
}

test "RamFs.Tiered.ShouldReclaimTheArenaOnUnlink" {
    // The arena has to come back after a file is removed: a slow climb across
    // CONFIG_TMPFS_ARENA_RESERVE starts spilling bodies to SD, after which every
    // operation on /tmp answers ENOMEM. A fresh name per round, because that is
    // what the workload does and it exercises the entry and its name too.
    var arena_memory: [8192]u8 align(256) = undefined;
    var pool = try kernel.memory.heap.TmpMemoryPool(256).init(std.testing.allocator, &arena_memory);
    defer pool.deinit();
    var page_allocator = kernel.memory.heap.TmpPageAllocator(@TypeOf(pool)).init(&pool);

    var fixture = try TieredFixture.init(std.testing.allocator, page_allocator.allocator(), 1024 * 1024);
    defer fixture.deinit(std.testing.allocator);

    var payload: [512]u8 = undefined;
    @memset(&payload, 'x');

    const baseline = pool.get_used_size();
    for (0..8) |round| {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/scratch{d}.o", .{round});
        try fixture.sut.interface.create(path, 0);
        try fixture.write(path, 0, &payload);
        try fixture.sut.interface.unlink(path);
    }

    try std.testing.expectEqual(baseline, pool.get_used_size());
}

test "RamFs.Tiered.ShouldKeepSmallFilesInMemory" {
    var fixture = try TieredFixture.init(std.testing.allocator, std.testing.allocator, 64);
    defer fixture.deinit(std.testing.allocator);

    try fixture.sut.interface.create("/small", 0);
    try fixture.write("/small", 0, "0123456789");
    try fixture.expect_content("/small", "0123456789");

    try std.testing.expectEqual(@as(usize, 0), fixture.spilled_body_count());
    try std.testing.expectEqual(@as(usize, 0), fixture.tier.spills);
}

test "RamFs.Tiered.ShouldSpillWhenAFileOutgrowsTheThreshold" {
    var fixture = try TieredFixture.init(std.testing.allocator, std.testing.allocator, 16);
    defer fixture.deinit(std.testing.allocator);

    try fixture.sut.interface.create("/big", 0);
    try fixture.write("/big", 0, "0123456789");
    try std.testing.expectEqual(@as(usize, 0), fixture.spilled_body_count());

    // Crosses the 16-byte threshold, so the whole body moves to the backing
    // store — including the bytes already written.
    try fixture.write("/big", 10, "abcdefghij");
    try std.testing.expectEqual(@as(usize, 1), fixture.spilled_body_count());
    try std.testing.expectEqual(@as(usize, 1), fixture.tier.spills);
    try fixture.expect_content("/big", "0123456789abcdefghij");

    // Everything past the spill goes straight to the backing store.
    try fixture.write("/big", 20, "!");
    try fixture.expect_content("/big", "0123456789abcdefghij!");
    try std.testing.expectEqual(@as(usize, 1), fixture.spilled_body_count());
}

test "RamFs.Tiered.ShouldSpillWhenTheArenaIsExhausted" {
    // A 4 KiB arena in 256-byte pages, and a threshold far above it: the only
    // thing that can force a spill here is the arena running out.
    var arena_memory: [4096]u8 align(256) = undefined;
    var pool = try kernel.memory.heap.TmpMemoryPool(256).init(std.testing.allocator, &arena_memory);
    defer pool.deinit();
    var page_allocator = kernel.memory.heap.TmpPageAllocator(@TypeOf(pool)).init(&pool);

    var fixture = try TieredFixture.init(std.testing.allocator, page_allocator.allocator(), 1024 * 1024);
    defer fixture.deinit(std.testing.allocator);

    var payload: [8192]u8 = undefined;
    for (&payload, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }

    try fixture.sut.interface.create("/huge", 0);
    try fixture.write("/huge", 0, &payload);
    try std.testing.expectEqual(@as(usize, 1), fixture.tier.spills);
    try fixture.expect_content("/huge", &payload);
}

test "RamFs.Tiered.ShouldKeepTheArenaReserveFreeForMetadata" {
    var arena_memory: [8192]u8 align(256) = undefined;
    var pool = try kernel.memory.heap.TmpMemoryPool(256).init(std.testing.allocator, &arena_memory);
    defer pool.deinit();
    var page_allocator = kernel.memory.heap.TmpPageAllocator(@TypeOf(pool)).init(&pool);

    var fixture = try TieredFixture.init(std.testing.allocator, page_allocator.allocator(), 1024 * 1024);
    defer fixture.deinit(std.testing.allocator);

    // Reserve nearly the whole arena: every body that wants to grow must spill
    // straight away, leaving the arena for the tree.
    const Arena = struct {
        fn free(context: *anyopaque) usize {
            const p: *@TypeOf(pool) = @ptrCast(@alignCast(context));
            return p.memory_size - p.get_used_size();
        }
    };
    fixture.tier.set_arena(.{ .context = &pool, .free_bytes = &Arena.free }, arena_memory.len);

    // Without the reserve this stays in RAM: it is one byte and far under the
    // 1 MiB threshold.
    try fixture.sut.interface.create("/tiny", 0);
    try fixture.write("/tiny", 0, "x");
    try std.testing.expectEqual(@as(usize, 1), fixture.tier.spills);
    try fixture.expect_content("/tiny", "x");

    // And the arena still has room to name more files.
    try fixture.sut.interface.create("/another", 0);
    try std.testing.expect(has_path(&fixture.sut, "/another"));
}

test "RamFs.Tiered.ShouldShareASpillAcrossOpenHandles" {
    var fixture = try TieredFixture.init(std.testing.allocator, std.testing.allocator, 8);
    defer fixture.deinit(std.testing.allocator);

    try fixture.sut.interface.create("/shared", 0);
    var reader_node = try fixture.sut.interface.get("/shared");
    defer reader_node.delete();
    var reader = reader_node.as_file().?;

    // The write goes through a second handle and spills; the handle opened
    // before the spill must still see the file.
    try fixture.write("/shared", 0, "spilled payload");
    try std.testing.expectEqual(@as(usize, 1), fixture.tier.spills);

    var buffer: [32]u8 = undefined;
    _ = try reader.interface.seek(0, c.SEEK_SET);
    try std.testing.expectEqual(@as(isize, 15), reader.interface.read(&buffer));
    try std.testing.expectEqualStrings("spilled payload", buffer[0..15]);
}

test "RamFs.Tiered.ShouldTruncateAndSeekASpilledFile" {
    var fixture = try TieredFixture.init(std.testing.allocator, std.testing.allocator, 8);
    defer fixture.deinit(std.testing.allocator);

    try fixture.sut.interface.create("/edited", 0);
    try fixture.write("/edited", 0, "abcdefghijkl");
    try std.testing.expectEqual(@as(usize, 1), fixture.tier.spills);

    var node = try fixture.sut.interface.get("/edited");
    defer node.delete();
    var file = node.as_file().?;

    try file.interface.truncate(5);
    try fixture.expect_content("/edited", "abcde");

    // Seeking past the end pads with spaces, exactly as a RAM-resident body does.
    _ = try file.interface.seek(8, c.SEEK_SET);
    try fixture.expect_content("/edited", "abcde   ");

    try file.interface.truncate(10);
    try fixture.expect_content("/edited", "abcde   \x00\x00");
}

test "RamFs.Tiered.ShouldRemoveTheSpilledBodyOnUnlink" {
    var fixture = try TieredFixture.init(std.testing.allocator, std.testing.allocator, 8);
    defer fixture.deinit(std.testing.allocator);

    try fixture.sut.interface.create("/gone", 0);
    try fixture.write("/gone", 0, "long enough to spill");
    try std.testing.expectEqual(@as(usize, 1), fixture.spilled_body_count());

    try fixture.sut.interface.unlink("/gone");
    try std.testing.expect(!has_path(&fixture.sut, "/gone"));
    try std.testing.expectEqual(@as(usize, 0), fixture.spilled_body_count());
}

test "RamFs.Tiered.ShouldKeepSymbolicLinksInMemory" {
    var fixture = try TieredFixture.init(std.testing.allocator, std.testing.allocator, 4);
    defer fixture.deinit(std.testing.allocator);

    try fixture.sut.interface.symlink("/a/rather/long/target/path", "/link");
    try std.testing.expectEqual(@as(usize, 0), fixture.spilled_body_count());

    var buffer: [64]u8 = undefined;
    const length = try fixture.sut.interface.readlink("/link", &buffer);
    try std.testing.expectEqualStrings("/a/rather/long/target/path", buffer[0..length]);
}

test "RamFsFile.ShouldCreateAndRemoveFiles" {
    const verify_directory_content = @import("../tests/directory_traverser.zig").verify_directory_content;
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectEqualStrings("ramfs", sut.interface.name());
    try sut.interface.mkdir("/test", 0);
    try sut.interface.mkdir("/test/dir", 0);
    try sut.interface.mkdir("test/dir/nested", 0);
    try sut.interface.mkdir("other", 0);

    try std.testing.expectError(kernel.errno.ErrnoSet.FileExists, sut.interface.mkdir("/test/dir", 0));
    try std.testing.expectEqual(kernel.errno.ErrnoSet.NoEntry, sut.interface.mkdir("nonexisting/dir/nested", 0));

    try std.testing.expect(!has_path(&sut, "other2"));
    try std.testing.expect(has_path(&sut, "/"));
    try std.testing.expect(has_path(&sut, "/test"));
    try std.testing.expect(has_path(&sut, "/test/dir"));
    try std.testing.expect(has_path(&sut, "/test/dir/nested"));
    try std.testing.expect(has_path(&sut, "/other"));
    try std.testing.expect(has_path(&sut, "test"));
    try std.testing.expect(has_path(&sut, "test/dir"));
    try std.testing.expect(has_path(&sut, "test/dir/nested"));
    try std.testing.expect(has_path(&sut, "other"));

    try sut.interface.create("/test/file.txt", 0);
    try std.testing.expectError(kernel.errno.ErrnoSet.FileExists, sut.interface.create("/test/file.txt", 0));

    try sut.interface.create("test/dir/nested/file", 0);
    try std.testing.expect(has_path(&sut, "/test/file.txt"));
    try std.testing.expect(has_path(&sut, "/test/dir/nested/file"));

    try verify_directory_content(&sut, "/test", &.{
        .{ .name = "file.txt", .kind = .File },
        .{ .name = "dir", .kind = .Directory },
    });

    try verify_directory_content(&sut, "/", &.{
        .{ .name = "test", .kind = .Directory },
        .{ .name = "other", .kind = .Directory },
    });

    try verify_directory_content(&sut, "/test/dir", &.{
        .{ .name = "nested", .kind = .Directory },
    });

    // reject non empty directory removal
    try std.testing.expectError(kernel.errno.ErrnoSet.DeviceOrResourceBusy, sut.interface.unlink("/test"));
    var node = try sut.interface.get("/test/file.txt");
    var file = node.as_file();
    try std.testing.expect(file != null);
    try std.testing.expectEqual(18, file.?.interface.write("Some data for file"));
    node.delete();

    try sut.interface.unlink("/test/file.txt");
    try std.testing.expect(!has_path(&sut, "/test/file.txt"));
    try sut.interface.unlink("/test/dir/nested/file");
    try sut.interface.unlink("/test/dir/nested");
    try sut.interface.unlink("/test/dir");
    try sut.interface.unlink("/test");
}

test "RamFs.ShouldCreateLink" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectEqualStrings("ramfs", sut.interface.name());
    try sut.interface.mkdir("/dir", 0);

    try sut.interface.create("/dir/file.txt", 0);
    var node = try sut.interface.get("/dir/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);
    try std.testing.expectEqual(18, file.?.interface.write("Some data for file"));

    try std.testing.expect(has_path(&sut, "/dir/file.txt"));
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.link("/dir/file2.txt", "/dir/file_link.txt"));
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, sut.interface.link("/dir", "/dir/file_link"));
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.link("/dir/file.txt", "/dir2/file_link.txt"));

    try sut.interface.link("/dir/file.txt", "/dir/file_link.txt");
    var link_node = try sut.interface.get("/dir/file_link.txt");
    defer link_node.delete();

    var link_file = link_node.as_file();
    try std.testing.expect(link_file != null);

    var buffer: [40]u8 = undefined;
    try std.testing.expectEqual(18, link_file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file", buffer[0..18]);
    try std.testing.expectEqual(10, link_file.?.interface.write(" More data"));

    try std.testing.expect(file != null);
    _ = try file.?.interface.seek(0, c.SEEK_SET);
    try std.testing.expectEqual(28, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file More data", buffer[0..28]);

    try sut.interface.unlink("/dir/file.txt");
    try std.testing.expect(!has_path(&sut, "/dir/file.txt"));

    _ = try link_file.?.interface.seek(0, c.SEEK_SET);
    try std.testing.expectEqual(28, link_file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file More data", buffer[0..28]);
}

test "RamFs.ShouldFormat" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectEqualStrings("ramfs", sut.interface.name());
    try sut.interface.mkdir("/test", 0);
    try sut.interface.mkdir("/test/dir", 0);

    try std.testing.expect(has_path(&sut, "/test"));
    try std.testing.expect(has_path(&sut, "/test/dir"));

    try sut.interface.format();

    try std.testing.expect(!has_path(&sut, "/test"));
    try std.testing.expect(!has_path(&sut, "/test/dir"));
}

test "RamFs.StatShouldWork" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    var stat_data: c.struct_stat = undefined;

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.stat("/nonexisting", &stat_data, true));

    try sut.interface.mkdir("/test", 0);
    try sut.interface.stat("/test", &stat_data, true);
    try std.testing.expectEqual(c.S_IFDIR, @as(c_int, @intCast(stat_data.st_mode)));

    try sut.interface.create("/test/file.txt", 0);
    try sut.interface.stat("/test/file.txt", &stat_data, true);
    try std.testing.expectEqual(c.S_IFREG, @as(c_int, @intCast(stat_data.st_mode)));
}

/// Pin the wall clock at `unix_seconds` for the duration of a test.
///
/// The stub's monotonic clock does not run unless a test moves it, so this
/// holds until the next call: "time passes" in these tests means calling it
/// again with a later value.
fn set_test_clock(unix_seconds: u64) void {
    kernel.time.set_realtime_us(unix_seconds * 1_000_000);
}

test "RamFs.StatReportsWhenAFileWasCreated" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    const created_at: u64 = 1_000_000_000; // 2001-09-09T01:46:40Z
    set_test_clock(created_at);
    try sut.interface.create("/file.txt", 0);

    var info: c.struct_stat = undefined;
    try sut.interface.stat("/file.txt", &info, true);
    try std.testing.expectEqual(@as(i64, created_at), @as(i64, @intCast(info.st_mtim.tv_sec)));
    try std.testing.expectEqual(@as(i64, created_at), @as(i64, @intCast(info.st_atim.tv_sec)));
    try std.testing.expectEqual(@as(i64, created_at), @as(i64, @intCast(info.st_ctim.tv_sec)));
}

test "RamFs.StatReportsTheFileSize" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var maybe_node = try sut.interface.get("/file.txt");
    defer maybe_node.delete();
    var file = maybe_node.as_file().?;
    _ = file.interface.write("0123456789");

    var info: c.struct_stat = undefined;
    try sut.interface.stat("/file.txt", &info, true);
    try std.testing.expectEqual(@as(usize, 10), @as(usize, @intCast(info.st_size)));
}

test "RamFs.WritingMovesTheModificationTimeAndLeavesTheAccessTime" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    const created_at: u64 = 1_000_000_000;
    set_test_clock(created_at);
    try sut.interface.create("/file.txt", 0);

    const written_at: u64 = created_at + 3600;
    set_test_clock(written_at);
    var maybe_node = try sut.interface.get("/file.txt");
    defer maybe_node.delete();
    var file = maybe_node.as_file().?;
    _ = file.interface.write("payload");

    var info: c.struct_stat = undefined;
    try sut.interface.stat("/file.txt", &info, true);
    // This is the whole point of the exercise: the modification time moved,
    // which is what lets anything comparing dates see the file as new.
    try std.testing.expectEqual(@as(i64, written_at), @as(i64, @intCast(info.st_mtim.tv_sec)));
    try std.testing.expectEqual(@as(i64, written_at), @as(i64, @intCast(info.st_ctim.tv_sec)));
    // Writing is not reading, so the access time stayed where it was.
    try std.testing.expectEqual(@as(i64, created_at), @as(i64, @intCast(info.st_atim.tv_sec)));

    // And reading moves that one, and only that one.
    const read_at: u64 = written_at + 60;
    set_test_clock(read_at);
    var buffer: [16]u8 = undefined;
    _ = file.interface.seek(0, c.SEEK_SET) catch unreachable;
    _ = file.interface.read(buffer[0..]);
    try sut.interface.stat("/file.txt", &info, true);
    try std.testing.expectEqual(@as(i64, read_at), @as(i64, @intCast(info.st_atim.tv_sec)));
    try std.testing.expectEqual(@as(i64, written_at), @as(i64, @intCast(info.st_mtim.tv_sec)));
}

test "RamFs.UtimensSetsWhatItIsGivenAndOmitsTheRest" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    set_test_clock(1_000_000_000);
    try sut.interface.create("/file.txt", 0);

    const stamped_at: u64 = 1_500_000_000;
    set_test_clock(stamped_at);
    try sut.interface.utimens("/file.txt", .{
        .accessed = null, // UTIME_OMIT, once the syscall layer has resolved it
        .modified = .{ .tv_sec = 1_234_567_890, .tv_nsec = 500 },
    }, true);

    var info: c.struct_stat = undefined;
    try sut.interface.stat("/file.txt", &info, true);
    try std.testing.expectEqual(@as(i64, 1_234_567_890), @as(i64, @intCast(info.st_mtim.tv_sec)));
    try std.testing.expectEqual(@as(i64, 500), @as(i64, @intCast(info.st_mtim.tv_nsec)));
    // Omitted, so untouched.
    try std.testing.expectEqual(@as(i64, 1_000_000_000), @as(i64, @intCast(info.st_atim.tv_sec)));
    // The metadata did change, whichever halves were asked for.
    try std.testing.expectEqual(@as(i64, stamped_at), @as(i64, @intCast(info.st_ctim.tv_sec)));
}

test "RamFs.UtimensWorksOnADirectoryToo" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    set_test_clock(1_000_000_000);
    try sut.interface.mkdir("/dir", 0);

    try sut.interface.utimens("/dir", .{
        .accessed = .{ .tv_sec = 111, .tv_nsec = 0 },
        .modified = .{ .tv_sec = 222, .tv_nsec = 0 },
    }, true);

    var info: c.struct_stat = undefined;
    try sut.interface.stat("/dir", &info, true);
    try std.testing.expectEqual(@as(i64, 111), @as(i64, @intCast(info.st_atim.tv_sec)));
    try std.testing.expectEqual(@as(i64, 222), @as(i64, @intCast(info.st_mtim.tv_sec)));
}

test "RamFs.AddingAnEntryMovesTheDirectoryTimestamp" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    set_test_clock(1_000_000_000);
    try sut.interface.mkdir("/dir", 0);
    var before: c.struct_stat = undefined;
    try sut.interface.stat("/dir", &before, true);

    set_test_clock(1_000_003_600);
    try sut.interface.create("/dir/file.txt", 0);
    var after: c.struct_stat = undefined;
    try sut.interface.stat("/dir", &after, true);

    try std.testing.expect(after.st_mtim.tv_sec > before.st_mtim.tv_sec);
}

test "RamFs.StatsItsOwnRootUnderEverySpellingOfIt" {
    // What the VFS hands a mount when the path *is* the mount point: it strips
    // the prefix and passes the remainder, which for `/tmp` itself is the empty
    // string. Getting this wrong is not subtle -- `ls -la /` renders the failed
    // stat as a row of question marks where /tmp should be.
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    for ([_][]const u8{ "", "/", "." }) |spelling| {
        var info: c.struct_stat = undefined;
        sut.interface.stat(spelling, &info, true) catch |err| {
            std.debug.print("stat({s}) failed: {s}\n", .{ spelling, @errorName(err) });
            return err;
        };
        try std.testing.expectEqual(c.S_IFDIR, @as(c_int, @intCast(info.st_mode)));
    }
}

test "RamFs.HardLinksShareOneInodeAndOneSetOfTimestamps" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    set_test_clock(1_000_000_000);
    try sut.interface.create("/original.txt", 0);
    try sut.interface.link("/original.txt", "/hardlink.txt");

    var original: c.struct_stat = undefined;
    var linked: c.struct_stat = undefined;
    try sut.interface.stat("/original.txt", &original, true);
    try sut.interface.stat("/hardlink.txt", &linked, true);
    try std.testing.expectEqual(original.st_ino, linked.st_ino);

    // And a different file is a different inode, which is the half that was
    // broken while every body was handed the number 1.
    try sut.interface.create("/other.txt", 0);
    var other: c.struct_stat = undefined;
    try sut.interface.stat("/other.txt", &other, true);
    try std.testing.expect(other.st_ino != original.st_ino);

    // One body, one set of timestamps: touching either name moves both.
    try sut.interface.utimens("/hardlink.txt", .{
        .accessed = null,
        .modified = .{ .tv_sec = 1_234_567_890, .tv_nsec = 0 },
    }, true);
    try sut.interface.stat("/original.txt", &original, true);
    try std.testing.expectEqual(@as(i64, 1_234_567_890), @as(i64, @intCast(original.st_mtim.tv_sec)));
}

test "RamFs.UtimensOnAMissingPathFails" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectError(
        kernel.errno.ErrnoSet.NoEntry,
        sut.interface.utimens("/nonexisting", .{ .accessed = null, .modified = null }, true),
    );
}

test "RamFs.AccessShouldWork" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.interface.access("/nonexisting", c.F_OK, 0));

    try sut.interface.mkdir("/test", 0);
    try sut.interface.access("/test", c.F_OK, 0);
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, sut.interface.access("/test", c.W_OK, 0));

    try sut.interface.create("/test/file.txt", 0);
    try sut.interface.access("/test/file.txt", c.F_OK, 0);
    try sut.interface.access("/test/file.txt", c.W_OK, 0);
}

test "RamFsFile.ShouldWriteAndReadData" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var node = try sut.interface.get("/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);

    try std.testing.expectEqual(18, file.?.interface.write("Some data for file"));

    var buffer: [32]u8 = undefined;
    _ = try file.?.interface.seek(0, c.SEEK_SET);
    try std.testing.expectEqual(18, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("Some data for file", buffer[0..18]);
}

test "RamFsFile.ShouldHandleSeekCorrectly" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var node = try sut.interface.get("/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);

    try std.testing.expectEqual(11, file.?.interface.write("Hello World"));

    var buffer: [32]u8 = undefined;
    _ = try file.?.interface.seek(-5, c.SEEK_END);
    try std.testing.expectEqual(5, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("World", buffer[0..5]);

    _ = try file.?.interface.seek(6, c.SEEK_SET);
    try std.testing.expectEqual(5, file.?.interface.read(buffer[0..]));
    try std.testing.expectEqualStrings("World", buffer[0..5]);

    _ = try file.?.interface.seek(-11, c.SEEK_CUR);
    try std.testing.expectEqual(11, file.?.interface.read(buffer[0..11]));
    try std.testing.expectEqualStrings("Hello World", buffer[0..11]);

    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.?.interface.seek(-1, 9999));
    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.?.interface.seek(@as(isize, -2) * @as(isize, @intCast(file.?.interface.size())), c.SEEK_END));
}

test "RamFsFile.ShouldAlwaysReturnZeroForSync" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var node = try sut.interface.get("/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);

    _ = file.?.interface.write("Some data");
    try std.testing.expectEqual(0, file.?.interface.sync());
}

test "RamFsFile.ShouldReturnNotMemoryMappedForIoctl" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var node = try sut.interface.get("/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);

    var status: kernel.fs.FileMemoryMapAttributes = undefined;
    try std.testing.expectEqual(-1, file.?.interface.ioctl(-1, &status));
    try std.testing.expectEqual(0, file.?.interface.ioctl(@intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus), &status));
    try std.testing.expectEqual(false, status.is_memory_mapped);
    try std.testing.expectEqual(@as(?*const anyopaque, null), status.mapped_address_r);
}

test "RamFsFile.ShouldAlwaysReturnZeroForFcntl" {
    var fs = try RamFs.InstanceType.init(std.testing.allocator);
    var sut = fs.interface.create();
    defer _ = sut.interface.delete();

    try sut.interface.create("/file.txt", 0);
    var node = try sut.interface.get("/file.txt");
    defer node.delete();
    var file = node.as_file();
    try std.testing.expect(file != null);

    var data: i32 = 0;
    try std.testing.expectEqual(0, file.?.interface.fcntl(-1, &data));
    try std.testing.expectEqual(0, data);
    try std.testing.expectEqual(0, file.?.interface.fcntl(-123, null));
    try std.testing.expectEqual(0, file.?.interface.fcntl(0, &data));
    try std.testing.expectEqual(0, file.?.interface.fcntl(999, null));
}
