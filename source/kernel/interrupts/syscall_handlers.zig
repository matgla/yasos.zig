// Copyright (c) 2025 Mateusz Stadnik
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

const std = @import("std");
const process_manager = @import("../process_manager.zig");

const Semaphore = @import("../semaphore.zig").Semaphore;
const KernelSemaphore = @import("kernel_semaphore.zig").KernelSemaphore;

const FileType = @import("../fs/ifile.zig").FileType;
const IFile = @import("../fs/ifile.zig").IFile;

const fs = @import("../fs/vfs.zig");
const log = &@import("../../log/kernel_log.zig").kernel_log;

const systick = @import("systick.zig");

const config = @import("config");

const c = @import("../../libc_imports.zig").c;

const E = enum(u16) {
    EINVAL = c.EINVAL,
};

pub fn errno(rc: u16) anyerror {
    return @errorFromInt(rc);
}

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

const DirentTraverseTracker = struct {
    dirp: *allowzero c.dirent,
    offset: usize,
    count: usize,
    skipuntil: ?IFile,
    lastfile: ?IFile,
};

pub const CreateProcessCall = struct {
    allocator: std.mem.Allocator,
    entry: *const anyopaque,
    stack_size: u32,
    arg: ?*const anyopaque,
};

pub const SemaphoreEvent = struct {
    object: *Semaphore,
};

extern fn switch_to_next_task() void;

pub fn sys_start_root_process(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    switch_to_next_task();
    return 0;
}

pub fn sys_create_process(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile CreateProcessCall = @ptrCast(@alignCast(arg));
    process_manager.instance.create_process(context.stack_size, context.entry, context.arg, "/") catch |err| {
        return err;
    };
    return 0;
}

pub fn sys_semaphore_acquire(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
    return KernelSemaphore.acquire(context.object);
}

pub fn sys_semaphore_release(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
    return KernelSemaphore.release(context.object);
}

pub fn sys_getpid(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        return @intCast(process.pid);
    }
    return -1;
}

pub fn sys_mkdir(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}

pub fn sys_fstat(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}

pub fn sys_isatty(arg: *const volatile anyopaque) !i32 {
    const fd: *const volatile c_int = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd.*));
        if (maybe_file) |file| {
            if (file.file.filetype() == FileType.CharDevice) return 1;
        }
    }
    return 0;
}

pub fn sys_open(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.open_context = @ptrCast(@alignCast(arg));

    const maybe_process = process_manager.instance.get_current_process();
    const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(context.path.?)));
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

pub fn sys_close(arg: *const volatile anyopaque) !i32 {
    const fd: *const volatile c_int = @ptrCast(@alignCast(arg));

    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(fd.*));
        if (maybe_file) |file| {
            _ = file.file.close();
            _ = process.fds.remove(@intCast(fd.*));
            return 0;
        }
    }
    return -1;
}

pub fn sys_exit(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c_int = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process_manager.instance.delete_process(process.pid);
    } else {
        @panic("No process found");
    }
    log.print("Process exited with code {d}\n", .{context.*});
    return 0;
}

pub fn sys_read(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.read_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (context.buf == null) {
        return errno(c.EFAULT);
    }
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |file| {
            context.result.* = file.file.read(@as([*:0]u8, @ptrCast(context.buf.?))[0..context.count]);
            return 0;
        }
    }
    return 0;
}
pub fn sys_kill(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c_int = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process_manager.instance.delete_process(process.pid);
    } else {
        @panic("No process found");
    }
    log.print("Process killed with code {d}\n", .{context.*});
    return 0;
}

pub fn sys_write(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.write_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();

    if (context.buf == null) {
        return errno(c.EFAULT);
    }

    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |file| {
            context.result.* = file.file.write(@as([*:0]const u8, @ptrCast(context.buf.?))[0..context.count]);
            return 0;
        }
    }
    return -1;
}

pub fn sys_vfork(arg: *const volatile anyopaque) !i32 {
    const lr: *const volatile usize = @ptrCast(@alignCast(arg));
    var result: c.pid_t = -1;
    _ = try process_manager.instance.vfork(lr.*, @intFromPtr(&result));
    return 0;
}

pub fn sys_unlink(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_link(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_stat(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_getentropy(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_lseek(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.lseek_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();

    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |file| {
            context.result.* = file.file.seek(context.offset, context.whence);
            return 0;
        }
    }
    return -1;
}
pub fn sys_wait(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_times(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}

pub fn sys_getdents(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.getdents_context = @ptrCast(@alignCast(arg));

    if (context.dirp == null) {
        context.result.* = -1;
    } else {
        const maybe_process = process_manager.instance.get_current_process();
        if (maybe_process) |process| {
            const maybe_entity = process.fds.getPtr(@intCast(context.fd));
            if (maybe_entity) |entity| {
                var tracker = DirentTraverseTracker{
                    .dirp = @ptrCast(@alignCast(context.dirp)),
                    .offset = 0,
                    .count = context.count,
                    .skipuntil = if (entity.diriter != null) entity.diriter.?.dupe() else null,
                    .lastfile = null,
                };
                _ = fs.ivfs().traverse(std.mem.span(@as([*:0]const u8, @ptrCast(&entity.path))), traverse_directory, &tracker);
                if (entity.diriter) |*diriter| {
                    _ = diriter.close();
                }
                entity.diriter = tracker.lastfile;
                context.result.* = @intCast(tracker.offset);
                return 0;
            }
        }
        return -1;
    }
    return -1;
}

pub fn sys_ioctl(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.ioctl_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |file| {
            return file.file.ioctl(context.op, context.arg);
        }
    }
    return -1;
}

pub fn sys_gettimeofday(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_waitpid(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.waitpid_context = @ptrCast(@alignCast(arg));
    return process_manager.instance.waitpid(context.pid, context.status);
}

pub fn sys_execve(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.execve_context = @ptrCast(@alignCast(arg));
    context.result.*.result = try process_manager.instance.prepare_exec(std.mem.span(context.filename), context.argv, context.envp);
    return 0;
}

pub fn sys_nanosleep(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_mmap(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.mmap_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    context.result.* = @ptrFromInt(0);
    if (maybe_process) |process| {
        context.result.* = process.mmap(context.addr, context.length, context.prot, context.flags, context.fd, context.offset) catch {
            return -1;
        };
    }
    return -1;
}

pub fn sys_munmap(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.munmap_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process.munmap(context.addr, context.length);
        return 0;
    }
    return -1;
}

pub fn sys_getcwd(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.getcwd_context = @ptrCast(@alignCast(arg));
    if (process_manager.instance.get_current_process()) |current_process| {
        const cwd = current_process.get_current_directory();
        const cwd_len = @min(cwd.len, context.size);
        std.mem.copyForwards(u8, context.buf[0..cwd_len], cwd[0..cwd_len]);
        var last_index = cwd.len;
        if (last_index > context.size) {
            last_index = context.size - 1;
        }
        context.buf[last_index] = 0;
        context.result.* = context.buf;
        return 0;
    } else {
        context.buf[0] = 0;
        context.result.* = @ptrFromInt(0);
        return -1;
    }
    return -1;
}

pub fn sys_chdir(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.chdir_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(context.path.?)));
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

pub fn sys_time(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.time_context = @ptrCast(@alignCast(arg));
    const ticks: c.time_t = @intCast(systick.get_system_ticks().*);
    context.result.* = ticks;
    return 0;
}
pub fn sys_fcntl(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.fcntl_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |file| {
            return file.file.fcntl(context.op, context.arg);
        }
    }
    return -1;
}
pub fn sys_remove(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_realpath(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_mprotect(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}
