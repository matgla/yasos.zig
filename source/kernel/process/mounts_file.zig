//
// mounts_file.zig
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

// The storage files of /proc, in the formats the Linux tools parse:
//
//   /proc/mounts       what is mounted where (mount, umount -a, df, fdisk, mkfs)
//   /proc/filesystems  the types mount(2) knows (`mount` without -t tries the
//                      ones not marked nodev)
//   /proc/partitions   disks and partitions (blkid scans it for LABEL=)

const std = @import("std");

const interface = @import("interface");

const kernel = @import("../kernel.zig");

const BufferSize = 2048;
const StorageBufferedFile = kernel.fs.BufferedFile(BufferSize);

pub const Kind = enum { mounts, filesystems, partitions };

fn file_name(kind: Kind) []const u8 {
    return switch (kind) {
        .mounts => "mounts",
        .filesystems => "filesystems",
        .partitions => "partitions",
    };
}

pub const StorageFile = interface.DeriveFromBase(StorageBufferedFile, struct {
    const Self = @This();
    base: StorageBufferedFile,
    _kind: Kind,

    /// Empty until opened: procfs syncs a node on every lookup, and at
    /// creation (procfs's own init) the VFS may not exist yet.
    pub fn create(allocator: std.mem.Allocator, kind: Kind) StorageFile {
        return StorageFile.init(.{
            .base = StorageBufferedFile.InstanceType.create(allocator, file_name(kind)),
            ._kind = kind,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, kind: Kind) anyerror!kernel.fs.Node {
        const file = try create(allocator, kind).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn sync(self: *Self) i32 {
        const buffer = interface.base(self).buffer() orelse return -1;
        var writer = std.Io.Writer.fixed(buffer);
        // A full buffer truncates the listing rather than failing the read.
        switch (self._kind) {
            .mounts => kernel.fs.get_vfs().mount_points.write_mounts(&writer) catch {},
            .filesystems => writer.writeAll("\text4\n\tvfat\nnodev\tramfs\nnodev\ttmpfs\nnodev\tproc\nnodev\tbind\n") catch {},
            .partitions => kernel.driver.block.write_partitions(&writer) catch {},
        }
        interface.base(self)._end = writer.buffered().len;
        return 0;
    }

    pub fn delete(self: *Self) void {
        interface.base(self).delete();
    }
});
