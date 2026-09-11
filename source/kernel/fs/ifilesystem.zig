//
// filesystem.zig
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

const IFile = @import("ifile.zig").IFile;

const interface = @import("interface");

const kernel = @import("../kernel.zig");

/// The two timestamps `utimens` can set. Null means "leave this one alone" --
/// `utimensat`'s UTIME_OMIT, already resolved by the syscall layer, along with
/// UTIME_NOW, so a filesystem never has to know those sentinels exist.
///
/// There is no `changed` field: POSIX gives no way to set st_ctime, and every
/// filesystem here stamps it with the current time as a side effect of the
/// metadata change `utimens` itself is.
pub const TimeStamps = struct {
    accessed: ?c.struct_timespec,
    modified: ?c.struct_timespec,

    /// Both timestamps set to `now`, which is what `touch` without a `-t`/`-r`
    /// asks for and what a filesystem uses when it creates a file.
    pub fn now(current: c.struct_timespec) TimeStamps {
        return .{ .accessed = current, .modified = current };
    }
};

/// The three timestamps a filesystem keeps for one file, in the storage form:
/// concrete values, where `TimeStamps` above is the request form with holes in
/// it. A filesystem that can hold timestamps at all owns one of these per
/// inode, and `write_into` is how it answers a `stat`.
pub const FileTimes = struct {
    accessed: c.struct_timespec,
    modified: c.struct_timespec,
    /// Last metadata change. Not settable by `utimens` -- POSIX has no way to
    /// ask for a particular ctime -- so it always says "when the change was".
    changed: c.struct_timespec,

    /// A file that has just come into existence: all three the same instant.
    pub fn create(current: c.struct_timespec) FileTimes {
        return .{ .accessed = current, .modified = current, .changed = current };
    }

    /// A write happened. Modification and change move; access does not, because
    /// writing is not reading.
    pub fn record_write(self: *FileTimes, current: c.struct_timespec) void {
        self.modified = current;
        self.changed = current;
    }

    /// A read happened.
    pub fn record_read(self: *FileTimes, current: c.struct_timespec) void {
        self.accessed = current;
    }

    /// Apply a `utimens` request. Whichever halves the caller left out stay as
    /// they were; `changed` moves either way, because the metadata did change.
    pub fn apply(self: *FileTimes, times: TimeStamps, current: c.struct_timespec) void {
        if (times.accessed) |accessed| self.accessed = accessed;
        if (times.modified) |modified| self.modified = modified;
        self.changed = current;
    }

    pub fn write_into(self: *const FileTimes, data: *c.struct_stat) void {
        data.st_atim = self.accessed;
        data.st_mtim = self.modified;
        data.st_ctim = self.changed;
    }
};

pub const IFileSystem = interface.ConstructInterface(struct {
    pub const Self = @This();

    pub fn mount(self: *Self) i32 {
        return interface.VirtualCall(self, "mount", .{}, i32);
    }

    pub fn umount(self: *Self) i32 {
        return interface.VirtualCall(self, "umount", .{}, i32);
    }

    pub fn create(self: *Self, path: []const u8, flags: i32) anyerror!void {
        return interface.VirtualCall(self, "create", .{ path, flags }, anyerror!void);
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        return interface.VirtualCall(self, "mkdir", .{ path, mode }, anyerror!void);
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        return interface.VirtualCall(self, "unlink", .{path}, anyerror!void);
    }

    pub fn name(self: *const Self) []const u8 {
        return interface.VirtualCall(self, "name", .{}, []const u8);
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        return interface.VirtualCall(self, "get", .{path}, anyerror!kernel.fs.Node);
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        return interface.VirtualCall(self, "link", .{ old_path, new_path }, anyerror!void);
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        return interface.VirtualCall(self, "access", .{ path, mode, flags }, anyerror!void);
    }

    pub fn delete(self: *Self) void {
        interface.DestructorCall(self);
    }

    pub fn format(self: *Self) anyerror!void {
        try interface.VirtualCall(self, "format", .{}, anyerror!void);
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_links: bool) anyerror!void {
        return interface.VirtualCall(self, "stat", .{ path, data, follow_links }, anyerror!void);
    }

    /// Set a path's access and/or modification timestamps.
    ///
    /// Filesystems with nowhere to keep a timestamp return
    /// `ReadOnlyFileSystem` (romfs) or `NotSupported`; `touch` on such a path
    /// is expected to fail rather than silently do nothing, because a `make`
    /// that believes a timestamp moved when it did not is worse than one told
    /// it cannot move.
    pub fn utimens(self: *Self, path: []const u8, times: TimeStamps, follow_links: bool) anyerror!void {
        return interface.VirtualCall(self, "utimens", .{ path, times, follow_links }, anyerror!void);
    }

    // Read a symbolic link's target into `buffer`, returning the number of bytes
    // written. Filesystems that do not support symlinks return InvalidArgument
    // (EINVAL: "not a symbolic link").
    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        return interface.VirtualCall(self, "readlink", .{ path, buffer }, anyerror!usize);
    }

    // Create a symbolic link at `linkpath` pointing to `target`.
    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        return interface.VirtualCall(self, "symlink", .{ target, linkpath }, anyerror!void);
    }

    /// Whether this filesystem can hold a symbolic link at all.
    ///
    /// Not a question about a path -- a question about the format. FAT and
    /// littlefs have nowhere to put one and always will not; romfs and ramfs
    /// do. The VFS asks so it can skip work that cannot pay: every failed
    /// lookup runs a resolution pass that stats each path component hunting
    /// for a link, one directory walk apiece, and library and include searches
    /// are made of failed lookups. On a filesystem that answers false, that
    /// pass can only ever confirm what the format already guarantees.
    ///
    /// Answer for the format, not for the current contents: a filesystem that
    /// supports links but happens to hold none must still answer true, or a
    /// link created later would stop resolving.
    pub fn supports_symlinks(self: *const Self) bool {
        return interface.VirtualCall(self, "supports_symlinks", .{}, bool);
    }
});

pub const ReadOnlyFileSystem = interface.DeriveFromBase(IFileSystem, struct {
    pub const Self = @This();

    pub fn mount(self: *Self) i32 {
        _ = self;
        return 0; // Read-only filesystem does not need to do anything on mount
    }

    pub fn umount(self: *Self) i32 {
        _ = self;
        return 0; // Read-only filesystem does not need to do anything on unmount
    }

    pub fn create(self: *Self, path: []const u8, flags: i32) anyerror!void {
        _ = self;
        _ = path;
        _ = flags;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem;
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        _ = self;
        _ = path;
        _ = mode;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow directory creation
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow linking
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        _ = self;
        _ = path;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow unlinking
    }

    pub fn format(self: *Self) anyerror!void {
        _ = self;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem cannot be formatted
    }

    pub fn utimens(self: *Self, path: []const u8, times: TimeStamps, follow_links: bool) anyerror!void {
        _ = self;
        _ = path;
        _ = times;
        _ = follow_links;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // nowhere to write a timestamp
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        _ = self;
        _ = path;
        _ = buffer;
        return kernel.errno.ErrnoSet.InvalidArgument; // not a symbolic link
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        _ = self;
        _ = target;
        _ = linkpath;
        return kernel.errno.ErrnoSet.ReadOnlyFileSystem; // Read-only filesystem does not allow symlinking
    }

    /// Matches the `readlink` above: a read-only filesystem that has not said
    /// otherwise cannot hold a link. One that can -- romfs -- overrides both.
    pub fn supports_symlinks(self: *const Self) bool {
        _ = self;
        return false;
    }
});
