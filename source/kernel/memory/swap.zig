// Copyright (c) 2026 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// Swap space: a file or a partition (`swap` lines in /etc/fstab) that the
// process pool writes a waiting process out to when an allocation finds it
// full -- see "swap" in heap/process_memory_pool.zig for what is swapped and
// when, and process_manager.zig for who.
//
// Space goes in 4 KiB clusters, a run per swapped-out mapping. The I/O is the
// filesystem's or the block device's, behind `io_lock`; the cluster bitmap has
// a spinlock of its own because `drop` is called from under the pool's lock
// when a swapped-out process is reaped.

const std = @import("std");

const kernel = @import("../kernel.zig");
const c = @import("libc_imports").c;
const ProcessMemoryPool = @import("heap/process_memory_pool.zig").ProcessMemoryPool;

const log = std.log.scoped(.@"kernel/swap");

pub const cluster_size: usize = 4096;

/// Serializes swapping: one process out or in at a time.  Taken by
/// process_manager.zig around a whole swap-out or swap-in.
pub var io_lock: kernel.sync.RankedMutex(.swap) = .{};
var slots_lock: kernel.sync.Ranked(.swap_slots) = .{};

var node: ?kernel.fs.Node = null;
var path_buffer: [128]u8 = undefined;
var path_len: usize = 0;
var clusters: std.DynamicBitSetUnmanaged = .{};
var used_clusters: usize = 0;

pub const Stats = struct {
    total: usize = 0,
    used: usize = 0,
    outs: usize = 0,
    ins: usize = 0,
};
var counters: Stats = .{};

pub fn active() bool {
    return node != null;
}

pub fn stats() Stats {
    const flags = slots_lock.lock_irqsave();
    defer slots_lock.unlock_irqrestore(flags);
    var s = counters;
    s.total = clusters.bit_length * cluster_size;
    s.used = used_clusters * cluster_size;
    return s;
}

pub fn path() []const u8 {
    return path_buffer[0..path_len];
}

/// Use `swap_path` (a file, or a block device such as /dev/mmc0p4) as swap.
/// A file shorter than `size` bytes is created or grown to it first, zeros
/// written once; a device is used whole.
pub fn activate(allocator: std.mem.Allocator, swap_path: []const u8, size: u64) !void {
    if (node != null) return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
    if (swap_path.len > path_buffer.len) return kernel.errno.ErrnoSet.NameTooLong;
    var vfs = kernel.fs.get_ivfs();
    var n = vfs.interface.get(swap_path) catch blk: {
        if (size == 0) return kernel.errno.ErrnoSet.NoEntry;
        try kernel.fs.get_vfs().create(swap_path, 0o600);
        break :blk try vfs.interface.get(swap_path);
    };
    errdefer n.delete();
    var file = n.as_file() orelse return kernel.errno.ErrnoSet.IsADirectory;
    var have = file.interface.size();
    if (have < size) {
        try grow(allocator, &file, have, size);
        have = size;
    }
    const count: usize = @intCast(have / cluster_size);
    if (count == 0) return kernel.errno.ErrnoSet.InvalidArgument;
    // A bit per 4 KiB: 4 KiB of bitmap for 128 MiB, kept out of the kernel's
    // SRAM where the board has PSRAM for it.
    clusters = try std.DynamicBitSetUnmanaged.initEmpty(kernel.memory.heap.slow.allocator_or(allocator), count);
    @memcpy(path_buffer[0..swap_path.len], swap_path);
    path_len = swap_path.len;
    node = n;
    ProcessMemoryPool.swap_io = .{ .ctx = undefined, .store = store, .load = load, .drop = drop };
    ProcessMemoryPool.swap_hook = &kernel.process.process_manager.swap_hook;
    log.info("swap on {s}: {d} KiB", .{ swap_path, count * cluster_size / 1024 });
}

/// Zeros to `to`, in writes big enough that the first boot with a new swap
/// file is seconds, not the minute 512-byte ones took; on the heap, as this
/// runs on whoever mounts (the boot's mount -a, or mount(2)).
fn grow(allocator: std.mem.Allocator, file: *kernel.fs.IFile, from: u64, to: u64) !void {
    const zeros = try allocator.alloc(u8, 8192);
    defer allocator.free(zeros);
    @memset(zeros, 0);
    _ = try file.interface.seek(@intCast(from), c.SEEK_SET);
    var at = from;
    while (at < to) {
        const n: usize = @intCast(@min(to - at, zeros.len));
        if (file.interface.write(zeros[0..n]) != n) return kernel.errno.ErrnoSet.NoSpaceLeftOnDevice;
        at += n;
    }
    _ = file.interface.sync();
}

fn claim(count: usize) ?usize {
    const flags = slots_lock.lock_irqsave();
    defer slots_lock.unlock_irqrestore(flags);
    var start: usize = 0;
    while (start + count <= clusters.bit_length) {
        var len: usize = 0;
        while (len < count and !clusters.isSet(start + len)) : (len += 1) {}
        if (len == count) {
            clusters.setRangeValue(.{ .start = start, .end = start + count }, true);
            used_clusters += count;
            return start;
        }
        start += len + 1;
    }
    return null;
}

fn release(first: usize, count: usize) void {
    const flags = slots_lock.lock_irqsave();
    defer slots_lock.unlock_irqrestore(flags);
    clusters.setRangeValue(.{ .start = first, .end = first + count }, false);
    used_clusters -= count;
}

fn clusters_for(bytes: usize) usize {
    return (bytes + cluster_size - 1) / cluster_size;
}

fn transfer(first: usize, data: []u8, comptime write: bool) !void {
    var n = node orelse return kernel.errno.ErrnoSet.NoSuchDevice;
    var file = n.as_file() orelse return kernel.errno.ErrnoSet.NoSuchDevice;
    _ = try file.interface.seek(@intCast(first * cluster_size), c.SEEK_SET);
    const done = if (write) file.interface.write(data) else file.interface.read(data);
    if (done != data.len) return kernel.errno.ErrnoSet.InputOutputError;
}

// ---- ProcessMemoryPool.SwapIo: io_lock held by the caller ----

fn store(_: *anyopaque, data: []const u8) anyerror!u32 {
    const count = clusters_for(data.len);
    const first = claim(count) orelse return kernel.errno.ErrnoSet.NoSpaceLeftOnDevice;
    errdefer release(first, count);
    try transfer(first, @constCast(data), true);
    counters.outs += 1;
    return @intCast(first);
}

fn load(_: *anyopaque, slot: u32, data: []u8) anyerror!void {
    try transfer(slot, data, false);
    counters.ins += 1;
}

fn drop(_: *anyopaque, slot: u32, bytes: usize) void {
    release(slot, clusters_for(bytes));
}
