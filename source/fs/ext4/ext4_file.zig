//
// ext4_file.zig
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

//! An open regular file on an ext4 volume: an lwext4 `ext4_file`, opened
//! read-write (O_TRUNC and O_APPEND are applied by the open syscall through
//! `truncate` and `seek`, as for every filesystem here).

const std = @import("std");
const builtin = @import("builtin");

const interface = @import("interface");
const kernel = @import("kernel");
const c = @import("libc_imports").c;

const ext4fs = @import("ext4fs.zig");
const lwext4 = ext4fs.lwext4;

const log = std.log.scoped(.@"fs/ext4");

pub const Ext4File = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    _file: lwext4.ext4_file,
    _allocator: std.mem.Allocator,
    _is_open: bool,
    /// Holding write-back on the volume: taken by the first write or
    /// truncate, let go at close. Without it every write() call wrote its metadata through on its own --
    /// inode, block bitmap, group descriptor, extent node -- a few blocks per
    /// call; held, they are written once, when the last writer on the volume
    /// closes, at fsync, or when the cache needs the slot.
    _write_back: bool,
    _name: []const u8,
    /// "/eN/": what ext4_cache_flush wants. lwext4's mount point struct is
    /// opaque out here.
    _mount_point: [8:0]u8,
    /// Small writes gathered for one ext4_fwrite (see ext4fs.PendingWrites):
    /// `_buffered` bytes that belong right after lwext4's file position. The
    /// buffer comes with the first small write and goes at close.
    _pending: ext4fs.PendingWrites,
    _buffer: ?[]u8,
    _buffer_allocator: std.mem.Allocator,
    _buffered: usize,
    /// Where the gathered run ends: the next `buffer_size` boundary of the file
    /// from where it started, so lwext4 is handed whole aligned chunks rather
    /// than 31 lines of 65 bytes that straddle three blocks.
    _gather_limit: usize,
    /// errno of a gathered write lwext4 refused after write() had returned:
    /// reported by the next write() or fsync, as a delayed write error is.
    _deferred_errno: u16,

    /// Gathering buffer size: a few lines of a tty reader, a fraction of a
    /// card block. A write this long or longer goes straight through.
    const buffer_size = 2048;
    /// SRAM kernel heap kept free before a buffer is taken from it; below
    /// that the slow heap lends it, and with neither the file writes through.
    const fast_heap_reserve = 12 * 1024;

    /// `full` is the lwext4 path (mount point prefix included). The caller
    /// holds `ext4fs.lock`.
    pub fn create(allocator: std.mem.Allocator, full: [:0]const u8) !Ext4File {
        const filename = try allocator.dupe(u8, std.fs.path.basename(full));
        errdefer allocator.free(filename);
        var mount_point: [8:0]u8 = @splat(0);
        const prefix_end = (std.mem.indexOfScalarPos(u8, full, 1, '/') orelse return kernel.errno.ErrnoSet.InvalidArgument) + 1;
        if (prefix_end > mount_point.len) return kernel.errno.ErrnoSet.InvalidArgument;
        @memcpy(mount_point[0..prefix_end], full[0..prefix_end]);
        var file: lwext4.ext4_file = undefined;
        try ext4fs.check(lwext4.ext4_fopen(&file, full.ptr, "r+"));
        return Ext4File.init(.{
            ._file = file,
            ._allocator = allocator,
            ._is_open = true,
            ._write_back = false,
            ._name = filename,
            ._mount_point = mount_point,
            ._pending = ext4fs.PendingWrites{ .flush = &flush_pending_entry },
            ._buffer = null,
            ._buffer_allocator = allocator,
            ._buffered = 0,
            ._gather_limit = 0,
            ._deferred_errno = 0,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, full: [:0]const u8) anyerror!kernel.fs.Node {
        const file = try (try create(allocator, full)).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        ext4fs.lock_settled();
        defer ext4fs.lock.unlock();
        var count: usize = 0;
        if (lwext4.ext4_fread(&self._file, buffer.ptr, buffer.len, &count) != 0) return -1;
        return @intCast(count);
    }

    /// A short write is gathered, and lwext4 gets the buffer when it fills,
    /// before anything else touches the volume (ext4fs.lock_settled) and at
    /// close. A long one, or one with no buffer to go to, goes straight
    /// through, after what is gathered. A failure comes back as -errno.
    pub fn write(self: *Self, data: []const u8) isize {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        // Other files first: their bytes were written before these.
        ext4fs.settle_pending(&self._pending);
        self.hold_write_back();
        if (self._deferred_errno != 0) {
            const code = self._deferred_errno;
            self._deferred_errno = 0;
            return -@as(isize, code);
        }
        if (data.len == 0) return 0;
        if (data.len < buffer_size) {
            if (self.gather_buffer()) |buffer| {
                var rest = data;
                while (rest.len > 0) {
                    if (self._buffered == 0) {
                        const offset: usize = @intCast(lwext4.ext4_ftell(&self._file) % buffer.len);
                        self._gather_limit = buffer.len - offset;
                    }
                    const take = @min(rest.len, self._gather_limit - self._buffered);
                    @memcpy(buffer[self._buffered..][0..take], rest[0..take]);
                    self._buffered += take;
                    rest = rest[take..];
                    if (self._buffered == self._gather_limit) {
                        if (!self.flush_gathered()) return self.take_deferred();
                    }
                }
                if (self._buffered > 0) ext4fs.queue_pending(&self._pending);
                return @intCast(data.len);
            }
        }
        if (!self.flush_gathered()) return self.take_deferred();
        var count: usize = 0;
        const rc = lwext4.ext4_fwrite(&self._file, data.ptr, data.len, &count);
        if (rc != 0 and count == 0) return -@as(isize, @intCast(rc));
        return @intCast(count);
    }

    fn take_deferred(self: *Self) isize {
        const code = self._deferred_errno;
        self._deferred_errno = 0;
        return -@as(isize, if (code != 0) code else c.EIO);
    }

    /// The gathering buffer, taken on first use. Null when neither heap has
    /// room for it. The caller holds `ext4fs.lock`.
    fn gather_buffer(self: *Self) ?[]u8 {
        if (self._buffer) |buffer| return buffer;
        // The volume's own allocator is the slow heap on the PSRAM boards
        // (initialize_filesystem); the SRAM kernel heap is preferred while it
        // can spare the buffer. On a board without PSRAM the two are one heap,
        // and a heap that cannot spare it means writing through.
        const fast_heap = kernel.memory.heap.slow.fast_or(self._allocator);
        // Host tests have no kernel break to measure (`__heap_limit__`).
        const fast_has_room = if (comptime builtin.is_test) true else kernel.memory.heap.malloc.headroom() >= buffer_size + fast_heap_reserve;
        const allocator = if (fast_has_room)
            fast_heap
        else if (fast_heap.ptr != self._allocator.ptr)
            self._allocator
        else
            return null;
        const buffer = allocator.alloc(u8, buffer_size) catch return null;
        self._buffer = buffer;
        self._buffer_allocator = allocator;
        return buffer;
    }

    /// Hand the gathered bytes to lwext4. False when it refused them; the
    /// errno waits in `_deferred_errno` and the bytes are dropped, as a
    /// delayed write's are. The caller holds `ext4fs.lock`.
    fn flush_gathered(self: *Self) bool {
        ext4fs.unqueue_pending(&self._pending);
        if (self._buffered == 0) return true;
        const buffer = self._buffer.?;
        const length = self._buffered;
        self._buffered = 0;
        var count: usize = 0;
        const rc = lwext4.ext4_fwrite(&self._file, buffer.ptr, length, &count);
        if (rc == 0 and count == length) return true;
        self._deferred_errno = if (rc != 0) @intCast(rc) else c.ENOSPC;
        return false;
    }

    fn flush_pending_entry(entry: *ext4fs.PendingWrites) void {
        const self: *Self = @alignCast(@fieldParentPtr("_pending", entry));
        _ = self.flush_gathered();
    }

    /// The caller holds `ext4fs.lock`.
    fn hold_write_back(self: *Self) void {
        if (self._write_back) return;
        ext4fs.hold_write_back(&self._mount_point, true);
        self._write_back = true;
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
        ext4fs.lock_settled();
        defer ext4fs.lock.unlock();
        const file_size: i64 = @intCast(lwext4.ext4_fsize(&self._file));
        const position: i64 = switch (whence) {
            c.SEEK_SET => offset,
            c.SEEK_CUR => @as(i64, @intCast(lwext4.ext4_ftell(&self._file))) + offset,
            c.SEEK_END => file_size + offset,
            else => return kernel.errno.ErrnoSet.InvalidArgument,
        };
        // lwext4 cannot leave a hole: a position past the end is refused
        // rather than silently clamped.
        if (position < 0 or position > file_size) return kernel.errno.ErrnoSet.InvalidArgument;
        try ext4fs.check(lwext4.ext4_fseek(&self._file, position, c.SEEK_SET));
        return position;
    }

    pub fn sync(self: *Self) i32 {
        ext4fs.lock_settled();
        defer ext4fs.lock.unlock();
        if (self._deferred_errno != 0) {
            self._deferred_errno = 0;
            return -1;
        }
        return if (lwext4.ext4_cache_flush(&self._mount_point) == 0) 0 else -1;
    }

    pub fn tell(self: *Self) i64 {
        ext4fs.lock_settled();
        defer ext4fs.lock.unlock();
        return @intCast(lwext4.ext4_ftell(&self._file));
    }

    pub fn name(self: *const Self) []const u8 {
        return self._name;
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        _ = self;
        switch (cmd) {
            @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus) => {
                const attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(data orelse return -1));
                attr.is_memory_mapped = false;
                return 0;
            },
            else => return -1,
        }
    }

    pub fn fcntl(self: *Self, _: i32, _: ?*anyopaque) i32 {
        _ = self;
        return 0;
    }

    pub fn poll(self: *Self, events: kernel.fs.PollMask) kernel.fs.PollMask {
        _ = self;
        return kernel.fs.poll_always_ready(events);
    }

    pub fn filetype(self: *const Self) kernel.fs.FileType {
        _ = self;
        return .File;
    }

    pub fn delete(self: *Self) void {
        ext4fs.lock_settled();
        defer ext4fs.lock.unlock();
        if (!self._is_open) return;
        self._is_open = false;
        if (self._deferred_errno != 0) {
            log.warn("{s}: a gathered write was lost: errno {d}", .{ self._name, self._deferred_errno });
        }
        ext4fs.unqueue_pending(&self._pending);
        if (self._buffer) |buffer| {
            self._buffer_allocator.free(buffer);
            self._buffer = null;
        }
        _ = lwext4.ext4_fclose(&self._file);
        // The last holder letting go writes the volume's dirty blocks.
        if (self._write_back) ext4fs.hold_write_back(&self._mount_point, false);
        self._allocator.free(self._name);
    }

    pub fn size(self: *const Self) u64 {
        ext4fs.lock_settled();
        defer ext4fs.lock.unlock();
        return lwext4.ext4_fsize(@constCast(&self._file));
    }

    /// ftruncate(2). lwext4 only shrinks; growing is writing zeros, which is
    /// what the file would read as anyway.
    pub fn truncate(self: *Self, length: u64) anyerror!void {
        ext4fs.lock_settled();
        defer ext4fs.lock.unlock();
        self.hold_write_back();
        const current = lwext4.ext4_fsize(&self._file);
        if (length <= current) {
            try ext4fs.check(lwext4.ext4_ftruncate(&self._file, length));
            return;
        }
        const position = lwext4.ext4_ftell(&self._file);
        try ext4fs.check(lwext4.ext4_fseek(&self._file, @intCast(current), c.SEEK_SET));
        const zeros: [512]u8 = @splat(0);
        var remaining = length - current;
        while (remaining > 0) {
            const chunk: usize = @intCast(@min(remaining, zeros.len));
            var written: usize = 0;
            try ext4fs.check(lwext4.ext4_fwrite(&self._file, &zeros, chunk, &written));
            if (written == 0) return kernel.errno.ErrnoSet.NoSpaceLeftOnDevice;
            remaining -= written;
        }
        try ext4fs.check(lwext4.ext4_fseek(&self._file, @intCast(position), c.SEEK_SET));
    }
});
