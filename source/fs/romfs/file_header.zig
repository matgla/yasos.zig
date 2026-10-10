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
const dev_lock = kernel.driver.dev_lock;
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
    /// The image mapped at its base, or null when the device cannot map. While
    /// the filesystem is mounted the image is immutable, and the mapping is
    /// held by the device for as long as the system runs (see `main.zig`), so
    /// header bytes behind this pointer are plain memory -- `load` reads them
    /// with neither the shared device position nor its lock.
    _mapped_memory: ?*const anyopaque,
    _allocator: std.mem.Allocator,
    _filesystem_offset: c.off_t,
    /// Size of the whole image in bytes, from the volume header. The mapped
    /// reader bounds every access by it, so a corrupt `next` pointer cannot
    /// walk a header read off the image into whatever is mapped behind it.
    _image_size: u32,
    _filetype: kernel.fs.FileType,
    /// Inline storage for the name, valid for `_name_len` bytes when
    /// `_name_heap` is null. See `name()`.
    _name_storage: [inline_name_max]u8,
    _name_len: u8,
    _name_heap: ?[]u8,
    _size: u32,
    _specinfo: u32,
    /// Offset of the next entry in this directory, already masked. Kept from the
    /// header read so stepping to the sibling costs no read of its own.
    _next: u32,

    /// Read one directory entry -- the hot loop of every path lookup, which
    /// constructs one of these per entry it steps over. A single 32-byte read
    /// parsed in place, with the name left in the header rather than copied onto
    /// the kernel heap for the caller to compare and free.
    ///
    /// Everything but the entry offset is session state, stored here once:
    /// `load` and `step_to_next` then take an offset only, instead of passing
    /// the device file and mapping by value on every step of a directory scan.
    pub fn init(device_file: IFile, start_offset: c.off_t, filesystem_offset: c.off_t, image_size: u32, mapped_address: ?*const anyopaque, allocator: std.mem.Allocator) !FileHeader {
        var self: FileHeader = undefined;
        self._device_file = device_file;
        self._mapped_memory = mapped_address;
        self._allocator = allocator;
        self._filesystem_offset = filesystem_offset;
        self._image_size = image_size;
        self._name_heap = null;
        try self.load(start_offset);
        return self;
    }

    /// Fill this header from the entry at `start_offset`, reusing the storage
    /// already here rather than returning a new one. The struct is ~120 bytes,
    /// and returning it by value made the directory scan copy it two or three
    /// times per entry stepped over.
    pub fn load(self: *FileHeader, start_offset: c.off_t) !void {
        const t_start = if (kernel.perf.enabled) kernel.perf.read_cycles() else 0;
        var buffer: [first_read_bytes]u8 = undefined;
        const entry_offset: i64 = start_offset - self._filesystem_offset;

        // The mapped image: the bytes are already memory, so neither the shared
        // device position nor the lock around it is needed. Every access is
        // bounded by the image size -- an offset past the end means a corrupt
        // chain and stops here rather than reading what maps behind the image.
        const image: ?[]const u8 = if (self._mapped_memory) |base|
            @as([*]const u8, @ptrCast(base))[0..self._image_size]
        else
            null;

        if (image) |img| {
            if (entry_offset < 0) return kernel.errno.ErrnoSet.InputOutputError;
            const at: usize = @intCast(entry_offset);
            if (at + first_read_bytes > img.len) return kernel.errno.ErrnoSet.InputOutputError;
            @memcpy(buffer[0..], img[at..][0..first_read_bytes]);
        } else {
            var df = self._device_file;
            // The seek and the read are one operation and the device position they
            // share is global: split them and the other core's romfs read lands in
            // between, so this returns bytes from elsewhere in the image and parses
            // them as a header.
            //
            // Scoped to the pair, and it has to be: the long-name path below calls
            // `FileReader.read_string`, which takes this same lock, and
            // `RankedMutex` does not recurse.
            {
                dev_lock.acquire();
                defer dev_lock.release();
                kernel.perf.romfs_read();
                _ = try df.interface.seek(@intCast(start_offset), c.SEEK_SET);
                _ = df.interface.read(buffer[0..]);
            }
        }

        const fileheader = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, buffer[0..4]));
        const specinfo_data = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, buffer[4..8]));
        const size_data = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, buffer[8..12]));
        const ft = FileHeader.convert_filetype(@enumFromInt(fileheader & 0x7));

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
        } else if (image) |img| {
            // A long name, with its bytes already in the mapped image: scan for
            // the terminator instead of reading the device. The name is
            // NUL-terminated and padded to the next 16-byte boundary, so the
            // terminator is what decides where data starts.
            const at: usize = @intCast(entry_offset);
            const name_area = img[at + fixed_header_bytes ..];
            const end = std.mem.indexOfScalar(u8, name_area, 0) orelse
                return kernel.errno.ErrnoSet.InputOutputError;
            data_offset = fixed_header_bytes +
                std.mem.alignForward(u64, end + 1, name_chunk);
            if (end <= inline_name_max) {
                self._name_len = @intCast(end);
                @memcpy(self._name_storage[0..end], name_area[0..end]);
            } else {
                kernel.perf.romfs_name_alloc();
                self._name_heap = self._allocator.dupe(u8, name_area[0..end]) catch null;
            }
        } else {
            // A name of 16 bytes or more. Keep reading 16-byte chunks until the
            // terminator turns up, which is also what finds the data offset.
            var reader = FileReader.init_at(self._device_file, @intCast(start_offset), first_read_bytes);
            kernel.perf.romfs_name_alloc();
            const maybe_name: ?[]u8 = reader.read_string(self._allocator, fixed_header_bytes) catch null;
            if (maybe_name) |heap_name| {
                // The name is NUL-terminated and padded to the next 16-byte
                // boundary, so the terminator is what decides where data starts.
                data_offset = fixed_header_bytes +
                    std.mem.alignForward(u64, heap_name.len + 1, name_chunk);
                if (heap_name.len <= inline_name_max) {
                    self._name_len = @intCast(heap_name.len);
                    @memcpy(self._name_storage[0..heap_name.len], heap_name);
                    if (heap_name.len != 0) self._allocator.free(heap_name);
                } else {
                    self._name_heap = heap_name;
                }
            }
        }

        self._reader = FileReader.init_at(self._device_file, @intCast(start_offset), data_offset);
        if (kernel.perf.enabled) kernel.perf.romfs_header(kernel.perf.read_cycles() -% t_start);
    }

    /// Advance to the next entry in the same directory, in place. Returns false
    /// when this was the last entry, leaving the header as it was.
    pub fn step_to_next(self: *FileHeader) !bool {
        if (self._next == 0) {
            return false;
        }
        const next_offset: c.off_t = @as(c.off_t, @intCast(self._next)) + self._filesystem_offset;
        self.deinit();
        try self.load(next_offset);
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
        return try FileHeader.init(self._device_file, next_file_header + self._filesystem_offset, self._filesystem_offset, self._image_size, self._mapped_memory, self._allocator);
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

    /// `timestamp` is the whole image's age -- see `RomFs.image_time`. The
    /// format has no per-entry date field, so all three stamps are the same one
    /// and every entry in the image carries it.
    pub fn stat(self: *FileHeader, buf: *c.struct_stat, timestamp: c.struct_timespec) void {
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
        buf.st_atim = timestamp;
        buf.st_mtim = timestamp;
        buf.st_ctim = timestamp;
    }

    /// Device offset of this entry's header.
    pub fn image_offset(self: *const FileHeader) c.off_t {
        return self._reader.get_offset();
    }

    pub fn dupe(self: *const FileHeader) !FileHeader {
        return try FileHeader.init(self._device_file, self._reader.get_offset(), self._filesystem_offset, self._image_size, self._mapped_memory, self._allocator);
    }
};
