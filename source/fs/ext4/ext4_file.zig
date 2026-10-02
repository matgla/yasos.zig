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

const interface = @import("interface");
const kernel = @import("kernel");
const c = @import("libc_imports").c;

const ext4fs = @import("ext4fs.zig");
const lwext4 = ext4fs.lwext4;

pub const Ext4File = interface.DeriveFromBase(kernel.fs.IFile, struct {
    const Self = @This();
    _file: lwext4.ext4_file,
    _allocator: std.mem.Allocator,
    _is_open: bool,
    _name: []const u8,
    /// "/eN/": what ext4_cache_flush wants. lwext4's mount point struct is
    /// opaque out here.
    _mount_point: [8:0]u8,

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
            ._name = filename,
            ._mount_point = mount_point,
        });
    }

    pub fn create_node(allocator: std.mem.Allocator, full: [:0]const u8) anyerror!kernel.fs.Node {
        const file = try (try create(allocator, full)).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        var count: usize = 0;
        if (lwext4.ext4_fread(&self._file, buffer.ptr, buffer.len, &count) != 0) return -1;
        return @intCast(count);
    }

    pub fn write(self: *Self, data: []const u8) isize {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        var count: usize = 0;
        if (lwext4.ext4_fwrite(&self._file, data.ptr, data.len, &count) != 0 and count == 0) return -1;
        return @intCast(count);
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
        ext4fs.lock.lock();
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
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        return if (lwext4.ext4_cache_flush(&self._mount_point) == 0) 0 else -1;
    }

    pub fn tell(self: *Self) i64 {
        ext4fs.lock.lock();
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
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        if (!self._is_open) return;
        self._is_open = false;
        _ = lwext4.ext4_fclose(&self._file);
        self._allocator.free(self._name);
    }

    pub fn size(self: *const Self) u64 {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
        return lwext4.ext4_fsize(@constCast(&self._file));
    }

    /// ftruncate(2). lwext4 only shrinks; growing is writing zeros, which is
    /// what the file would read as anyway.
    pub fn truncate(self: *Self, length: u64) anyerror!void {
        ext4fs.lock.lock();
        defer ext4fs.lock.unlock();
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
