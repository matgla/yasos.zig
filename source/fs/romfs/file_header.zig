//
// file_header.zig
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

const kernel = @import("kernel");

const FileType = kernel.fs.FileType;
const IFile = kernel.fs.IFile;
const FileName = kernel.fs.FileName;

const c = @import("libc_imports").c;

const log = std.log.scoped(.fileheader);

const FileReader = @import("file_reader.zig").FileReader;

const alignment: u32 = 16;

pub const Type = enum(u4) {
    HardLink = 0,
    Directory = 1,
    RegularFile = 2,
    SymbolicLink = 3,
    BlockDevice = 4,
    CharDevice = 5,
    Socket = 6,
    Fifo = 7,
};

/// romfs lays an entry out as a 16-byte fixed header (next+type, spec_info,
/// size, checksum) followed by a NUL-terminated name padded to the next 16-byte
/// boundary. So one 32-byte read covers the header and the whole name for any
/// name shorter than 16 bytes, which in practice is nearly all of them.
const fixed_header_bytes = 16;
const name_chunk = 16;
const first_read_bytes = fixed_header_bytes + name_chunk;

/// Names up to this length are kept in the header itself. Anything longer
/// still works and falls back to the heap; 31 covers every name in this
/// rootfs, so the allocation is effectively never taken.
const inline_name_max = 31;

pub const FileHeader = struct {
    _reader: FileReader,
    _device_file: IFile,
    _mapped_memory: ?*const anyopaque,
    _allocator: std.mem.Allocator,
    _filesystem_offset: c.off_t,
    _filetype: kernel.fs.FileType,
    /// Inline storage for the name, valid for `_name_len` bytes when
    /// `_name_heap` is null. See `name()`.
    _name_storage: [inline_name_max]u8,
    _name_len: u8,
    _name_heap: ?[]u8,
    _size: u32,
    _specinfo: u32,
    /// Offset of the next entry in this directory, already masked. Kept from
    /// the header read so stepping to the sibling costs no read of its own --
    /// `next()` used to re-read the very word `init` had just parsed, which on
    /// a directory scan doubled the reads.
    _next: u32,

    /// Read one directory entry.
    ///
    /// This is the hot loop of every path lookup: resolving `/usr/lib/libc.so`
    /// constructs one of these per entry it steps over, in every directory
    /// along the way. It used to cost about six virtual reads and a
    /// malloc/free pair each time -- `FileReader.init` seeking and reading to
    /// find where the name ended, then a separate seek+read for each of the
    /// three u32 fields, then `read_string` copying the name onto the kernel
    /// heap purely so the caller could compare it and free it again. All of
    /// that reads the same 32 bytes of memory-mapped XIP flash.
    ///
    /// It is now a single read of those 32 bytes, parsed in place, with the
    /// name left in the header rather than on the heap.
    pub fn init(device_file: IFile, start_offset: c.off_t, filesystem_offset: c.off_t, mapped_address: ?*const anyopaque, allocator: std.mem.Allocator) !FileHeader {
        var self: FileHeader = undefined;
        self._name_heap = null;
        try self.load(device_file, start_offset, filesystem_offset, mapped_address, allocator);
        return self;
    }

    /// Fill this header from the entry at `start_offset`, reusing the storage
    /// already here rather than returning a new one.
    ///
    /// The struct is ~120 bytes, and returning it by value made the directory
    /// scan in `get_file_header` copy it two or three times per entry it
    /// stepped over: the walk compiled to nine `__aeabi_memcpy8` calls against
    /// a byte/word copy that checks its pointers as it goes. Loading in place
    /// is what `step_to_next` uses, so a scan of N entries now copies nothing.
    pub fn load(self: *FileHeader, device_file: IFile, start_offset: c.off_t, filesystem_offset: c.off_t, mapped_address: ?*const anyopaque, allocator: std.mem.Allocator) !void {
        const t_start = if (kernel.perf.enabled) kernel.perf.read_cycles() else 0;
        var buffer: [first_read_bytes]u8 = undefined;
        var df = device_file;
        kernel.perf.romfs_read();
        _ = try df.interface.seek(@intCast(start_offset), c.SEEK_SET);
        _ = df.interface.read(buffer[0..]);

        const fileheader = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, buffer[0..4]));
        const specinfo_data = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, buffer[4..8]));
        const size_data = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, buffer[8..12]));
        const ft = FileHeader.convert_filetype(@enumFromInt(fileheader & 0x7));

        self._device_file = device_file;
        self._mapped_memory = mapped_address;
        self._allocator = allocator;
        self._filesystem_offset = filesystem_offset;
        self._filetype = ft;
        self._name_len = 0;
        self._name_heap = null;
        self._size = size_data;
        self._specinfo = specinfo_data;
        self._next = fileheader & 0xfffffff0;

        const first_chunk = buffer[fixed_header_bytes..];
        var data_offset: u64 = first_read_bytes;
        if (std.mem.indexOfScalar(u8, first_chunk, 0)) |end| {
            // The common case: the whole name arrived in the read above.
            self._name_len = @intCast(end);
            @memcpy(self._name_storage[0..end], first_chunk[0..end]);
        } else {
            // A name of 16 bytes or more. Keep reading 16-byte chunks until the
            // terminator turns up, which is also what finds the data offset.
            var reader = FileReader.init_at(device_file, @intCast(start_offset), first_read_bytes);
            kernel.perf.romfs_name_alloc();
            const maybe_name: ?[]u8 = reader.read_string(allocator, fixed_header_bytes) catch null;
            if (maybe_name) |heap_name| {
                // The name is NUL-terminated and padded to the next 16-byte
                // boundary, so the terminator is what decides where data starts.
                data_offset = fixed_header_bytes +
                    std.mem.alignForward(u64, heap_name.len + 1, name_chunk);
                if (heap_name.len <= inline_name_max) {
                    self._name_len = @intCast(heap_name.len);
                    @memcpy(self._name_storage[0..heap_name.len], heap_name);
                    if (heap_name.len != 0) allocator.free(heap_name);
                } else {
                    self._name_heap = heap_name;
                }
            }
        }

        self._reader = FileReader.init_at(device_file, @intCast(start_offset), data_offset);
        if (kernel.perf.enabled) kernel.perf.romfs_header(kernel.perf.read_cycles() -% t_start);
    }

    /// Advance to the next entry in the same directory, in place.
    ///
    /// Returns false when this was the last entry, leaving the header as it
    /// was. The in-place form is what keeps a directory scan free of struct
    /// copies -- see `load`.
    pub fn step_to_next(self: *FileHeader) !bool {
        if (self._next == 0) {
            return false;
        }
        const next_offset: c.off_t = @as(c.off_t, @intCast(self._next)) + self._filesystem_offset;
        const device_file = self._device_file;
        const filesystem_offset = self._filesystem_offset;
        const mapped_memory = self._mapped_memory;
        const allocator = self._allocator;
        self.deinit();
        try self.load(device_file, next_offset, filesystem_offset, mapped_memory, allocator);
        return true;
    }

    pub fn deinit(self: *FileHeader) void {
        if (self._name_heap) |heap| {
            self._allocator.free(heap);
            self._name_heap = null;
        }
    }

    fn convert_filetype(ft: Type) FileType {
        switch (ft) {
            Type.HardLink => return FileType.HardLink,
            Type.Directory => return FileType.Directory,
            Type.RegularFile => return FileType.File,
            Type.SymbolicLink => return FileType.SymbolicLink,
            Type.BlockDevice => return FileType.BlockDevice,
            Type.CharDevice => return FileType.CharDevice,
            Type.Socket => return FileType.Socket,
            Type.Fifo => return FileType.Fifo,
        }
    }

    pub fn filetype(self: *const FileHeader) FileType {
        return self._filetype;
    }

    pub fn specinfo(self: *const FileHeader) u32 {
        return self._specinfo;
    }

    pub fn size(self: *const FileHeader) u32 {
        return self._size;
    }

    pub fn name(self: *const FileHeader) []const u8 {
        if (self._name_heap) |heap| return heap;
        return self._name_storage[0..self._name_len];
    }

    pub fn read_bytes(self: *FileHeader, buffer: []u8, offset: c.off_t) !void {
        try self._reader.read_bytes(buffer, self._reader.get_data_offset() + offset);
    }

    pub fn read_name_at_offset(self: *FileHeader, allocator: std.mem.Allocator, offset: c.off_t) ?FileName {
        const name_buffer = self._reader.read_string(allocator, self._reader.get_data_offset() + offset) catch {
            return null;
        };
        return FileName.init(name_buffer, allocator);
    }

    pub fn get_mapped_address(self: FileHeader) ?*const anyopaque {
        return @ptrFromInt(@intFromPtr(self._mapped_memory) + @as(usize, @intCast((self._reader.get_offset() - self._filesystem_offset + self._reader.get_data_offset()))));
    }

    // genromfs sets checksum field as 0 before calculation and returns -sum as a result
    // if result is equal to 0, then checksum is correct
    pub fn validate_checksum(self: *FileHeader) !bool {
        const length = std.mem.alignBackward(u32, @min(self.size(), 512), 4);
        var i: u32 = 0;
        var checksum_value: u32 = 0;
        while (i < length) {
            const word = try self._reader.read(u32, i);
            checksum_value +%= word;
            i += 4;
        }
        return checksum_value == 0;
    }

    pub fn next(self: *FileHeader) !?FileHeader {
        const next_file_header: c.off_t = @intCast(self._next);
        if (next_file_header == 0) {
            return null;
        }
        return try FileHeader.init(self._device_file, next_file_header + self._filesystem_offset, self._filesystem_offset, self._mapped_memory, self._allocator);
    }

    fn filetype_to_mode(ftype: FileType) c.mode_t {
        switch (ftype) {
            FileType.HardLink => unreachable,
            FileType.Directory => return c.S_IFDIR,
            FileType.File => return c.S_IFREG,
            FileType.SymbolicLink => return c.S_IFLNK,
            FileType.BlockDevice => return c.S_IFBLK,
            FileType.CharDevice => return c.S_IFCHR,
            FileType.Socket => return c.S_IFSOCK,
            FileType.Fifo => return c.S_IFIFO,
            FileType.Unknown => return 0,
        }
        return 0;
    }

    pub fn stat(self: *FileHeader, buf: *c.struct_stat) void {
        buf.st_dev = 0;
        buf.st_ino = @intCast(self._reader.get_offset());
        buf.st_mode = @intCast(filetype_to_mode(self.filetype()));
        buf.st_nlink = 0;
        buf.st_uid = 0;
        buf.st_gid = 0;
        buf.st_rdev = 0;
        buf.st_size = @intCast(self.size());
        buf.st_blksize = 1;
        buf.st_blocks = 1;
    }

    pub fn dupe(self: *const FileHeader) !FileHeader {
        return try FileHeader.init(self._device_file, self._reader.get_offset(), self._filesystem_offset, self._mapped_memory, self._allocator);
    }
};
