//
// block.zig
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

// Disks and their partitions, independent of what the disk is.
//
// A disk (the SD card, the QEMU fatdisk window) registers here once at boot.
// `probe` reads its first sector and publishes one `/dev/<disk>p<N>` node per
// MBR slot, numbered from 1 like Linux (`mmc0p1` is the first slot). A disk
// whose first sector is a FAT boot sector rather than an MBR -- a
// "superfloppy", which is what the QEMU host-exchange image is -- has no
// partitions and is used whole.
//
// `rescan` is BLKRRPART: after `fdisk` rewrites the table it drops the old
// partition nodes and probes again, so the new layout is usable without a
// reboot. It refuses while anything is mounted from the disk.

const std = @import("std");

const c = @import("libc_imports").c;

const kernel = @import("../kernel.zig");
const MmcPartitionDriver = @import("mmc/mmc_partition_driver.zig").MmcPartitionDriver;

const log = std.log.scoped(.@"kernel/block");

pub const sector_size = 512;
pub const max_partitions = 4;
const max_disks = 4;

/// A FAT volume label: 11 bytes, space padded, as the boot sector holds it.
pub const Label = struct {
    bytes: [11]u8 = @splat(' '),
    len: u8 = 0,

    pub fn slice(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Disk = struct {
    name_buffer: [16]u8 = undefined,
    name_len: u8 = 0,
    file: ?kernel.fs.IFile = null,
    /// Names of the partition nodes currently published for this disk, so a
    /// rescan can take exactly those away again.
    partitions: [max_partitions]?[]u8 = @splat(null),

    fn name(self: *const Disk) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

/// Where partition nodes are published. Set once, by `init`. A copy of the
/// boot-time DriverFs value: it holds the `/dev` directory by interface, so
/// the copy and the mounted instance share one directory.
const DriverDirectory = kernel.driver.fs.DriverFs;
var directory: ?DriverDirectory = null;
var allocator: std.mem.Allocator = undefined;
var disks: [max_disks]Disk = @splat(.{});

/// Serialises probe/rescan against each other and against label lookups:
/// all of them walk `disks` and publish or remove nodes. Sleeping, since it is
/// held across disk reads.
var lock: kernel.sync.RankedMutex(.block) = .{};

pub fn init(driverfs: DriverDirectory, kernel_allocator: std.mem.Allocator) void {
    directory = driverfs;
    allocator = kernel_allocator;
}

/// Register `file` as the whole-disk device `/dev/<name>` and publish its
/// partitions. `file` is borrowed: the registry keeps its own clone.
pub fn add_disk(name: []const u8, file: kernel.fs.IFile) !void {
    lock.lock();
    defer lock.unlock();
    for (&disks) |*disk| {
        if (disk.file != null) continue;
        if (name.len > disk.name_buffer.len) return kernel.errno.ErrnoSet.NameTooLong;
        @memcpy(disk.name_buffer[0..name.len], name);
        disk.name_len = @intCast(name.len);
        disk.file = try file.clone();
        probe_locked(disk);
        return;
    }
    return kernel.errno.ErrnoSet.OutOfMemory;
}

fn find_disk(name: []const u8) ?*Disk {
    for (&disks) |*disk| {
        if (disk.file != null and std.mem.eql(u8, disk.name(), name)) return disk;
    }
    return null;
}

/// Is `sector` the boot sector of a FAT volume (as opposed to an MBR)? Both
/// end in 0x55AA, so the signature alone cannot tell. A FAT boot sector starts
/// with a jump and carries a BIOS parameter block with values in narrow,
/// well-defined ranges; an MBR's boot code practically never passes all of
/// these at once.
pub fn is_fat_boot_sector(sector: []const u8) bool {
    if (sector.len < sector_size) return false;
    const jump_ok = (sector[0] == 0xEB and sector[2] == 0x90) or sector[0] == 0xE9;
    if (!jump_ok) return false;
    const bytes_per_sector = std.mem.readInt(u16, sector[11..13], .little);
    switch (bytes_per_sector) {
        512, 1024, 2048, 4096 => {},
        else => return false,
    }
    const sectors_per_cluster = sector[13];
    if (sectors_per_cluster == 0 or !std.math.isPowerOfTwo(sectors_per_cluster)) return false;
    const reserved = std.mem.readInt(u16, sector[14..16], .little);
    const fats = sector[16];
    return reserved != 0 and (fats == 1 or fats == 2);
}

/// Does `sector` hold a usable MBR partition table? The 0x55AA signature is
/// not enough -- a FAT boot sector ends in it too, and a card reformatted from
/// a whole-disk FAT volume keeps that volume's boot code in front of its new
/// table. So, as Linux does: every entry's boot flag is 0x00 or 0x80, at least
/// one entry is in use, and each used entry lies on the disk. Checked before
/// `is_fat_boot_sector`, which a leftover boot code would also pass.
pub fn has_partition_table(sector: []const u8, disk_sectors: u64) bool {
    if (sector.len < sector_size) return false;
    const mbr = kernel.fs.MBR.create(sector);
    if (!mbr.is_valid()) return false;
    var used: usize = 0;
    for (mbr.partitions) |part| {
        if (part.boot_indicator != 0x00 and part.boot_indicator != 0x80) return false;
        if (part.partition_type == 0 or part.size_in_sectors == 0) continue;
        if (part.start_lba == 0) return false;
        const end: u64 = @as(u64, part.start_lba) + part.size_in_sectors;
        if (disk_sectors != 0 and end > disk_sectors) return false;
        used += 1;
    }
    return used != 0;
}

/// The volume label from a FAT boot sector, or null when `sector` is not one
/// or carries no label. FAT12/16 keep it at 0x2B, FAT32 at 0x47, each behind
/// an extended boot signature (0x29) that says the field is valid. "NO NAME"
/// is FAT's way of saying there is none.
pub fn fat_label(sector: []const u8) ?Label {
    if (!is_fat_boot_sector(sector)) return null;
    const fat_size_16 = std.mem.readInt(u16, sector[22..24], .little);
    const signature_offset: usize, const label_offset: usize = if (fat_size_16 == 0) .{ 0x42, 0x47 } else .{ 0x26, 0x2B };
    if (sector[signature_offset] != 0x29) return null;
    var label: Label = .{};
    @memcpy(&label.bytes, sector[label_offset .. label_offset + 11]);
    var len: usize = 11;
    while (len > 0 and label.bytes[len - 1] == ' ') len -= 1;
    if (len == 0 or std.mem.eql(u8, label.bytes[0..len], "NO NAME")) return null;
    label.len = @intCast(len);
    return label;
}

/// Enough of a volume's start to identify it: the FAT boot sector, and the
/// ext2/3/4 superblock at byte 1024.
pub const head_size = 3 * sector_size;

pub const VolumeKind = enum { fat, ext4, unknown };

/// The ext2/3/4 superblock's magic at 1024 + 0x38, and its volume name at
/// 1024 + 0x78 (16 bytes, NUL padded).
pub fn is_ext_superblock(head: []const u8) bool {
    if (head.len < head_size) return false;
    return std.mem.readInt(u16, head[1024 + 0x38 ..][0..2], .little) == 0xEF53;
}

pub fn ext_label(head: []const u8) ?Label {
    if (!is_ext_superblock(head)) return null;
    const field = head[1024 + 0x78 ..][0..16];
    const len = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    if (len == 0) return null;
    var label: Label = .{ .bytes = undefined, .len = 0 };
    // Label keeps FAT's 11; an ext label longer than that is not one of ours.
    if (len > label.bytes.len) return null;
    @memcpy(label.bytes[0..len], field[0..len]);
    label.len = @intCast(len);
    return label;
}

pub fn volume_kind(head: []const u8) VolumeKind {
    if (is_ext_superblock(head)) return .ext4;
    if (is_fat_boot_sector(head)) return .fat;
    return .unknown;
}

/// The label of whichever filesystem `head` starts, FAT or ext.
pub fn volume_label(head: []const u8) ?Label {
    return ext_label(head) orelse fat_label(head);
}

/// Read the first `head_size` bytes of a volume.
pub fn read_head(file: *kernel.fs.IFile, buffer: *[head_size]u8) bool {
    kernel.driver.dev_lock.acquire();
    defer kernel.driver.dev_lock.release();
    _ = file.interface.seek(0, c.SEEK_SET) catch return false;
    return file.interface.read(buffer) == head_size;
}

fn read_first_sector(file: *kernel.fs.IFile, buffer: *[sector_size]u8) bool {
    // The seek position lives in the shared device file; keep the pair whole
    // against a mounted FatFs on another partition of the same card.
    kernel.driver.dev_lock.acquire();
    defer kernel.driver.dev_lock.release();
    _ = file.interface.seek(0, c.SEEK_SET) catch return false;
    return file.interface.read(buffer) == sector_size;
}

fn probe_locked(disk: *Disk) void {
    var sector: [sector_size]u8 = undefined;
    if (!read_first_sector(&disk.file.?, &sector)) {
        log.err("{s}: can't read the first sector", .{disk.name()});
        return;
    }
    const disk_sectors: u64 = disk.file.?.interface.size() / sector_size;
    if (!has_partition_table(&sector, disk_sectors)) {
        if (is_fat_boot_sector(&sector)) {
            log.info("{s}: FAT volume without a partition table", .{disk.name()});
        } else {
            log.info("{s}: no partition table", .{disk.name()});
        }
        return;
    }
    const mbr = kernel.fs.MBR.create(&sector);
    for (mbr.partitions, 0..) |part, index| {
        if (part.size_in_sectors == 0 or part.partition_type == 0) continue;
        // Extended partitions are containers; nothing here reads logical ones.
        if (part.partition_type == 0x05 or part.partition_type == 0x0F or part.partition_type == 0x85) {
            log.warn("{s}: slot {d} is an extended partition, skipped", .{ disk.name(), index + 1 });
            continue;
        }
        const end: u64 = @as(u64, part.start_lba) + part.size_in_sectors;
        if (part.start_lba == 0 or (disk_sectors != 0 and end > disk_sectors)) {
            log.err("{s}: slot {d} lies outside the disk, skipped", .{ disk.name(), index + 1 });
            continue;
        }
        publish_partition(disk, index, part.start_lba, part.size_in_sectors) catch |err| {
            log.err("{s}: can't publish partition {d}: {s}", .{ disk.name(), index + 1, @errorName(err) });
        };
    }
}

fn publish_partition(disk: *Disk, index: usize, start_lba: u32, size_in_sectors: u32) !void {
    const dir = if (directory) |*d| d.data() else return error.NotInitialized;
    const node_name = try std.fmt.allocPrint(allocator, "{s}p{d}", .{ disk.name(), index + 1 });
    errdefer allocator.free(node_name);
    const driver_data = try MmcPartitionDriver.InstanceType.create(allocator, disk.file.?, node_name, start_lba, size_in_sectors);
    var driver = try driver_data.interface.new(allocator);
    errdefer driver.interface.delete();
    try dir.append(driver, node_name);
    disk.partitions[index] = node_name;
    log.info("/dev/{s}: {d} sectors at LBA {d}", .{ node_name, size_in_sectors, start_lba });
}

fn unpublish_partitions(disk: *Disk) void {
    const dir = if (directory) |*d| d.data() else return;
    for (&disk.partitions) |*slot| {
        if (slot.*) |node_name| {
            dir.remove(node_name);
            allocator.free(node_name);
            slot.* = null;
        }
    }
}

/// Would taking `disk`'s partitions away pull a filesystem out from under a
/// mount? Mounts record the device path they were made from.
fn disk_in_use(disk: *const Disk) bool {
    var path_buffer: [32]u8 = undefined;
    const vfs = kernel.fs.get_vfs();
    const whole = std.fmt.bufPrint(&path_buffer, "/dev/{s}", .{disk.name()}) catch return true;
    if (vfs.mount_points.is_source_mounted(whole)) return true;
    for (disk.partitions) |maybe_name| {
        const node_name = maybe_name orelse continue;
        const path = std.fmt.bufPrint(&path_buffer, "/dev/{s}", .{node_name}) catch return true;
        if (vfs.mount_points.is_source_mounted(path)) return true;
    }
    return false;
}

/// BLKRRPART: drop `name`'s partition nodes and read the table again.
pub fn rescan(name: []const u8) !void {
    lock.lock();
    defer lock.unlock();
    const disk = find_disk(name) orelse return kernel.errno.ErrnoSet.NoSuchDevice;
    if (disk_in_use(disk)) return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
    unpublish_partitions(disk);
    probe_locked(disk);
}

/// Every block device a filesystem could live on -- partitions, and disks used
/// whole -- as `/dev` names, for `LABEL=` lookups. Calls `visit` until it
/// returns true.
fn for_each_volume(context: anytype, comptime visit: fn (@TypeOf(context), []const u8) bool) void {
    lock.lock();
    defer lock.unlock();
    for (&disks) |*disk| {
        if (disk.file == null) continue;
        var any_partition = false;
        for (disk.partitions) |maybe_name| {
            const node_name = maybe_name orelse continue;
            any_partition = true;
            if (visit(context, node_name)) return;
        }
        if (!any_partition and visit(context, disk.name())) return;
    }
}

/// The `/dev` name of the volume whose label (FAT or ext) is `wanted`, written into
/// `out`. Labels compare case-insensitively, as FAT stores them upper case.
pub fn find_by_label(wanted: []const u8, out: []u8) ?[]const u8 {
    const Search = struct {
        wanted: []const u8,
        out: []u8,
        found: ?[]const u8 = null,

        fn visit(self: *@This(), node_name: []const u8) bool {
            const dir = if (directory) |*d| d.data() else return true;
            var node = dir.get(node_name) catch return false;
            defer node.delete();
            var file = node.as_file() orelse return false;
            var head: [head_size]u8 = undefined;
            if (!read_head(&file, &head)) return false;
            const label = volume_label(&head) orelse return false;
            if (!std.ascii.eqlIgnoreCase(label.slice(), self.wanted)) return false;
            if (node_name.len > self.out.len) return false;
            @memcpy(self.out[0..node_name.len], node_name);
            self.found = self.out[0..node_name.len];
            return true;
        }
    };
    var search = Search{ .wanted = wanted, .out = out };
    for_each_volume(&search, Search.visit);
    return search.found;
}

/// `/proc/partitions`: every disk and each of its partitions, sizes in KiB.
/// Major 179 is Linux's MMC block major; minors number the disks in eights.
pub fn write_partitions(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    lock.lock();
    defer lock.unlock();
    try writer.writeAll("major minor  #blocks  name\n\n");
    for (&disks, 0..) |*disk, disk_index| {
        const file = disk.file orelse continue;
        const minor_base = disk_index * 8;
        try writer.print("{d:>5} {d:>5} {d:>10} {s}\n", .{ 179, minor_base, file.interface.size() / 1024, disk.name() });
        const dir = if (directory) |*d| d.data() else continue;
        for (disk.partitions, 0..) |maybe_name, index| {
            const node_name = maybe_name orelse continue;
            var node = dir.get(node_name) catch continue;
            defer node.delete();
            const part = node.as_file() orelse continue;
            try writer.print("{d:>5} {d:>5} {d:>10} {s}\n", .{ 179, minor_base + index + 1, part.interface.size() / 1024, node_name });
        }
    }
}

/// The block-device ioctls every disk and partition answers the same way.
/// Returns null for a command that is not one of them, so the caller can go on
/// to its own.
pub fn common_ioctl(name: []const u8, size_in_bytes: u64, cmd: i32, arg: ?*anyopaque) ?i32 {
    const command: u32 = @bitCast(cmd);
    switch (command) {
        c.BLKGETSIZE64 => {
            const out: *align(1) u64 = @ptrCast(arg orelse return -1);
            out.* = size_in_bytes;
            return 0;
        },
        c.BLKGETSIZE => {
            const out: *align(1) c_ulong = @ptrCast(arg orelse return -1);
            out.* = @intCast(size_in_bytes / sector_size);
            return 0;
        },
        c.BLKSSZGET, c.BLKBSZGET => {
            const out: *align(1) c_int = @ptrCast(arg orelse return -1);
            out.* = sector_size;
            return 0;
        },
        c.BLKFLSBUF => return 0,
        c.BLKRRPART => {
            rescan(name) catch |err| {
                return -@as(i32, kernel.errno.to_errno(err));
            };
            return 0;
        },
        else => return null,
    }
}

test "Block.RecognisesAFatBootSectorAndItsLabel" {
    var sector: [sector_size]u8 = @splat(0);
    sector[0] = 0xEB;
    sector[1] = 0x58;
    sector[2] = 0x90;
    std.mem.writeInt(u16, sector[11..13], 512, .little);
    sector[13] = 8;
    std.mem.writeInt(u16, sector[14..16], 32, .little);
    sector[16] = 2;
    // FAT32: 16-bit FAT size is zero, the label sits at 0x47.
    sector[0x42] = 0x29;
    @memcpy(sector[0x47 .. 0x47 + 11], "YASVAR     ");
    sector[510] = 0x55;
    sector[511] = 0xAA;
    try std.testing.expect(is_fat_boot_sector(&sector));
    try std.testing.expectEqualStrings("YASVAR", fat_label(&sector).?.slice());

    // FAT16: label at 0x2B.
    std.mem.writeInt(u16, sector[22..24], 64, .little);
    sector[0x26] = 0x29;
    @memcpy(sector[0x2B .. 0x2B + 11], "NO NAME    ");
    try std.testing.expect(fat_label(&sector) == null);
}

test "Block.AnMbrBehindLeftoverFatBootCodeIsStillAnMbr" {
    // What a partitioner that keeps the first 440 bytes as boot code leaves
    // over a whole-disk FAT volume (the old sdformat did; fdisk clears them).
    var sector: [sector_size]u8 = @splat(0);
    sector[0] = 0xEB;
    sector[2] = 0x90;
    std.mem.writeInt(u16, sector[11..13], 512, .little);
    sector[13] = 2;
    std.mem.writeInt(u16, sector[14..16], 1, .little);
    sector[16] = 2;
    sector[510] = 0x55;
    sector[511] = 0xAA;
    try std.testing.expect(is_fat_boot_sector(&sector));
    try std.testing.expect(!has_partition_table(&sector, 32768));

    sector[446 + 4] = 0x01;
    std.mem.writeInt(u32, sector[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, sector[446 + 12 ..][0..4], 4096, .little);
    try std.testing.expect(has_partition_table(&sector, 32768));
    // Off the end of the disk: not a table this disk can have.
    try std.testing.expect(!has_partition_table(&sector, 4096));
    // Boot code in the entries' place: a boot flag that is neither 0 nor 0x80.
    sector[446] = 0x33;
    try std.testing.expect(!has_partition_table(&sector, 32768));
}

test "Block.ReadsAnExtSuperblockLabel" {
    var head: [head_size]u8 = @splat(0);
    try std.testing.expect(volume_kind(&head) == .unknown);
    std.mem.writeInt(u16, head[1024 + 0x38 ..][0..2], 0xEF53, .little);
    @memcpy(head[1024 + 0x78 ..][0..7], "YASHOME");
    try std.testing.expect(volume_kind(&head) == .ext4);
    try std.testing.expectEqualStrings("YASHOME", volume_label(&head).?.slice());
}

test "Block.AnMbrIsNotAFatBootSector" {
    var sector: [sector_size]u8 = @splat(0);
    sector[510] = 0x55;
    sector[511] = 0xAA;
    // Partition 1: FAT32 LBA at 2048.
    sector[446 + 4] = 0x0C;
    std.mem.writeInt(u32, sector[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, sector[446 + 12 ..][0..4], 4096, .little);
    try std.testing.expect(!is_fat_boot_sector(&sector));
    try std.testing.expect(fat_label(&sector) == null);
    try std.testing.expect(kernel.fs.MBR.create(&sector).is_valid());
}
