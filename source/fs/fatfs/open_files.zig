// Copyright (c) 2026 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

//! The files the kernel holds open on FAT volumes, so that unlink and rename
//! can find the ones whose directory entry they are about to change.
//!
//! FatFs is built `FF_FS_LOCK 0`: it keeps no table of open objects and lets
//! f_unlink and f_rename change an entry a FIL still points at. The FIL keeps
//! the entry's place (`dir_sect`, `dir_ptr`), and every f_sync -- f_close
//! makes one -- writes its start cluster and size back to that place. After an
//! unlink the place is a free slot the next file created in that directory
//! takes, so the dead file's close rewrote the new file's entry to point at
//! clusters f_unlink had already freed: the new file read back the old one's
//! data at the old one's size, the FAT and the entry disagreed, and later
//! allocations cross-linked them. A rename left the FIL writing to the
//! abandoned slot, and the renamed file lost what was written after the
//! rename. Any process that deletes a directory while files in it are still
//! open, then exits, does this to whatever directory the slots end up in.
//!
//! What POSIX promises is kept instead: a name removed from an open file is
//! gone at once, the file lives on for its handles (an orphan: it never
//! touches a directory entry again, and its clusters are freed at the last
//! close), and a rename moves the handles to the new entry.
//!
//! Everything here runs under `fs_lock`.

const std = @import("std");
const fatfs = @import("zfat");

const kernel = @import("kernel");
const fs_lock = @import("fs_lock.zig");

const log = std.log.scoped(.fatfs_open_files);

/// FIL.flag bits from ff.c (ff.h does not export them). FatFs writes the
/// directory entry at f_sync only while `modified` is set; `dirty` is a
/// FIL.buf[] not yet written back.
const fa_modified: u8 = 0x40;
const fa_dirty: u8 = 0x80;
const fa_write: u8 = @intFromEnum(fatfs.File.Access.write_only);

/// A FatFs file the kernel holds open. On the heap: it holds a sector buffer,
/// and FatFsFile is created on a process's stack.
pub const OpenFile = struct {
    file: fatfs.File,
    /// The name is gone (unlinked, or replaced by a rename): `file` must never
    /// write its old entry, which another file may own by now.
    orphan: bool = false,
    /// The orphan's clusters are named by no entry, so they are its to free at
    /// the last close.
    frees_chain: bool = false,
    /// Marked by `begin_move` for `end_move`.
    moving: bool = false,
    prev: ?*OpenFile = null,
    next: ?*OpenFile = null,

    /// After any operation that may have set FA_MODIFIED: an orphan's entry is
    /// not its own any more.
    pub fn settle(self: *OpenFile) void {
        if (self.orphan) self.file.raw.flag &= ~fa_modified;
    }
};

var head: ?*OpenFile = null;

pub fn add(of: *OpenFile) void {
    fs_lock.lock.assert_held();
    of.prev = null;
    of.next = head;
    if (head) |h| h.prev = of;
    head = of;
}

pub fn remove(of: *OpenFile) void {
    fs_lock.lock.assert_held();
    if (of.prev) |p| p.next = of.next else head = of.next;
    if (of.next) |n| n.prev = of.prev;
    of.prev = null;
    of.next = null;
}

fn same_entry(a: *const fatfs.File, b: *const fatfs.File) bool {
    return a.raw.obj.fs == b.raw.obj.fs and a.raw.dir_sect == b.raw.dir_sect and a.raw.dir_ptr == b.raw.dir_ptr;
}

/// The entry `path` names, as a read-only FIL, or null for a directory or
/// nothing. Costs a directory walk, so it is only taken while something is
/// open.
fn probe(allocator: std.mem.Allocator, path: [:0]const u8) !?*fatfs.File {
    if (head == null) return null;
    const file = try allocator.create(fatfs.File);
    const flags = @intFromEnum(fatfs.File.Mode.open_existing) | @intFromEnum(fatfs.File.Access.read_only);
    fatfs.File.OpenError.throw(fatfs.api.open(&file.raw, path.ptr, flags)) catch {
        allocator.destroy(file);
        return null;
    };
    return file;
}

fn drop_probe(allocator: std.mem.Allocator, file: *fatfs.File) void {
    // Read-only and never modified: f_close writes nothing.
    file.close();
    allocator.destroy(file);
}

/// `path` is about to lose its directory entry (unlink, or the destination of
/// a rename). Turns the handles open on it into orphans and leaves the entry
/// naming no clusters the orphans still use, so f_unlink frees only what
/// nobody holds.
pub fn detach(allocator: std.mem.Allocator, path: [:0]const u8) !void {
    fs_lock.lock.assert_held();
    const entry = (try probe(allocator, path)) orelse return;
    defer drop_probe(allocator, entry);

    var entry_chain = entry.raw.obj.sclust;
    var found = false;
    var it = head;
    while (it) |of| : (it = of.next) {
        if (of.orphan or !same_entry(&of.file, entry)) continue;
        // First make the entry say what the handle has: one that truncated
        // freed the chain the entry may still name, and f_unlink would free it
        // a second time from under whoever took it since.
        if (of.file.raw.flag & fa_modified != 0) {
            of.file.sync() catch |err| log.warn("sync before unlink: {t}", .{err});
            entry_chain = of.file.raw.obj.sclust;
        }
        of.orphan = true;
        of.frees_chain = true;
        found = true;
    }
    if (!found) return;

    // The entry's chain belongs to an orphan now: the entry stops naming it,
    // so f_unlink leaves it alone. A chain no handle uses is f_unlink's to free.
    it = head;
    while (it) |of| : (it = of.next) {
        if (of.orphan and same_entry(&of.file, entry) and entry_chain >= 2 and of.file.raw.obj.sclust == entry_chain) {
            entry.raw.obj.sclust = 0;
            entry.raw.obj.objsize = 0;
            entry.raw.flag |= fa_modified;
            try entry.sync();
            break;
        }
    }
}

/// Before f_rename(`path`, ...): the entry is copied to the new name as it is
/// on the disk, so the handles open on it write what they have first, and are
/// marked for `end_move`.
pub fn begin_move(allocator: std.mem.Allocator, path: [:0]const u8) !void {
    fs_lock.lock.assert_held();
    const entry = (try probe(allocator, path)) orelse return;
    defer drop_probe(allocator, entry);
    var it = head;
    while (it) |of| : (it = of.next) {
        if (of.orphan or !same_entry(&of.file, entry)) continue;
        if (of.file.raw.flag & fa_modified != 0) try of.file.sync();
        of.moving = true;
    }
}

/// After f_rename: the handles `begin_move` marked follow the entry to
/// `new_path` (null when the rename failed and the entry stayed where it was).
pub fn end_move(allocator: std.mem.Allocator, new_path: ?[:0]const u8) void {
    fs_lock.lock.assert_held();
    const entry: ?*fatfs.File = if (new_path) |p| probe(allocator, p) catch null else null;
    defer if (entry) |e| drop_probe(allocator, e);
    var it = head;
    while (it) |of| : (it = of.next) {
        if (!of.moving) continue;
        of.moving = false;
        if (new_path == null) continue;
        if (entry) |e| {
            of.file.raw.dir_sect = e.raw.dir_sect;
            of.file.raw.dir_ptr = e.raw.dir_ptr;
        } else {
            // Renamed, but the new entry cannot be found: the old slot is free
            // and the new entry names the chain. Writing nowhere and freeing
            // nothing leaks at worst.
            log.err("renamed entry not found; an open file stops updating it", .{});
            of.orphan = true;
            of.frees_chain = false;
            of.settle();
        }
    }
}

/// At the last close of an orphan: free its clusters, unless another orphan
/// still reads the same chain. Nothing of the file is read again, so its
/// buffer is dropped rather than written.
pub fn release(of: *OpenFile) void {
    fs_lock.lock.assert_held();
    if (!of.orphan) return;
    const raw = &of.file.raw;
    raw.flag &= ~(fa_modified | fa_dirty);
    if (!of.frees_chain) return;
    of.frees_chain = false;
    if (raw.obj.sclust < 2) return;
    var it = head;
    while (it) |other| : (it = other.next) {
        if (other != of and other.orphan and other.file.raw.obj.fs == raw.obj.fs and other.file.raw.obj.sclust == raw.obj.sclust) return;
    }
    // f_truncate at position 0 removes the whole chain; it frees only past
    // the position, so an empty file with clusters is given a size first.
    raw.flag |= fa_write;
    of.file.seekTo(0) catch |err| return log.warn("orphan seek: {t}", .{err});
    if (raw.obj.objsize == 0) raw.obj.objsize = 1;
    of.file.truncate() catch |err| log.warn("orphan clusters not freed: {t}", .{err});
    raw.flag &= ~fa_modified;
}
