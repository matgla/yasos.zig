//
// mount_api.zig
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

// mount(2) and umount(2), the kernel half.
//
// Mounting needs the filesystem drivers (FatFs, littlefs, ramfs...), which
// live outside the kernel module, so `mount` goes through a backend the boot
// code installs (`source/fs/mounter.zig`). Unmounting needs nothing but the
// mount tree and the process table, so it is done here.
//
// A mount cannot be taken away while it is busy: while a process works inside
// it or holds a descriptor under it, while something is mounted below it, or
// while a bind mount's source lies in it (a pin). The kernel's other users of
// a path -- the kernel log in /var/log, the /tmp spill in /var/tmp -- let go
// of it instead: `umount` asks them to (`User`), and a later mount over the
// path gives it back. That is what lets /var come off a running system to have
// its card reformatted.

const std = @import("std");

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.@"kernel/fs/mount");

pub const Request = struct {
    source: []const u8,
    target: []const u8,
    fstype: []const u8,
    flags: u32 = 0,
    options: []const u8 = "",
};

pub const MountFn = *const fn (request: Request) anyerror!void;

/// Installed at boot by the code that knows the filesystem types.
pub var backend: ?MountFn = null;

pub fn mount(request: Request) !void {
    const handler = backend orelse return kernel.errno.ErrnoSet.NotImplemented;
    try handler(request);
    reattach_users_under(request.target);
}

/// `path` is `prefix` or lies below it, compared by whole components.
pub fn path_is_under(path: []const u8, prefix: []const u8) bool {
    const trimmed_prefix = std.mem.trimEnd(u8, prefix, "/");
    if (trimmed_prefix.len == 0) return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, trimmed_prefix)) return false;
    return path.len == trimmed_prefix.len or path[trimmed_prefix.len] == '/';
}

const max_pins = 8;
const Pin = struct {
    buffer: [64]u8 = undefined,
    len: u8 = 0,
    count: u8 = 0,

    fn path(self: *const Pin) []const u8 {
        return self.buffer[0..self.len];
    }
};
var pins: [max_pins]Pin = @splat(.{});
/// Rank `fs`, inner to `mount`: a bind mount unpins its source from `delete`,
/// which `umount` runs with the mount tree locked.
var pin_lock: kernel.sync.RankedMutex(.fs) = .{};

/// Mark `path` as something the kernel keeps using. The mount holding it
/// cannot be unmounted until `unpin`. Pins count, so two users of one path
/// each pin and unpin it.
pub fn pin(path: []const u8) !void {
    pin_lock.lock();
    defer pin_lock.unlock();
    for (&pins) |*slot| {
        if (slot.count != 0 and std.mem.eql(u8, slot.path(), path)) {
            slot.count += 1;
            return;
        }
    }
    for (&pins) |*slot| {
        if (slot.count != 0) continue;
        if (path.len > slot.buffer.len) return kernel.errno.ErrnoSet.NameTooLong;
        @memcpy(slot.buffer[0..path.len], path);
        slot.len = @intCast(path.len);
        slot.count = 1;
        return;
    }
    return kernel.errno.ErrnoSet.OutOfMemory;
}

pub fn unpin(path: []const u8) void {
    pin_lock.lock();
    defer pin_lock.unlock();
    for (&pins) |*slot| {
        if (slot.count != 0 and std.mem.eql(u8, slot.path(), path)) {
            slot.count -= 1;
            return;
        }
    }
}

/// A kernel subsystem working in `path` that can stop when the mount holding
/// it goes away. `release` stops it -- an error keeps the mount, busy -- and
/// `reattach` restarts it once a mount covers `path` again. Both run with no
/// lock held, so they may do file I/O.
pub const User = struct {
    path: []const u8,
    release: *const fn () anyerror!void,
    reattach: *const fn () void,
};

const max_users = 4;
/// Filled at boot; read through `snapshot_users`.
var users: [max_users]?*const User = @splat(null);

pub fn register_user(user: *const User) !void {
    pin_lock.lock();
    defer pin_lock.unlock();
    for (&users) |*slot| {
        if (slot.* == null) {
            slot.* = user;
            return;
        }
    }
    return kernel.errno.ErrnoSet.OutOfMemory;
}

fn snapshot_users() [max_users]?*const User {
    pin_lock.lock();
    defer pin_lock.unlock();
    return users;
}

/// Release every user under `prefix`, recording each in `released`. On the
/// first refusal the ones already released are reattached and the mount is
/// busy.
fn release_users_under(prefix: []const u8, released: *[max_users]?*const User) !void {
    for (snapshot_users(), 0..) |maybe_user, index| {
        const user = maybe_user orelse continue;
        if (!path_is_under(user.path, prefix)) continue;
        user.release() catch |err| {
            log.info("umount {s}: busy, the kernel uses {s} ({s})", .{ prefix, user.path, @errorName(err) });
            reattach_all(released);
            return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
        };
        released[index] = user;
    }
}

fn reattach_all(released: *const [max_users]?*const User) void {
    for (released) |maybe_user| {
        if (maybe_user) |user| user.reattach();
    }
}

fn reattach_users_under(target: []const u8) void {
    for (snapshot_users()) |maybe_user| {
        const user = maybe_user orelse continue;
        if (path_is_under(user.path, target)) user.reattach();
    }
}

fn pinned_under(prefix: []const u8) ?[]const u8 {
    pin_lock.lock();
    defer pin_lock.unlock();
    for (&pins) |*slot| {
        if (slot.count != 0 and path_is_under(slot.path(), prefix)) return slot.path();
    }
    return null;
}

/// umount(2). `target` is an absolute path.
pub fn umount(target: []const u8) !void {
    const path = std.mem.trimEnd(u8, target, "/");
    if (path.len == 0) return kernel.errno.ErrnoSet.DeviceOrResourceBusy; // "/"
    if (target[0] != '/') return kernel.errno.ErrnoSet.InvalidArgument;
    if (pinned_under(path)) |user| {
        log.info("umount {s}: busy, the kernel uses {s}", .{ path, user });
        return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
    }
    if (kernel.process.process_manager.instance.path_in_use(path)) {
        return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
    }
    var released: [max_users]?*const User = @splat(null);
    try release_users_under(path, &released);
    kernel.fs.get_vfs().mount_points.umount(path) catch |err| {
        reattach_all(&released);
        return switch (err) {
            error.NotMounted => kernel.errno.ErrnoSet.InvalidArgument,
            else => err,
        };
    };
}

test "MountApi.PathIsUnderComparesWholeComponents" {
    try std.testing.expect(path_is_under("/var/log/kernel.log", "/var"));
    try std.testing.expect(path_is_under("/var", "/var/"));
    try std.testing.expect(!path_is_under("/variable", "/var"));
    try std.testing.expect(path_is_under("/anything", "/"));
    try std.testing.expect(!path_is_under("/home", "/home/root"));
}

const TestUsers = struct {
    var log_held = true;
    var spill_held = true;
    var spill_refuses = false;

    fn release_log() anyerror!void {
        log_held = false;
    }
    fn reattach_log() void {
        log_held = true;
    }
    fn release_spill() anyerror!void {
        if (spill_refuses) return error.Busy;
        spill_held = false;
    }
    fn reattach_spill() void {
        spill_held = true;
    }

    const log_user: User = .{ .path = "/var/log", .release = &release_log, .reattach = &reattach_log };
    const spill_user: User = .{ .path = "/var/tmp", .release = &release_spill, .reattach = &reattach_spill };
};

test "MountApi.UsersLetGoOnUmountAndComeBackOnMount" {
    const saved = users;
    defer users = saved;
    users = @splat(null);
    try register_user(&TestUsers.log_user);
    try register_user(&TestUsers.spill_user);

    var released: [max_users]?*const User = @splat(null);
    try release_users_under("/home", &released);
    try std.testing.expect(TestUsers.log_held and TestUsers.spill_held);

    try release_users_under("/var", &released);
    try std.testing.expect(!TestUsers.log_held and !TestUsers.spill_held);

    reattach_users_under("/var");
    try std.testing.expect(TestUsers.log_held and TestUsers.spill_held);
}

test "MountApi.AUserThatRefusesKeepsTheMountAndTheOthers" {
    const saved = users;
    defer users = saved;
    users = @splat(null);
    try register_user(&TestUsers.log_user);
    try register_user(&TestUsers.spill_user);
    TestUsers.spill_refuses = true;
    defer TestUsers.spill_refuses = false;

    var released: [max_users]?*const User = @splat(null);
    try std.testing.expectError(kernel.errno.ErrnoSet.DeviceOrResourceBusy, release_users_under("/var", &released));
    // The log was released first and is given back.
    try std.testing.expect(TestUsers.log_held and TestUsers.spill_held);
}

test "MountApi.PinsCountAndBlockTheirMount" {
    try pin("/var/tmp");
    try pin("/var/tmp");
    try std.testing.expectEqualStrings("/var/tmp", pinned_under("/var").?);
    unpin("/var/tmp");
    try std.testing.expect(pinned_under("/var") != null);
    unpin("/var/tmp");
    try std.testing.expect(pinned_under("/var") == null);
    try std.testing.expect(pinned_under("/home") == null);
}
