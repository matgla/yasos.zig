// Copyright (c) 2025 Mateusz Stadnik
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

// Validation of pointers handed to the kernel by userspace. Syscall handlers run
// privileged, so an unchecked pointer is an arbitrary read/write primitive for
// any process. The MPU is no defence: PRIVDEFENA plus the background map means
// it only ever restricted unprivileged access.
//
// A valid user pointer may point at user-owned RAM (process SRAM and PSRAM) for
// a write, and additionally at the read-only executable image for a read -- the
// loader borrows .rodata from XIP rather than copying it, so open("/bin/ls")
// legitimately passes a flash pointer. Kernel RAM, the /tmp arena, MMIO and the
// PPB are all excluded; MMIO because a DMA engine programmed through it can
// write kernel RAM.
//
// Region-granular, not per-process: it stops a process reaching kernel memory,
// not process A reaching process B's pages. Closing that needs the page pool's
// per-pid map.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");

const ErrnoSet = @import("errno.zig").ErrnoSet;

const log = std.log.scoped(.uaccess);

/// Pointer validation only means anything where userspace and the kernel share
/// one address space, i.e. the Cortex-M targets. The host and unit-test builds
/// pass ordinary heap pointers no region list would cover, and their
/// `get_memory_layout()` allocates fresh backing memory on every call, so
/// consulting it per syscall would leak megabytes.
pub const enabled = builtin.cpu.arch.isThumb();

pub const Access = enum { read, write };

pub const Region = struct {
    start: usize,
    end: usize, // exclusive
};

// Four user regions is already more than any board defines (rp2350 has two:
// process SRAM and PSRAM); the two read-only entries are flash and romfs.
var writable: [4]Region = undefined;
var writable_count: usize = 0;
var readonly: [2]Region = undefined;
var readonly_count: usize = 0;
var initialized: bool = false;

extern var __flash_start__: u8;
extern var __flash_end__: u8;
extern var __romfs_start__: u8;
extern var __romfs_end__: u8;

/// Snapshot the regions once, at boot.
///
/// Snapshotting rather than calling `get_memory_layout()` per check is not just
/// a speed matter: on the host and ut_stub HALs that getter allocates.
pub fn init() void {
    if (comptime !enabled) {
        initialized = true;
        return;
    }

    writable_count = 0;
    for (hal.memory.get_memory_layout()) |region| {
        if (region.owner != .User or region.size == 0) continue;
        if (writable_count == writable.len) {
            log.err("more user regions than uaccess can hold, ignoring the rest", .{});
            break;
        }
        writable[writable_count] = .{
            .start = region.start_address,
            .end = region.start_address + region.size,
        };
        writable_count += 1;
    }

    readonly_count = 0;
    const images = [_]Region{
        .{ .start = @intFromPtr(&__flash_start__), .end = @intFromPtr(&__flash_end__) },
        .{ .start = @intFromPtr(&__romfs_start__), .end = @intFromPtr(&__romfs_end__) },
    };
    for (images) |image| {
        if (image.end <= image.start) continue;
        readonly[readonly_count] = image;
        readonly_count += 1;
    }

    initialized = true;
    log.info("user ranges: {d} writable, {d} read-only", .{ writable_count, readonly_count });
}

/// Does [ptr, ptr+len) lie wholly inside a single region? Pure, so it can be
/// tested without a HAL. Two details are load-bearing: `ptr + len` is checked
/// for wraparound, and the range must fit in ONE region -- spanning two would
/// let a caller reach the kernel memory sitting between them.
pub fn range_ok(regions: []const Region, ptr: usize, len: usize) bool {
    if (len == 0) return true;
    const end = std.math.add(usize, ptr, len) catch return false;
    for (regions) |region| {
        if (ptr >= region.start and end <= region.end) return true;
    }
    return false;
}

fn permitted(ptr: usize, len: usize, comptime access: Access) bool {
    if (comptime !enabled) return true;
    std.debug.assert(initialized);
    if (range_ok(writable[0..writable_count], ptr, len)) return true;
    if (access == .read and range_ok(readonly[0..readonly_count], ptr, len)) return true;
    return false;
}

/// True when userspace may access [ptr, ptr+len) with `access`.
pub fn access_ok(ptr: usize, len: usize, comptime access: Access) bool {
    const ok = permitted(ptr, len, access);
    if (!ok) {
        log.warn("rejected {s} of {d} bytes at 0x{x}", .{ @tagName(access), len, ptr });
    }
    return ok;
}

/// `access_ok` as an error, for `try` in handlers.
pub fn check(ptr: usize, len: usize, comptime access: Access) !void {
    if (!access_ok(ptr, len, access)) return ErrnoSet.BadAddress;
}

/// Validate a user pointer and return it as a kernel-usable slice.
pub fn slice(comptime T: type, ptr: ?*anyopaque, count: usize) ![]T {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return ErrnoSet.BadAddress;
    try check(@intFromPtr(p), bytes, .write);
    return @as([*]T, @ptrCast(@alignCast(p)))[0..count];
}

/// Const form of `slice`, permitting the read-only image regions.
pub fn const_slice(comptime T: type, ptr: ?*const anyopaque, count: usize) ![]const T {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    const bytes = std.math.mul(usize, count, @sizeOf(T)) catch return ErrnoSet.BadAddress;
    try check(@intFromPtr(p), bytes, .read);
    return @as([*]const T, @ptrCast(@alignCast(p)))[0..count];
}

/// Validate a user pointer that the kernel is going to write a `T` through.
pub fn out_ptr(comptime T: type, ptr: ?*anyopaque) !*T {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    try check(@intFromPtr(p), @sizeOf(T), .write);
    return @ptrCast(@alignCast(p));
}

/// Length of a NUL-terminated user string, without copying it. Replaces
/// `std.mem.span()` on user pointers, which scans unbounded. The scan is clamped
/// to the end of the region containing `ptr`, so it cannot walk out of the
/// caller's memory even when no NUL is present.
pub fn strnlen_user(ptr: ?*const anyopaque, max: usize) !usize {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    const base = @intFromPtr(p);

    // At least one readable byte, so a bad pointer is rejected up front rather
    // than faulting on the first load.
    try check(base, 1, .read);

    var scan: usize = if (comptime enabled) region_bytes_from(base, .read) else max;
    scan = @min(scan, max);

    const source = @as([*]const u8, @ptrCast(p));
    var i: usize = 0;
    while (i < scan) : (i += 1) {
        if (source[i] == 0) return i;
    }
    return ErrnoSet.NameTooLong;
}

/// Copy a NUL-terminated string out of user memory, bounded.
pub fn strncpy_from_user(dst: []u8, ptr: ?*const anyopaque, max: usize) ![]u8 {
    const limit = @min(max, dst.len);
    const len = try strnlen_user(ptr, limit);
    const source = @as([*]const u8, @ptrCast(ptr.?));
    @memcpy(dst[0..len], source[0..len]);
    return dst[0..len];
}

/// Bytes from `ptr` to the end of the region that contains it, 0 if none does.
fn region_bytes_from(ptr: usize, comptime access: Access) usize {
    for (writable[0..writable_count]) |region| {
        if (ptr >= region.start and ptr < region.end) return region.end - ptr;
    }
    if (access == .read) {
        for (readonly[0..readonly_count]) |region| {
            if (ptr >= region.start and ptr < region.end) return region.end - ptr;
        }
    }
    return 0;
}

const testing = std.testing;

test "uaccess.range_ok accepts a range inside one region" {
    const regions = [_]Region{.{ .start = 0x1000, .end = 0x2000 }};
    try testing.expect(range_ok(&regions, 0x1000, 0x1000));
    try testing.expect(range_ok(&regions, 0x1800, 0x800));
    try testing.expect(range_ok(&regions, 0x1fff, 1));
}

test "uaccess.range_ok rejects a range leaving the region" {
    const regions = [_]Region{.{ .start = 0x1000, .end = 0x2000 }};
    try testing.expect(!range_ok(&regions, 0x0fff, 1));
    try testing.expect(!range_ok(&regions, 0x1000, 0x1001));
    try testing.expect(!range_ok(&regions, 0x2000, 1));
}

test "uaccess.range_ok rejects a range straddling two regions" {
    // The gap between them is exactly the kernel memory this check exists to
    // protect, so a range spanning both must not be accepted.
    const regions = [_]Region{
        .{ .start = 0x1000, .end = 0x2000 },
        .{ .start = 0x3000, .end = 0x4000 },
    };
    try testing.expect(!range_ok(&regions, 0x1800, 0x2000));
    try testing.expect(range_ok(&regions, 0x3000, 0x1000));
}

test "uaccess.range_ok rejects a length that wraps the address space" {
    const regions = [_]Region{.{ .start = 0x1000, .end = 0x2000 }};
    try testing.expect(!range_ok(&regions, 0x1800, std.math.maxInt(usize)));
    try testing.expect(!range_ok(&regions, 0x1800, std.math.maxInt(usize) - 0x1000));
}

test "uaccess.range_ok accepts an empty range" {
    const regions = [_]Region{.{ .start = 0x1000, .end = 0x2000 }};
    try testing.expect(range_ok(&regions, 0, 0));
}

test "uaccess.range_ok rejects everything when there are no regions" {
    try testing.expect(!range_ok(&.{}, 0x1000, 1));
}
