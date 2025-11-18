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
const kernel = @import("../kernel.zig");

const c = @import("libc_imports").c;
const fs = @import("../fs/vfs.zig");
const IFile = @import("../fs/ifile.zig").IFile;
const systick = @import("systick.zig");
const time = @import("../time.zig");

const config = @import("config");

const process_manager = @import("../process_manager.zig");
const FileType = @import("../fs/ifile.zig").FileType;
const handlers = @import("syscall_handlers.zig");

fn get_file_from_process(fd: u16) ?*kernel.fs.IFile {
    const process = process_manager.instance.get_current_process();
    const maybe_handle = process.get_file_handle(fd);
    if (maybe_handle) |handle| {
        var maybe_file = handle.node.as_file();
        if (maybe_file) |*file| {
            return file;
        }
    }
    return null;
}

pub export fn _exit(code: c_int) void {
    const process = process_manager.instance.get_current_process();
    process_manager.instance.delete_process(process.pid, code);
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
    return handlers.sys_isatty(&fd) catch {
        return -1;
    };
}

pub export fn _close(fd: c_int) c_int {
    const process = process_manager.instance.get_current_process();
    process.release_file(@intCast(fd));
    return 0;
}

export fn _lseek(_: c_int, _: c.off_t, _: c_int) c_int {
    return 0;
}

pub export fn _read(fd: c_int, data: *anyopaque, size: usize) isize {
    const maybe_file = get_file_from_process(@intCast(fd));
    if (maybe_file) |file| {
        return file.interface.read(@as([*:0]u8, @ptrCast(data))[0..size]);
    }
    return 0;
}

pub export fn _write(fd: c_int, data: *const anyopaque, size: usize) isize {
    const maybe_file = get_file_from_process(@intCast(fd));
    if (maybe_file) |file| {
        return file.interface.write(@as([*:0]const u8, @ptrCast(data))[0..size]);
    }
    return 0;
}

pub export fn _ioctl(fd: c_int, request: c_int, data: ?*anyopaque) c_int {
    const maybe_file = get_file_from_process(@intCast(fd));
    if (maybe_file) |file| {
        return file.interface.ioctl(request, data);
    }
    return -1;
}

pub export fn _fcntl(fd: c_int, request: c_int, data: ?*anyopaque) c_int {
    const maybe_file = get_file_from_process(@intCast(fd));
    if (maybe_file) |file| {
        return file.interface.fcntl(request, data);
    }
    return -1;
}

pub export fn _nanosleep(ts: c.timespec) c_int {
    if (ts.tv_sec != 0) {
        time.sleep_ms(@intCast(ts.tv_sec * 1000));
    }

    if (ts.tv_nsec != 0) {
        time.sleep_us(@intCast(@divTrunc(ts.tv_nsec, 1000)));
    }

    return 0;
}

pub fn _time(t: ?*c.time_t) c.time_t {
    const ticks: c.time_t = @intCast(systick.get_system_ticks().*);
    if (t) |time_ptr| {
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
    const process = process_manager.instance.get_current_process();
    const prev_heap_end: *u8 = process.heap_end;
    const next_heap_end: *u8 = @ptrFromInt(@intFromPtr(process.heap_end) + incr);
    if (@intFromPtr(next_heap_end) >= @intFromPtr(&__heap_limit__)) {
        return @ptrFromInt(0);
    }
    process.heap_end = next_heap_end;
    return prev_heap_end;
}

export fn hard_assertion_failure() void {
    while (true) {}
}
