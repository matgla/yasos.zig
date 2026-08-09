//
// ramfs.zig
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

const oop = @import("interface");
const fatfs = @import("zfat");
const c = @import("libc_imports").c;

const config = @import("config");
const kernel = @import("kernel");
const arch = @import("arch");

const log = std.log.scoped(.@"fs/fatfs");

const FatFsFile = @import("fatfs_file.zig").FatFsFile;
const FatFsDirectory = @import("fatfs_directory.zig").FatFsDirectory;
const FatFsIterator = @import("fatfs_directory.zig").FatFsIterator;

const fatfs_error_to_errno = @import("errno_converter.zig").fatfs_error_to_errno;

fn initialize_stat_identity(data: *c.struct_stat, path: []const u8) void {
    data.* = std.mem.zeroes(c.struct_stat);

    const normalized_path = if (path.len == 0) "/" else path;
    const device_hash = std.hash.Wyhash.hash(0, "fatfs") | 1;
    const inode_hash = std.hash.Wyhash.hash(device_hash, normalized_path) | 1;

    data.st_dev = @truncate(device_hash);
    data.st_ino = @truncate(inode_hash);
    data.st_nlink = 1;
}

var global_fs: fatfs.FileSystem = undefined;
var workspace_buffer: [4096]u8 = undefined;
pub const FatFs = oop.DeriveFromBase(kernel.fs.IFileSystem, struct {
    const Self = @This();
    _allocator: std.mem.Allocator,
    _device: kernel.fs.IFile,
    _disk_wrapper: DiskWrapper,

    pub fn init(allocator: std.mem.Allocator, device: kernel.fs.IFile) !FatFs {
        var wrapper = DiskWrapper{ .device = try device.clone() };
        // Safe to do before the wrapper reaches its final address: it holds the
        // cache by slice, so moving the struct carries the reference along.
        wrapper.attach_cache(allocator);
        return FatFs.init(.{
            ._allocator = allocator,
            ._device = try device.clone(),
            ._disk_wrapper = wrapper,
        });
    }

    pub fn mount(self: *Self) i32 {
        log.debug("Mounting FAT filesystem", .{});
        // Whatever the cache still holds describes whichever medium was there
        // before this mount, which is not something a mount may assume.
        self._disk_wrapper.invalidate();
        fatfs.disks[0] = &self._disk_wrapper.interface;
        global_fs.mount("0:", true) catch |err| {
            log.err("Failed to mount FAT filesystem: {s}", .{@errorName(err)});
            return -1;
        };
        return 0;
    }

    pub fn delete(self: *Self) void {
        _ = self.umount();
        self._device.interface.delete();
        self._disk_wrapper.release_cache(self._allocator);
        self._disk_wrapper.device.interface.delete();
    }

    pub fn umount(self: *Self) i32 {
        log.debug("Unmounting FAT filesystem", .{});
        _ = self;
        fatfs.FileSystem.unmount("0:") catch |err| {
            log.err("Failed to unmount FAT filesystem: {s}", .{@errorName(err)});
            return -1;
        };
        return 0;
    }

    pub fn create(self: *Self, path: []const u8, _: i32) anyerror!void {
        const filepath = try self._allocator.dupeSentinel(u8, path, 0);
        defer self._allocator.free(filepath);
        var file = try fatfs.File.create(filepath);
        file.close();
    }

    pub fn mkdir(self: *Self, path: []const u8, _: i32) anyerror!void {
        const filepath = try self._allocator.dupeSentinel(u8, path, 0);
        defer self._allocator.free(filepath);
        _ = fatfs.mkdir(filepath) catch |err| {
            return fatfs_error_to_errno(err);
        };
    }

    pub fn unlink(self: *Self, path: []const u8) anyerror!void {
        const filepath = try self._allocator.dupeSentinel(u8, path, 0);
        defer self._allocator.free(filepath);
        try fatfs.unlink(filepath);
    }

    pub fn name(self: *const Self) []const u8 {
        _ = self;
        return "fatfs";
    }

    pub fn get(self: *Self, path: []const u8) anyerror!kernel.fs.Node {
        const filepath = try self._allocator.dupeSentinel(u8, path, 0);
        defer self._allocator.free(filepath);

        // Files first, and only once.
        //
        // Every FatFs entry point resolves the path by walking the directory,
        // and that walk is linear in the number of entries: measured at ~10 ms
        // in a 1685-entry directory against 0.15 ms in a small one. This used
        // to probe with Dir.open (one walk, which fails for a file) and then
        // open the file (a second walk), so opening a source in the test
        // corpus cost ~20 ms -- twice.
        //
        // File.open resolves the path once and hands back the handle the node
        // needs, so the common case is now a single walk. A directory costs
        // that failed probe plus one stat, which is what it cost before.
        if (FatFsFile.InstanceType.create_node(self._allocator, filepath)) |node| {
            return node;
        } else |_| {}

        // Not a file: stat says whether it is a directory or nothing at all.
        // The check matters -- FatFsDirectory.create tolerates a failed stat
        // and would happily produce a node for a path that does not exist.
        const maybe_info: ?fatfs.FileInfo = fatfs.stat(filepath) catch null;
        if (maybe_info) |info| {
            if (info.kind != .Directory) {
                return kernel.errno.ErrnoSet.NoEntry;
            }
            return try FatFsDirectory.InstanceType.create_node(self._allocator, filepath);
        }

        // FatFs cannot stat a volume root ("" or "/"), so confirm that one the
        // way this function always used to: by opening it as a directory.
        var dir = fatfs.Dir.open(filepath) catch return kernel.errno.ErrnoSet.NoEntry;
        dir.close();
        return try FatFsDirectory.InstanceType.create_node(self._allocator, filepath);
    }

    pub fn format(self: *Self) anyerror!void {
        fatfs.disks[0] = &self._disk_wrapper.interface;
        fatfs.mkfs(
            "0:",
            // `any` = best fit for the volume size. FAT32 needs >= 65525
            // clusters, which a small device (the 1 MB QEMU fatdisk window)
            // can never reach, so hardcoding it aborted mkfs there.
            .{ .filesystem = .any, .sector_align = 1, .use_partitions = false },
            &workspace_buffer,
        ) catch |err| {
            log.err("Failed to format FAT filesystem: {s}", .{@errorName(err)});
            return err;
        };
        _ = self.umount();
        _ = self.mount();
    }

    pub fn stat(self: *Self, path: []const u8, data: *c.struct_stat, follow_symlinks: bool) anyerror!void {
        _ = follow_symlinks;
        initialize_stat_identity(data, path);
        if (std.mem.eql(u8, path, "/") or path.len == 0) {
            data.st_mode = c.S_IFDIR;
            data.st_blksize = 512;
            return;
        }
        var path_c = try std.fmt.allocPrintSentinel(self._allocator, "0:/{s} ", .{path}, 0);
        path_c[path_c.len - 1] = 0; // Null-terminate
        defer self._allocator.free(path_c);
        const finfo = fatfs.stat(path_c) catch |err| {
            // NoFile/NoPath just mean "not on this filesystem" — an expected
            // negative result the VFS relies on for its symlink/cross-mount
            // fallback (vfs.stat re-resolves on failure). Logging it at err
            // level spams every stat that crosses a symlink (e.g. /tmp).
            switch (err) {
                error.NoFile, error.NoPath => {
                    log.debug("stat: path not found: {s}", .{path});
                },
                else => {
                    log.err("Failed to stat path: {s}, error: {s}", .{ path, @errorName(err) });
                },
            }
            return fatfs_error_to_errno(err);
        };
        data.st_blksize = 512;
        data.st_size = @intCast(finfo.size);
        data.st_mode = if (finfo.kind == .Directory) c.S_IFDIR else c.S_IFREG;
        data.st_blocks = @intCast((finfo.size + 511) / 512);
    }

    pub fn link(self: *Self, old_path: []const u8, new_path: []const u8) anyerror!void {
        _ = self;
        _ = old_path;
        _ = new_path;
        return error.NotSupported;
    }

    pub fn symlink(self: *Self, target: []const u8, linkpath: []const u8) anyerror!void {
        _ = self;
        _ = target;
        _ = linkpath;
        return error.NotSupported; // FAT has no symbolic links
    }

    pub fn supports_symlinks(self: *const Self) bool {
        _ = self;
        // FAT has no such directory entry, so a path under this mount can
        // never have a link in it and the VFS can skip looking.
        return false;
    }

    pub fn readlink(self: *Self, path: []const u8, buffer: []u8) anyerror!usize {
        _ = self;
        _ = path;
        _ = buffer;
        return kernel.errno.ErrnoSet.InvalidArgument; // not a symbolic link
    }

    pub fn access(self: *Self, path: []const u8, mode: i32, flags: i32) anyerror!void {
        _ = flags;
        var node = try self.get(path);
        node.delete();
        if ((mode & c.W_OK) != 0 or (mode & c.X_OK) != 0) {
            if (node.filetype() == kernel.fs.FileType.Directory) {
                return kernel.errno.ErrnoSet.IsADirectory;
            }
        }
    }

    const DiskWrapper = struct {
        const sector_size = 512;

        /// How much the write-combining buffer below can hold, in sectors.
        /// Eight covers the contiguous runs a compile emits without tying up
        /// more than 4 KiB.
        const combine_sectors: u32 = 8;
        const combine_bytes: usize = @as(usize, combine_sectors) * sector_size;

        // Read cache for the FAT metadata.
        //
        // FatFs reads file *data* straight into the caller's buffer, in runs of
        // as many sectors as the read spans. Everything else -- directory
        // entries, the allocation table -- goes through its single-sector
        // window, which asks for one sector per call. On an SD card a read is
        // almost entirely the command sequence around it rather than the 512
        // bytes: measured on the smoke rig, a sector fetched on its own costs
        // ~1.6 ms, while a sector inside a multi-block transfer costs ~0.13 ms.
        //
        // That gap is what made creating a file cost time proportional to how
        // many files the directory already held -- FAT walks the directory to
        // prove the name is new, and the walk paid the per-command price on
        // every sector it crossed. `open()` in a 600-file directory measured
        // 108 ms against 22 ms in a 100-file one, which is most of why pushing
        // the smoke corpus (2000 sources in one directory) crawled.
        //
        // So a single-sector read is served out of a line spanning
        // `line_sectors` consecutive sectors, filled by one multi-block read.
        // The walks that pay for this are sequential, so a line filled for one
        // sector serves the rest.
        const line_sectors: u32 = config.fatfs.cache_line_sectors;
        const line_count: usize = config.fatfs.cache_lines;
        const configured = line_sectors > 0 and line_count > 0;
        const line_bytes: usize = @as(usize, line_sectors) * sector_size;

        /// One cached run. `sectors` is zero when the line holds nothing, and
        /// short of `line_sectors` only for the line covering the end of the
        /// disk, which must not be read past.
        const Line = struct {
            base: fatfs.LBA = 0,
            sectors: u32 = 0,
            used: u32 = 0,
        };

        device: kernel.fs.IFile,
        /// Held by reference, never inline: the kernel's MSP stack is 16 KB
        /// (see the linker script) and a `FatFs` is built as a value before it
        /// reaches the allocator, so an inline buffer of any useful size
        /// overflows that stack during boot -- which it did, silently, as a
        /// double fault before the console was up.
        ///
        /// Both are empty when the cache is configured away, and also when the
        /// kernel heap could not spare the room -- 76 KB is all of it. A
        /// filesystem that reads a little slower is a far better outcome than
        /// one that refuses to mount.
        lines: []Line = &.{},
        cache: []u8 = &.{},

        // ── Write combining ────────────────────────────────────────────────
        //
        // FatFs hands the block layer one sector at a time, and on this card a
        // single-block write costs ~875 us against ~113 us a block inside a
        // multi-block one. The difference is the card's program cycle, which is
        // paid per command: the TX PIO program will not report a write until
        // the card releases DAT0 (`wait_idle` in sdio_rp2350.pio), so a
        // one-sector write waits out the whole cycle to move 512 bytes.
        //
        // A compile's writes are not scattered. Traced, one emits sectors
        // 1200, 1201, 1202 consecutively, then rewrites 1200, the FAT sector
        // and the directory sector. Holding one contiguous run and issuing it
        // as a single multi-block write turns those three commands into one,
        // and a rewrite of a sector still in the buffer into none.
        //
        // This is only safe because FatFs asks: sync_fs() ends in
        // disk_ioctl(CTRL_SYNC), and it runs from f_close, f_sync, f_unlink,
        // f_mkdir and f_rename -- every point at which the medium is supposed
        // to be consistent. `ioctl(.sync)` below is that flush, and was a
        // no-op before this.
        combine: []u8 = &.{},
        combine_base: fatfs.LBA = 0,
        combine_count: u32 = 0,
        /// Counter standing in for time in the LRU choice; nothing here needs a
        /// real clock, only an order. It is 32 bits and wraps, which keeps this
        /// struct 4-byte aligned so `@fieldParentPtr` can reach it from the disk
        /// interface below. A wrap costs one poorly chosen eviction, never a
        /// wrong answer: a line is matched on the sectors it holds, and this
        /// only decides which one to give up.
        clock: u32 = 0,
        /// Filled on first use. Zero means "not known yet", which is also what
        /// a device that cannot report its size leaves it as -- lines are then
        /// never shortened, which is correct for every device that can.
        sectors_on_disk: fatfs.LBA = 0,

        interface: fatfs.Disk = fatfs.Disk{
            .getStatusFn = &getStatus,
            .initializeFn = &initialize,
            .readFn = &read,
            .writeFn = &write,
            .ioctlFn = &ioctl,
        },

        pub fn getStatus(self: *fatfs.Disk) fatfs.Disk.Status {
            _ = self;
            return .{
                .initialized = true,
                .disk_present = true,
                .write_protected = false,
            };
        }

        pub fn initialize(interface: *fatfs.Disk) fatfs.Disk.Error!fatfs.Disk.Status {
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            return getStatus(&self.interface);
        }

        /// Attach a cache, or leave the wrapper reading straight through when
        /// the configuration asks for none or the heap cannot spare it.
        pub fn attach_cache(self: *DiskWrapper, allocator: std.mem.Allocator) void {
            if (!configured) return;
            const cache = allocator.alloc(u8, line_count * line_bytes) catch {
                log.warn("no room for the {d} KiB FAT cache; reading through", .{(line_count * line_bytes) / 1024});
                return;
            };
            const lines = allocator.alloc(Line, line_count) catch {
                allocator.free(cache);
                return;
            };
            @memset(lines, .{});
            self.cache = cache;
            self.lines = lines;
            // Write combining is independent of the read cache; without the
            // buffer every write simply goes through as before.
            self.combine = allocator.alloc(u8, combine_bytes) catch &.{};
        }

        pub fn release_cache(self: *DiskWrapper, allocator: std.mem.Allocator) void {
            // Anything still buffered belongs on the medium before the buffer
            // holding it goes away.
            self.flush_combined() catch |err| {
                log.err("failed to flush combined writes on release: {s}", .{@errorName(err)});
            };
            allocator.free(self.cache);
            allocator.free(self.lines);
            allocator.free(self.combine);
            self.cache = &.{};
            self.lines = &.{};
            self.combine = &.{};
        }

        /// Issue whatever the combining buffer holds, as one write.
        fn flush_combined(self: *DiskWrapper) fatfs.Disk.Error!void {
            if (self.combine_count == 0) return;
            const count = self.combine_count;
            const base = self.combine_base;
            // Cleared first: a failed write must not leave the run queued for
            // a later flush to retry against a device that already rejected it.
            self.combine_count = 0;
            try self.write_through(self.combine.ptr, base, count);
        }

        /// Take a write into the combining buffer, issuing whatever it has to
        /// in order to do so.
        ///
        /// Four cases, in the order they are worth taking:
        ///   - the run is already long enough to amortise its own command, so
        ///     it goes straight out (after flushing, to keep ordering);
        ///   - it continues the buffered run, and is appended;
        ///   - it lands inside the buffered run, and overwrites it in place --
        ///     this is the rewrite of a directory sector that would otherwise
        ///     cost a second full command;
        ///   - it goes somewhere else, so the buffer is issued and the new
        ///     write starts a fresh run.
        fn write_combined(self: *DiskWrapper, from: [*]const u8, sector: fatfs.LBA, count: u32) fatfs.Disk.Error!void {
            if (self.combine.len == 0 or count >= combine_sectors) {
                try self.flush_combined();
                return self.write_through(from, sector, count);
            }

            const length = sector_size * count;

            if (self.combine_count != 0) {
                const base = self.combine_base;
                const held = self.combine_count;
                if (sector == base + held and held + count <= combine_sectors) {
                    @memcpy(self.combine[held * sector_size ..][0..length], from[0..length]);
                    self.combine_count = held + count;
                    return;
                }
                if (sector >= base and sector + count <= base + held) {
                    const at: usize = @intCast(sector - base);
                    @memcpy(self.combine[at * sector_size ..][0..length], from[0..length]);
                    return;
                }
                try self.flush_combined();
            }

            @memcpy(self.combine[0..length], from[0..length]);
            self.combine_base = sector;
            self.combine_count = count;
        }

        /// True when *sector*..+*count* overlaps what is buffered but not yet
        /// written, which a read has to resolve before going to the device.
        fn overlaps_combined(self: *const DiskWrapper, sector: fatfs.LBA, count: u32) bool {
            if (self.combine_count == 0) return false;
            return sector < self.combine_base + self.combine_count and
                self.combine_base < sector + count;
        }

        fn caching(self: *const DiskWrapper) bool {
            return self.lines.len != 0;
        }

        /// Drop everything cached, for when what is on the card stops being
        /// what we last saw it as: a mount, or a reformat.
        pub fn invalidate(self: *DiskWrapper) void {
            for (self.lines) |*line| {
                line.sectors = 0;
            }
            // Dropped rather than flushed on purpose: this runs at mount and
            // at reformat, where whatever is buffered describes a volume that
            // is no longer the one on the card. Writing it out would put one
            // volume's sectors onto another.
            self.combine_count = 0;
            self.sectors_on_disk = 0;
        }

        fn tick(self: *DiskWrapper) u32 {
            self.clock +%= 1;
            return self.clock;
        }

        fn disk_sectors(self: *DiskWrapper) fatfs.LBA {
            if (self.sectors_on_disk == 0) {
                const size = self.device.interface.size();
                if (size > 0) {
                    self.sectors_on_disk = @intCast(size >> 9);
                }
            }
            return self.sectors_on_disk;
        }

        fn line_data(self: *const DiskWrapper, index: usize) []u8 {
            return self.cache[index * line_bytes .. (index + 1) * line_bytes];
        }

        /// The device I/O itself, with the seek and the transfer kept together
        /// under one critical section so nothing can reposition the device
        /// between them. Everything the cache does around this runs with
        /// interrupts on.
        fn read_through(self: *DiskWrapper, into: [*]u8, sector: fatfs.LBA, count: u32) fatfs.Disk.Error!void {
            const state = arch.sync.save_and_disable_interrupts();
            defer arch.sync.restore_interrupts(state);
            const position = self.device.interface.seek(@as(i64, @intCast(sector)) * sector_size, c.SEEK_SET) catch return error.IoError;
            if (position < 0) return error.IoError;
            const length = sector_size * count;
            if (self.device.interface.read(into[0..length]) != length) {
                return error.IoError;
            }
        }

        fn write_through(self: *DiskWrapper, from: [*]const u8, sector: fatfs.LBA, count: u32) fatfs.Disk.Error!void {
            const state = arch.sync.save_and_disable_interrupts();
            defer arch.sync.restore_interrupts(state);
            const position = self.device.interface.seek(@as(i64, @intCast(sector)) * sector_size, c.SEEK_SET) catch return error.IoError;
            if (position < 0) return error.IoError;
            const length = sector_size * count;
            if (self.device.interface.write(from[0..length]) != length) {
                return error.IoError;
            }
        }

        /// Index of the line holding *sector*, filling one if none does.
        fn line_for(self: *DiskWrapper, sector: fatfs.LBA) fatfs.Disk.Error!usize {
            // Unreachable through `read`, which serves everything directly when
            // there is no cache; said here too so a zero line size cannot reach
            // the modulo below.
            if (!configured or !self.caching()) return error.IoError;
            const base = sector - (sector % line_sectors);
            var victim: usize = 0;
            for (0..self.lines.len) |index| {
                const line = self.lines[index];
                if (line.sectors != 0 and line.base == base and sector - base < line.sectors) {
                    self.lines[index].used = self.tick();
                    return index;
                }
                if (line.used < self.lines[victim].used) {
                    victim = index;
                }
            }

            var sectors: u32 = line_sectors;
            const total = self.disk_sectors();
            if (total != 0 and base + sectors > total) {
                sectors = @intCast(total - base);
            }
            // Marked empty across the read so a failure cannot leave a line
            // that claims to hold sectors it never received.
            self.lines[victim].sectors = 0;
            try self.read_through(self.line_data(victim).ptr, base, sectors);
            self.lines[victim] = .{ .base = base, .sectors = sectors, .used = self.tick() };
            return victim;
        }

        pub fn read(interface: *fatfs.Disk, buff: [*]u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            // The device does not have the buffered run yet, so a read that
            // covers any of it has to make it real first. Reads served from
            // the line cache would be correct either way -- write() refreshes
            // the lines it touches -- but a miss goes straight to the card.
            if (self.overlaps_combined(sector, @intCast(count))) {
                try self.flush_combined();
            }
            // A run this long already amortises the per-command cost the cache
            // exists to remove, and filling lines for it would evict more than
            // it saves. File data arrives here.
            if (!self.caching() or count >= line_sectors) {
                return self.read_through(buff, sector, @intCast(count));
            }

            var done: u32 = 0;
            while (done < count) {
                const wanted = sector + done;
                const index = try self.line_for(wanted);
                const line = self.lines[index];
                const offset: u32 = @intCast(wanted - line.base);
                if (offset >= line.sectors) {
                    // Past the end of the disk; the device is the one entitled
                    // to say so.
                    return self.read_through(buff + done * sector_size, wanted, count - done);
                }
                const available = @min(count - done, line.sectors - offset);
                @memcpy(
                    buff[done * sector_size .. (done + available) * sector_size],
                    self.line_data(index)[offset * sector_size .. (offset + available) * sector_size],
                );
                done += available;
            }
        }

        pub fn write(interface: *fatfs.Disk, buff: [*]const u8, sector: fatfs.LBA, count: c_uint) fatfs.Disk.Error!void {
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            log.debug("Writing to sector {d}, count {d}", .{ sector, count });
            try self.write_combined(buff, sector, @intCast(count));
            if (!self.caching()) return;

            // Refresh what we hold rather than dropping it. Every file creation
            // writes a directory entry into the sectors it has just searched,
            // and invalidating there would make the next creation re-read the
            // run we still have -- which is exactly the cost being removed.
            for (0..self.lines.len) |index| {
                const line = self.lines[index];
                if (line.sectors == 0) continue;
                const first = @max(line.base, sector);
                const last = @min(line.base + line.sectors, sector + count);
                if (first >= last) continue;
                const into: usize = @as(usize, @intCast(first - line.base)) * sector_size;
                const from: usize = @as(usize, @intCast(first - sector)) * sector_size;
                const length: usize = @as(usize, @intCast(last - first)) * sector_size;
                @memcpy(self.line_data(index)[into .. into + length], buff[from .. from + length]);
            }
        }

        pub fn ioctl(interface: *fatfs.Disk, cmd: fatfs.IoCtl, buff: [*]u8) fatfs.Disk.Error!void {
            const state = arch.sync.save_and_disable_interrupts();
            defer arch.sync.restore_interrupts(state);
            const self: *DiskWrapper = @fieldParentPtr("interface", interface);
            switch (cmd) {
                // Was a no-op, which was correct only while every write went
                // straight to the card. Writes are now combined, so this is
                // what makes FatFs's "the volume is consistent" true.
                .sync => try self.flush_combined(),
                .get_sector_count => {
                    const size = self.device.interface.size();
                    @as(*align(1) fatfs.LBA, @ptrCast(buff)).* = @intCast(size >> 9);
                },
                else => {
                    log.err("invalid ioctl: {}", .{cmd});
                    return error.InvalidParameter;
                },
            }
        }
    };
});

pub fn create_fs_for_test() !kernel.fs.IFileSystem {
    const FatFsDeviceFileStub = @import("tests/device_stub.zig").FatFsDeviceFileStub;
    var device_file = try (try FatFsDeviceFileStub.InstanceType.create(std.testing.allocator, null)).interface.new(std.testing.allocator);
    defer device_file.interface.delete();
    return try (try FatFs.InstanceType.init(std.testing.allocator, device_file)).interface.new(std.testing.allocator);
}

test "FatFs.ShouldMountAfterFormat" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    const mount_result = fs.interface.mount();
    try std.testing.expectEqual(-1, mount_result);

    try fs.interface.format();
    try std.testing.expectEqual(0, fs.interface.mount());
}

test "FatFs.ShouldReturnCorrectName" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    const fs_name = fs.interface.name();
    try std.testing.expectEqualStrings("fatfs", fs_name);
}

fn create_write_and_verify(fs: *kernel.fs.IFileSystem, path: []const u8, data: []const u8) !void {
    try fs.interface.create(path, 0o644);
    var node = try fs.interface.get(path);
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    if (maybe_file) |*file| {
        const bytes_written = file.interface.write(data);
        try std.testing.expectEqual(@as(isize, @intCast(data.len)), bytes_written);

        // Seek back to beginning
        const seek_result = file.interface.seek(0, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 0), seek_result);

        // Read back the data
        var read_buffer = std.testing.allocator.alloc(u8, data.len) catch unreachable;
        defer std.testing.allocator.free(read_buffer);
        const bytes_read = file.interface.read(read_buffer);
        try std.testing.expectEqual(@as(isize, @intCast(data.len)), bytes_read);
        try std.testing.expectEqualStrings(data, read_buffer[0..@intCast(bytes_read)]);
    }
    // Delete the node to close the file
    node.delete();
}

test "FatFs.ShouldCreateFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try create_write_and_verify(&fs, "/test.txt", "Hello, FatFs!");
    // Remove the file
    try fs.interface.unlink("/test.txt");

    // Verify file no longer exists
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.get("/test.txt"));
}

test "FatFs.ShouldCreateDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create root directory
    try fs.interface.mkdir("/testdir", 0o755);

    // Create nested directories
    try fs.interface.mkdir("/testdir/subdir1", 0o755);
    try fs.interface.mkdir("/testdir/subdir1/subdir2", 0o755);

    // Verify directories exist
    var node1 = try fs.interface.get("/testdir");
    defer node1.delete();
    try std.testing.expect(node1.is_directory());

    var node2 = try fs.interface.get("/testdir/subdir1");
    defer node2.delete();
    try std.testing.expect(node2.is_directory());

    var node3 = try fs.interface.get("/testdir/subdir1/subdir2");
    defer node3.delete();
    try std.testing.expect(node3.is_directory());

    // Write to files in different directories
    const test_data = [_]struct { path: []const u8, content: []const u8 }{
        .{ .path = "/testdir/file1.txt", .content = "Root level file" },
        .{ .path = "/testdir/subdir1/file2.txt", .content = "First nested file" },
        .{ .path = "/testdir/subdir1/subdir2/file3.txt", .content = "Deep nested file" },
    };

    for (test_data) |data| {
        try create_write_and_verify(&fs, data.path, data.content);
    }
}

test "FatFs.ShouldStatRootDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    var stat_buf: c.struct_stat = undefined;
    try fs.interface.stat("", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
    try std.testing.expectEqual(0, stat_buf.st_size);
}

test "FatFs.ShouldStatFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);

    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var stat_buf: c.struct_stat = undefined;
    try fs.interface.stat("/test.txt", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFREG), stat_buf.st_mode);
}

test "FatFs.ShouldStatDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/testdir", 0o755);

    var stat_buf: c.struct_stat = undefined;
    try fs.interface.stat("/testdir", &stat_buf, true);

    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
}

test "FatFs.ShouldStatNestedDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/parent", 0o755);
    try fs.interface.mkdir("/parent/child", 0o755);
    try fs.interface.mkdir("/parent/child/grandchild", 0o755);

    // Test stat for each level
    var stat_buf: c.struct_stat = undefined;

    try fs.interface.stat("/parent", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);

    try fs.interface.stat("/parent/child", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);

    try fs.interface.stat("/parent/child/grandchild", &stat_buf, true);
    try std.testing.expectEqual(@as(c_uint, c.S_IFDIR), stat_buf.st_mode);
}

test "FatFs.ShouldAccessFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);

    // Test read access
    try fs.interface.access("/test.txt", c.R_OK, 0);

    // Test file existence
    try fs.interface.access("/test.txt", c.F_OK, 0);

    // Test non-existent file
    try std.testing.expectError(kernel.errno.ErrnoSet.NoEntry, fs.interface.access("/nonexistent.txt", c.F_OK, 0));
}

test "FatFs.ShouldAccessDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/testdir", 0o755);

    // Test directory access
    try fs.interface.access("/testdir", c.F_OK, 0);

    // Test write access on directory should fail with IsADirectory
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, fs.interface.access("/testdir", c.W_OK, 0));

    // Test execute access on directory should fail with IsADirectory
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, fs.interface.access("/testdir", c.X_OK, 0));
}

test "FatFs.ShouldRejectLinkOperation" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/old.txt", 0o644);

    // Link operation should not be supported
    try std.testing.expectError(error.NotSupported, fs.interface.link("/old.txt", "/new.txt"));
}

fn traverse_directory(fs: *kernel.fs.IFileSystem, path: []const u8, expectations: []const kernel.fs.DirectoryEntry) !void {
    var root_node = try fs.interface.get(path);
    defer root_node.delete();

    try std.testing.expect(root_node.is_directory());

    var maybe_dir = root_node.as_directory();
    try std.testing.expect(maybe_dir != null);

    if (maybe_dir) |*dir| {
        var iterator = try dir.interface.iterator();
        defer iterator.interface.delete();

        var found_entries = try std.ArrayList(kernel.fs.DirectoryEntry).initCapacity(std.testing.allocator, expectations.len);
        defer found_entries.deinit(std.testing.allocator);

        while (iterator.interface.next()) |entry| {
            const e = kernel.fs.DirectoryEntry{
                .name = try std.testing.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            };
            try found_entries.append(std.testing.allocator, e);
        }

        errdefer {
            for (found_entries.items) |found_entry| {
                std.testing.allocator.free(found_entry.name);
            }
        }

        for (expectations) |expected_entry| {
            var found = false;
            for (found_entries.items, 0..) |found_entry, i| {
                if (std.mem.eql(u8, expected_entry.name, found_entry.name) and
                    expected_entry.kind == found_entry.kind)
                {
                    const n = found_entries.orderedRemove(i);
                    std.testing.allocator.free(n.name);
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
        }
        try std.testing.expectEqual(@as(usize, 0), found_entries.items.len);
    }
}

test "FatFs.ShouldIterateRootDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create some files and directories in root
    try fs.interface.create("/file1.txt", 0o644);
    try fs.interface.create("/file2.txt", 0o644);
    try fs.interface.mkdir("/dir1", 0o755);
    try fs.interface.mkdir("/dir2", 0o755);

    const expected_entries: [4]kernel.fs.DirectoryEntry = [_]kernel.fs.DirectoryEntry{
        .{ .name = "file1.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "file2.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "dir1", .kind = kernel.fs.FileType.Directory },
        .{ .name = "dir2", .kind = kernel.fs.FileType.Directory },
    };
    try traverse_directory(&fs, "/", &expected_entries);
}

test "FatFs.ShouldIterateNestedDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create nested structure
    try fs.interface.mkdir("/parent", 0o755);
    try fs.interface.create("/parent/file1.txt", 0o644);
    try fs.interface.create("/parent/file2.txt", 0o644);
    try fs.interface.create("/parent/file3.txt", 0o644);
    try fs.interface.mkdir("/parent/subdir1", 0o755);
    try fs.interface.mkdir("/parent/subdir2", 0o755);

    const expected_entries: [5]kernel.fs.DirectoryEntry = [_]kernel.fs.DirectoryEntry{
        .{ .name = "file1.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "file2.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "file3.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "subdir1", .kind = kernel.fs.FileType.Directory },
        .{ .name = "subdir2", .kind = kernel.fs.FileType.Directory },
    };
    try traverse_directory(&fs, "/parent", &expected_entries);
}

test "FatFs.ShouldIterateDeeplyNestedDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Create deeply nested structure
    try fs.interface.mkdir("/level1", 0o755);
    try fs.interface.mkdir("/level1/level2", 0o755);
    try fs.interface.mkdir("/level1/level2/level3", 0o755);
    try fs.interface.create("/level1/level2/level3/deep_file1.txt", 0o644);
    try fs.interface.create("/level1/level2/level3/deep_file2.txt", 0o644);
    try fs.interface.mkdir("/level1/level2/level3/deep_dir", 0o755);

    const expected_entries: [3]kernel.fs.DirectoryEntry = [_]kernel.fs.DirectoryEntry{
        .{ .name = "deep_file1.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "deep_file2.txt", .kind = kernel.fs.FileType.File },
        .{ .name = "deep_dir", .kind = kernel.fs.FileType.Directory },
    };
    try traverse_directory(&fs, "/level1/level2/level3", &expected_entries);
}

test "FatFs.ShouldIterateEmptyDirectory" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.mkdir("/empty_dir", 0o755);

    var empty_node = try fs.interface.get("/empty_dir");
    defer empty_node.delete();

    try std.testing.expect(empty_node.is_directory());

    var maybe_dir = empty_node.as_directory();
    try std.testing.expect(maybe_dir != null);

    if (maybe_dir) |*dir| {
        var iterator = try dir.interface.iterator();
        defer iterator.interface.delete();

        var entry_count: usize = 0;
        while (iterator.interface.next()) |_| {
            entry_count += 1;
        }

        try std.testing.expectEqual(@as(usize, 0), entry_count);
    }
}

test "FatFs.ShouldSeekInFile" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    const test_data = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    try fs.interface.create("/seektest.txt", 0o644);
    var node = try fs.interface.get("/seektest.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        // Write test data
        const bytes_written = file.interface.write(test_data);
        try std.testing.expectEqual(@as(isize, @intCast(test_data.len)), bytes_written);

        // Test SEEK_SET - seek to beginning
        var pos = try file.interface.seek(0, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 0), pos);

        var buffer: [10]u8 = undefined;
        var bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("0123456789", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_SET - seek to position 20
        pos = try file.interface.seek(20, c.SEEK_SET);
        try std.testing.expectEqual(@as(c.off_t, 20), pos);

        bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("KLMNOPQRST", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_CUR - seek forward 5 bytes from current position (30)
        pos = try file.interface.seek(5, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, 35), pos);

        bytes_read = file.interface.read(buffer[0..2]);
        try std.testing.expectEqual(@as(isize, 1), bytes_read);
        try std.testing.expectEqualStrings("Z", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_CUR - seek backward 10 bytes from current position (37)
        pos = try file.interface.seek(-10, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, 26), pos);

        bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("QRSTUVWXY", buffer[0..9]);

        // Test SEEK_END - seek to end of file
        pos = try file.interface.seek(0, c.SEEK_END);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), pos);

        // Test SEEK_END - seek 10 bytes before end
        pos = try file.interface.seek(-10, c.SEEK_END);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len - 10)), pos);

        bytes_read = file.interface.read(&buffer);
        try std.testing.expectEqual(@as(isize, 10), bytes_read);
        try std.testing.expectEqualStrings("QRSTUVWXYZ", buffer[0..@intCast(bytes_read)]);

        // Test SEEK_CUR with 0 offset (should return current position without moving)
        pos = try file.interface.seek(0, c.SEEK_CUR);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), pos);
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), file.interface.tell());

        // Test invalid seek (negative position with SEEK_SET)
        try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(-1, c.SEEK_SET));
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), file.interface.tell());

        // Test invalid seek (beyond end of file with SEEK_SET) - FatFS allows seeking beyond EOF
        // so we skip this test for FatFS

        // Test invalid seek whence
        try std.testing.expectError(kernel.errno.ErrnoSet.InvalidArgument, file.interface.seek(10, -123));
        try std.testing.expectEqual(@as(c.off_t, @intCast(test_data.len)), file.interface.tell());
    }
}

test "FatFs.ShouldReturnNotMemoryMapped" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);
    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        var status: kernel.fs.FileMemoryMapAttributes = undefined;
        try std.testing.expectEqual(-1, file.interface.ioctl(-1, &status));
        try std.testing.expectEqual(0, file.interface.ioctl(@intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus), &status));
        try std.testing.expectEqual(false, status.is_memory_mapped);
    }
}

test "FatFs.ShouldReturnCorrectFileType" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Test file type
    try fs.interface.create("/test_file.txt", 0o644);
    var file_node = try fs.interface.get("/test_file.txt");
    defer file_node.delete();

    try std.testing.expectEqual(kernel.fs.FileType.File, file_node.filetype());
    try fs.interface.mkdir("/test_dir", 0o755);
    var dir_node = try fs.interface.get("/test_dir");
    defer dir_node.delete();

    try std.testing.expectEqual(kernel.fs.FileType.Directory, dir_node.filetype());
}

test "FatFs.ShouldAlwaysReturnZeroForFcntl" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    try fs.interface.create("/test.txt", 0o644);
    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    try std.testing.expect(node.is_file());

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        var data: i32 = 0;
        try std.testing.expectEqual(0, file.interface.fcntl(-1, &data));
        try std.testing.expectEqual(0, data);
        try std.testing.expectEqual(0, file.interface.fcntl(-123, null));
        try std.testing.expectEqual(0, file.interface.fcntl(0, &data));
        try std.testing.expectEqual(0, file.interface.fcntl(999, null));
    }
}

test "FatFs.ShouldReturnCorrectFileSize" {
    var fs = try create_fs_for_test();
    defer fs.interface.delete();

    try fs.interface.format();
    _ = fs.interface.mount();
    defer _ = fs.interface.umount();

    // Test empty file
    try fs.interface.create("/empty.txt", 0o644);
    var empty_node = try fs.interface.get("/empty.txt");
    defer empty_node.delete();

    try std.testing.expect(empty_node.is_file());
    if (empty_node.as_file()) |f| {
        try std.testing.expectEqual(0, f.interface.size());
    }

    // Test file with content
    const test_data = "Hello, FatFs! This is a test file.";
    try fs.interface.create("/test.txt", 0o644);
    var node = try fs.interface.get("/test.txt");
    defer node.delete();

    var maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);

    if (maybe_file) |*file| {
        _ = file.interface.write(test_data);
        try std.testing.expectEqual(test_data.len, file.interface.size());
    }

    // Re-open file and verify size persists
    node.delete();
    var reopened_node = try fs.interface.get("/test.txt");
    defer reopened_node.delete();
    if (reopened_node.as_file()) |f| {
        try std.testing.expectEqual(test_data.len, f.interface.size());
    }

    // Test large file
    const large_data = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(large_data);
    @memset(large_data, 'X');

    try fs.interface.create("/large.txt", 0o644);
    var large_node = try fs.interface.get("/large.txt");
    defer large_node.delete();

    var maybe_large_file = large_node.as_file();
    if (maybe_large_file) |*file| {
        _ = file.interface.write(large_data);
        try std.testing.expectEqual(4096, file.interface.size());
    }
}
