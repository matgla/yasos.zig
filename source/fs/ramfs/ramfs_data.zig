//
// ramfs_data.zig
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

///! This module provides basic file implementation for RamFS filesystem.
///!
///! A body lives either in the filesystem's memory arena or, when the RamFs was
///! given a `Tier` and the body outgrew it, in a file on a backing filesystem
///! (see ramfs_tier.zig). The two are behind the accessors below rather than
///! behind the file handle, so a spill is immediately visible to every handle
///! and every hard link that shares this body.
const std = @import("std");

const c = @import("libc_imports").c;

const kernel = @import("kernel");
const log = kernel.log;

const Tier = @import("ramfs_tier.zig").Tier;
const refcount = kernel.sync.refcount;

pub const RamFsDataError = error{
    FileNameTooLong,
};

var inode_counter: u32 = 1;

/// Bytes written per call while padding a spilled body out to a new length.
const pad_chunk = 64;

/// Capacity granularity for a tiered body. Matches the default arena page size
/// (CONFIG_TMPFS_PAGE_SIZE); a mismatch only costs a little slack.
const growth_granularity = 256;

const SpilledBody = struct {
    file: kernel.fs.IFile,
    length: usize,
    id: u32,
};

const Storage = union(enum) {
    ram: std.ArrayListAligned(u8, .@"8"),
    spilled: SpilledBody,
};

pub const RamFsData = struct {
    /// File contents
    _allocator: std.mem.Allocator,
    /// Buffer for filename, do not use it except of this module, instead please use: `RamFsData.name`
    // name: []u8,
    storage: Storage,
    /// Spill policy, or null for a filesystem that is RAM-only.
    tier: ?*Tier,
    refcounter: *i16,
    inode: u32,

    pub fn create(allocator: std.mem.Allocator) !RamFsData {
        return create_tiered(allocator, null);
    }

    pub fn create_tiered(allocator: std.mem.Allocator, tier: ?*Tier) !RamFsData {
        const obj = RamFsData{
            ._allocator = allocator,
            .storage = .{ .ram = try std.ArrayListAligned(u8, .@"8").initCapacity(allocator, 0) },
            .tier = tier,
            .refcounter = try allocator.create(i16),
            .inode = inode_counter,
        };
        refcount.init(obj.refcounter);
        return obj;
    }

    pub fn share(self: *RamFsData) *RamFsData {
        refcount.acquire(self.refcounter);
        return self;
    }

    pub fn deinit(self: *RamFsData) bool {
        // Fused decrement-and-test: read back separately, two contexts dropping
        // the last two references can both see zero and both free the body.
        if (refcount.release(self.refcounter)) {
            switch (self.storage) {
                .ram => |*list| list.deinit(self._allocator),
                .spilled => |*body| {
                    body.file.interface.delete();
                    if (self.tier) |tier| {
                        tier.remove_body(body.id);
                    }
                },
            }
            self._allocator.destroy(self.refcounter);
            return true;
        }
        return false;
    }

    pub fn is_in_memory(self: *const RamFsData) bool {
        return std.meta.activeTag(self.storage) == .ram;
    }

    pub fn len(self: *const RamFsData) usize {
        return switch (self.storage) {
            .ram => |list| list.items.len,
            .spilled => |body| body.length,
        };
    }

    pub fn read_at(self: *RamFsData, position: usize, buffer: []u8) isize {
        const total = self.len();
        if (position >= total) {
            return 0;
        }
        const count = @min(total - position, buffer.len);
        if (count == 0) {
            return 0;
        }
        switch (self.storage) {
            .ram => |*list| {
                @memcpy(buffer[0..count], list.items[position .. position + count]);
                return @intCast(count);
            },
            .spilled => |*body| {
                _ = body.file.interface.seek(@intCast(position), c.SEEK_SET) catch return -1;
                var done: usize = 0;
                while (done < count) {
                    const read_bytes = body.file.interface.read(buffer[done..count]);
                    if (read_bytes <= 0) {
                        break;
                    }
                    done += @intCast(read_bytes);
                }
                return @intCast(done);
            },
        }
    }

    pub fn write_at(self: *RamFsData, position: usize, bytes: []const u8) !usize {
        if (bytes.len == 0) {
            return 0;
        }
        if (self.is_in_memory()) {
            if (self.tier) |tier| {
                const end = position + bytes.len;
                const grows = end > self.storage.ram.items.len;
                if (end > tier.max_file_bytes or (grows and tier.arena_is_low())) {
                    try self.spill();
                }
            }
        }
        if (self.is_in_memory()) {
            const end = position + bytes.len;
            if (end > self.storage.ram.items.len) {
                self.resize_in_memory(end, 0) catch |err| {
                    if (self.tier == null) {
                        return err;
                    }
                    try self.spill();
                    return self.write_spilled(position, bytes);
                };
            }
            @memcpy(self.storage.ram.items[position..end], bytes);
            return bytes.len;
        }
        return self.write_spilled(position, bytes);
    }

    /// Grow (padding with `fill`) or shrink the body to `length`.
    pub fn resize(self: *RamFsData, length: usize, fill: u8) !void {
        if (self.is_in_memory()) {
            if (self.tier) |tier| {
                const grows = length > self.storage.ram.items.len;
                if (length > tier.max_file_bytes or (grows and tier.arena_is_low())) {
                    try self.spill();
                }
            }
        }
        if (self.is_in_memory()) {
            self.resize_in_memory(length, fill) catch |err| {
                if (self.tier == null) {
                    return err;
                }
                try self.spill();
                return self.resize_spilled(length, fill);
            };
            return;
        }
        return self.resize_spilled(length, fill);
    }

    fn resize_in_memory(self: *RamFsData, length: usize, fill: u8) !void {
        var list = &self.storage.ram;
        const old_length = list.items.len;
        if (length <= old_length) {
            list.shrinkRetainingCapacity(length);
            return;
        }
        if (self.tier == null) {
            // A plain RamFs sits on the kernel heap, where doubling is the right
            // trade and what the allocator underneath expects.
            try list.ensureTotalCapacity(self._allocator, length);
        } else {
            // A tiered one sits on a small arena, where doubling a file that is
            // already half of it fails outright. Grow by whole arena pages
            // instead: the page allocator extends in place while the pages above
            // are free, so an append-only writer normally pays no copy at all,
            // and rounding up keeps a byte-at-a-time writer from asking on every
            // call.
            try list.ensureTotalCapacityPrecise(
                self._allocator,
                std.mem.alignForward(usize, length, growth_granularity),
            );
        }
        list.items.len = length;
        @memset(list.items[old_length..length], fill);
    }

    fn write_spilled(self: *RamFsData, position: usize, bytes: []const u8) !usize {
        if (position > self.storage.spilled.length) {
            try self.resize_spilled(position, 0);
        }
        var body = &self.storage.spilled;
        _ = body.file.interface.seek(@intCast(position), c.SEEK_SET) catch
            return kernel.errno.ErrnoSet.InputOutputError;
        var done: usize = 0;
        while (done < bytes.len) {
            const written = body.file.interface.write(bytes[done..]);
            if (written <= 0) {
                return kernel.errno.ErrnoSet.InputOutputError;
            }
            done += @intCast(written);
        }
        if (position + done > body.length) {
            body.length = position + done;
        }
        return done;
    }

    fn resize_spilled(self: *RamFsData, length: usize, fill: u8) !void {
        var body = &self.storage.spilled;
        if (length == body.length) {
            return;
        }
        if (length < body.length) {
            try body.file.interface.truncate(length);
            body.length = length;
            return;
        }
        _ = body.file.interface.seek(@intCast(body.length), c.SEEK_SET) catch
            return kernel.errno.ErrnoSet.InputOutputError;
        var padding: [pad_chunk]u8 = undefined;
        @memset(&padding, fill);
        var left = length - body.length;
        while (left > 0) {
            const written = body.file.interface.write(padding[0..@min(left, padding.len)]);
            if (written <= 0) {
                return kernel.errno.ErrnoSet.InputOutputError;
            }
            left -= @intCast(written);
        }
        body.length = length;
    }

    /// Move the body out of the arena and onto the tier's backing filesystem.
    fn spill(self: *RamFsData) !void {
        const tier = self.tier orelse return kernel.errno.ErrnoSet.OutOfMemory;
        if (!self.is_in_memory()) {
            return;
        }

        const id = tier.next_identifier();
        var file = try tier.open_body(id);
        errdefer {
            file.interface.delete();
            tier.remove_body(id);
        }

        const body = self.storage.ram.items;
        const body_length = body.len;
        var done: usize = 0;
        while (done < body_length) {
            const written = file.interface.write(body[done..]);
            if (written <= 0) {
                return kernel.errno.ErrnoSet.InputOutputError;
            }
            done += @intCast(written);
        }

        var previous = self.storage.ram;
        self.storage = .{ .spilled = .{ .file = file, .length = body_length, .id = id } };
        previous.deinit(self._allocator);
        tier.account_spill(body_length);
        log.debug("ramfs: spilled {d} bytes of inode {d} to body {d}", .{ body_length, self.inode, id });
    }
};

test "RamFsData.ShouldAppendToFile" {
    var file1 = try RamFsData.create(std.testing.allocator);
    try std.testing.expectEqual(20, try file1.write_at(0, "This is test content"));
    try std.testing.expectEqualStrings("This is test content", file1.storage.ram.items);

    var file2 = file1.share();
    try std.testing.expect(!file1.deinit());

    try std.testing.expectEqual(file1.refcounter.*, 1);
    try std.testing.expectEqualStrings("This is test content", file2.storage.ram.items);
    try std.testing.expect(file2.deinit());
}
