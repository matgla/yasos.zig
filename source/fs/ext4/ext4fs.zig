//
// ext4fs.zig
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

// ext4 through lwext4 (libs/lwext4, built by source/fs/ext4/build.zig).
//
// lwext4 is one global library: a table of registered block devices and a
// table of mount points, addressed by name. Each `Ext4Fs` takes a slot N and
// registers its device as "eN" and mounts it at "/eN/"; every path it is
// handed is rewritten under that prefix. One lock serialises every call into
// the library, as `fs_lock` does for FatFs -- lwext4's own per-mount-point
// locks would not cover the shared tables.
//
// The device is read and written in 512-byte sectors through the kernel IFile
// it was mounted from (an SD partition), under `dev_lock` like FatFs's disk
// wrapper, so the two can share a card.
//
// What the format holds is what stat reports: mode, owner, link count, and
// three timestamps, which lwext4 keeps current through the clock hook this
// module installs (ext4_set_clock). Symbolic links are real; the VFS resolves
// them, so `get` and following `stat` refuse a link rather than open it.

const std = @import("std");

const oop = @import("interface");
const kernel = @import("kernel");
const c = @import("libc_imports").c;
pub const lwext4 = @import("lwext4");

const Ext4File = @import("ext4_file.zig").Ext4File;
const Ext4Directory = @import("ext4_directory.zig").Ext4Directory;

const log = std.log.scoped(.@"fs/ext4");

/// Every call into lwext4 holds this. Rank `fs`, like FatFs's; the two never
/// nest.
pub var lock: kernel.sync.RankedMutex(.fs) = .{};

/// CONFIG_EXT4_MOUNTPOINTS_COUNT in build.zig.
pub const max_volumes = 4;
var slot_in_use: [max_volumes]bool = @splat(false);

pub const sector_size = 512;

/// lwext4's error codes are errno values.
pub fn to_error(rc: c_int) anyerror {
    return kernel.errno.from_errno(@intCast(rc));
}

pub fn check(rc: c_int) anyerror!void {
    if (rc != 0) return to_error(rc);
}

// ── Allocation ────────────────────────────────────────────────────────────
//
// lwext4 is built with CONFIG_USE_USER_MALLOC, so every allocation comes here
// and lands on the kernel allocator (counted, and under its lock) rather than
// on the C library's malloc underneath it. A header in front of each block
// remembers its size, which the Zig allocator needs back at free.

var c_allocator: ?std.mem.Allocator = null;
const header_size = 16;
const alignment: std.mem.Alignment = .@"16";

fn allocate(size: usize) ?[*]u8 {
    const allocator = c_allocator orelse return null;
    const block = allocator.alignedAlloc(u8, alignment, size + header_size) catch return null;
    std.mem.writeInt(usize, block[0..@sizeOf(usize)], size, .little);
    return block.ptr + header_size;
}

fn block_of(pointer: *anyopaque) []align(16) u8 {
    const base: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(pointer)) - header_size);
    const size = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
    return base[0 .. size + header_size];
}

export fn ext4_user_malloc(size: usize) ?*anyopaque {
    return @ptrCast(allocate(size));
}

export fn ext4_user_calloc(count: usize, size: usize) ?*anyopaque {
    const total = std.math.mul(usize, count, size) catch return null;
    const memory = allocate(total) orelse return null;
    @memset(memory[0..total], 0);
    return @ptrCast(memory);
}

export fn ext4_user_free(pointer: ?*anyopaque) void {
    const allocator = c_allocator orelse return;
    allocator.free(block_of(pointer orelse return));
}

export fn ext4_user_realloc(pointer: ?*anyopaque, size: usize) ?*anyopaque {
    const old = pointer orelse return ext4_user_malloc(size);
    const old_block = block_of(old);
    const fresh = allocate(size) orelse return null;
    const keep = @min(size, old_block.len - header_size);
    @memcpy(fresh[0..keep], old_block[header_size..][0..keep]);
    ext4_user_free(old);
    return @ptrCast(fresh);
}

/// lwext4's clock: the kernel's wall clock, in the 32-bit seconds ext4 keeps.
fn wall_clock_seconds() callconv(.c) u32 {
    return @intCast(@min(kernel.time.realtime_seconds(), std.math.maxInt(u32)));
}

// ── Block device ──────────────────────────────────────────────────────────

/// What lwext4 holds a pointer to while mounted, so it lives on the heap and
/// never moves: the `ext4_blockdev` and its interface, and the device behind
/// them.
const Volume = struct {
    iface: lwext4.struct_ext4_blockdev_iface,
    bdev: lwext4.struct_ext4_blockdev,
    buffer: [sector_size]u8 align(4),
    device: kernel.fs.IFile,
    slot: u8,
    mounted: bool,
    device_name: [8:0]u8,
    mount_point: [8:0]u8,

    fn from_bdev(bdev: [*c]lwext4.struct_ext4_blockdev) *Volume {
        return @ptrCast(@alignCast(bdev.*.bdif.*.p_user));
    }

    fn transfer(self: *Volume, write: bool, buffer: ?*anyopaque, block: u64, count: u32) c_int {
        const length: usize = @as(usize, count) * sector_size;
        const bytes: [*]u8 = @ptrCast(buffer orelse return c.EINVAL);
        kernel.driver.dev_lock.acquire();
        defer kernel.driver.dev_lock.release();
        _ = self.device.interface.seek(@intCast(block * sector_size), c.SEEK_SET) catch return c.EIO;
        const done = if (write) self.device.interface.write(bytes[0..length]) else self.device.interface.read(bytes[0..length]);
        return if (done == @as(isize, @intCast(length))) 0 else c.EIO;
    }
};

fn bdev_open(bdev: [*c]lwext4.struct_ext4_blockdev) callconv(.c) c_int {
    _ = bdev;
    return 0;
}

fn bdev_close(bdev: [*c]lwext4.struct_ext4_blockdev) callconv(.c) c_int {
    _ = bdev;
    return 0;
}

fn bdev_read(bdev: [*c]lwext4.struct_ext4_blockdev, buffer: ?*anyopaque, block: u64, count: u32) callconv(.c) c_int {
    return Volume.from_bdev(bdev).transfer(false, buffer, block, count);
}

fn bdev_write(bdev: [*c]lwext4.struct_ext4_blockdev, buffer: ?*const anyopaque, block: u64, count: u32) callconv(.c) c_int {
    return Volume.from_bdev(bdev).transfer(true, @constCast(buffer), block, count);
}

fn initialize_stat_identity(data: *c.struct_stat, slot: u8) void {
    data.* = std.mem.zeroes(c.struct_stat);
    data.st_dev = @truncate(std.hash.Wyhash.hash(slot, "ext4") | 1);
}

/// A C `bool` for lwext4: `_Bool`, or an unsigned char when the C library's
/// stdbool.h spells it that way (yasos libc's did).
fn c_bool(comptime T: type, value: bool) T {
    return if (T == bool) value else @intFromBool(value);
}

fn timespec(seconds: u32) c.struct_timespec {
    return .{ .tv_sec = @intCast(seconds), .tv_nsec = 0 };
}

pub const Ext4Fs = oop.DeriveFromBase(kernel.fs.IFileSystem, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _volume: *Volume,

    pub fn init(allocator: std.mem.Allocator, device: kernel.fs.IFile) !Ext4Fs {
        lock.lock();
        defer lock.unlock();
        c_allocator = allocator;
        lwext4.ext4_set_clock(&wall_clock_seconds);

        const slot: u8 = for (&slot_in_use, 0..) |*taken, index| {
            if (!taken.*) {
                taken.* = true;
                break @intCast(index);
            }
        } else return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
        errdefer slot_in_use[slot] = false;

        const volume = try allocator.create(Volume);
        errdefer allocator.destroy(volume);
        volume.* = .{
            .iface = std.mem.zeroes(lwext4.struct_ext4_blockdev_iface),
            .bdev = std.mem.zeroes(lwext4.struct_ext4_blockdev),
            .buffer = undefined,
            .device = try device.clone(),
            .slot = slot,
            .mounted = false,
            .device_name = @splat(0),
            .mount_point = @splat(0),
        };
        _ = std.fmt.bufPrint(&volume.device_name, "e{d}", .{slot}) catch unreachable;
        _ = std.fmt.bufPrint(&volume.mount_point, "/e{d}/", .{slot}) catch unreachable;
        volume.iface.open = &bdev_open;
        volume.iface.bread = &bdev_read;
        volume.iface.bwrite = &bdev_write;
        volume.iface.close = &bdev_close;
        volume.iface.ph_bsize = sector_size;
        volume.iface.ph_bcnt = device.interface.size() / sector_size;
        volume.iface.ph_bbuf = &volume.buffer;
        volume.iface.p_user = volume;
        volume.bdev.bdif = &volume.iface;
        volume.bdev.part_offset = 0;
        volume.bdev.part_size = volume.iface.ph_bcnt * sector_size;

        return Ext4Fs.init(.{
            ._allocator = allocator,
            ._volume = volume,
        });
    }

    /// `path` under this volume's mount point, NUL terminated, as lwext4 wants
    /// it. The root is the mount point itself, trailing slash included.
    pub fn full_path(self: *const Self, path: []const u8) ![:0]u8 {
        const relative = std.mem.trim(u8, path, "/");
        return std.fmt.allocPrintSentinel(self._allocator, "{s}{s}", .{ std.mem.sliceTo(&self._volume.mount_point, 0), relative }, 0);
    }

    fn mount_point(self: *const Self) [*:0]const u8 {
        return &self._volume.mount_point;
    }

    pub fn mount(self: *Self) i32 {
        lock.lock();
        defer lock.unlock();
        const volume = self._volume;
        if (volume.mounted) return 0;
        if (lwext4.ext4_device_register(&volume.bdev, &volume.device_name) != 0) return -1;
        const ReadOnly = @typeInfo(@TypeOf(lwext4.ext4_mount)).@"fn".param_types[2].?;
        const rc = lwext4.ext4_mount(&volume.device_name, &volume.mount_point, c_bool(ReadOnly, false));
        if (rc != 0) {
            log.info("no ext4 filesystem on the device ({d})", .{rc});
            _ = lwext4.ext4_device_unregister(&volume.device_name);
            return -1;
        }
        volume.mounted = true;
        return 0;
    }

    pub fn umount(self: *Self) i32 {
        lock.lock();
        defer lock.unlock();
        return self.umount_locked();
    }

    fn umount_locked(self: *Self) i32 {
        const volume = self._volume;
        if (!volume.mounted) return 0;
        _ = lwext4.ext4_cache_flush(&volume.mount_point);
        const rc = lwext4.ext4_umount(&volume.mount_point);
        _ = lwext4.ext4_device_unregister(&volume.device_name);
        volume.mounted = false;
        return if (rc == 0) 0 else -1;
    }

    pub fn delete(self: *Self) void {
        lock.lock();
        defer lock.unlock();
        _ = self.umount_locked();
        const volume = self._volume;
        slot_in_use[volume.slot] = false;
        volume.device.interface.delete();
        self._allocator.destroy(volume);
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "ext4";
    }

    /// The inode behind `path`, without following a final symbolic link.
    fn inode_of(self: *Self, full: [:0]const u8, number: *u32, inode: *lwext4.struct_ext4_inode) !void {
        _ = self;
        try check(lwext4.ext4_raw_inode_fill(full.ptr, number, inode));
    }

    fn superblock(self: *Self) ?*lwext4.struct_ext4_sblock {
        var sb: [*c]lwext4.struct_ext4_sblock = null;
        if (lwext4.ext4_get_sblock(self.mount_point(), &sb) != 0) return null;
        return sb;
    }

    fn mode_of(self: *Self, inode: *lwext4.struct_ext4_inode) u32 {
        return lwext4.ext4_inode_get_mode(self.superblock(), inode);
    }

    pub fn create(self: *Self, path: []const u8, mode: i32) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        // One flush for the lot: each call below otherwise writes the new
        // inode's table block (and the group descriptor) on its own.
        const WriteBack = @typeInfo(@TypeOf(lwext4.ext4_cache_write_back)).@"fn".param_types[1].?;
        _ = lwext4.ext4_cache_write_back(self.mount_point(), c_bool(WriteBack, true));
        defer _ = lwext4.ext4_cache_write_back(self.mount_point(), c_bool(WriteBack, false));
        var file: lwext4.ext4_file = undefined;
        try check(lwext4.ext4_fopen(&file, full.ptr, "a"));
        _ = lwext4.ext4_fclose(&file);
        if (mode != 0) _ = lwext4.ext4_mode_set(full.ptr, @intCast(mode & 0o7777));
    }

    pub fn mkdir(self: *Self, path: []const u8, mode: i32) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        if (lwext4.ext4_inode_exist(full.ptr, lwext4.EXT4_DE_UNKNOWN) == 0) {
            return kernel.errno.ErrnoSet.FileExists;
        }
        try check(lwext4.ext4_dir_mk(full.ptr));
        _ = lwext4.ext4_mode_set(full.ptr, @intCast(if (mode != 0) mode & 0o7777 else 0o755));
    }

    /// True when the directory at `full` holds nothing but "." and "..".
    fn directory_is_empty(full: [:0]const u8) !bool {
        var dir: lwext4.ext4_dir = undefined;
        try check(lwext4.ext4_dir_open(&dir, full.ptr));
        defer _ = lwext4.ext4_dir_close(&dir);
        while (lwext4.ext4_dir_entry_next(&dir)) |entry| {
            const entry_name = entry.*.name[0..entry.*.name_length];
            if (!std.mem.eql(u8, entry_name, ".") and !std.mem.eql(u8, entry_name, "..")) return false;
        }
        return true;
    }

    /// unlink(2) and rmdir(2): lwext4's ext4_dir_rm deletes a whole tree, so an
    /// occupied directory is refused here first, as POSIX has it.
    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        var number: u32 = 0;
        var inode: lwext4.struct_ext4_inode = undefined;
        try self.inode_of(full, &number, &inode);
        if ((self.mode_of(&inode) & 0xF000) == lwext4.EXT4_INODE_MODE_DIRECTORY) {
            if (!try directory_is_empty(full)) return kernel.errno.ErrnoSet.DirectoryNotEmpty;
            try check(lwext4.ext4_dir_rm(full.ptr));
            return;
        }
        try check(lwext4.ext4_fremove(full.ptr));
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        var number: u32 = 0;
        var inode: lwext4.struct_ext4_inode = undefined;
        self.inode_of(full, &number, &inode) catch return kernel.errno.ErrnoSet.NoEntry;
        switch (self.mode_of(&inode) & 0xF000) {
            lwext4.EXT4_INODE_MODE_DIRECTORY => return Ext4Directory.InstanceType.create_node(self._allocator, full),
            lwext4.EXT4_INODE_MODE_FILE => return Ext4File.InstanceType.create_node(self._allocator, full),
            // A link is the VFS's to follow: it resolves through readlink.
            else => return kernel.errno.ErrnoSet.NoEntry,
        }
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const old_full = try self.full_path(old_path);
        defer self._allocator.free(old_full);
        const new_full = try self.full_path(new_path);
        defer self._allocator.free(new_full);
        try check(lwext4.ext4_flink(old_full.ptr, new_full.ptr));
    }

    /// rename(2): an existing destination is replaced, as POSIX asks --
    /// lwext4 itself refuses one. A directory may only replace an empty one.
    pub fn rename(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const old_full = try self.full_path(old_path);
        defer self._allocator.free(old_full);
        const new_full = try self.full_path(new_path);
        defer self._allocator.free(new_full);
        var number: u32 = 0;
        var inode: lwext4.struct_ext4_inode = undefined;
        if (self.inode_of(new_full, &number, &inode)) |_| {
            if ((self.mode_of(&inode) & 0xF000) == lwext4.EXT4_INODE_MODE_DIRECTORY) {
                if (!try directory_is_empty(new_full)) return kernel.errno.ErrnoSet.DirectoryNotEmpty;
                try check(lwext4.ext4_dir_rm(new_full.ptr));
            } else {
                try check(lwext4.ext4_fremove(new_full.ptr));
            }
        } else |_| {}
        try check(lwext4.ext4_frename(old_full.ptr, new_full.ptr));
    }

    /// Everything is owned by root and yasos runs as root, so existence is
    /// the whole question -- except execute, which the mode bits answer.
    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        _ = flags;
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        var number: u32 = 0;
        var inode: lwext4.struct_ext4_inode = undefined;
        self.inode_of(full, &number, &inode) catch return kernel.errno.ErrnoSet.NoEntry;
        if ((mode & c.X_OK) != 0 and (self.mode_of(&inode) & 0o111) == 0) {
            return kernel.errno.ErrnoSet.PermissionDenied;
        }
    }

    /// A fresh ext4 over the whole device: 1 KiB blocks, no journal -- what
    /// mkfs.ext4 makes. Unmounts first; mount again to use it.
    pub fn format(self: *Self) anyerror!void {
        lock.lock();
        defer lock.unlock();
        _ = self.umount_locked();
        const fs = try self._allocator.create(lwext4.struct_ext4_fs);
        defer self._allocator.destroy(fs);
        fs.* = std.mem.zeroes(lwext4.struct_ext4_fs);
        var info = std.mem.zeroes(lwext4.struct_ext4_mkfs_info);
        info.len = self._volume.bdev.part_size;
        info.block_size = 1024; // `journal` stays zero: no journal
        try check(lwext4.ext4_mkfs(fs, &self._volume.bdev, &info, lwext4.F_SET_EXT4));
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_links: bool) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        var number: u32 = 0;
        var inode: lwext4.struct_ext4_inode = undefined;
        self.inode_of(full, &number, &inode) catch return kernel.errno.ErrnoSet.NoEntry;
        const sb = self.superblock();
        const mode = lwext4.ext4_inode_get_mode(sb, &inode);
        // Following a link is the VFS's job; refusing sends it there.
        if (follow_links and (mode & 0xF000) == lwext4.EXT4_INODE_MODE_SOFTLINK) {
            return kernel.errno.ErrnoSet.NoEntry;
        }
        initialize_stat_identity(data, self._volume.slot);
        data.st_ino = number;
        data.st_mode = @intCast(mode);
        data.st_nlink = @intCast(lwext4.ext4_inode_get_links_cnt(&inode));
        data.st_uid = @intCast(lwext4.ext4_inode_get_uid(&inode));
        data.st_gid = @intCast(lwext4.ext4_inode_get_gid(&inode));
        const size = lwext4.ext4_inode_get_size(sb, &inode);
        data.st_size = @intCast(@min(size, std.math.maxInt(c.off_t)));
        data.st_blksize = @intCast(if (sb) |s| @as(u32, 1024) << @intCast(s.log_block_size) else 1024);
        data.st_blocks = @intCast(lwext4.ext4_inode_get_blocks_count(sb, &inode));
        data.st_atim = timespec(lwext4.ext4_inode_get_access_time(&inode));
        data.st_mtim = timespec(lwext4.ext4_inode_get_modif_time(&inode));
        data.st_ctim = timespec(lwext4.ext4_inode_get_change_inode_time(&inode));
    }

    pub fn utimens(self: *Self, path: []const u8, times: kernel.fs.TimeStamps, follow_links: bool) anyerror!void {
        _ = follow_links;
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        if (times.accessed) |accessed| try check(lwext4.ext4_atime_set(full.ptr, @intCast(accessed.tv_sec)));
        if (times.modified) |modified| try check(lwext4.ext4_mtime_set(full.ptr, @intCast(modified.tv_sec)));
        try check(lwext4.ext4_ctime_set(full.ptr, wall_clock_seconds()));
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        var number: u32 = 0;
        var inode: lwext4.struct_ext4_inode = undefined;
        self.inode_of(full, &number, &inode) catch return kernel.errno.ErrnoSet.NoEntry;
        if ((self.mode_of(&inode) & 0xF000) != lwext4.EXT4_INODE_MODE_SOFTLINK) {
            return kernel.errno.ErrnoSet.InvalidArgument; // not a symbolic link
        }
        var count: usize = 0;
        try check(lwext4.ext4_readlink(full.ptr, buffer.ptr, buffer.len, &count));
        return count;
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(linkpath);
        defer self._allocator.free(full);
        const target_z = try self._allocator.dupeSentinel(u8, target, 0);
        defer self._allocator.free(target_z);
        try check(lwext4.ext4_fsymlink(target_z.ptr, full.ptr));
    }

    /// A final link, when following, is the VFS's to resolve -- refused with
    /// NoEntry as in `stat`.
    fn refuse_link_when_following(self: *Self, full: [:0]const u8, follow_links: bool) !void {
        var number: u32 = 0;
        var inode: lwext4.struct_ext4_inode = undefined;
        self.inode_of(full, &number, &inode) catch return kernel.errno.ErrnoSet.NoEntry;
        if (follow_links and (self.mode_of(&inode) & 0xF000) == lwext4.EXT4_INODE_MODE_SOFTLINK) {
            return kernel.errno.ErrnoSet.NoEntry;
        }
    }

    pub fn chmod(self: *Self, path: []const u8, mode: u32, follow_links: bool) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        try self.refuse_link_when_following(full, follow_links);
        try check(lwext4.ext4_mode_set(full.ptr, mode & 0o7777));
        try check(lwext4.ext4_ctime_set(full.ptr, wall_clock_seconds()));
    }

    pub fn chown(self: *Self, path: []const u8, uid: u32, gid: u32, follow_links: bool) anyerror!void {
        lock.lock();
        defer lock.unlock();
        const full = try self.full_path(path);
        defer self._allocator.free(full);
        try self.refuse_link_when_following(full, follow_links);
        var old_uid: u32 = 0;
        var old_gid: u32 = 0;
        try check(lwext4.ext4_owner_get(full.ptr, &old_uid, &old_gid));
        const unchanged = std.math.maxInt(u32);
        try check(lwext4.ext4_owner_set(full.ptr, if (uid == unchanged) old_uid else uid, if (gid == unchanged) old_gid else gid));
        try check(lwext4.ext4_ctime_set(full.ptr, wall_clock_seconds()));
    }

    pub fn supports_symlinks(self: *const Self) bool {
        _ = self;
        return true;
    }

    pub fn statvfs(self: *Self) anyerror!kernel.fs.FsStats {
        lock.lock();
        defer lock.unlock();
        var stats: lwext4.struct_ext4_mount_stats = undefined;
        try check(lwext4.ext4_mount_point_stats(self.mount_point(), &stats));
        return .{
            .block_size = stats.block_size,
            .total_blocks = stats.blocks_count,
            .free_blocks = stats.free_blocks_count,
            .total_files = stats.inodes_count,
            .free_files = stats.free_inodes_count,
            .name_max = 255,
        };
    }
});
