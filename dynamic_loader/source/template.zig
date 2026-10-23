//
// template.zig
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

//! Relocated-image templates: what a load computed, kept so the next load of
//! the same image is a copy and a list of stores instead of a relocation.
//!
//! Every process needs its own writable [data][bss][got] region and thunk
//! block (there is no MMU), and both land at a different address on every
//! exec. What does not change between two loads of one image is everything
//! else: which import resolved to which export, which GOT slot got a thunk,
//! which section an offset fell in. So a load records every word it writes
//! and which base the value was computed from -- this module's region, its
//! thunks, its image, or one of its direct dependencies' region or image
//! (`find_symbol` never looks further). A template is that list of writes,
//! with the bases subtracted out. Applying it to a fresh region -- data and
//! GOT copied from the image as for any load, thunks zeroed -- is one store per
//! entry, each adding the new base back.
//!
//! Templates come from two places:
//!
//!  - The RAM cache, filled by loads as they happen, keyed by image address.
//!    Only images whose address cannot be reused for different contents
//!    (romfs XIP) are cached -- the caller says which. It lives in pages the
//!    pool may take back: when an allocation finds no room, `reclaim` drops
//!    the least recently used templates that no load is reading.
//!
//!  - The precache, built with the rootfs by running this same loader on the
//!    host (tools/yasld_prelink.zig) and read in place from flash. It is keyed
//!    by `content_hash`, which covers everything a template depends on, so a
//!    precache that does not match the images simply finds nothing.
//!
//! Either way a template is only valid against the dependencies it was
//! computed with, which are checked on every hit.

const std = @import("std");

const log = std.log.scoped(.@"yasld/template");

/// Which base a word's value was computed from. Stored as `value - base`; a
/// hit adds the new base back.
pub const Kind = u8;
pub const absolute: Kind = 0;
pub const self_thunks: Kind = 2;
/// A word the load never wrote: it keeps what the image (or the zeroed thunk
/// block) put there. Only ever in a capture, never in a template.
const unwritten: Kind = 0xff;

/// Owner 0 is the module itself, owner k + 1 its k-th direct dependency.
pub fn region_kind(owner: u8) Kind {
    return if (owner == 0) 1 else 4 + 2 * (owner - 1);
}

pub fn image_kind(owner: u8) Kind {
    return if (owner == 0) 3 else 5 + 2 * (owner - 1);
}

/// Dependencies a template can describe. Real images import two to four.
pub const max_children = 16;
pub const max_kinds = 4 + 2 * max_children;

/// The current load's bases, indexed by `Kind`.
pub const Bases = [max_kinds]usize;

/// Thunk slot layout (indirect_call_thunk.S): code, then the {r9, fn}
/// descriptor the code loads. module.thunk_code checks the assembly size
/// before exposing it as this fixed-size template.
pub const thunk_size: usize = 16;
pub const thunk_r9_offset: usize = 8;
pub const thunk_fn_offset: usize = 12;

/// Where a load's writable words live: the three ranges a template covers, in
/// the order its word indices count them. bss is not among them -- it starts
/// out zero and nothing relocates into it.
pub const Layout = struct {
    data: []u8,
    got: []u8,
    thunks: []u8,

    fn words(self: Layout) usize {
        return (self.data.len + self.got.len + self.thunks.len) / 4;
    }

    fn index_of(self: Layout, address: usize) ?usize {
        if (address & 3 != 0) return null;
        var first: usize = 0;
        inline for (.{ self.data, self.got, self.thunks }) |range| {
            const start = @intFromPtr(range.ptr);
            if (address >= start and address < start + range.len) {
                if (start & 3 != 0) return null;
                return first + (address - start) / 4;
            }
            first += range.len / 4;
        }
        return null;
    }

    fn word_at(self: Layout, index: usize) *align(1) u32 {
        var rest = index;
        inline for (.{ self.data, self.got }) |range| {
            if (rest < range.len / 4) return @ptrCast(range.ptr + rest * 4);
            rest -= range.len / 4;
        }
        return @ptrCast(self.thunks.ptr + rest * 4);
    }
};

/// One store a template replays: word `at >> 8` gets `value` plus the base of
/// kind `at & 0xff`. Sorted by word.
pub const Entry = extern struct {
    at: u32,
    value: u32,
};

/// A run of words the load never wrote, over the [data][got] word space: the
/// image's own bytes still belong there, so the next load copies just those
/// runs instead of the whole region. `[start, end)` in words.
pub const CopyRun = extern struct {
    start: u32,
    end: u32,
};

/// Runs past this describe a region whose written words are too scattered for
/// the copy to win, so the template keeps no runs and the full copy stands.
pub const max_copy_runs = 64;

/// Fill a fresh region the way any load starts: the image's words for `runs`
/// (word indices over [data][got]; copy_all requests every word) into `data`/`got`.
pub fn copy_from_image(data: []u8, got: []u8, image_data: []const u8, image_got: []const u8, runs: []align(1) const CopyRun, copy_all: bool) void {
    if (copy_all) {
        @memcpy(data, image_data);
        @memcpy(got, image_got);
        return;
    }
    const data_words = data.len / 4;
    for (runs) |run| {
        const lo = run.start;
        const hi = run.end;
        if (lo < data_words) {
            const upto = @min(hi, data_words);
            @memcpy(data[lo * 4 .. upto * 4], image_data[lo * 4 .. upto * 4]);
        }
        if (hi > data_words) {
            const from = (@max(lo, data_words) - data_words) * 4;
            const to = (hi - data_words) * 4;
            @memcpy(got[from..to], image_got[from..to]);
        }
    }
}

/// The per-word record of one load in progress. `mark` every word written,
/// absolute values included -- an unmarked word is replayed from the image.
pub const Capture = struct {
    layout: Layout,
    kinds: []Kind,
    /// Cleared when a write landed somewhere the template cannot describe;
    /// the load still completes, it just is not cached.
    ok: bool = true,

    pub fn mark(self: *Capture, address: usize, kind: Kind) void {
        if (self.layout.index_of(address)) |index| {
            self.kinds[index] = kind;
        } else {
            log.debug("capture: write at 0x{x} outside the template", .{address});
            self.ok = false;
        }
    }

    pub fn mark_ptr(self: *Capture, pointer: anytype, kind: Kind) void {
        self.mark(@intFromPtr(pointer), kind);
    }

    /// The kind last recorded for the word at `address` -- for a value the
    /// loader reads back out of the GOT and stores again elsewhere. A word
    /// never written holds what the image put there, which no base moves.
    pub fn kind_of(self: *const Capture, address: usize) Kind {
        const index = self.layout.index_of(address) orelse return absolute;
        const kind = self.kinds[index];
        return if (kind == unwritten) absolute else kind;
    }
};

/// A template wherever it is stored: RAM cache or flash precache.
pub const View = struct {
    /// Identity of each direct dependency, in import order: image addresses
    /// for the RAM cache, content hashes for the precache.
    children: []align(1) const u64,
    data_length: u32,
    got_length: u32,
    thunk_count: u32,
    /// What a fresh load copies from the image before these stores run.
    /// Lists the complement of replay stores; copy_all selects full fallback.
    copy_runs: []align(1) const CopyRun = &.{},
    /// Full-copy fallback is distinct from selective mode with no runs.
    copy_all: bool = true,
    /// Complete prefix whose clear replay can skip. Later slots may also be
    /// written: phase reservations can leave holes between generated slots.
    slots_written: u32 = 0,
    entries: []align(1) const Entry,

    /// Whether this template was computed for a load of this shape against
    /// these dependencies.
    pub fn fits(self: View, children: []const u64, layout: Layout, slot_size: usize) bool {
        if (self.children.len != children.len) return false;
        for (self.children, children) |a, b| {
            if (a != b) return false;
        }
        return self.data_length == layout.data.len and self.got_length == layout.got.len and
            slot_size == thunk_size and @as(usize, self.thunk_count) * slot_size == layout.thunks.len;
    }

    /// Validate once at capture/precache acceptance, never in the warm loop.
    pub fn valid(self: View, slot_size: usize) bool {
        if (self.children.len > max_children or self.copy_runs.len > max_copy_runs or
            self.data_length % 4 != 0 or self.got_length % 4 != 0 or
            slot_size != thunk_size or self.slots_written > self.thunk_count) return false;
        const region_bytes = std.math.add(usize, self.data_length, self.got_length) catch return false;
        const thunk_bytes = std.math.mul(usize, self.thunk_count, thunk_size) catch return false;
        const total = std.math.add(usize, region_bytes, thunk_bytes) catch return false;
        if (total / 4 > 0x1000000) return false;
        const region_words = region_bytes / 4;
        var previous: ?usize = null;
        var data_entries: usize = 0;
        var pending_slot: ?usize = null;
        var prefix: usize = 0;
        for (self.entries) |entry| {
            const word: usize = entry.at >> 8;
            const kind = entry.at & 0xff;
            if (word >= total / 4 or kind >= 4 + self.children.len * 2) return false;
            if (previous) |prev| {
                if (word <= prev) return false;
            }
            previous = word;
            if (word < region_words) {
                data_entries += 1;
                continue;
            }
            const offset = (word - region_words) * 4;
            const slot = offset / thunk_size;
            switch (offset % thunk_size) {
                thunk_r9_offset => {
                    if (pending_slot != null) return false;
                    pending_slot = slot;
                },
                thunk_fn_offset => {
                    if (pending_slot == null or pending_slot.? != slot) return false;
                    if (slot == prefix) prefix += 1;
                    pending_slot = null;
                },
                else => return false,
            }
        }
        if (pending_slot != null or self.slots_written > prefix) return false;
        if (self.copy_all) return self.copy_runs.len == 0;
        // Merge stores and copy runs: they must partition the image word space.
        var cursor: usize = 0;
        var e: usize = 0;
        var r: usize = 0;
        while (e < data_entries or r < self.copy_runs.len) {
            if (r < self.copy_runs.len and (e == data_entries or self.copy_runs[r].start < self.entries[e].at >> 8)) {
                const run = self.copy_runs[r];
                if (run.start != cursor or run.end <= run.start or run.end > region_words) return false;
                cursor = run.end;
                r += 1;
            } else {
                if (self.entries[e].at >> 8 != cursor) return false;
                cursor += 1;
                e += 1;
            }
        }
        return cursor == region_words;
    }

    /// Replay onto a fresh load: data and GOT already copied from the image,
    /// thunks zeroed. Requires a valid template and matching layout.
    /// `thunk_code` is one slot's template (code + descriptor).
    pub fn apply(self: View, layout: Layout, bases: *const Bases, thunk_code: *const [thunk_size]u8) void {
        // Entries are sorted by word, so the data words come first, then the
        // GOT's, then the thunks'. The first two ranges are a plain store
        // each; only the thunk words need the slot bookkeeping -- and the
        // memcpy that, kept in one loop with the rest, made every value of
        // every iteration survive a call (~30 instructions per entry, 1,674
        // entries per /bin/true launch).
        const data_words = layout.data.len / 4;
        const got_end = data_words + layout.got.len / 4;
        var next = replay_range(self.entries, 0, data_words, layout.data.ptr, 0, bases);
        next = replay_range(self.entries, next, got_end, layout.got.ptr, data_words, bases);
        replay_thunks(self.entries[next..], got_end, layout.thunks.ptr, bases, thunk_code);
    }
};

inline fn replay_thunks(list: []align(1) const Entry, first: usize, thunks: [*]u8, bases: *const Bases, thunk_code: *const [thunk_size]u8) void {
    // valid() requires the suffix to contain complete, sorted {r9, fn}
    // pairs, even across reserved holes. Each pair names its own slot;
    // only the two code words need copying before its descriptors.
    const code: *align(1) const [thunk_r9_offset / 4]u32 = @ptrCast(thunk_code);
    const code0 = code[0];
    const code1 = code[1];
    // Read each pair by value before writing the slot. Besides handling
    // align(1) records, this avoids reloading entries after aliasing stores.
    const pairs = std.mem.bytesAsSlice([2]Entry, std.mem.sliceAsBytes(list));
    for (pairs) |pair| {
        const r9 = pair[0];
        const fn_ = pair[1];
        const offset = ((r9.at >> 8) - first) * 4 - thunk_r9_offset;
        const slot: *align(1) [thunk_size / 4]u32 = @ptrCast(thunks + offset);
        const r9_value = r9.value +% @as(u32, @truncate(bases[r9.at & 0xff]));
        const fn_value = fn_.value +% @as(u32, @truncate(bases[fn_.at & 0xff]));
        slot[0] = code0;
        slot[1] = code1;
        slot[thunk_r9_offset / 4] = r9_value;
        slot[thunk_fn_offset / 4] = fn_value;
    }
}

/// Replay `list[start..]` while their word is below `end`, into the range at
/// `range` whose first word is `first`. Returns the first entry not taken.
/// Inline: six arguments would put two on the stack, re-read every entry.
inline fn replay_range(list: []align(1) const Entry, start: usize, end: usize, range: [*]u8, first: usize, bases: *const Bases) usize {
    // `for` reads each entry as two words; `list[i]` of an align(1) element
    // is a memcpy into a temporary in the C backend's output.
    for (list[start..], start..) |entry, i| {
        const index = entry.at >> 8;
        if (index >= end) return i;
        const word: *align(1) u32 = @ptrCast(range + (index - first) * 4);
        word.* = entry.value +% @as(u32, @truncate(bases[entry.at & 0xff]));
    }
    return list.len;
}

const block_alignment = 8;

pub const Template = struct {
    image: usize,
    pins: u32 = 0,
    last_used: u32 = 0,
    /// The allocation this lives at the head of.
    block: []align(block_alignment) u8,
    view: View,

    pub fn bytes(self: *const Template) usize {
        return self.block.len;
    }
};

var allocator: ?std.mem.Allocator = null;

/// Serialises the entry table against `reclaim`, which can arrive from any
/// allocation in the system. Never held across an allocation or a free.
pub const LockHooks = struct {
    lock: *const fn () usize,
    unlock: *const fn (usize) void,
};

fn no_lock() usize {
    return 0;
}

fn no_unlock(_: usize) void {}

var lock_hooks: LockHooks = .{ .lock = &no_lock, .unlock = &no_unlock };

const max_entries = 32;
var entries: [max_entries]?*Template = @splat(null);
var clock: u32 = 0;

pub const Stats = struct {
    verified: u32 = 0,
    verification_failures: u32 = 0,
    hits: u32 = 0,
    precache_hits: u32 = 0,
    misses: u32 = 0,
    inserted: u32 = 0,
    evicted: u32 = 0,
    bytes: usize = 0,
};
pub var stats: Stats = .{};

/// Turn the cache on. Templates are allocated from `page_allocator`, which
/// should be memory the system may reclaim -- see `reclaim`.
pub fn enable(page_allocator: std.mem.Allocator, hooks: LockHooks) void {
    allocator = page_allocator;
    lock_hooks = hooks;
}

pub fn enabled() bool {
    return allocator != null or precache != null;
}

/// Start recording a load. The caller owns the result and passes it to
/// `finish_capture` (or `discard_capture`).
pub fn begin_capture(layout: Layout) ?Capture {
    const a = allocator orelse return null;
    if (layout.data.len % 4 != 0 or layout.got.len % 4 != 0 or layout.thunks.len % 4 != 0 or layout.words() > 0x1000000) return null;
    const kinds = a.alloc(Kind, layout.words()) catch return null;
    @memset(kinds, unwritten);
    return .{ .layout = layout, .kinds = kinds };
}

pub fn discard_capture(capture: *Capture) void {
    if (allocator) |a| a.free(capture.kinds);
}

/// Turn a finished load into a cached template. `children` are the
/// dependencies' image addresses.
pub fn finish_capture(capture: *Capture, image: usize, children: []const usize, thunk_count: usize, bases: *const Bases) void {
    defer discard_capture(capture);
    if (!capture.ok or children.len > max_children) return;
    const a = allocator orelse return;

    var entry_count: usize = 0;
    for (capture.kinds) |kind| {
        if (kind != unwritten) entry_count += 1;
    }

    // The gaps between the stores over [data][got]: words the load never wrote
    // still hold the image, so the next load copies those runs and nothing else.
    // Too many runs to name is a region whose stores are scattered anyway --
    // there the full copy is cheaper than describing it, so keep none.
    const region_words = (capture.layout.data.len + capture.layout.got.len) / 4;
    var runs: [max_copy_runs + 1]CopyRun = undefined;
    var run_count: usize = 0;
    var gap_start: ?usize = null;
    for (capture.kinds[0..region_words], 0..) |kind, index| {
        if (kind == unwritten) {
            if (gap_start == null) gap_start = index;
            continue;
        }
        if (gap_start) |from| {
            if (run_count == runs.len) break;
            runs[run_count] = .{ .start = @intCast(from), .end = @intCast(index) };
            run_count += 1;
            gap_start = null;
        }
    }
    if (gap_start) |from| {
        if (run_count < runs.len) {
            runs[run_count] = .{ .start = @intCast(from), .end = @intCast(region_words) };
            run_count += 1;
        }
    }
    const copy_all = run_count > max_copy_runs;
    if (copy_all) run_count = 0;

    // Phases reserve separate ranges: weak references can leave interior holes.
    // Skip clearing only the complete prefix; replay also fills later slots.
    var slots_written: u32 = 0;
    if (thunk_count == 0) {
        if (capture.layout.thunks.len != 0) return;
    } else {
        if (capture.layout.thunks.len % thunk_count != 0) return;
        const slot_words = capture.layout.thunks.len / thunk_count / 4;
        if (slot_words < 4) return;
        var prefix = true;
        for (0..thunk_count) |slot| {
            const kinds = capture.kinds[region_words + slot * slot_words ..][0..slot_words];
            const r9 = kinds[thunk_r9_offset / 4] != unwritten;
            const fn_ = kinds[thunk_fn_offset / 4] != unwritten;
            if (r9 != fn_) return;
            for (kinds, 0..) |kind, i| {
                if (kind != unwritten and i != thunk_r9_offset / 4 and i != thunk_fn_offset / 4) return;
            }
            if (!r9) prefix = false;
            if (prefix) slots_written += 1;
        }
    }
    for (capture.kinds) |kind| {
        if (kind != unwritten and kind >= 4 + 2 * children.len) return;
    }

    const header = std.mem.alignForward(usize, @sizeOf(Template), 8);
    const runs_at = header + children.len * @sizeOf(u64);
    const total = runs_at + run_count * @sizeOf(CopyRun) + entry_count * @sizeOf(Entry);
    comptime std.debug.assert(@alignOf(Template) <= block_alignment);
    const block = a.alignedAlloc(u8, .fromByteUnits(block_alignment), total) catch return;

    const child_ids: []u64 = @as([*]u64, @ptrCast(@alignCast(block.ptr + header)))[0..children.len];
    for (child_ids, children) |*id, child| id.* = child;
    const stored_runs: []CopyRun = @as([*]CopyRun, @ptrCast(@alignCast(block.ptr + runs_at)))[0..run_count];
    for (stored_runs, 0..) |*to, i| to.* = runs[i];
    const stored: []Entry = @as([*]Entry, @ptrCast(@alignCast(block.ptr + runs_at + run_count * @sizeOf(CopyRun))))[0..entry_count];
    var n: usize = 0;
    for (capture.kinds, 0..) |kind, index| {
        if (kind == unwritten) continue;
        stored[n] = .{
            .at = @as(u32, @intCast(index)) << 8 | kind,
            .value = capture.layout.word_at(index).* -% @as(u32, @truncate(bases[kind])),
        };
        n += 1;
    }

    const template: *Template = @ptrCast(@alignCast(block.ptr));
    template.* = .{
        .image = image,
        .block = block,
        .view = .{
            .children = child_ids,
            .data_length = @intCast(capture.layout.data.len),
            .got_length = @intCast(capture.layout.got.len),
            .thunk_count = @intCast(thunk_count),
            .copy_runs = stored_runs,
            .copy_all = copy_all,
            .slots_written = slots_written,
            .entries = stored,
        },
    };
    if (!template.view.valid(if (thunk_count == 0) thunk_size else capture.layout.thunks.len / thunk_count)) {
        a.free(block);
        return;
    }
    insert(template);
}

fn insert(template: *Template) void {
    var victim: ?*Template = null;
    const flags = lock_hooks.lock();
    clock +%= 1;
    template.last_used = clock;
    var slot: ?usize = null;
    var oldest: ?usize = null;
    for (&entries, 0..) |*entry, i| {
        if (entry.*) |existing| {
            if (existing.image == template.image and existing.pins == 0) {
                // A stale template for this image (its dependencies changed).
                victim = existing;
                slot = i;
                break;
            }
            if (existing.pins == 0 and (oldest == null or older(existing, entries[oldest.?].?))) oldest = i;
        } else if (slot == null) {
            slot = i;
        }
    }
    if (slot == null) {
        if (oldest) |i| {
            victim = entries[i];
            slot = i;
        }
    }
    if (slot) |i| {
        entries[i] = template;
        stats.inserted += 1;
        stats.bytes += template.bytes();
        if (victim) |v| {
            stats.evicted += 1;
            stats.bytes -= v.bytes();
        }
    }
    lock_hooks.unlock(flags);
    if (slot == null) {
        // Every slot pinned by a load in progress; not worth waiting for.
        free_template(template);
        return;
    }
    if (victim) |v| free_template(v);
}

fn older(a: *const Template, b: *const Template) bool {
    // Wrapping clock: compare by distance from now.
    return clock -% a.last_used > clock -% b.last_used;
}

fn free_template(template: *Template) void {
    if (allocator) |a| a.free(template.block);
}

/// The RAM template for `image`, pinned against eviction until `release`.
pub fn lookup(image: usize) ?*Template {
    if (allocator == null) return null;
    const flags = lock_hooks.lock();
    defer lock_hooks.unlock(flags);
    for (entries) |maybe| {
        if (maybe) |template| {
            if (template.image == image) {
                template.pins += 1;
                clock +%= 1;
                template.last_used = clock;
                return template;
            }
        }
    }
    return null;
}

pub fn release(template: *Template) void {
    const flags = lock_hooks.lock();
    defer lock_hooks.unlock(flags);
    template.pins -= 1;
}

/// Every RAM template, for a caller that owns the whole cache (the prelink
/// tool, after its loads).
pub fn cached() []const ?*Template {
    return &entries;
}

/// Drop the template for `image`, if one exists and nothing is reading it.
pub fn invalidate(image: usize) void {
    var victim: ?*Template = null;
    const flags = lock_hooks.lock();
    for (&entries) |*entry| {
        if (entry.*) |template| {
            if (template.image == image and template.pins == 0) {
                victim = template;
                entry.* = null;
                stats.evicted += 1;
                stats.bytes -= template.bytes();
                break;
            }
        }
    }
    lock_hooks.unlock(flags);
    if (victim) |v| free_template(v);
}

/// Free least recently used templates until about `wanted` bytes have been
/// given back. Returns what was freed; 0 means nothing evictable is left.
pub fn reclaim(wanted: usize) usize {
    if (allocator == null) return 0;
    var freed: usize = 0;
    while (freed < wanted) {
        var victim: ?*Template = null;
        const flags = lock_hooks.lock();
        var oldest: ?usize = null;
        for (entries, 0..) |maybe, i| {
            if (maybe) |template| {
                if (template.pins == 0 and (oldest == null or older(template, entries[oldest.?].?))) oldest = i;
            }
        }
        if (oldest) |i| {
            victim = entries[i];
            entries[i] = null;
            stats.evicted += 1;
            stats.bytes -= victim.?.bytes();
        }
        lock_hooks.unlock(flags);
        const v = victim orelse break;
        freed += v.bytes();
        free_template(v);
    }
    if (freed != 0) log.debug("reclaimed {d} bytes", .{freed});
    return freed;
}

// ---------------------------------------------------------------------------
// Content identity and the precache.

/// Everything a template computed from `image` depends on: the header and
/// every table ahead of the code (imports, exports, relocations, hash
/// tables), and the GOT's initial contents. Not the code, data or rodata --
/// a template stores no byte of those, and their sizes and offsets are in
/// the header. A dependency's hash covers what an importer resolves against:
/// its exports, and the layout that places its region.
pub fn content_hash(image: [*]const u8, text_offset: u32, got: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x79617366_74706c31); // "yasftpl1"
    hasher.update(image[0..text_offset]);
    hasher.update(got);
    return hasher.final();
}

/// Hashes of stable images, so each is hashed once per boot rather than once
/// per exec. A rootfs has a few dozen images; searched in full, replaced
/// round robin once full.
const memo_slots = 64;
var memo_images: [memo_slots]usize = @splat(0);
var memo_hashes: [memo_slots]u64 = @splat(0);
var memo_next: usize = 0;

pub fn memo_lookup(image: usize) ?u64 {
    for (memo_images, 0..) |at, i| {
        if (at == image) return memo_hashes[i];
    }
    return null;
}

/// Loads are serialised by the kernel's loader lock, which is the only
/// writer's caller.
pub fn memo_store(image: usize, hash: u64) void {
    const slot = memo_next;
    memo_next = (memo_next + 1) % memo_slots;
    memo_images[slot] = image;
    memo_hashes[slot] = hash;
}

/// The precache file: a header, an index sorted by image hash, then the
/// templates the index points at. Little endian, 4-byte aligned throughout.
pub const precache_magic: u32 = 0x43444c59; // "YLDC"
pub const precache_version: u32 = 3;

pub const PrecacheHeader = extern struct {
    magic: u32,
    version: u32,
    /// Whole file, header included.
    size: u32,
    entry_count: u32,
    /// The thunk slot size the templates were laid out for.
    thunk_size: u32,
    reserved: u32 = 0,
};

pub const PrecacheIndex = extern struct {
    hash_low: u32,
    hash_high: u32,
    /// Byte offset of the PrecacheTemplate from the start of the file.
    offset: u32,
    reserved: u32 = 0,

    fn hash(self: PrecacheIndex) u64 {
        return @as(u64, self.hash_high) << 32 | self.hash_low;
    }
};

/// Followed by `child_count` u64 child hashes, then `copy_run_count` CopyRuns,
/// then `entry_count` Entries. Version 3 distinguishes full-copy fallback from
/// selective copying with zero runs; older formats are refused outright.
pub const PrecacheTemplate = extern struct {
    child_count: u32,
    entry_count: u32,
    data_length: u32,
    got_length: u32,
    thunk_count: u32,
    copy_run_count: u32,
    slots_written: u32,
    copy_all: u32 = 1,
};

var precache: ?[]const u8 = null;

pub const PrecacheError = error{
    /// Not a precache, or one from a newer or older prelink.
    NotAPrecache,
    /// Built for another thunk layout, or cut short.
    DoesNotFit,
};

/// Use the precache at `file` (memory-mapped, read in place for as long as
/// the system runs). Refused when it is not one, or was built for another
/// thunk layout -- loads then relocate as if there were none.
pub fn set_precache(file: []const u8, slot_size: usize) PrecacheError!void {
    precache = null;
    if (file.len < @sizeOf(PrecacheHeader)) return error.NotAPrecache;
    const header: *align(1) const PrecacheHeader = @ptrCast(file.ptr);
    if (header.magic != precache_magic or header.version != precache_version) return error.NotAPrecache;
    if (header.size > file.len or header.size < @sizeOf(PrecacheHeader) or header.thunk_size != slot_size or slot_size != thunk_size) return error.DoesNotFit;
    const bytes = file[0..header.size];
    const first = bounded_end(@sizeOf(PrecacheHeader), header.entry_count, @sizeOf(PrecacheIndex), bytes.len) orelse return error.DoesNotFit;
    const index: []align(1) const PrecacheIndex = @as([*]align(1) const PrecacheIndex, @ptrCast(bytes.ptr + @sizeOf(PrecacheHeader)))[0..header.entry_count];
    var previous: ?u64 = null;
    for (index) |entry| {
        if (previous) |hash| {
            if (entry.hash() <= hash) return error.DoesNotFit;
        }
        previous = entry.hash();
        if (entry.offset < first or entry.offset % 4 != 0) return error.DoesNotFit;
        const view = view_at(bytes, entry.offset) orelse return error.DoesNotFit;
        if (!view.valid(slot_size)) return error.DoesNotFit;
    }
    precache = bytes;
}

pub fn have_precache() bool {
    return precache != null;
}

/// The precached template for the image with `hash`, if any.
pub fn precache_find(hash: u64) ?View {
    const file = precache orelse return null;
    const header: *align(1) const PrecacheHeader = @ptrCast(file.ptr);
    const index: []align(1) const PrecacheIndex = @as([*]align(1) const PrecacheIndex, @ptrCast(file.ptr + @sizeOf(PrecacheHeader)))[0..header.entry_count];
    var low: usize = 0;
    var high: usize = index.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const at = index[mid].hash();
        if (at == hash) return view_at(file, index[mid].offset);
        if (at < hash) low = mid + 1 else high = mid;
    }
    return null;
}

fn bounded_end(start: usize, count: usize, stride: usize, limit: usize) ?usize {
    if (start > limit or count > (limit - start) / stride) return null;
    return start + count * stride;
}

fn view_at(file: []const u8, offset: u32) ?View {
    const children_at = bounded_end(offset, 1, @sizeOf(PrecacheTemplate), file.len) orelse return null;
    const t: *align(1) const PrecacheTemplate = @ptrCast(file.ptr + offset);
    if (t.child_count > max_children or t.copy_run_count > max_copy_runs or t.copy_all > 1) return null;
    const runs_at = bounded_end(children_at, t.child_count, @sizeOf(u64), file.len) orelse return null;
    const entries_at = bounded_end(runs_at, t.copy_run_count, @sizeOf(CopyRun), file.len) orelse return null;
    _ = bounded_end(entries_at, t.entry_count, @sizeOf(Entry), file.len) orelse return null;
    return .{
        .children = @as([*]align(1) const u64, @ptrCast(file.ptr + children_at))[0..t.child_count],
        .data_length = t.data_length,
        .got_length = t.got_length,
        .thunk_count = t.thunk_count,
        .copy_runs = @as([*]align(1) const CopyRun, @ptrCast(file.ptr + runs_at))[0..t.copy_run_count],
        .slots_written = t.slots_written,
        .copy_all = t.copy_all != 0,
        .entries = @as([*]align(1) const Entry, @ptrCast(file.ptr + entries_at))[0..t.entry_count],
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn reset_for_test() void {
    for (&entries) |*entry| {
        if (entry.*) |t| free_template(t);
        entry.* = null;
    }
    stats = .{};
    allocator = testing.allocator;
    lock_hooks = .{ .lock = &no_lock, .unlock = &no_unlock };
}

const test_thunk = [_]u8{ 0xa1, 0xa2, 0xa3, 0xa4, 0xb1, 0xb2, 0xb3, 0xb4, 0, 0, 0, 0, 0, 0, 0, 0 };

// Two loads of one image: words written relative to each base, read back
// at the second load's bases.
test "Template.ReplaysEachWordAgainstTheNewBases" {
    reset_for_test();
    defer reset_for_test();
    var data_a: [4]u32 align(4) = .{ 0x11, 0x22, 0x33, 0x44 };
    var got_a: [2]u32 align(4) = .{ 0, 0 };
    var thunks_a: [4]u32 align(4) = @splat(0);
    const layout_a: Layout = .{ .data = std.mem.sliceAsBytes(&data_a), .got = std.mem.sliceAsBytes(&got_a), .thunks = std.mem.sliceAsBytes(&thunks_a) };
    var bases_a: Bases = @splat(0);
    bases_a[region_kind(0)] = 0x2000_0000;
    bases_a[self_thunks] = 0x2100_0000;
    bases_a[image_kind(0)] = 0x1000_0000;
    bases_a[region_kind(1)] = 0x2200_0000;

    var capture = begin_capture(layout_a).?;
    data_a[1] = 0x2000_0010; // into own region
    capture.mark_ptr(&data_a[1], region_kind(0));
    got_a[0] = 0x1000_0101; // own code
    capture.mark_ptr(&got_a[0], image_kind(0));
    got_a[1] = 0x2200_0040; // a dependency's data
    capture.mark_ptr(&got_a[1], region_kind(1));
    data_a[3] = 0; // weak NULL over an image value
    capture.mark_ptr(&data_a[3], absolute);
    thunks_a[2] = 0x2200_0000; // r9 of slot 0
    capture.mark_ptr(&thunks_a[2], region_kind(1));
    thunks_a[3] = 0x1000_0201;
    capture.mark_ptr(&thunks_a[3], image_kind(0));
    finish_capture(&capture, 0x1000_0000, &.{0x1800_0000}, 1, &bases_a);

    const t = lookup(0x1000_0000).?;
    defer release(t);
    try testing.expectEqual(@as(usize, 6), t.view.entries.len);

    // Second load: the image's own data again, everything else moved.
    var data_b: [4]u32 align(4) = .{ 0x11, 0x22, 0x33, 0x44 };
    var got_b: [2]u32 align(4) = .{ 0, 0 };
    var thunks_b: [4]u32 align(4) = @splat(0);
    const layout_b: Layout = .{ .data = std.mem.sliceAsBytes(&data_b), .got = std.mem.sliceAsBytes(&got_b), .thunks = std.mem.sliceAsBytes(&thunks_b) };
    var bases_b = bases_a;
    bases_b[region_kind(0)] = 0x3000_0000;
    bases_b[self_thunks] = 0x3100_0000;
    bases_b[region_kind(1)] = 0x3200_0000;
    t.view.apply(layout_b, &bases_b, &test_thunk);

    try testing.expectEqualSlices(u32, &.{ 0x11, 0x3000_0010, 0x33, 0 }, &data_b);
    try testing.expectEqualSlices(u32, &.{ 0x1000_0101, 0x3200_0040 }, &got_b);
    try testing.expectEqualSlices(u8, test_thunk[0..8], std.mem.sliceAsBytes(&thunks_b)[0..8]);
    try testing.expectEqualSlices(u32, &.{ 0x3200_0000, 0x1000_0201 }, thunks_b[2..4]);
}

// apply replays data, GOT and thunk words in separate passes; a range with no
// entries (or no words at all) must hand the next one the right start.
test "Template.ReplaysAcrossEmptyRanges" {
    reset_for_test();
    defer reset_for_test();
    var got_a: [2]u32 align(4) = .{ 0, 0 };
    var thunks_a: [4]u32 align(4) = @splat(0);
    const layout_a: Layout = .{ .data = &.{}, .got = std.mem.sliceAsBytes(&got_a), .thunks = std.mem.sliceAsBytes(&thunks_a) };
    var bases_a: Bases = @splat(0);
    bases_a[region_kind(0)] = 0x2000_0000;
    var capture = begin_capture(layout_a).?;
    got_a[1] = 0x2000_0008;
    capture.mark_ptr(&got_a[1], region_kind(0));
    thunks_a[2] = 0x2000_0000;
    capture.mark_ptr(&thunks_a[2], region_kind(0));
    capture.mark_ptr(&thunks_a[3], absolute);
    finish_capture(&capture, 0x1000_0000, &.{}, 1, &bases_a);

    const t = lookup(0x1000_0000).?;
    defer release(t);
    var got_b: [2]u32 align(4) = .{ 7, 7 };
    var thunks_b: [4]u32 align(4) = @splat(0);
    const layout_b: Layout = .{ .data = &.{}, .got = std.mem.sliceAsBytes(&got_b), .thunks = std.mem.sliceAsBytes(&thunks_b) };
    var bases_b = bases_a;
    bases_b[region_kind(0)] = 0x3000_0000;
    t.view.apply(layout_b, &bases_b, &test_thunk);
    try testing.expectEqualSlices(u32, &.{ 7, 0x3000_0008 }, &got_b);
    try testing.expectEqualSlices(u8, test_thunk[0..8], std.mem.sliceAsBytes(&thunks_b)[0..8]);
    try testing.expectEqual(@as(u32, 0x3000_0000), thunks_b[2]);
}

test "Template.ReclaimSkipsTemplatesInUse" {
    reset_for_test();
    defer reset_for_test();
    var data: [2]u32 align(4) = .{ 0, 0 };
    const layout: Layout = .{ .data = std.mem.sliceAsBytes(&data), .got = &.{}, .thunks = &.{} };
    const bases: Bases = @splat(0);
    for ([_]usize{ 0x100, 0x200 }) |image| {
        var capture = begin_capture(layout).?;
        capture.mark_ptr(&data[0], absolute);
        finish_capture(&capture, image, &.{}, 0, &bases);
    }
    const pinned = lookup(0x100).?;
    try testing.expect(reclaim(std.math.maxInt(usize)) > 0);
    try testing.expect(lookup(0x200) == null);
    release(pinned);
    try testing.expect(reclaim(std.math.maxInt(usize)) > 0);
    try testing.expect(lookup(0x100) == null);
    try testing.expectEqual(@as(usize, 0), stats.bytes);
}

test "Template.CaptureOutsideTheLayoutIsNotCached" {
    reset_for_test();
    defer reset_for_test();
    var data: [2]u32 align(4) = .{ 0, 0 };
    var elsewhere: u32 = 0;
    const layout: Layout = .{ .data = std.mem.sliceAsBytes(&data), .got = &.{}, .thunks = &.{} };
    const bases: Bases = @splat(0);
    var capture = begin_capture(layout).?;
    capture.mark_ptr(&elsewhere, absolute);
    finish_capture(&capture, 0x100, &.{}, 0, &bases);
    try testing.expect(lookup(0x100) == null);
}

test "Template.PrecacheFindsByHashAndRejectsForeignFiles" {
    const Blob = extern struct {
        header: PrecacheHeader,
        index: [2]PrecacheIndex,
        first: PrecacheTemplate,
        first_child_lo: u32,
        first_child_hi: u32,
        first_run: CopyRun,
        first_entry: Entry,
        second: PrecacheTemplate,
    };
    var blob: Blob = .{
        .header = .{ .magic = precache_magic, .version = precache_version, .size = @sizeOf(Blob), .entry_count = 2, .thunk_size = 16 },
        .index = .{
            .{ .hash_low = 5, .hash_high = 0, .offset = @offsetOf(Blob, "first") },
            .{ .hash_low = 9, .hash_high = 1, .offset = @offsetOf(Blob, "second") },
        },
        .first = .{ .child_count = 1, .entry_count = 1, .data_length = 8, .got_length = 0, .thunk_count = 0, .copy_run_count = 1, .slots_written = 0, .copy_all = 0 },
        // Records need only 4-byte alignment, so child hashes can be unaligned.
        // The reader uses unaligned child hashes.
        .first_child_lo = 77,
        .first_child_hi = 0,
        .first_run = .{ .start = 0, .end = 1 },
        .first_entry = .{ .at = @as(u32, 1) << 8 | absolute, .value = 42 },
        .second = .{ .child_count = 0, .entry_count = 0, .data_length = 0, .got_length = 0, .thunk_count = 0, .copy_run_count = 0, .slots_written = 0 },
    };
    const bytes = std.mem.asBytes(&blob);
    defer precache = null;

    // A precache from the previous format is not this one: it stored no copy
    // runs, and applying it as if it stored none would skip image words.
    var stale: Blob = blob;
    stale.header.version = 1;
    try testing.expectError(error.NotAPrecache, set_precache(std.mem.asBytes(&stale), 16));
    try testing.expect(!have_precache());

    try testing.expectError(error.DoesNotFit, set_precache(bytes, 20));
    try testing.expect(!have_precache());

    try set_precache(bytes, 16);
    const view = precache_find(5).?;
    try testing.expectEqual(@as(usize, 1), view.children.len);
    try testing.expectEqual(@as(u64, 77), view.children[0]);
    try testing.expectEqual(@as(usize, 1), view.copy_runs.len);
    try testing.expectEqual(@as(u32, 0), view.copy_runs[0].start);
    try testing.expectEqual(@as(u32, 1), view.copy_runs[0].end);
    try testing.expectEqual(@as(u32, 42), view.entries[0].value);
    try testing.expect(precache_find(1 << 32 | 9) != null);
    try testing.expect(precache_find(6) == null);
}

// The copy runs and the zeroed thunk tail must leave exactly what a full copy
// and a full zeroing leave: the runs are only what a store can skip.
test "Template.CopyRunsAndThunkTailMatchAFullCopy" {
    reset_for_test();
    defer reset_for_test();
    var data_a: [6]u32 align(4) = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    var got_a: [2]u32 align(4) = .{ 0, 0 };
    var thunks_a: [8]u32 align(4) = @splat(0);
    const layout_a: Layout = .{
        .data = std.mem.sliceAsBytes(&data_a),
        .got = std.mem.sliceAsBytes(&got_a),
        .thunks = std.mem.sliceAsBytes(&thunks_a),
    };
    var bases_a: Bases = @splat(0);
    bases_a[region_kind(0)] = 0x2000_0000;
    bases_a[self_thunks] = 0x2100_0000;

    // Words 1 and 4 of data, one GOT word, and slot 0 of two thunk slots.
    var capture = begin_capture(layout_a).?;
    data_a[1] = 0x2000_0010;
    capture.mark_ptr(&data_a[1], region_kind(0));
    data_a[4] = 0x2000_0040;
    capture.mark_ptr(&data_a[4], region_kind(0));
    got_a[1] = 0x2000_0008;
    capture.mark_ptr(&got_a[1], region_kind(0));
    thunks_a[2] = 0x2000_0000;
    capture.mark_ptr(&thunks_a[2], region_kind(0));
    thunks_a[3] = 0x2100_0040;
    capture.mark_ptr(&thunks_a[3], self_thunks);
    finish_capture(&capture, 0x1000_0000, &.{}, 2, &bases_a);

    const t = lookup(0x1000_0000).?;
    defer release(t);
    // The gaps: data words 0, then 2..3, then 5 through the GOT's word 0.
    try testing.expectEqual(@as(usize, 3), t.view.copy_runs.len);
    try testing.expectEqual(@as(u32, 0), t.view.copy_runs[0].start);
    try testing.expectEqual(@as(u32, 1), t.view.copy_runs[0].end);
    try testing.expectEqual(@as(u32, 2), t.view.copy_runs[1].start);
    try testing.expectEqual(@as(u32, 4), t.view.copy_runs[1].end);
    try testing.expectEqual(@as(u32, 5), t.view.copy_runs[2].start);
    try testing.expectEqual(@as(u32, 7), t.view.copy_runs[2].end);
    try testing.expectEqual(@as(u32, 1), t.view.slots_written);

    const image_data: []const u8 = std.mem.sliceAsBytes(&[_]u32{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 });
    const image_got: []const u8 = std.mem.sliceAsBytes(&[_]u32{ 7, 7 });

    // The full start, then the extent start: both replayed to the same words.
    // Both blocks start out full of garbage, so a tail the extent path failed
    // to zero, or a written slot it failed to fill, shows up here.
    var full_data: [6]u32 align(4) = undefined;
    var full_got: [2]u32 align(4) = undefined;
    var full_thunks: [8]u32 align(4) = @splat(0xdead);
    const full: Layout = .{
        .data = std.mem.sliceAsBytes(&full_data),
        .got = std.mem.sliceAsBytes(&full_got),
        .thunks = std.mem.sliceAsBytes(&full_thunks),
    };
    @memcpy(full.data, image_data);
    @memcpy(full.got, image_got);
    @memset(full.thunks, 0);

    var part_data: [6]u32 align(4) = undefined;
    var part_got: [2]u32 align(4) = undefined;
    var part_thunks: [8]u32 align(4) = @splat(0xbeef);
    const part: Layout = .{
        .data = std.mem.sliceAsBytes(&part_data),
        .got = std.mem.sliceAsBytes(&part_got),
        .thunks = std.mem.sliceAsBytes(&part_thunks),
    };
    copy_from_image(part.data, part.got, image_data, image_got, t.view.copy_runs, t.view.copy_all);
    // One thunk slot is 16 bytes here, which is what `test_thunk` is.
    @memset(part.thunks[t.view.slots_written * test_thunk.len ..], 0);

    var bases_b: Bases = @splat(0);
    bases_b[region_kind(0)] = 0x3000_0000;
    bases_b[self_thunks] = 0x3100_0000;
    t.view.apply(full, &bases_b, &test_thunk);
    t.view.apply(part, &bases_b, &test_thunk);

    try testing.expectEqualSlices(u32, &full_data, &part_data);
    try testing.expectEqualSlices(u32, &full_got, &part_got);
    try testing.expectEqualSlices(u32, &full_thunks, &part_thunks);
    // The hole is what an unresolved weak function pointer leaves: its slot
    // must read back as the all-zero {r9, fn} descriptor, so `find_thunk` never
    // matches it and a stray branch lands on zeroes rather than stale bytes.
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0, 0 }, part_thunks[4..8]);
}

// A load whose stores are scattered past what can be named keeps no runs: the
// full copy stands, and a replay of such a template must not skip any word.
test "Template.CopyRunsPastTheCapFallBackToAFullCopy" {
    reset_for_test();
    defer reset_for_test();
    var data_a: [130]u32 align(4) = @splat(0x11);
    const layout_a: Layout = .{
        .data = std.mem.sliceAsBytes(&data_a),
        .got = &.{},
        .thunks = &.{},
    };
    var bases_a: Bases = @splat(0);
    bases_a[region_kind(0)] = 0x2000_0000;
    var capture = begin_capture(layout_a).?;
    var i: usize = 0;
    while (i < data_a.len) : (i += 2) {
        data_a[i] = @intCast(0x2000_0000 + i);
        capture.mark_ptr(&data_a[i], region_kind(0));
    }
    finish_capture(&capture, 0x1000_0000, &.{}, 0, &bases_a);

    const t = lookup(0x1000_0000).?;
    defer release(t);
    try testing.expectEqual(@as(usize, 0), t.view.copy_runs.len);
    try testing.expect(t.view.copy_all);

    // With no runs named, the extent copy is the full copy.
    var image_words: [130]u32 align(4) = @splat(0x11);
    const image_data: []const u8 = std.mem.sliceAsBytes(&image_words);
    var part_data: [130]u32 align(4) = undefined;
    const part: Layout = .{
        .data = std.mem.sliceAsBytes(&part_data),
        .got = &.{},
        .thunks = &.{},
    };
    copy_from_image(part.data, part.got, image_data, &.{}, t.view.copy_runs, t.view.copy_all);
    try testing.expectEqualSlices(u32, &image_words, &part_data);
}

test "Template.AllReplayedWordsNeedNoImageCopy" {
    reset_for_test();
    defer reset_for_test();
    var data: [2]u32 align(4) = .{ 17, 23 };
    const layout: Layout = .{ .data = std.mem.sliceAsBytes(&data), .got = &.{}, .thunks = &.{} };
    const bases: Bases = @splat(0);
    var capture = begin_capture(layout).?;
    capture.mark_ptr(&data[0], absolute);
    capture.mark_ptr(&data[1], absolute);
    finish_capture(&capture, 0x100, &.{}, 0, &bases);
    const t = lookup(0x100).?;
    defer release(t);
    try testing.expect(!t.view.copy_all);
    try testing.expectEqual(@as(usize, 0), t.view.copy_runs.len);
    var destination: [2]u32 align(4) = @splat(0xdeadbeef);
    const bytes = std.mem.sliceAsBytes(&destination);
    copy_from_image(bytes, &.{}, std.mem.sliceAsBytes(&data), &.{}, t.view.copy_runs, t.view.copy_all);
    try testing.expectEqual(@as(u32, 0xdeadbeef), destination[0]);
    t.view.apply(.{ .data = bytes, .got = &.{}, .thunks = &.{} }, &bases, &test_thunk);
    try testing.expectEqualSlices(u32, &data, &destination);
}

test "Template.InteriorThunkHolesAreClearedAndLaterSlotsReplay" {
    reset_for_test();
    defer reset_for_test();
    var thunks: [12]u32 align(4) = @splat(0);
    const layout: Layout = .{ .data = &.{}, .got = &.{}, .thunks = std.mem.sliceAsBytes(&thunks) };
    const bases: Bases = @splat(0);
    var capture = begin_capture(layout).?;
    for ([_]usize{ 0, 2 }) |slot| {
        thunks[slot * 4 + 2] = 0x2000;
        thunks[slot * 4 + 3] = 0x1001;
        capture.mark_ptr(&thunks[slot * 4 + 2], absolute);
        capture.mark_ptr(&thunks[slot * 4 + 3], absolute);
    }
    finish_capture(&capture, 0x100, &.{}, 3, &bases);
    const t = lookup(0x100).?;
    defer release(t);
    try testing.expectEqual(@as(u32, 1), t.view.slots_written);
    var replayed: [12]u32 align(4) = @splat(0xdeadbeef);
    @memset(replayed[4..], 0);
    t.view.apply(.{ .data = &.{}, .got = &.{}, .thunks = std.mem.sliceAsBytes(&replayed) }, &bases, &test_thunk);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, replayed[4..8]);
    try testing.expectEqual(@as(u32, 0x2000), replayed[10]);
    try testing.expectEqual(@as(u32, 0x1001), replayed[11]);
    try testing.expectEqualSlices(u8, test_thunk[0..8], std.mem.sliceAsBytes(&replayed)[32..40]);
}

test "Template.RejectsPartialThunkDescriptorsAndNonwordLayouts" {
    reset_for_test();
    defer reset_for_test();
    var thunks: [4]u32 align(4) = @splat(0);
    var capture = begin_capture(.{ .data = &.{}, .got = &.{}, .thunks = std.mem.sliceAsBytes(&thunks) }).?;
    capture.mark_ptr(&thunks[2], absolute);
    const bases: Bases = @splat(0);
    finish_capture(&capture, 0x100, &.{}, 1, &bases);
    try testing.expect(lookup(0x100) == null);
    var odd: [3]u8 = @splat(7);
    try testing.expect(begin_capture(.{ .data = &odd, .got = &.{}, .thunks = &.{} }) == null);
}

test "Template.ReplaysUnalignedThunkPairsWithIndependentBases" {
    const stores = [_]Entry{
        .{ .at = @as(u32, 0) << 8 | region_kind(0), .value = 4 },
        .{ .at = @as(u32, 1) << 8 | self_thunks, .value = 1 },
        .{ .at = @as(u32, 4) << 8 | region_kind(1), .value = 0x40 },
        .{ .at = @as(u32, 5) << 8 | image_kind(1), .value = 0x101 },
        .{ .at = @as(u32, 12) << 8 | absolute, .value = 0 },
        .{ .at = @as(u32, 13) << 8 | image_kind(0), .value = 0x201 },
    };
    // Both flash records and the replay API permit byte alignment. Exercise
    // that contract rather than relying on aligned test arrays.
    var encoded: [1 + @sizeOf(@TypeOf(stores))]u8 align(4) = undefined;
    @memcpy(encoded[1..], std.mem.sliceAsBytes(&stores));
    const view: View = .{
        .children = &.{1},
        .data_length = 4,
        .got_length = 4,
        .thunk_count = 3,
        .slots_written = 1,
        .entries = std.mem.bytesAsSlice(Entry, encoded[1..]),
    };
    try testing.expect(view.valid(thunk_size));
    var bases: Bases = @splat(0);
    bases[region_kind(0)] = 0x2000;
    bases[self_thunks] = 0x3000;
    bases[region_kind(1)] = 0xfffffff0; // descriptor addition wraps at 32 bits
    bases[image_kind(1)] = 0x10000100;
    bases[image_kind(0)] = 0x10001000;
    var data: [1]u32 = @splat(0xdeadbeef);
    var got: [1]u32 = @splat(0xdeadbeef);
    var storage: [1 + 3 * thunk_size + 1]u8 align(4) = @splat(0xee);
    const thunks = storage[1..][0 .. 3 * thunk_size];
    @memset(thunks[thunk_size..], 0); // complete prefix may skip clearing
    view.apply(.{ .data = std.mem.sliceAsBytes(&data), .got = std.mem.sliceAsBytes(&got), .thunks = thunks }, &bases, &test_thunk);
    try testing.expectEqual(@as(u32, 0x2004), data[0]);
    try testing.expectEqual(@as(u32, 0x3001), got[0]);
    try testing.expectEqualSlices(u8, test_thunk[0..thunk_r9_offset], thunks[0..thunk_r9_offset]);
    try testing.expectEqualSlices(u8, test_thunk[0..thunk_r9_offset], thunks[2 * thunk_size ..][0..thunk_r9_offset]);
    try testing.expectEqual(@as(u32, 0x30), std.mem.readInt(u32, thunks[8..12], .little));
    try testing.expectEqual(@as(u32, 0x10000201), std.mem.readInt(u32, thunks[12..16], .little));
    try testing.expectEqualSlices(u8, &@as([thunk_size]u8, @splat(0)), thunks[thunk_size .. 2 * thunk_size]);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, thunks[40..44], .little));
    try testing.expectEqual(@as(u32, 0x10001201), std.mem.readInt(u32, thunks[44..48], .little));
    try testing.expectEqual(@as(u8, 0xee), storage[0]);
    try testing.expectEqual(@as(u8, 0xee), storage[storage.len - 1]);
}

test "Template.PrecacheRejectsMalformedThunkPairsAndForeignSlotSizes" {
    const Blob = extern struct {
        header: PrecacheHeader,
        index: PrecacheIndex,
        record: PrecacheTemplate,
        stores: [4]Entry,
    };
    const blob: Blob = .{
        .header = .{ .magic = precache_magic, .version = precache_version, .size = @sizeOf(Blob), .entry_count = 1, .thunk_size = thunk_size },
        .index = .{ .hash_low = 1, .hash_high = 0, .offset = @offsetOf(Blob, "record") },
        .record = .{ .child_count = 0, .entry_count = 4, .data_length = 0, .got_length = 0, .thunk_count = 2, .slots_written = 2, .copy_run_count = 0 },
        .stores = .{
            .{ .at = @as(u32, 2) << 8 | absolute, .value = 7 },
            .{ .at = @as(u32, 3) << 8 | absolute, .value = 8 },
            .{ .at = @as(u32, 6) << 8 | absolute, .value = 9 },
            .{ .at = @as(u32, 7) << 8 | absolute, .value = 10 },
        },
    };
    defer precache = null;
    try set_precache(std.mem.asBytes(&blob), thunk_size);
    for (0..6) |case| {
        var bad = blob;
        switch (case) {
            0 => bad.record.entry_count = 3, // missing final fn
            1 => std.mem.swap(Entry, &bad.stores[0], &bad.stores[1]), // unsorted
            2 => bad.stores[1].at = bad.stores[0].at, // duplicate word
            3 => bad.stores[0].at = 0, // store into code
            4 => bad.stores[1].at = 7 << 8, // fn belongs to a later slot
            5 => bad.stores[3].at = 11 << 8, // past the thunk block
            else => unreachable,
        }
        try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&bad), thunk_size));
        try testing.expect(!have_precache());
    }
    var foreign = blob;
    foreign.header.thunk_size = 20;
    try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&foreign), thunk_size));
    try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&foreign), 20));
}

test "Template.PrecacheRejectsInvalidCoverageAndOverflowingCounts" {
    const Blob = extern struct {
        header: PrecacheHeader,
        index: PrecacheIndex,
        record: PrecacheTemplate,
        run: CopyRun,
        entry: Entry,
    };
    var blob: Blob = .{
        .header = .{ .magic = precache_magic, .version = precache_version, .size = @sizeOf(Blob), .entry_count = 1, .thunk_size = 16 },
        .index = .{ .hash_low = 1, .hash_high = 0, .offset = @offsetOf(Blob, "record") },
        .record = .{ .child_count = 0, .entry_count = 1, .data_length = 8, .got_length = 0, .thunk_count = 0, .copy_run_count = 1, .slots_written = 0, .copy_all = 0 },
        .run = .{ .start = 0, .end = 1 },
        .entry = .{ .at = @as(u32, 1) << 8 | absolute, .value = 7 },
    };
    defer precache = null;
    try set_precache(std.mem.asBytes(&blob), 16);
    var bad = blob;
    bad.run.end = 3;
    try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&bad), 16));
    try testing.expect(!have_precache());
    bad = blob;
    bad.record.entry_count = 0xffffffff;
    try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&bad), 16));
    bad = blob;
    bad.entry.at = 1 << 8 | 254;
    try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&bad), 16));
    bad = blob;
    bad.record.copy_all = 2;
    try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&bad), 16));
    bad = blob;
    bad.record.slots_written = 1;
    try testing.expectError(error.DoesNotFit, set_precache(std.mem.asBytes(&bad), 16));
    for ([_]u32{ 1, 2 }) |version| {
        bad = blob;
        bad.header.version = version;
        try testing.expectError(error.NotAPrecache, set_precache(std.mem.asBytes(&bad), 16));
    }
}

test "Template.AcceptsExactlySixtyFourCopyRuns" {
    reset_for_test();
    defer reset_for_test();
    var words: [128]u32 align(4) = @splat(0x11);
    const layout: Layout = .{ .data = std.mem.sliceAsBytes(&words), .got = &.{}, .thunks = &.{} };
    const bases: Bases = @splat(0);
    var capture = begin_capture(layout).?;
    for (&words, 0..) |*word, i| {
        if (i % 2 == 0) capture.mark_ptr(word, absolute);
    }
    finish_capture(&capture, 0x100, &.{}, 0, &bases);
    const t = lookup(0x100).?;
    defer release(t);
    try testing.expect(!t.view.copy_all);
    try testing.expectEqual(@as(usize, 64), t.view.copy_runs.len);
    var destination: [128]u32 align(4) = @splat(0xdeadbeef);
    const bytes = std.mem.sliceAsBytes(&destination);
    copy_from_image(bytes, &.{}, layout.data, &.{}, t.view.copy_runs, t.view.copy_all);
    t.view.apply(.{ .data = bytes, .got = &.{}, .thunks = &.{} }, &bases, &test_thunk);
    try testing.expectEqualSlices(u32, &words, &destination);
}
