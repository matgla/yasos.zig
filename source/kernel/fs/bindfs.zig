//
// bindfs.zig
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

// A bind mount: a directory that is already reachable somewhere in the tree,
// made reachable at a second place too (`mount --bind /home/root /root`).
//
// It holds no data. Every call is rewritten to `<source>/<path>` and handed
// back to the VFS, so it lands on whichever filesystem serves the source --
// including one mounted after the bind was made. The source is pinned for as
// long as the bind exists, so the filesystem under it cannot be unmounted
// from beneath it.

const std = @import("std");

const c = @import("libc_imports").c;

const interface = @import("interface");

const kernel = @import("../kernel.zig");
const IFileSystem = @import("ifilesystem.zig").IFileSystem;
const FsStats = @import("ifilesystem.zig").FsStats;
const TimeStamps = @import("ifilesystem.zig").TimeStamps;
const mount_api = @import("mount_api.zig");

pub const BindFs = interface.DeriveFromBase(IFileSystem, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    /// Absolute, no trailing slash. Owned.
    _source: []u8,
    _pinned: bool,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !BindFs {
        const trimmed = std.mem.trimEnd(u8, source, "/");
        if (source.len == 0 or source[0] != '/') return kernel.errno.ErrnoSet.InvalidArgument;
        return BindFs.init(.{
            ._allocator = allocator,
            ._source = try allocator.dupe(u8, trimmed),
            ._pinned = false,
        });
    }

    fn full_path(self: *const Self, path: []const u8) ![]u8 {
        const relative = std.mem.trim(u8, path, "/");
        if (relative.len == 0) {
            return self._allocator.dupe(u8, if (self._source.len == 0) "/" else self._source);
        }
        return std.fmt.allocPrint(self._allocator, "{s}/{s}", .{ self._source, relative });
    }

    fn vfs() *IFileSystem {
        return kernel.fs.get_ivfs();
    }

    /// The source has to be a directory that exists now; afterwards it is
    /// pinned, so it stays reachable.
    pub fn mount(self: *Self) i32 {
        var node = vfs().interface.get(if (self._source.len == 0) "/" else self._source) catch return -1;
        const is_directory = node.is_directory();
        node.delete();
        if (!is_directory) return -1;
        mount_api.pin(self._source) catch return -1;
        self._pinned = true;
        return 0;
    }

    pub fn umount(self: *Self) i32 {
        if (self._pinned) {
            mount_api.unpin(self._source);
            self._pinned = false;
        }
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self.umount();
        self._allocator.free(self._source);
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "bind";
    }

    pub fn create(self: *Self, path: []const u8, flags: i32) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.create(full, flags);
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.mkdir(full, mode);
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.unlink(full);
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.get(full);
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        const old_full = try self.full_path(old_path);
        defer self._allocator.free(old_full);
        const new_full = try self.full_path(new_path);
        defer self._allocator.free(new_full);
        return vfs().interface.link(old_full, new_full);
    }

    pub fn rename(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        const old_full = try self.full_path(old_path);
        defer self._allocator.free(old_full);
        const new_full = try self.full_path(new_path);
        defer self._allocator.free(new_full);
        return vfs().interface.rename(old_full, new_full);
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.access(full, mode, flags);
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        return kernel.errno.ErrnoSet.InvalidArgument;
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_links: bool) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.stat(full, data, follow_links);
    }

    pub fn utimens(self: *Self, path: []const u8, times: TimeStamps, follow_links: bool) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.utimens(full, times, follow_links);
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.readlink(full, buffer);
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        const full = try self.full_path(linkpath);
        defer self._allocator.free(full);
        return vfs().interface.symlink(target, full);
    }

    /// Whatever serves the source decides; asking costs a lookup, and the VFS
    /// asks this on every failed path walk, so answer for the format the
    /// source lives on.
    pub fn supports_symlinks(self: *const Self) bool {
        const vfs_data = kernel.fs.get_vfs();
        const match = vfs_data.mount_points.find_longest_matching_point(*kernel.fs.mount_points.MountPoint, if (self._source.len == 0) "/" else self._source) orelse return true;
        var filesystem = match.point.filesystem;
        return filesystem.interface.supports_symlinks();
    }

    pub fn chmod(self: *Self, path: []const u8, mode: u32, follow_links: bool) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.chmod(full, mode, follow_links);
    }

    pub fn chown(self: *Self, path: []const u8, uid: u32, gid: u32, follow_links: bool) anyerror!void {
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        return vfs().interface.chown(full, uid, gid, follow_links);
    }

    pub fn statvfs(self: *Self) anyerror!FsStats {
        return kernel.fs.get_vfs().statvfs_path(self._source);
    }
});
