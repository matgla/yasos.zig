//
// tests.zig
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

//! The ext4 driver against lwext4 on the host, over a 40 MB RAM device,
//! formatted by the driver's own `format`.

const std = @import("std");

const kernel = @import("kernel");
const c = @import("libc_imports").c;

const Ext4Fs = @import("ext4fs.zig").Ext4Fs;
const lwext4 = @import("ext4fs.zig").lwext4;
const FatFsDeviceFileStub = @import("../fatfs/tests/device_stub.zig").FatFsDeviceFileStub;

fn create_formatted() !kernel.fs.IFileSystem {
    var device = try (try FatFsDeviceFileStub.InstanceType.create(std.testing.allocator, null)).interface.new(std.testing.allocator);
    defer device.interface.delete();
    var fs = try (try Ext4Fs.InstanceType.init(std.testing.allocator, device)).interface.new(std.testing.allocator);
    errdefer fs.interface.delete();
    try std.testing.expectEqual(@as(i32, -1), fs.interface.mount());
    try fs.interface.format();
    try std.testing.expectEqual(@as(i32, 0), fs.interface.mount());
    return fs;
}

fn write_file(fs: *kernel.fs.IFileSystem, path: []const u8, data: []const u8) !void {
    try fs.interface.create(path, 0o644);
    var node = try fs.interface.get(path);
    defer node.delete();
    var file = node.as_file().?;
    try std.testing.expectEqual(@as(isize, @intCast(data.len)), file.interface.write(data));
}

fn read_file(fs: *kernel.fs.IFileSystem, path: []const u8, buffer: []u8) ![]u8 {
    var node = try fs.interface.get(path);
    defer node.delete();
    var file = node.as_file().?;
    const n = file.interface.read(buffer);
    try std.testing.expect(n >= 0);
    return buffer[0..@intCast(n)];
}

test "Ext4.FormatMountWriteReadBack" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try std.testing.expectEqualStrings("ext4", fs.interface.name());

    try write_file(&fs, "/hello.txt", "hello ext4");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello ext4", try read_file(&fs, "/hello.txt", &buffer));

    var st: c.struct_stat = undefined;
    try fs.interface.stat("/hello.txt", &st, true);
    try std.testing.expectEqual(@as(u32, c.S_IFREG), @as(u32, @intCast(st.st_mode)) & c.S_IFMT);
    try std.testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(st.st_mode)) & 0o7777);
    try std.testing.expectEqual(@as(i64, 10), @as(i64, @intCast(st.st_size)));
    try std.testing.expectEqual(1, st.st_nlink);
}

test "Ext4.DataSurvivesARemount" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try fs.interface.mkdir("/dir", 0o755);
    try write_file(&fs, "/dir/kept", "still here");
    try std.testing.expectEqual(@as(i32, 0), fs.interface.umount());
    try std.testing.expectEqual(@as(i32, 0), fs.interface.mount());
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("still here", try read_file(&fs, "/dir/kept", &buffer));
}

test "Ext4.DirectoriesListWithoutDotEntries" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try fs.interface.mkdir("/sub", 0o755);
    try write_file(&fs, "/sub/a", "a");
    try fs.interface.mkdir("/sub/inner", 0o755);
    try std.testing.expectError(kernel.errno.ErrnoSet.FileExists, fs.interface.mkdir("/sub", 0o755));

    var node = try fs.interface.get("/sub");
    defer node.delete();
    try std.testing.expect(node.is_directory());
    var it = try node.as_directory().?.interface.iterator();
    defer it.interface.delete();
    var saw_file = false;
    var saw_dir = false;
    var count: usize = 0;
    while (it.interface.next()) |entry| {
        count += 1;
        if (std.mem.eql(u8, entry.name, "a")) saw_file = entry.kind == .File;
        if (std.mem.eql(u8, entry.name, "inner")) saw_dir = entry.kind == .Directory;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(saw_file and saw_dir);
}

test "Ext4.RmdirRefusesAnOccupiedDirectory" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try fs.interface.mkdir("/full", 0o755);
    try write_file(&fs, "/full/x", "x");
    try std.testing.expectError(kernel.errno.ErrnoSet.DirectoryNotEmpty, fs.interface.unlink("/full"));
    try fs.interface.unlink("/full/x");
    try fs.interface.unlink("/full");
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.get("/full"));
}

test "Ext4.RenameReplacesTheDestination" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try write_file(&fs, "/old", "new contents");
    try write_file(&fs, "/target", "stale");
    try fs.interface.rename("/old", "/target");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("new contents", try read_file(&fs, "/target", &buffer));
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.get("/old"));
}

test "Ext4.SymlinksAreLeftToTheVfs" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try write_file(&fs, "/real", "r");
    try fs.interface.symlink("/some/where/real", "/link");
    try std.testing.expect(fs.interface.supports_symlinks());

    var buffer: [64]u8 = undefined;
    const n = try fs.interface.readlink("/link", &buffer);
    try std.testing.expectEqualStrings("/some/where/real", buffer[0..n]);
    try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, fs.interface.readlink("/real", &buffer));

    var st: c.struct_stat = undefined;
    try fs.interface.stat("/link", &st, false);
    try std.testing.expectEqual(@as(u32, c.S_IFLNK), @as(u32, @intCast(st.st_mode)) & c.S_IFMT);
    // Following is the VFS's job: the filesystem sends it there.
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.stat("/link", &st, true));
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.get("/link"));
}

test "Ext4.TruncateShrinksAndGrows" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try write_file(&fs, "/t", "0123456789");
    var node = try fs.interface.get("/t");
    defer node.delete();
    var file = node.as_file().?;
    try file.interface.truncate(4);
    try std.testing.expectEqual(@as(u64, 4), file.interface.size());
    try file.interface.truncate(1000);
    try std.testing.expectEqual(@as(u64, 1000), file.interface.size());
    _ = try file.interface.seek(0, c.SEEK_SET);
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 8), file.interface.read(&buffer));
    try std.testing.expectEqualSlices(u8, "0123\x00\x00\x00\x00", &buffer);
}

test "Ext4.ReportsCapacity" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    const stats = try fs.interface.statvfs();
    try std.testing.expectEqual(@as(u32, 1024), stats.block_size);
    try std.testing.expectEqual(@as(u64, 40 * 1024), stats.total_blocks);
    try std.testing.expect(stats.free_blocks > 30 * 1024 and stats.free_blocks < stats.total_blocks);
    try std.testing.expect(stats.free_files > 0);
}

test "Ext4.TwoVolumesStayApart" {
    var first = try create_formatted();
    defer first.interface.delete();
    var second = try create_formatted();
    defer second.interface.delete();
    try write_file(&first, "/only_on_first", "1");
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, second.interface.get("/only_on_first"));
    var a: c.struct_stat = undefined;
    var b: c.struct_stat = undefined;
    try first.interface.stat("/", &a, true);
    try second.interface.stat("/", &b, true);
    try std.testing.expect(a.st_dev != b.st_dev);
}

test "Ext4.VolumesShareOneIdleBlockBudget" {
    var volumes: [3]kernel.fs.IFileSystem = undefined;
    for (&volumes) |*volume| volume.* = try create_formatted();
    defer for (&volumes) |*volume| volume.interface.delete();

    // Enough metadata on each to fill a per-volume cache several times over.
    var name_buffer: [16]u8 = undefined;
    for (&volumes, 0..) |*volume, index| {
        for (0..6) |n| {
            const name = try std.fmt.bufPrint(&name_buffer, "/d{d}", .{n});
            try volume.interface.mkdir(name, 0o755);
            const file = try std.fmt.bufPrint(&name_buffer, "/d{d}/f{d}", .{ n, index });
            try write_file(volume, file, file);
        }
    }
    const idle = lwext4.ext4_bcache_idle_total();
    try std.testing.expect(idle > 0 and idle <= 8);

    // What was evicted reads back from the device.
    var read_buffer: [16]u8 = undefined;
    for (&volumes, 0..) |*volume, index| {
        for (0..6) |n| {
            const file = try std.fmt.bufPrint(&name_buffer, "/d{d}/f{d}", .{ n, index });
            var expected: [16]u8 = undefined;
            @memcpy(expected[0..file.len], file);
            try std.testing.expectEqualStrings(expected[0..file.len], try read_file(volume, expected[0..file.len], &read_buffer));
        }
    }
    try std.testing.expect(lwext4.ext4_bcache_idle_total() <= 8);
}

test "Ext4.KeepsModesAndOwners" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try write_file(&fs, "/script", "#!/bin/sh\n");
    try fs.interface.chmod("/script", 0o755, true);
    try fs.interface.chown("/script", 1000, std.math.maxInt(u32), true);
    var st: c.struct_stat = undefined;
    try fs.interface.stat("/script", &st, true);
    try std.testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.st_mode)) & 0o7777);
    try std.testing.expectEqual(@as(u32, c.S_IFREG), @as(u32, @intCast(st.st_mode)) & c.S_IFMT);
    try std.testing.expectEqual(1000, st.st_uid);
    try std.testing.expectEqual(0, st.st_gid);
    try fs.interface.access("/script", c.X_OK, 0);
    try fs.interface.chmod("/script", 0o644, true);
    try std.testing.expectError(kernel.errno.ErrnoSet.PermissionDenied, fs.interface.access("/script", c.X_OK, 0));
}

/// One file the way `rz` lands it: open(O_CREAT|O_TRUNC) as sys_open does it
/// (look up, create, look up again, truncate), then one write.
fn create_and_write(fs: *kernel.fs.IFileSystem, path: []const u8, data: []const u8) !void {
    if (fs.interface.get(path)) |found| {
        var node = found;
        node.delete();
    } else |_| {}
    try fs.interface.create(path, 0o644);
    var node = try fs.interface.get(path);
    defer node.delete();
    var file = node.as_file().?;
    try file.interface.truncate(0);
    try std.testing.expectEqual(@as(isize, @intCast(data.len)), file.interface.write(data));
}

// A run of new files in one deep directory -- a source tree being unpacked --
// costs the device a handful of blocks each (~5 reads, ~10 writes). Every open
// used to walk the path from the root through more blocks than the cache
// holds, re-reading ~84 of them per file, and creating wrote the new inode
// twice.
test "Ext4.CreatingFilesInADeepDirectoryStaysCheap" {
    const io = @import("../fatfs/tests/device_stub.zig").io;
    var fs = try create_formatted();
    defer fs.interface.delete();
    for ([_][]const u8{ "/root", "/root/ci", "/root/ci/sources", "/root/ci/sources/gcc", "/root/ci/sources/gcc/execute" }) |dir| {
        try fs.interface.mkdir(dir, 0o755);
    }
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @intCast('a' + i % 26);
    var path_buffer: [96]u8 = undefined;
    const warmup = 200;
    const measured = 100;
    for (0..warmup + measured) |index| {
        if (index == warmup) io.reset();
        const path = try std.fmt.bufPrint(&path_buffer, "/root/ci/sources/gcc/execute/pr{d:0>6}-1.c", .{index});
        try create_and_write(&fs, path, &data);
    }
    try std.testing.expect(io.reads <= 6 * measured);
    try std.testing.expect(io.writes <= 11 * measured);

    var buffer: [1024]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &data, try read_file(&fs, "/root/ci/sources/gcc/execute/pr000123-1.c", &buffer));
}

// A file being written holds write-back on its volume from its first write to
// its close, so a run of small write() calls writes the data and nothing else:
// the inode, block bitmap, group descriptor and extent changes go out once,
// when the last writer closes. Write-through, each call also wrote its inode.
test "Ext4.SmallWritesDeferMetadataUntilClose" {
    const io = @import("../fatfs/tests/device_stub.zig").io;
    var fs = try create_formatted();
    defer fs.interface.delete();
    try fs.interface.create("/log", 0o644);
    var node = try fs.interface.get("/log");
    var file = node.as_file().?;
    const chunk = "0123456789abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqr";
    const calls = 200;
    io.reset();
    for (0..calls) |_| try std.testing.expectEqual(@as(isize, chunk.len), file.interface.write(chunk));
    // One read-modify-write of the sector each call lands in, a second when it
    // straddles two: ~240 for 20000 bytes.
    const data_writes = io.writes;
    try std.testing.expect(data_writes <= calls + calls * chunk.len / 512 + 2);
    node.delete();
    try std.testing.expect(io.writes > data_writes);
    try std.testing.expect(io.writes <= data_writes + 12);

    try std.testing.expectEqual(@as(i32, 0), fs.interface.umount());
    try std.testing.expectEqual(@as(i32, 0), fs.interface.mount());
    var buffer: [calls * chunk.len + 1]u8 = undefined;
    const back = try read_file(&fs, "/log", &buffer);
    try std.testing.expectEqual(@as(usize, calls * chunk.len), back.len);
    for (0..calls) |n| try std.testing.expectEqualStrings(chunk, back[n * chunk.len ..][0..chunk.len]);
}

/// A bare block cache of 1 KiB blocks holding `lbas`, each up to date, dirty
/// unless `clean`, and filled with `fill`. The buffers come back in `bufs`.
fn cache_blocks(bc: *lwext4.struct_ext4_bcache, lbas: []const u64, fill: u8, clean: bool, bufs: []*lwext4.struct_ext4_buf) !void {
    const IsNew = @typeInfo(@typeInfo(@TypeOf(lwext4.ext4_bcache_alloc)).@"fn".param_types[2].?).pointer.child;
    for (lbas, 0..) |lba, index| {
        var block = std.mem.zeroes(lwext4.struct_ext4_block);
        block.lb_id = lba;
        var is_new: IsNew = undefined;
        try std.testing.expectEqual(@as(c_int, 0), lwext4.ext4_bcache_alloc(bc, &block, &is_new));
        @memset(block.data[0..1024], fill);
        block.buf.*.flags |= @as(c_int, 1) << lwext4.BC_UPTODATE;
        if (!clean) block.buf.*.flags |= @as(c_int, 1) << lwext4.BC_DIRTY;
        bufs[index] = block.buf;
    }
}

fn has_flag(buf: *lwext4.struct_ext4_buf, flag: c_int) bool {
    return (buf.flags >> @intCast(flag)) & 1 != 0;
}

// Freeing blocks invalidates their cached copies, so a dirty one is never
// flushed over whatever the block holds next. A range used to start from an
// exact lookup of its first block: when that one was not cached, nothing in
// the range was invalidated.
test "Ext4.InvalidatingARangeReachesBlocksPastAnUncachedFirst" {
    var fs = try create_formatted(); // lwext4's allocator hook
    defer fs.interface.delete();
    var bc = std.mem.zeroes(lwext4.struct_ext4_bcache);
    try std.testing.expectEqual(@as(c_int, 0), lwext4.ext4_bcache_init_dynamic(&bc, 8, 1024));
    defer _ = lwext4.ext4_bcache_fini_dynamic(&bc);
    var bufs: [2]*lwext4.struct_ext4_buf = undefined;
    try cache_blocks(&bc, &.{ 5, 6 }, 'A', false, &bufs);
    defer for (bufs) |buf| lwext4.ext4_bcache_drop_buf(&bc, buf);

    lwext4.ext4_bcache_invalidate_lba(&bc, 4, 3);
    for (bufs) |buf| {
        try std.testing.expect(!has_flag(buf, lwext4.BC_DIRTY));
        try std.testing.expect(!has_flag(buf, lwext4.BC_UPTODATE));
    }
}

// Device I/O past the cache (file data, the byte helpers) agrees with it: a
// read takes dirty cached bytes over the device's, a write refreshes every
// cached copy it overlaps, and the cache's own fill or flush is left alone.
test "Ext4.DirectIoAgreesWithTheBlockCache" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    var bc = std.mem.zeroes(lwext4.struct_ext4_bcache);
    try std.testing.expectEqual(@as(c_int, 0), lwext4.ext4_bcache_init_dynamic(&bc, 8, 1024));
    defer _ = lwext4.ext4_bcache_fini_dynamic(&bc);
    var dirty: [1]*lwext4.struct_ext4_buf = undefined;
    var clean: [1]*lwext4.struct_ext4_buf = undefined;
    try cache_blocks(&bc, &.{2}, 'A', false, &dirty);
    defer lwext4.ext4_bcache_drop_buf(&bc, dirty[0]);
    try cache_blocks(&bc, &.{3}, 'C', true, &clean);
    defer lwext4.ext4_bcache_drop_buf(&bc, clean[0]);

    // Bytes 1536..4608: half of block 1, blocks 2 and 3, half of block 4.
    var device: [3072]u8 = @splat('D');
    lwext4.ext4_bcache_direct_io(&bc, &device, 1536, 1536 + device.len, false);
    try std.testing.expect(std.mem.allEqual(u8, device[0..512], 'D'));
    try std.testing.expect(std.mem.allEqual(u8, device[512..1536], 'A'));
    try std.testing.expect(std.mem.allEqual(u8, device[1536..], 'D'));

    // A write straddling blocks 2 and 3 lands in both cached copies.
    var written: [1024]u8 = @splat('N');
    lwext4.ext4_bcache_direct_io(&bc, &written, 2048 + 512, 2048 + 512 + written.len, true);
    try std.testing.expect(std.mem.allEqual(u8, dirty[0].data[0..512], 'A'));
    try std.testing.expect(std.mem.allEqual(u8, dirty[0].data[512..1024], 'N'));
    try std.testing.expect(std.mem.allEqual(u8, clean[0].data[0..512], 'N'));
    try std.testing.expect(std.mem.allEqual(u8, clean[0].data[512..1024], 'C'));

    // The cache flushing its own buffer copies nothing onto itself.
    lwext4.ext4_bcache_direct_io(&bc, dirty[0].data, 2048, 3072, true);
    try std.testing.expect(std.mem.allEqual(u8, dirty[0].data[512..1024], 'N'));
}

// With memory of its own (PSRAM on the board) the cache grows past the 8
// blocks a volume it gets on the kernel heap, and a tree walk stops re-reading
// the device.
test "Ext4.ACacheWithItsOwnMemoryStopsRereading" {
    const ext4fs = @import("ext4fs.zig");
    const io = @import("../fatfs/tests/device_stub.zig").io;
    var backing = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer backing.deinit();
    ext4fs.use_cache_memory(backing.allocator(), 128, 128);
    defer ext4fs.release_cache_memory();

    var fs = try create_formatted();
    defer fs.interface.delete();
    for ([_][]const u8{ "/a", "/a/b", "/a/b/c", "/a/b/c/d" }) |dir| try fs.interface.mkdir(dir, 0o755);
    var path_buffer: [64]u8 = undefined;
    for (0..50) |index| {
        try write_file(&fs, try std.fmt.bufPrint(&path_buffer, "/a/b/c/d/f{d}", .{index}), "x");
    }
    io.reset();
    var buffer: [8]u8 = undefined;
    for (0..50) |index| {
        try std.testing.expectEqualStrings("x", try read_file(&fs, try std.fmt.bufPrint(&path_buffer, "/a/b/c/d/f{d}", .{index}), &buffer));
    }
    // The file's own data block is read past the cache; the walk to it is not.
    try std.testing.expect(io.reads <= 50 + 2);
}

// Every directory lwext4 makes is indexed, and the index does not cover "."
// and "..": `#include "../fp/x.h"` from a source on ext4 used to be ENOENT.
test "Ext4.DotAndDotDotResolveInIndexedDirectories" {
    var fs = try create_formatted();
    defer fs.interface.delete();
    try fs.interface.mkdir("/v2", 0o755);
    try fs.interface.mkdir("/v2/ir_tests", 0o755);
    try fs.interface.mkdir("/v2/fp", 0o755);
    try write_file(&fs, "/v2/fp/h.h", "header");
    try write_file(&fs, "/v2/ir_tests/t.c", "source");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("header", try read_file(&fs, "/v2/ir_tests/../fp/h.h", &buffer));
    try std.testing.expectEqualStrings("source", try read_file(&fs, "/v2/ir_tests/./t.c", &buffer));
    try std.testing.expectEqualStrings("header", try read_file(&fs, "/v2/fp/../../v2/fp/h.h", &buffer));
}
