//
// mounter.zig
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

// Turning a mount request into a mounted filesystem: the backend of mount(2),
// and the boot-time `mount -a` over /etc/fstab.
//
// Types:
//   ext4 (ext2, ext3)  lwext4 on a block device (no journal)
//   vfat (fat, msdos)  FatFs on a block device
//   auto               whichever of the two the device holds
//   ramfs              an empty RamFs on the kernel heap
//   tmpfs              the tiered RAM/disk /tmp (at most one; `spill=DIR`)
//   proc               procfs
//   bind               another directory, reachable here too
//
// Sources: `/dev/<name>`, `LABEL=<fat label>`, a directory (bind), or anything
// for the types that need none.
//
// Options understood here, beyond `ro`/`rw`/`defaults` (the VFS enforces
// `ro`):
//   noauto            skipped by the boot-time pass
//   nofail            a failure at boot is logged quietly, not as an error
//   x-fallback=ramfs  if the mount fails, put an empty RamFs there instead,
//                     so the path is still writable (boards without an SD card)
//   x-format-blank    vfat: format the device if its first sector is all zero
//   x-mkdir           bind: create the source directory if it is missing
//   spill=DIR         tmpfs: where bodies too big for RAM go

const std = @import("std");

const kernel = @import("kernel");
const c = @import("libc_imports").c;

const RamFs = @import("ramfs/ramfs.zig").RamFs;
const FatFs = @import("fatfs/fatfs.zig").FatFs;
const Ext4Fs = @import("ext4/ext4fs.zig").Ext4Fs;

const log = std.log.scoped(.@"fs/mounter");

pub const TmpFsFactory = *const fn (allocator: std.mem.Allocator, spill_directory: []const u8) anyerror!kernel.fs.IFileSystem;

var kernel_allocator: std.mem.Allocator = undefined;
var tmpfs_factory: ?TmpFsFactory = null;
/// RamFs bodies live on the kernel heap; growth has to stop short of it.
var ramfs_headroom: ?*const fn () usize = null;

pub fn init(allocator: std.mem.Allocator, make_tmpfs: ?TmpFsFactory, heap_headroom: ?*const fn () usize) void {
    kernel_allocator = allocator;
    tmpfs_factory = make_tmpfs;
    ramfs_headroom = heap_headroom;
    kernel.fs.mount_api.backend = &mount;
}

const Request = kernel.fs.mount_api.Request;

fn has(options: []const u8, name: []const u8) bool {
    return kernel.fs.fstab.has_option_in(options, name);
}

/// A device source made concrete: `LABEL=` looked up, the result always a
/// `/dev/...` path, which is what the mount records.
fn resolve_device(source: []const u8, buffer: []u8) ![]const u8 {
    if (std.mem.startsWith(u8, source, "LABEL=")) {
        var name_buffer: [24]u8 = undefined;
        const name = kernel.driver.block.find_by_label(source["LABEL=".len..], &name_buffer) orelse return kernel.errno.ErrnoSet.NoSuchDevice;
        return std.fmt.bufPrint(buffer, "/dev/{s}", .{name}) catch kernel.errno.ErrnoSet.NameTooLong;
    }
    if (std.mem.startsWith(u8, source, "/dev/")) return source;
    return kernel.errno.ErrnoSet.BlockDeviceRequired;
}

const FirstSector = enum { blank, fat, ext4, partition_table, other, unreadable };

fn classify_first_sector(file: *kernel.fs.IFile) FirstSector {
    const block = kernel.driver.block;
    var head: [block.head_size]u8 = undefined;
    if (!block.read_head(file, &head)) return .unreadable;
    if (std.mem.allEqual(u8, &head, 0)) return .blank;
    if (block.has_partition_table(head[0..512], file.interface.size() / 512)) return .partition_table;
    return switch (block.volume_kind(&head)) {
        .ext4 => .ext4,
        .fat => .fat,
        .unknown => .other,
    };
}

const Kind = enum { fat, ext4 };

fn attach(filesystem: kernel.fs.IFileSystem, request: Request, source: []const u8, fstype: []const u8) !void {
    var owned = filesystem;
    kernel.fs.get_vfs().mount_filesystem_with_info(request.target, owned, kernel.fs.MountInfo.init(source, fstype, request.options)) catch |err| {
        owned.interface.delete();
        return err;
    };
}

/// A filesystem on a block device: FAT or ext4, or whichever the device
/// holds when `kind` is null ("auto").
fn mount_block(request: Request, requested: ?Kind) !void {
    var device_buffer: [32]u8 = undefined;
    const device = try resolve_device(request.source, &device_buffer);
    var node = try kernel.fs.get_ivfs().interface.get(device);
    defer node.delete();
    var file = node.as_file() orelse return kernel.errno.ErrnoSet.BlockDeviceRequired;
    if (file.interface.filetype() != .BlockDevice) return kernel.errno.ErrnoSet.BlockDeviceRequired;

    // A disk with a partition table is not a volume. FatFs would quietly mount
    // its first partition instead, which is never what the line meant --
    // mount the partition (/dev/<disk>p1) or its LABEL=. EINVAL, not ENOTBLK:
    // toybox mount takes ENOTBLK as "set up a loop device and retry".
    const first_sector = classify_first_sector(&file);
    if (first_sector == .partition_table) return kernel.errno.ErrnoSet.InvalidArgument;
    const kind: Kind = requested orelse switch (first_sector) {
        .fat => .fat,
        .ext4 => .ext4,
        else => return kernel.errno.ErrnoSet.InvalidArgument,
    };

    // `as_file` lends the node's interface; the filesystems clone what they keep.
    var filesystem = switch (kind) {
        .fat => try (try FatFs.InstanceType.init(kernel_allocator, file)).interface.new(kernel_allocator),
        .ext4 => try (try Ext4Fs.InstanceType.init(kernel_allocator, file)).interface.new(kernel_allocator),
    };
    const fstype = switch (kind) {
        .fat => "vfat",
        .ext4 => "ext4",
    };
    kernel.fs.get_vfs().mount_filesystem_with_info(request.target, filesystem, kernel.fs.MountInfo.init(device, fstype, request.options)) catch |first_error| {
        if (first_error != error.NotMounted or !has(request.options, "x-format-blank") or first_sector != .blank) {
            filesystem.interface.delete();
            return first_error;
        }
        log.info("{s} is blank, formatting it {s}", .{ device, fstype });
        filesystem.interface.format() catch |err| {
            filesystem.interface.delete();
            return err;
        };
        try attach(filesystem, request, device, fstype);
    };
}

fn mount_ramfs(request: Request, source: []const u8) !void {
    if (ramfs_headroom) |headroom| {
        @import("ramfs/ramfs_data.zig").kernel_heap_headroom = headroom;
    }
    const filesystem = try (try RamFs.InstanceType.init(kernel_allocator)).interface.new(kernel_allocator);
    try attach(filesystem, request, source, "ramfs");
}

fn mount_tmpfs(request: Request) !void {
    const factory = tmpfs_factory orelse return kernel.errno.ErrnoSet.NoSuchDevice;
    const spill = kernel.fs.fstab.option_value_in(request.options, "spill") orelse "";
    if (spill.len != 0) {
        mkdir_parents(spill) catch |err| {
            log.warn("tmpfs: can't create spill directory {s}: {s}", .{ spill, @errorName(err) });
        };
    }
    // The spill directory is not pinned: the tier lets go of it when its
    // mount goes (a `mount_api.User`, registered by the factory).
    const filesystem = try factory(kernel_allocator, spill);
    try attach(filesystem, request, "tmpfs", "tmpfs");
}

fn mount_proc(request: Request) !void {
    const filesystem = try (try kernel.process.ProcFs.InstanceType.init(kernel_allocator)).interface.new(kernel_allocator);
    try attach(filesystem, request, "proc", "proc");
}

fn mount_bind(request: Request) !void {
    if (request.source.len == 0 or request.source[0] != '/') return kernel.errno.ErrnoSet.InvalidArgument;
    if (has(request.options, "x-mkdir")) {
        mkdir_parents(request.source) catch |err| {
            log.warn("bind: can't create {s}: {s}", .{ request.source, @errorName(err) });
        };
    }
    const filesystem = try (try kernel.fs.BindFs.InstanceType.init(kernel_allocator, request.source)).interface.new(kernel_allocator);
    try attach(filesystem, request, request.source, "bind");
}

/// `mkdir -p`.
pub fn mkdir_parents(path: []const u8) !void {
    var vfs = kernel.fs.get_ivfs();
    var end: usize = 1;
    while (end <= path.len) : (end += 1) {
        if (end != path.len and path[end] != '/') continue;
        const prefix = path[0..end];
        vfs.interface.mkdir(prefix, 0o755) catch |err| {
            if (err != kernel.errno.ErrnoSet.FileExists) {
                // Already there as a directory is fine whatever the error.
                var node = vfs.interface.get(prefix) catch return err;
                defer node.delete();
                if (!node.is_directory()) return err;
            }
        };
    }
}

/// The mount(2) backend.
pub fn mount(request: Request) anyerror!void {
    if (request.target.len == 0 or request.target[0] != '/') return kernel.errno.ErrnoSet.InvalidArgument;
    const fstype = request.fstype;
    if (std.mem.eql(u8, fstype, "vfat") or std.mem.eql(u8, fstype, "fat") or std.mem.eql(u8, fstype, "msdos")) {
        return mount_block(request, .fat);
    }
    if (std.mem.eql(u8, fstype, "ext4") or std.mem.eql(u8, fstype, "ext3") or std.mem.eql(u8, fstype, "ext2")) {
        return mount_block(request, .ext4);
    }
    if (std.mem.eql(u8, fstype, "auto")) return mount_block(request, null);
    if (std.mem.eql(u8, fstype, "ramfs")) return mount_ramfs(request, request.source);
    if (std.mem.eql(u8, fstype, "tmpfs")) return mount_tmpfs(request);
    if (std.mem.eql(u8, fstype, "proc")) return mount_proc(request);
    if (std.mem.eql(u8, fstype, "bind")) return mount_bind(request);
    return kernel.errno.ErrnoSet.NoSuchDevice;
}

/// Is `path` a mount whose data outlives a reboot -- i.e. real storage, not a
/// RAM filesystem (and not a fallback standing in for missing storage)?
pub fn is_persistent(path: []const u8) bool {
    var vfs = kernel.fs.get_vfs();
    const match = vfs.mount_points.find_longest_matching_point(*kernel.fs.mount_points.MountPoint, path) orelse return false;
    const fstype = match.point.info.fstype();
    if (std.mem.eql(u8, fstype, "vfat") or std.mem.eql(u8, fstype, "ext4")) return true;
    // A bind is as persistent as what it points at.
    if (std.mem.eql(u8, fstype, "bind")) {
        const source = match.point.info.source();
        if (std.mem.eql(u8, source, path)) return false;
        return is_persistent(source);
    }
    return false;
}

/// The fallback used when /etc/fstab is missing or unreadable: every
/// writable directory backed by RAM, which is what a board without an SD card
/// gets from the shipped fstab too.
pub const default_fstab =
    \\proc   /proc  proc   defaults
    \\ramfs  /var   ramfs  defaults
    \\ramfs  /home  ramfs  defaults
    \\/home/root /root bind x-mkdir
    \\tmpfs  /tmp   tmpfs  spill=/var/tmp
;

/// `mount -a`: every entry without `noauto`, in order.
pub fn mount_all(text: []const u8) void {
    var it = kernel.fs.fstab.Iterator.init(text);
    while (true) {
        const maybe_entry = it.next() catch {
            log.err("fstab line {d}: needs at least <source> <target> <type>", .{it.line_number});
            continue;
        };
        const entry = maybe_entry orelse break;
        if (entry.has_option("noauto")) continue;
        const request = Request{
            .source = entry.source,
            .target = entry.target,
            .fstype = entry.fstype,
            .options = entry.options,
        };
        mount(request) catch |err| {
            const fallback = entry.option_value("x-fallback");
            if (entry.has_option("nofail") or fallback != null) {
                log.info("{s} on {s} ({s}) not mounted: {s}", .{ entry.source, entry.target, entry.fstype, @errorName(err) });
            } else {
                log.err("{s} on {s} ({s}) failed: {s}", .{ entry.source, entry.target, entry.fstype, @errorName(err) });
            }
            if (fallback) |kind| {
                if (std.mem.eql(u8, kind, "ramfs")) {
                    mount_ramfs(.{ .source = "ramfs", .target = entry.target, .fstype = "ramfs", .options = "x-fallback" }, "ramfs") catch |fallback_err| {
                        log.err("fallback ramfs on {s} failed: {s}", .{ entry.target, @errorName(fallback_err) });
                    };
                } else {
                    log.err("{s}: unknown x-fallback={s}", .{ entry.target, kind });
                }
            }
        };
    }
}

/// Read `path` (normally /etc/fstab) whole into kernel memory. Null when it
/// is missing or empty.
pub fn read_file(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var node = kernel.fs.get_ivfs().interface.get(path) catch return null;
    defer node.delete();
    var file = node.as_file() orelse return null;
    const size: usize = @intCast(@min(file.interface.size(), 16 * 1024));
    if (size == 0) return null;
    const buffer = allocator.alloc(u8, size) catch return null;
    var filled: usize = 0;
    while (filled < size) {
        const got = file.interface.read(buffer[filled..]);
        if (got <= 0) break;
        filled += @intCast(got);
    }
    if (filled == 0) {
        allocator.free(buffer);
        return null;
    }
    // Keep the allocation's length (the caller frees what it was given); a
    // short read just leaves blank lines at the end.
    @memset(buffer[filled..], '\n');
    return buffer;
}
