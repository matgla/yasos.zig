//
// system_stubs.zig
//
// Copyright (C) 2024 Mateusz Stadnik <matgla@live.com>
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
const log = &@import("../log/kernel_log.zig").kernel_log;

const c = @import("../libc_imports.zig").c;
const fs = @import("fs/vfs.zig");
const IFile = @import("fs/ifile.zig").IFile;
const systick = @import("interrupts/systick.zig");

const config = @import("config");

const process_manager = @import("process_manager.zig");
const FileType = @import("fs/ifile.zig").FileType;

pub export fn _exit(code: c_int) void {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process_manager.instance.delete_process(process.pid);
    } else {
        @panic("No process found");
    }
    log.print("Process exited with code {d}\n", .{code});
}

export fn _kill(_: c.pid_t, _: c_int) c.pid_t {
    return 0;
}

export fn _getpid() c.pid_t {
    return 0;
}

export fn panic(_: *const c_char, ...) void {
    while (true) {}
}

export fn _fstat(_: c_int, _: *c.struct_stat) c_int {
    return 0;
}

pub export fn _isatty(fd: c_int) c_int {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd));
        if (maybe_file) |file| {
            if (file.file.filetype() == FileType.CharDevice) return 1;
        }
    }
    return 0;
}

pub export fn _close(fd: c_int) c_int {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd));
        if (maybe_file) |file| {
            _ = file.file.close();
            _ = process.fds.remove(@intCast(fd));
            return 0;
        }
    }
    return 0;
}

export fn _lseek(_: c_int, _: c.off_t, _: c_int) c_int {
    return 0;
}

pub export fn _read(fd: c_int, data: *anyopaque, size: usize) isize {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd));
        if (maybe_file) |file| {
            return file.file.read(@as([*:0]u8, @ptrCast(data))[0..size]);
        }
    }
    return 0;
}

pub export fn _write(fd: c_int, data: *const anyopaque, size: usize) isize {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd));
        if (maybe_file) |file| {
            return file.file.write(@as([*:0]const u8, @ptrCast(data))[0..size]);
        }
    }
    return -1;
}

pub export fn _ioctl(fd: c_int, request: c_int, data: ?*anyopaque) c_int {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd));
        if (maybe_file) |file| {
            return file.file.ioctl(request, data);
        }
    }
    return -1;
}

pub export fn _fcntl(fd: c_int, request: c_int, data: ?*anyopaque) c_int {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd));
        if (maybe_file) |file| {
            return file.file.fcntl(request, data);
        }
    }
    return -1;
}

pub fn _mmap(addr: ?*anyopaque, size: i32, prot: i32, flags: i32, fd: i32, offset: i32) *allowzero anyopaque {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        return process.mmap(addr, size, prot, flags, fd, offset) catch {
            return @ptrFromInt(0);
        };
    }

    return @ptrFromInt(0);
}

pub fn _munmap(addr: ?*anyopaque, length: i32) i32 {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process.munmap(addr, length);
        return 0;
    }
    return -1;
}

pub fn _open(path: *const c_char, _: c_int, _: c_int) c_int {
    const maybe_process = process_manager.instance.get_current_process();
    const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(path)));
    if (maybe_process) |process| {
        const maybe_file = fs.ivfs().get(path_slice);
        if (maybe_file) |file| {
            defer file.destroy();
            const fd = process.get_free_fd();
            const maybe_ifile = file.dupe();
            if (maybe_ifile) |ifile| {
                process.fds.put(fd, .{
                    .file = ifile,
                    .path = blk: {
                        var path_buffer: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
                        std.mem.copyForwards(u8, path_buffer[0..path_slice.len], path_slice);
                        break :blk path_buffer;
                    },
                    .diriter = null,
                }) catch {
                    return -1;
                };
                return fd;
            }
        }
    }
    return -1;
}

const DirentTraverseTracker = struct {
    dirp: *allowzero c.dirent,
    offset: usize,
    count: usize,
    skipuntil: ?IFile,
    lastfile: ?IFile,
};

// most stupid way to keep track of the last file
pub fn traverse_directory(file: *IFile, context: *anyopaque) bool {
    const tracker: *DirentTraverseTracker = @ptrCast(@alignCast(context));
    const required_space = std.mem.alignForward(usize, @sizeOf(c.dirent) - 1 + file.name().len, @alignOf(c.dirent));
    // skip files that were already traversed

    if (tracker.skipuntil) |lastfile| {
        if (std.mem.eql(u8, lastfile.name(), file.name())) {
            _ = lastfile.close();
            tracker.skipuntil = null;
        }

        return true;
    }
    if (tracker.offset + required_space > tracker.count) {
        if (tracker.lastfile) |lastfile| {
            _ = lastfile.close();
        }
        tracker.lastfile = file.dupe();
        return false;
    }
    const address = @intFromPtr(tracker.dirp) + tracker.offset;
    const dirp: *c.dirent = @ptrCast(@alignCast(@as(*c.dirent, @ptrFromInt(address))));
    dirp.d_ino = 0xdead;
    dirp.d_off = 0xbeef;
    dirp.d_reclen = @intCast(required_space);
    std.mem.copyForwards(u8, dirp.d_name[0..], file.name());
    dirp.d_name[file.name().len] = 0;
    tracker.offset += required_space;
    if (tracker.lastfile) |lastfile| {
        _ = lastfile.close();
    }
    tracker.lastfile = file.dupe();

    return true;
}

pub fn _getdents(fd: c_int, dirp: *anyopaque, count: usize) isize {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_entity = process.fds.getPtr(@intCast(fd));
        if (maybe_entity) |entity| {
            var tracker = DirentTraverseTracker{
                .dirp = @ptrCast(@alignCast(dirp)),
                .offset = 0,
                .count = count,
                .skipuntil = if (entity.diriter != null) entity.diriter.?.dupe() else null,
                .lastfile = null,
            };
            _ = fs.ivfs().traverse(std.mem.span(@as([*:0]const u8, @ptrCast(&entity.path))), traverse_directory, &tracker);
            if (entity.diriter) |*diriter| {
                _ = diriter.close();
            }
            entity.diriter = tracker.lastfile;
            return @intCast(tracker.offset);
        }
    }
    return 0;
}

pub fn _chdir(path: *const c_char) c_int {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(path)));
        if (path_slice.len == 0) {
            return -1;
        }
        const maybe_file = fs.ivfs().get(path_slice);
        if (maybe_file) |file| {
            defer file.destroy();
            if (file.filetype() == FileType.Directory) {
                process.change_directory(path_slice) catch |err| {
                    log.print("chdir: failed to change directory: {s}\n", .{@errorName(err)});
                    return -1;
                };
                return 0;
            }
        }
    }
    return -1;
}

pub fn _time(time: ?*c.time_t) c.time_t {
    const ticks: c.time_t = @intCast(systick.get_system_ticks());
    if (time) |time_ptr| {
        time_ptr.* = ticks;
    }
    return ticks;
}

extern var end: u8;
extern var __heap_limit__: u8;
var heap_end: *u8 = &end;

export fn _sbrk(incr: usize) *allowzero anyopaque {
    const prev_heap_end: *u8 = heap_end;
    const next_heap_end: *u8 = @ptrFromInt(@intFromPtr(heap_end) + incr);

    if (@intFromPtr(next_heap_end) >= @intFromPtr(&__heap_limit__)) {
        return @ptrFromInt(0);
    }
    heap_end = next_heap_end;
    return prev_heap_end;
}

pub fn process_sbrk(incr: usize) *allowzero anyopaque {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const prev_heap_end: *u8 = process.heap_end;
        const next_heap_end: *u8 = @ptrFromInt(@intFromPtr(process.heap_end) + incr);
        if (@intFromPtr(next_heap_end) >= @intFromPtr(&__heap_limit__)) {
            return @ptrFromInt(0);
        }
        process.heap_end = next_heap_end;
        return prev_heap_end;
    }
}

export fn hard_assertion_failure() void {
    while (true) {}
}
