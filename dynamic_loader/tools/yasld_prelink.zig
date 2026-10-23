//
// yasld_prelink.zig
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

//! Build the loader precache for a rootfs: load every image the way the
//! device would, with the device's own loader, and write out the templates
//! that recorded (template.zig). The device reads the result in place from
//! flash, so even the first exec of a program after boot is a list of stores
//! instead of a relocation.
//!
//!   yasld-prelink OUTPUT LIBDIR IMAGE...
//!   find rootfs -type f | yasld-prelink OUTPUT LIBDIR -
//!
//! LIBDIR is where the device resolves dependencies (the rootfs's /lib).
//! Files that are not YAFF images are skipped, so the list can be every
//! regular file in the rootfs; `-` reads it from stdin, one path per line. Built for a 32-bit host: the loader computes with
//! `usize` addresses, and the device's are 32 bits.

const std = @import("std");
const yasld = @import("yasld");
const template = yasld.template;

pub const std_options: std.Options = .{ .log_level = .warn };

comptime {
    if (@sizeOf(usize) != 4) @compileError("yasld-prelink must be built for a 32-bit target (-target x86-linux)");
}

/// The thunk slot the device's indirect_call_thunk.S lays out. Only its size
/// and descriptor offsets matter here: a template stores the descriptor words,
/// the device lays down the code.
export const indirect_call_thunk_template_size: usize = template.thunk_size;
export fn indirect_call_thunk_template_start() callconv(.naked) void {
    asm volatile (std.fmt.comptimePrint(".skip {d}", .{template.thunk_size}));
}

const gpa = std.heap.page_allocator;

var io_global: std.Io = undefined;
var lib_dir_path: []const u8 = undefined;

/// Images read so far, by library name, so each is loaded at one address --
/// as on the device, where a library is one romfs file.
var libraries: std.StringHashMapUnmanaged([]align(16) u8) = .empty;

fn read_image(path: []const u8) ?[]align(16) u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io_global, path, gpa, .limited(256 << 20), .@"16", null) catch |err| {
        std.log.err("{s}: {s}", .{ path, @errorName(err) });
        return null;
    };
}

fn resolve_library(name: []const u8) ?yasld.Image {
    if (libraries.get(name)) |image| return image;
    const path = std.fs.path.join(gpa, &.{ lib_dir_path, name }) catch return null;
    const image = read_image(path) orelse return null;
    const key = gpa.dupe(u8, name) catch return null;
    libraries.put(gpa, key, image) catch return null;
    return image;
}

fn is_yaff(bytes: []const u8) bool {
    return bytes.len >= @sizeOf(yasld.Header) and std.mem.eql(u8, bytes[0..4], "YAFF");
}

fn image_hash(image: usize) u64 {
    if (template.memo_lookup(image)) |hash| return hash;
    const header: *const yasld.Header = @ptrFromInt(image);
    const base: [*]const u8 = @ptrFromInt(image);
    // The GOT follows text, init, plt and data (Parser.create).
    const got_at = header.text_offset + header.code_length + header.init_length + header.plt_length + header.data_length;
    const hash = template.content_hash(base, header.text_offset, base[got_at..][0..header.got_length]);
    template.memo_store(image, hash);
    return hash;
}

const Collected = struct {
    hash: u64,
    children: []u64,
    copy_runs: []template.CopyRun,
    slots_written: u32,
    copy_all: bool,
    data_length: u32,
    got_length: u32,
    thunk_count: u32,
    entries: []template.Entry,
};

var collected: std.AutoArrayHashMapUnmanaged(u64, Collected) = .empty;

/// Take every template the loads so far left in the cache. The cache holds
/// a few dozen, so this runs after each image rather than once at the end.
fn collect() !void {
    for (template.cached()) |maybe| {
        const t = maybe orelse continue;
        const hash = image_hash(t.image);
        if (collected.contains(hash)) continue;
        const children = try gpa.alloc(u64, t.view.children.len);
        for (children, t.view.children) |*child, image| child.* = image_hash(@intCast(image));
        const copy_runs = try gpa.alloc(template.CopyRun, t.view.copy_runs.len);
        for (copy_runs, t.view.copy_runs) |*to, from| to.* = from;
        const entries = try gpa.alloc(template.Entry, t.view.entries.len);
        for (entries, t.view.entries) |*to, from| to.* = from;
        try collected.put(gpa, hash, .{
            .hash = hash,
            .children = children,
            .copy_runs = copy_runs,
            .slots_written = t.view.slots_written,
            .copy_all = t.view.copy_all,
            .data_length = t.view.data_length,
            .got_length = t.view.got_length,
            .thunk_count = t.view.thunk_count,
            .entries = entries,
        });
    }
}

fn lessThan(_: void, a: Collected, b: Collected) bool {
    return a.hash < b.hash;
}

fn write_cache(output: []const u8) !void {
    const items = try gpa.dupe(Collected, collected.values());
    std.mem.sort(Collected, items, {}, lessThan);

    var out: std.ArrayList(u8) = .empty;
    const index_at = @sizeOf(template.PrecacheHeader);
    var offset: usize = index_at + items.len * @sizeOf(template.PrecacheIndex);
    try out.appendNTimes(gpa, 0, offset);
    for (items, 0..) |item, i| {
        const index: template.PrecacheIndex = .{
            .hash_low = @truncate(item.hash),
            .hash_high = @truncate(item.hash >> 32),
            .offset = @intCast(offset),
        };
        @memcpy(out.items[index_at + i * @sizeOf(template.PrecacheIndex) ..][0..@sizeOf(template.PrecacheIndex)], std.mem.asBytes(&index));
        const head: template.PrecacheTemplate = .{
            .child_count = @intCast(item.children.len),
            .entry_count = @intCast(item.entries.len),
            .data_length = item.data_length,
            .got_length = item.got_length,
            .thunk_count = item.thunk_count,
            .copy_run_count = @intCast(item.copy_runs.len),
            .slots_written = item.slots_written,
            .copy_all = @intFromBool(item.copy_all),
        };
        try out.appendSlice(gpa, std.mem.asBytes(&head));
        try out.appendSlice(gpa, std.mem.sliceAsBytes(item.children));
        try out.appendSlice(gpa, std.mem.sliceAsBytes(item.copy_runs));
        try out.appendSlice(gpa, std.mem.sliceAsBytes(item.entries));
        offset = out.items.len;
    }
    const header: template.PrecacheHeader = .{
        .magic = template.precache_magic,
        .version = template.precache_version,
        .size = @intCast(out.items.len),
        .entry_count = @intCast(items.len),
        .thunk_size = indirect_call_thunk_template_size,
    };
    @memcpy(out.items[0..@sizeOf(template.PrecacheHeader)], std.mem.asBytes(&header));
    try std.Io.Dir.cwd().writeFile(io_global, .{ .sub_path = output, .data = out.items });
}

pub fn main(init: std.process.Init) !void {
    io_global = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.log.err("usage: yasld-prelink OUTPUT LIBDIR IMAGE...", .{});
        std.process.exit(2);
    }
    const output = args[1];
    lib_dir_path = args[2];

    // Accept whatever an image declares: refusing an image is the device's
    // decision, made against its own hardware at exec time.
    const machine: yasld.MachineProfile = .{
        .arch = .Armv8_m,
        .float_abi = .Softfp,
        .features = .{ .fpu_sp = true, .fpu_dp = true, .dcp = true },
    };
    yasld.loader_init(&resolve_library, gpa, machine);
    yasld.set_load_map_logging(false);
    template.enable(gpa, .{ .lock = &no_lock, .unlock = &no_unlock });
    const loader = yasld.get_loader().?;

    var paths: std.ArrayList([]const u8) = .empty;
    for (args[3..]) |arg| {
        if (!std.mem.eql(u8, arg, "-")) {
            try paths.append(gpa, arg);
            continue;
        }
        var buffer: [4096]u8 = undefined;
        var stdin = std.Io.File.stdin().reader(io_global, &buffer);
        const list = try stdin.interface.allocRemaining(gpa, .unlimited);
        var lines = std.mem.tokenizeScalar(u8, list, '\n');
        while (lines.next()) |line| try paths.append(gpa, line);
    }

    var loaded: usize = 0;
    var skipped: usize = 0;
    for (paths.items) |path| {
        const image = read_image(path) orelse continue;
        if (!is_yaff(image)) {
            gpa.free(image);
            continue;
        }
        const header: *const yasld.Header = @ptrCast(image.ptr);
        switch (header.module_type) {
            1 => {
                const executable = loader.load_executable(image, gpa, true) catch |err| {
                    std.log.warn("{s}: not precached ({s})", .{ path, @errorName(err) });
                    skipped += 1;
                    continue;
                };
                _ = executable;
            },
            2 => {
                // Loaded through `libraries`, so a library that is also an
                // executable's dependency is one image, one hash.
                const base = std.fs.path.basename(path);
                const library = resolve_library(base) orelse continue;
                _ = loader.load_library(library, gpa, true) catch |err| {
                    std.log.warn("{s}: not precached ({s})", .{ path, @errorName(err) });
                    skipped += 1;
                    continue;
                };
            },
            else => continue,
        }
        loaded += 1;
        try collect();
    }
    if (loaded == 0) return error.NoImagesPrecached;
    try write_cache(output);
    std.debug.print("template verification: {d} checked, {d} failures\n", .{ template.stats.verified, template.stats.verification_failures });
    std.debug.print("yasld-prelink: {d} images loaded, {d} skipped, {d} templates -> {s}\n", .{ loaded, skipped, collected.count(), output });
}

fn no_lock() usize {
    return 0;
}

fn no_unlock(_: usize) void {}
