//
// ramfs_tier.zig
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

///! Spill policy for a RamFs whose memory arena is bounded (the hybrid /tmp).
///!
///! A RamFs handed a `Tier` keeps a file's body in RAM only while it fits: a
///! write past `max_file_bytes`, or one the arena cannot satisfy, moves the
///! whole body to a file in `directory` on `backing` and every later access goes
///! there. The tree (names, directories, link structure) always stays in RAM, so
///! only the body is ever tiered and directory listings need no merging.
///!
///! Bodies are named `y<id>.tmp` — 8.3-clean, because FAT short-name generation
///! for dotted or long names is a path the rest of the system does not exercise.
///! `id` restarts at 1 on every boot and a spill truncates whatever it finds
///! under that name, so a reset that leaves bodies behind costs the directory a
///! bounded number of stale entries (the largest spill count of any single run)
///! rather than unbounded growth.
const std = @import("std");

const kernel = @import("kernel");

const log = kernel.log;

/// How much room is left in the arena a tiered RamFs allocates from. The tier
/// only ever reads it, so any allocator that can answer the question fits.
pub const ArenaView = struct {
    context: *anyopaque,
    free_bytes: *const fn (context: *anyopaque) usize,

    pub fn free(self: ArenaView) usize {
        return self.free_bytes(self.context);
    }
};

pub const Tier = struct {
    /// Room for `directory` plus the "/yNNNNNNN.tmp" body name.
    pub const max_path_length = 128;

    /// Filesystem the spilled bodies are written to. On hardware this is the
    /// VFS itself, so `directory` routes to whatever is mounted there.
    backing: *kernel.fs.IFileSystem,
    directory: []const u8,
    max_file_bytes: usize,

    /// Optional arena guard. Without it a body only spills once it is too big
    /// or an allocation has already failed, which leaves the arena free to fill
    /// with bodies until there is no room left even to name the next file. With
    /// it, growth spills as soon as free space drops under `reserve_bytes`, so
    /// that much is always left for the tree.
    arena: ?ArenaView = null,
    reserve_bytes: usize = 0,

    next_id: u32 = 1,
    spills: usize = 0,
    spilled_bytes: usize = 0,

    /// Bodies on `backing` now, and whether new ones may be made there: the
    /// spill directory's mount can go only while it holds none (`detach`).
    /// A spill counts itself before it checks `detached`, and `detach` sets
    /// it before it checks the count, so one of the two always sees the other.
    live_bodies: kernel.sync.Atomic(u32) = .init(0),
    detached: kernel.sync.Atomic(bool) = .init(false),

    pub fn init(backing: *kernel.fs.IFileSystem, directory: []const u8, max_file_bytes: usize) Tier {
        return .{
            .backing = backing,
            .directory = directory,
            .max_file_bytes = max_file_bytes,
        };
    }

    pub fn set_arena(self: *Tier, arena: ArenaView, reserve_bytes: usize) void {
        self.arena = arena;
        self.reserve_bytes = reserve_bytes;
    }

    pub fn arena_is_low(self: *const Tier) bool {
        const arena = self.arena orelse return false;
        return arena.free() < self.reserve_bytes;
    }

    pub fn next_identifier(self: *Tier) u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        return id;
    }

    pub fn format_path(self: *const Tier, buffer: []u8, id: u32) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/y{x:0>7}.tmp", .{ self.directory, id }) catch
            kernel.errno.ErrnoSet.InvalidArgument;
    }

    /// Create (or truncate) the body for `id` and return an owning handle to it.
    /// The caller takes the reference and must `delete()` it.
    pub fn open_body(self: *Tier, id: u32) !kernel.fs.IFile {
        var path_buffer: [max_path_length]u8 = undefined;
        const path = try self.format_path(&path_buffer, id);

        // Start from nothing: a stale body left by a previous boot would
        // otherwise keep its tail past whatever this file writes.
        self.backing.interface.unlink(path) catch {};
        try self.backing.interface.create(path, 0o600);
        errdefer self.backing.interface.unlink(path) catch {};

        var node = try self.backing.interface.get(path);
        var maybe_file = node.as_file();
        if (maybe_file) |*file| {
            const retained = file.share();
            node.delete();
            return retained;
        }
        node.delete();
        return kernel.errno.ErrnoSet.IsADirectory;
    }

    pub fn remove_body(self: *Tier, id: u32) void {
        var path_buffer: [max_path_length]u8 = undefined;
        const path = self.format_path(&path_buffer, id) catch return;
        self.backing.interface.unlink(path) catch |err| {
            log.warn("can't remove spilled body '{s}': {s}", .{ path, @errorName(err) });
        };
    }

    /// Count a body about to be made. Fails while detached (ENOSPC for the
    /// write); `keeps_in_arena` says when the file stays in RAM instead.
    pub fn claim_body(self: *Tier) !void {
        _ = self.live_bodies.fetchAdd(1, .seq_cst);
        if (self.detached.load(.seq_cst)) {
            _ = self.live_bodies.fetchSub(1, .seq_cst);
            return kernel.errno.ErrnoSet.NoSpaceLeftOnDevice;
        }
    }

    /// A body counted by `claim_body` is gone.
    pub fn drop_body(self: *Tier) void {
        _ = self.live_bodies.fetchSub(1, .seq_cst);
    }

    /// The spill directory's mount is going away: make no more bodies there.
    /// Busy while a file still has its body there -- the data would go with
    /// the mount (removing the file frees it).
    pub fn detach(self: *Tier) !void {
        self.detached.store(true, .seq_cst);
        const live = self.live_bodies.load(.seq_cst);
        if (live != 0) {
            self.detached.store(false, .seq_cst);
            log.info("{d} file(s) in /tmp have their data in {s}", .{ live, self.directory });
            return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
        }
    }

    /// Whether a body due to spill stays in the arena instead: only while
    /// detached, and only while the arena -- never the kernel heap, which is
    /// what a tier without one allocates from -- has room above its reserve.
    pub fn keeps_in_arena(self: *const Tier, grows: bool) bool {
        if (!self.detached.load(.seq_cst) or self.arena == null) return false;
        return !(grows and self.arena_is_low());
    }

    pub fn reattach(self: *Tier) void {
        self.detached.store(false, .seq_cst);
    }

    pub fn account_spill(self: *Tier, bytes: usize) void {
        self.spills += 1;
        self.spilled_bytes += bytes;
    }
};
