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
const MountMatch = @import("mount_points.zig").MountPoints.Match(*MountPoint);

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
    /// Path buffers, gone by the end of the call and made on every lookup. Mount points
    /// stay for good and are read on every lookup too, but are not allocated then.
    paths_allocator: std.mem.Allocator,

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
            if (node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
            return try node.point.filesystem.interface.create(node.left, mode);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            if (node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
            return try node.point.filesystem.interface.mkdir(node.left, mode);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_unlink(self: *Self, path: []const u8) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            if (node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
            return node.point.filesystem.interface.unlink(node.left);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        const t_mount = if (perf.enabled) perf.read_cycles() else 0;
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        const t_fsget = if (perf.enabled) perf.read_cycles() else 0;
        if (perf.enabled) perf.vfs_mount(t_fsget -% t_mount);
        return get_on(maybe_node, t_fsget);
    }

    fn get_on(maybe_node: ?MountMatch, t_fsget: u64) anyerror!kernel.fs.Node {
        if (maybe_node) |*node| {
            defer if (perf.enabled) perf.vfs_fsget(perf.read_cycles() -% t_fsget);
            var result = try node.point.filesystem.interface.get(node.left);
            result.immutable_backing = node.point.info.read_only() and
                std.mem.eql(u8, node.point.info.fstype(), "romfs");
            return result;
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    // ------------------------------------------------------------------
    // Bind mounts, taken out here for the calls that go deep. BindFs would hand
    // the rewritten path back to the VFS, a whole dispatch and lookup further down
    // the calling process's stack, under a filesystem that needs all it can get.
    // ------------------------------------------------------------------
    const ThroughBinds = struct {
        /// The rewritten path, when a bind was crossed. The match's `left` points
        /// into it.
        owned: ?[]u8 = null,
        read_only: bool = false,
    };

    /// The source of the bind mounted at `point`. Null for anything else, and for
    /// a source too long for `MountInfo`, which BindFs still holds whole.
    fn bind_source(point: *const MountPoint) ?[]const u8 {
        if (!std.mem.eql(u8, point.info.fstype(), "bind")) return null;
        if (point.info.source_len == point.info.source_buffer.len) return null;
        return std.mem.trimEnd(u8, point.info.source(), "/");
    }

    fn find_through_binds(self: *Self, path: []const u8, through: *ThroughBinds) anyerror!?MountMatch {
        const allocator = self.paths_allocator;
        var match = self.mount_points.find_longest_matching_point(*MountPoint, path) orelse return null;
        var crossed: u8 = 0;
        while (bind_source(match.point)) |source| : (crossed += 1) {
            // A bind that leads back to itself. BindFs would only find out by
            // running off the end of the stack.
            if (crossed == max_symlink_depth) return kernel.errno.ErrnoSet.TooManySymbolicLinks;
            if (match.point.info.read_only()) through.read_only = true;
            const relative = std.mem.trim(u8, match.left, "/");
            const full = try allocator.alloc(u8, source.len + 1 + relative.len);
            @memcpy(full[0..source.len], source);
            full[source.len] = '/';
            @memcpy(full[source.len + 1..], relative);
            if (through.owned) |previous| allocator.free(previous);
            through.owned = full;
            match = self.mount_points.find_longest_matching_point(*MountPoint, full) orelse return null;
        }
        return match;
    }

    fn raw_stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            const trimmed_path = std.mem.trim(u8, node.left, "/ ");
            return try node.point.filesystem.interface.stat(trimmed_path, data, follow_symlinks);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_utimens(self: *Self, path: []const u8, times: kernel.fs.TimeStamps, follow_symlinks: bool) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            if (node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
            const trimmed_path = std.mem.trim(u8, node.left, "/ ");
            return try node.point.filesystem.interface.utimens(trimmed_path, times, follow_symlinks);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_chmod(self: *Self, path: []const u8, mode: u32, follow_symlinks: bool) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            if (node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
            return node.point.filesystem.interface.chmod(std.mem.trim(u8, node.left, "/ "), mode, follow_symlinks);
        }
        return kernel.errno.ErrnoSet.NoEntry;
    }

    fn raw_chown(self: *Self, path: []const u8, uid: u32, gid: u32, follow_symlinks: bool) anyerror!void {
        const maybe_node = self.mount_points.find_longest_matching_point(*MountPoint, path);
        if (maybe_node) |*node| {
            if (node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
            return node.point.filesystem.interface.chown(std.mem.trim(u8, node.left, "/ "), uid, gid, follow_symlinks);
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
            if (node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
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
            // A bind mount hands every call to the VFS again, which has already
            // run this pass on the bind's source: asking twice only pays twice.
            if (std.mem.eql(u8, node.point.info.fstype(), "bind")) return false;
            return node.point.filesystem.interface.supports_symlinks();
        }
        return false;
    }

    // The miss that brought us here usually has a real directory as its parent.
    // Filesystems walk a path literally, stopping at anything that is not a
    // directory, so a parent that stats as a directory rules out a link on every
    // component above it; only the final one is left to check. Without this, a
    // miss stats each prefix from the root: quadratic in depth, per -I directory.
    fn no_symlink_on_path(self: *Self, path: []const u8, follow_final: bool) anyerror!bool {
        const trimmed = std.mem.trimEnd(u8, path, "/");
        const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return false;
        if (slash == 0) return false;
        const parent = trimmed[0..slash];
        if (!self.prefix_can_hold_symlink(parent)) return false;
        var st: c.struct_stat = undefined;
        self.raw_stat(parent, &st, false) catch return false;
        if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return false;
        if (!follow_final) return true;
        self.raw_stat(trimmed, &st, false) catch return true;
        return (st.st_mode & c.S_IFMT) != c.S_IFLNK;
    }

    /// These two are out of line for the stack: a stat and a 256-byte target are only
    /// needed here, and every filesystem lookup below resolve_symlinks would pay for them.
    fn prefix_is_symlink(self: *Self, prefix: []const u8) !bool {
        var st: c.struct_stat = undefined;
        try self.raw_stat(prefix, &st, false);
        return (st.st_mode & c.S_IFMT) == c.S_IFLNK;
    }

    /// The path with the link at `prefix` replaced by its target; null when it cannot be read.
    fn follow_symlink(self: *Self, prefix: []const u8, remainder: []const u8, parent: []const u8) anyerror!?[]u8 {
        const allocator = self.paths_allocator;
        // On the heap: the readlink below goes all the way through the filesystem.
        const target_buffer = try allocator.alloc(u8, symlink_target_buffer);
        defer allocator.free(target_buffer);
        const n = self.raw_readlink(prefix, target_buffer) catch return null;
        const target = target_buffer[0..n];
        // Absolute target replaces from root; relative target resolves
        // against the link's parent directory.
        const base = if (target.len > 0 and target[0] == '/') "" else parent;
        const joined = try vfmt.allocPrint(allocator, "{s}{s}{s}", .{ base, target, remainder });
        defer allocator.free(joined);
        return try std.fs.path.resolve(allocator, &.{joined});
    }

    fn resolve_symlinks(self: *Self, path: []const u8, follow_final: bool) anyerror!?[]u8 {
        const allocator = self.paths_allocator;
        if (try self.no_symlink_on_path(path, follow_final)) return null;
        var cur = try allocator.dupe(u8, path);
        errdefer allocator.free(cur);
        var changed = false;
        var depth: usize = 0;
        var cur_next: []u8 = undefined;

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

                if (!(@call(.never_inline, prefix_is_symlink, .{ self, prefix }) catch break)) {
                    comp_start = i + 1;
                    continue;
                }

                depth += 1;
                if (depth > max_symlink_depth) return kernel.errno.ErrnoSet.TooManySymbolicLinks;
                cur_next = (try @call(.never_inline, follow_symlink, .{ self, prefix, cur[i..], cur[0..comp_start] })) orelse break;
                allocator.free(cur);
                cur = cur_next;
                changed = true;
                continue :outer;
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
                defer self.paths_allocator.free(resolved);
                return self.raw_create(resolved, mode);
            }
            return err;
        };
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        return self.raw_mkdir(path, mode) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
                return self.raw_mkdir(resolved, mode);
            }
            return err;
        };
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        return self.raw_unlink(path) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
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
        var through: ThroughBinds = .{};
        defer if (through.owned) |owned| self.paths_allocator.free(owned);
        const t_mount = if (perf.enabled) perf.read_cycles() else 0;
        const maybe_node = try @call(.never_inline, find_through_binds, .{ self, path, &through });
        const t_fsget = if (perf.enabled) perf.read_cycles() else 0;
        if (perf.enabled) perf.vfs_mount(t_fsget -% t_mount);
        // On the source, so links under a bind resolve where they live.
        var node = get_on(maybe_node, t_fsget) catch |err|
            try @call(.never_inline, get_through_symlinks, .{ self, through.owned orelse path, err });
        // What the bind's own mount says: it is not the romfs image, whatever the
        // source is on.
        if (through.owned != null) node.immutable_backing = false;
        return node;
    }

    /// Out of line: its frame would otherwise sit under every lookup that works.
    fn get_through_symlinks(self: *Self, path: []const u8, err: anyerror) anyerror!kernel.fs.Node {
        const maybe_resolved = self.resolve_symlinks(path, true) catch return err;
        if (maybe_resolved) |resolved| {
            defer self.paths_allocator.free(resolved);
            return self.raw_get(resolved);
        }
        return err;
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
                defer self.paths_allocator.free(resolved);
                return self.raw_stat(resolved, data, follow_symlinks);
            }
            return err;
        };
    }

    /// Same symlink fallback as `stat`: a path that only resolves through a
    /// link (`/tmp/...` is one) has to be re-resolved before the owning
    /// filesystem sees it.
    pub fn utimens(self: *Self, path: []const u8, times: kernel.fs.TimeStamps, follow_symlinks: bool) anyerror!void {
        return self.raw_utimens(path, times, follow_symlinks) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, follow_symlinks) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
                return self.raw_utimens(resolved, times, follow_symlinks);
            }
            return err;
        };
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        return self.raw_readlink(path, buffer) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
                return self.raw_readlink(resolved, buffer);
            }
            return err;
        };
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        return self.raw_symlink(target, linkpath) catch |err| {
            const maybe_resolved = self.resolve_symlinks(linkpath, false) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
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
            .paths_allocator = kernel.memory.heap.slow.fast_or(allocator),
        });
    }

    pub fn deinit(self: *Self) void {
        log.info("Virtual file system deinitialization", .{});
        self.mount_points.deinit();
    }

    pub fn mount_filesystem(self: *Self, path: []const u8, fs: IFileSystem) !void {
        try self.mount_points.mount_filesystem(path, fs);
    }

    /// Mount with the description `/proc/mounts` shows. On error the caller
    /// still owns `fs`.
    pub fn mount_filesystem_with_info(self: *Self, path: []const u8, fs: IFileSystem, info: kernel.fs.MountInfo) !void {
        try self.mount_points.mount_filesystem_with_info(path, fs, info);
    }

    /// chmod(2), with the same symlink fallback as `stat`.
    pub fn chmod(self: *Self, path: []const u8, mode: u32, follow_symlinks: bool) anyerror!void {
        return self.raw_chmod(path, mode, follow_symlinks) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, follow_symlinks) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
                return self.raw_chmod(resolved, mode, follow_symlinks);
            }
            return err;
        };
    }

    /// chown(2), likewise.
    pub fn chown(self: *Self, path: []const u8, uid: u32, gid: u32, follow_symlinks: bool) anyerror!void {
        return self.raw_chown(path, uid, gid, follow_symlinks) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, follow_symlinks) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
                return self.raw_chown(resolved, uid, gid, follow_symlinks);
            }
            return err;
        };
    }

    pub fn immutable_token(self: *Self, path: []const u8) ?u64 {
        return self.mount_points.immutable_token(path);
    }

    /// Whether `path` lies on a mount made with `ro`. `open` asks before it
    /// hands out a descriptor that could write.
    pub fn is_read_only(self: *Self, path: []const u8) bool {
        const match = self.mount_points.find_longest_matching_point(*MountPoint, path) orelse return false;
        return match.point.info.read_only();
    }

    /// The root filesystem's figures; `statvfs_path` is the useful one.
    pub fn statvfs(self: *Self) anyerror!kernel.fs.FsStats {
        return self.statvfs_path("/");
    }

    /// statvfs(2): the figures of whichever filesystem serves `path`.
    pub fn statvfs_path(self: *Self, path: []const u8) anyerror!kernel.fs.FsStats {
        const match = self.mount_points.find_longest_matching_point(*MountPoint, path) orelse return kernel.errno.ErrnoSet.NoEntry;
        var filesystem = match.point.filesystem;
        var stats = try filesystem.interface.statvfs();
        if (match.point.info.read_only()) stats.read_only = true;
        return stats;
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return error.NotSupported;
    }

    /// rename(2). Both paths have to land on the same mount point: moving an
    /// entry between filesystems would mean copying the contents, which
    /// rename() is not allowed to do (EXDEV is the answer that tells a caller
    /// to copy-and-delete itself, and every runtime knows to do that).
    pub fn rename(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        const maybe_old = self.mount_points.find_longest_matching_point(*MountPoint, old_path);
        const maybe_new = self.mount_points.find_longest_matching_point(*MountPoint, new_path);
        if (maybe_old == null or maybe_new == null) {
            return kernel.errno.ErrnoSet.NoEntry;
        }
        const old_node = maybe_old.?;
        const new_node = maybe_new.?;
        if (old_node.point != new_node.point) {
            return kernel.errno.ErrnoSet.CrossDeviceLink;
        }
        if (old_node.point.info.read_only()) return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
        return old_node.point.filesystem.interface.rename(old_node.left, new_node.left);
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        return self.raw_access(path, mode, flags) catch |err| {
            const maybe_resolved = self.resolve_symlinks(path, true) catch return err;
            if (maybe_resolved) |resolved| {
                defer self.paths_allocator.free(resolved);
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

const SymlinkFixture = struct {
    fn stat(_: ?*const anyopaque, args: @Tuple(&.{ []const u8, *c.struct_stat, bool })) anyerror!anyerror!void {
        if (std.mem.endsWith(u8, args[0], "missing")) return @as(anyerror!void, kernel.errno.ErrnoSet.NoEntry);
        args[1].* = std.mem.zeroes(c.struct_stat);
        args[1].st_mode = if (std.mem.endsWith(u8, args[0], "link")) c.S_IFLNK else c.S_IFDIR;
    }
    fn readlink(_: ?*const anyopaque, args: @Tuple(&.{ []const u8, []u8 })) anyerror!anyerror!usize {
        const target = "real";
        @memcpy(args[1][0..target.len], target);
        return target.len;
    }
};

test "VirtualFileSystem.MissUnderARealDirectoryStatsOnlyParentAndName" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    vfs_init(std.testing.allocator);
    defer vfs_deinit();
    const sut = get_vfs();
    try sut.mount_filesystem("/", fs_mock.get_interface());

    _ = fs_mock.expectCall("get").withArgs(.{"a/b/c/missing"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    _ = fs_mock.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(true);
    // Include search probes deep paths in bulk. Walking each prefix from the
    // root would stat "a" and "a/b" too; the mock panics on either.
    _ = fs_mock.expectCall("stat").withArgs(.{ "a/b/c", interface.mock.any{}, false }).invoke(&SymlinkFixture.stat, null);
    _ = fs_mock.expectCall("stat").withArgs(.{ "a/b/c/missing", interface.mock.any{}, false }).invoke(&SymlinkFixture.stat, null);

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.get("/a/b/c/missing"));
}

test "VirtualFileSystem.LinkAsFinalComponentStillResolves" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    vfs_init(std.testing.allocator);
    defer vfs_deinit();
    const sut = get_vfs();
    try sut.mount_filesystem("/", fs_mock.get_interface());
    var file_mock = try FileMock.create(std.testing.allocator);

    _ = fs_mock.expectCall("get").withArgs(.{"a/link"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    _ = fs_mock.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(true);
    _ = fs_mock.expectCall("stat").withArgs(.{ interface.mock.any{}, interface.mock.any{}, false }).times(interface.mock.any{}).invoke(&SymlinkFixture.stat, null);
    _ = fs_mock.expectCall("readlink").withArgs(.{ "a/link", interface.mock.any{} }).invoke(&SymlinkFixture.readlink, null);
    _ = fs_mock.expectCall("get").withArgs(.{"a/real"}).willReturn(kernel.fs.Node.create_file(file_mock.get_interface()));

    var node = try sut.get("/a/link");
    defer node.delete();
}

test "VirtualFileSystem.LinkInTheMiddleOfAPathStillResolves" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var fs_mock = try FileSystemMock.create(std.testing.allocator);
    vfs_init(std.testing.allocator);
    defer vfs_deinit();
    const sut = get_vfs();
    try sut.mount_filesystem("/", fs_mock.get_interface());
    var file_mock = try FileMock.create(std.testing.allocator);

    _ = fs_mock.expectCall("get").withArgs(.{"a/link/file"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    _ = fs_mock.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(true);
    _ = fs_mock.expectCall("stat").withArgs(.{ interface.mock.any{}, interface.mock.any{}, false }).times(interface.mock.any{}).invoke(&SymlinkFixture.stat, null);
    _ = fs_mock.expectCall("readlink").withArgs(.{ "a/link", interface.mock.any{} }).invoke(&SymlinkFixture.readlink, null);
    _ = fs_mock.expectCall("get").withArgs(.{"a/real/file"}).willReturn(kernel.fs.Node.create_file(file_mock.get_interface()));

    var node = try sut.get("/a/link/file");
    defer node.delete();
}

test "VirtualFileSystem.MissThroughABindMountRunsOneSymlinkPassOnTheSource" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    const Callbacks = struct {
        fn stat(_: ?*const anyopaque, args: @Tuple(&.{ []const u8, *c.struct_stat, bool })) anyerror!anyerror!void {
            // One pass, over the source's components and never the bind's.
            try std.testing.expect(std.mem.startsWith(u8, args[0], "src"));
            return @as(anyerror!void, kernel.errno.ErrnoSet.NoEntry);
        }
    };
    var root = try FileSystemMock.create(std.testing.allocator);
    var bound = try FileSystemMock.create(std.testing.allocator);
    vfs_init(std.testing.allocator);
    defer vfs_deinit();
    const sut = get_vfs();
    try sut.mount_filesystem_with_info("/", root.get_interface(), kernel.fs.MountInfo.init("root", "romfs", "rw"));
    var mount_point_mock = try FileMock.create(std.testing.allocator);
    _ = root.expectCall("get").withArgs(.{"bound"}).willReturn(kernel.fs.Node.create_file(mount_point_mock.get_interface()));
    _ = bound.expectCall("mount").willReturn(@as(u32, 0));
    try sut.mount_filesystem_with_info("/bound", bound.get_interface(), kernel.fs.MountInfo.init("/src", "bind", "rw"));

    // The bind itself is not called: the mock would panic.
    _ = root.expectCall("get").withArgs(.{"src/a/missing"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    _ = root.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(true);
    _ = bound.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(true);
    _ = root.expectCall("stat").withArgs(.{ interface.mock.any{}, interface.mock.any{}, interface.mock.any{} }).times(interface.mock.any{}).invoke(&Callbacks.stat, null);

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.get("/bound/a/missing"));
}

test "VirtualFileSystem.GetGoesThroughABindWithoutCallingIt" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var root = try FileSystemMock.create(std.testing.allocator);
    var bound = try FileSystemMock.create(std.testing.allocator);
    vfs_init(std.testing.allocator);
    defer vfs_deinit();
    const sut = get_vfs();
    try sut.mount_filesystem_with_info("/", root.get_interface(), kernel.fs.MountInfo.init("root", "romfs", "ro"));
    var mount_point_mock = try FileMock.create(std.testing.allocator);
    _ = root.expectCall("get").withArgs(.{"bound"}).willReturn(kernel.fs.Node.create_file(mount_point_mock.get_interface()));
    _ = bound.expectCall("mount").willReturn(@as(u32, 0));
    // A trailing slash on the source, and the bind's root as well as a path under it.
    try sut.mount_filesystem_with_info("/bound", bound.get_interface(), kernel.fs.MountInfo.init("/src/", "bind", "rw"));

    var under = try FileMock.create(std.testing.allocator);
    _ = root.expectCall("get").withArgs(.{"src/a/file"}).willReturn(kernel.fs.Node.create_file(under.get_interface()));
    var node = try sut.get("/bound/a/file");
    defer node.delete();
    // What the bind's own mount says, as before: it is not the romfs image.
    try std.testing.expect(!node.immutable_backing);

    var top = try FileMock.create(std.testing.allocator);
    _ = root.expectCall("get").withArgs(.{"src"}).willReturn(kernel.fs.Node.create_file(top.get_interface()));
    var top_node = try sut.get("/bound");
    defer top_node.delete();
}

test "VirtualFileSystem.ASourceTooLongForTheMountInfoStillGoesThroughTheBind" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    var root = try FileSystemMock.create(std.testing.allocator);
    var bound = try FileSystemMock.create(std.testing.allocator);
    vfs_init(std.testing.allocator);
    defer vfs_deinit();
    const sut = get_vfs();
    try sut.mount_filesystem_with_info("/", root.get_interface(), kernel.fs.MountInfo.init("root", "romfs", "rw"));
    var mount_point_mock = try FileMock.create(std.testing.allocator);
    _ = root.expectCall("get").withArgs(.{"bound"}).willReturn(kernel.fs.Node.create_file(mount_point_mock.get_interface()));
    _ = bound.expectCall("mount").willReturn(@as(u32, 0));
    const long = "/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    try sut.mount_filesystem_with_info("/bound", bound.get_interface(), kernel.fs.MountInfo.init(long, "bind", "rw"));

    var file = try FileMock.create(std.testing.allocator);
    _ = bound.expectCall("get").withArgs(.{"a"}).willReturn(kernel.fs.Node.create_file(file.get_interface()));
    var node = try sut.get("/bound/a");
    defer node.delete();
}

test "VirtualFileSystem.GetShouldFailIfNoFilesystemMounted" {
    vfs_init(std.testing.allocator);
    const sut = get_vfs();
    defer vfs_deinit();

    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, sut.get("/file.txt"));
}

test "VirtualFileSystem.SymlinkFallbackUsesActualBackingLifetime" {
    const FileSystemMock = @import("tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("tests/file_mock.zig").FileMock;
    const Callbacks = struct {
        fn stat(_: ?*const anyopaque, args: @Tuple(&.{ []const u8, *c.struct_stat, bool })) anyerror!anyerror!void {
            args[1].* = std.mem.zeroes(c.struct_stat);
            args[1].st_mode = c.S_IFLNK;
        }
        fn readlink(_: ?*const anyopaque, args: @Tuple(&.{ []const u8, []u8 })) anyerror!anyerror!usize {
            const target = "/var/file";
            @memcpy(args[1][0..target.len], target);
            return target.len;
        }
    };
    var root = try FileSystemMock.create(std.testing.allocator);
    var mutable = try FileSystemMock.create(std.testing.allocator);
    vfs_init(std.testing.allocator);
    defer vfs_deinit();
    const sut = get_vfs();
    try sut.mount_filesystem_with_info("/", root.get_interface(), kernel.fs.MountInfo.init("root", "romfs", "ro"));
    var mount_point_mock = try FileMock.create(std.testing.allocator);
    const mount_point = kernel.fs.Node.create_file(mount_point_mock.get_interface());
    _ = root.expectCall("get").withArgs(.{"var"}).willReturn(mount_point);
    _ = mutable.expectCall("mount").willReturn(@as(u32, 0));
    try sut.mount_filesystem_with_info("/var", mutable.get_interface(), kernel.fs.MountInfo.init("ram", "ramfs", "rw"));
    var file_mock = try FileMock.create(std.testing.allocator);
    // The filesystem cannot supply a false lifetime guarantee: VFS replaces it.
    var supplied = kernel.fs.Node.create_file(file_mock.get_interface());
    supplied.immutable_backing = true;
    _ = root.expectCall("get").withArgs(.{"alias"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    _ = root.expectCall("supports_symlinks").willReturn(true);
    _ = root.expectCall("stat").withArgs(.{ "alias", interface.mock.any{}, false }).invoke(&Callbacks.stat, null);
    _ = root.expectCall("readlink").withArgs(.{ "alias", interface.mock.any{} }).invoke(&Callbacks.readlink, null);
    _ = mutable.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(false);
    _ = mutable.expectCall("get").withArgs(.{"file"}).willReturn(supplied);
    try std.testing.expect(sut.immutable_token("/alias") != null);
    var node = try sut.get("/alias");
    defer node.delete();
    try std.testing.expect(!node.immutable_backing);
    var shared = node.share();
    defer shared.delete();
    try std.testing.expect(!shared.immutable_backing);
}
