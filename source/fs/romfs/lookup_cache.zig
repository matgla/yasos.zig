//
// lookup_cache.zig
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

const std = @import("std");

const kernel = @import("kernel");

/// Path -> image offset of the entry a lookup ends on, after links are
/// followed. A romfs image cannot change while it is mounted, so an answer
/// never goes stale and nothing ever invalidates one.
///
/// What it saves is the walk. A lookup steps over every sibling ahead of each
/// component, one header read apiece, and a symlink restarts it from the
/// root: launching `/bin/true` (a link to `toybox`, near the end of a /bin of
/// ~200 entries) read 282 headers, every launch. A hit reads one.
///
/// Only successes are kept. A miss can be transient -- a name of 16 bytes or
/// more is read onto the heap, and if that allocation fails the entry reads
/// as nameless, so the walk steps past it and reports NoEntry for a path that
/// exists. Caching that would make it permanent.
pub const LookupCache = struct {
    /// Longer paths are looked up every time. Every path the loader opens in
    /// this rootfs fits.
    pub const max_path = 54;
    pub const slots = 16;

    const Entry = struct {
        hash: u32 = 0,
        offset: u32 = 0,
        /// 0 marks an empty slot; no lookup is cached under an empty path.
        len: u8 = 0,
        follow_links: bool = false,
        path: [max_path]u8 = undefined,
    };

    entries: [slots]Entry = @splat(.{}),
    /// Next slot to overwrite. Round robin: the working set is a handful of
    /// executables and libraries, and anything smarter costs more to run
    /// than the misses it would save.
    victim: u8 = 0,

    /// One lock for every mount. Static, so it is never placed in PSRAM where
    /// its exclusives would never succeed (see sync/placement.zig), and held
    /// only for a probe or an insert -- never across device I/O.
    var lock: kernel.sync.RankedMutex(.fs) = .{};

    fn hash_of(path: []const u8, follow_links: bool) u32 {
        // FNV-1a. The paths are short and this runs on every lookup.
        var h: u32 = if (follow_links) 0x811c9dc5 else 0x050c5d1f;
        for (path) |byte| {
            h = (h ^ byte) *% 0x01000193;
        }
        return h;
    }

    pub fn find(self: *LookupCache, path: []const u8, follow_links: bool) ?u32 {
        if (path.len == 0) return null;
        const perf = kernel.perf;
        perf.cache_record(if (path.len <= 16) .romfs_len16 else if (path.len <= 32) .romfs_len32 else if (path.len <= max_path) .romfs_len54 else if (path.len <= 96) .romfs_len96 else if (path.len <= 128) .romfs_len128 else .romfs_len_long, 1);
        if (path.len > max_path) {
            perf.cache_record(.romfs_overflow, 1);
            perf.cache_record(.romfs_misses, 1);
            return null;
        }
        const h = hash_of(path, follow_links);
        lock.lock();
        defer lock.unlock();
        for (&self.entries) |*entry| {
            if (entry.hash != h or entry.len != path.len or entry.follow_links != follow_links) continue;
            if (std.mem.eql(u8, entry.path[0..entry.len], path)) {
                perf.cache_record(.romfs_hits, 1);
                return entry.offset;
            }
        }
        perf.cache_record(.romfs_misses, 1);
        return null;
    }

    pub fn insert(self: *LookupCache, path: []const u8, follow_links: bool, offset: u32) void {
        if (path.len == 0 or path.len > max_path) return;
        const h = hash_of(path, follow_links);
        lock.lock();
        defer lock.unlock();
        // Two lookups of one path can both miss and both insert; keep one.
        for (&self.entries) |*entry| {
            if (entry.hash == h and entry.len == path.len and entry.follow_links == follow_links and
                std.mem.eql(u8, entry.path[0..entry.len], path)) return;
        }
        const entry = &self.entries[self.victim];
        self.victim = (self.victim + 1) % slots;
        entry.hash = h;
        entry.offset = offset;
        entry.len = @intCast(path.len);
        entry.follow_links = follow_links;
        @memcpy(entry.path[0..path.len], path);
    }
};

test "LookupCache.FindsWhatWasInserted" {
    var cache: LookupCache = .{};
    try std.testing.expectEqual(null, cache.find("/bin/true", true));
    cache.insert("/bin/true", true, 0x1230);
    try std.testing.expectEqual(@as(?u32, 0x1230), cache.find("/bin/true", true));
}

test "LookupCache.KeepsFollowAndNoFollowApart" {
    // `readlink` and `lstat` want the link itself, `open` its target.
    var cache: LookupCache = .{};
    cache.insert("/bin/true", false, 0x100);
    cache.insert("/bin/true", true, 0x200);
    try std.testing.expectEqual(@as(?u32, 0x100), cache.find("/bin/true", false));
    try std.testing.expectEqual(@as(?u32, 0x200), cache.find("/bin/true", true));
}

test "LookupCache.MatchesWholePathsOnly" {
    var cache: LookupCache = .{};
    cache.insert("/bin/true", true, 0x100);
    try std.testing.expectEqual(null, cache.find("/bin/tru", true));
    try std.testing.expectEqual(null, cache.find("/bin/truex", true));
    try std.testing.expectEqual(null, cache.find("/bin/false", true));
}

test "LookupCache.SkipsPathsThatDoNotFit" {
    var cache: LookupCache = .{};
    const long = "/" ++ @as([LookupCache.max_path]u8, @splat('a'));
    cache.insert(long, true, 0x100);
    try std.testing.expectEqual(null, cache.find(long, true));
    cache.insert("", true, 0x100);
    try std.testing.expectEqual(null, cache.find("", true));
}

test "LookupCache.EvictsOldestWhenFull" {
    var cache: LookupCache = .{};
    var name: [8]u8 = undefined;
    for (0..LookupCache.slots + 1) |i| {
        const path = try std.fmt.bufPrint(&name, "/f{d}", .{i});
        cache.insert(path, true, @intCast(i + 1));
    }
    try std.testing.expectEqual(null, cache.find("/f0", true));
    try std.testing.expectEqual(@as(?u32, 2), cache.find("/f1", true));
    try std.testing.expectEqual(@as(?u32, LookupCache.slots + 1), cache.find(try std.fmt.bufPrint(&name, "/f{d}", .{LookupCache.slots}), true));
}

test "LookupCache.InsertingTwiceKeepsOneSlot" {
    var cache: LookupCache = .{};
    cache.insert("/bin/true", true, 0x100);
    cache.insert("/bin/true", true, 0x100);
    try std.testing.expectEqual(@as(u8, 1), cache.victim);
}
