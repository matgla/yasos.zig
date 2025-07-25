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

const kernel = @import("kernel");
const log = kernel.log;

const systick = @import("systick.zig");

const config = @import("config");

const c = @import("libc_imports").c;

const dynamic_loader = @import("../modules.zig");
const yasld = @import("yasld");

const hal = @import("hal");
const arch = @import("arch");

const E = enum(u16) {
    EINVAL = c.EINVAL,
};

pub fn errno(rc: u16) anyerror {
    return @errorFromInt(rc);
}

var kernel_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    kernel_allocator = allocator;
}

// most stupid way to keep track of the last file
fn fill_dirent(file: *IFile, dirent_address: *anyopaque) isize {
    var filename = file.name(kernel_allocator);
    defer filename.deinit();
    const required_space = std.mem.alignForward(usize, @sizeOf(c.dirent) - 1 + filename.get_name().len, @alignOf(c.dirent));
    // skip files that were already traversed
    const dirp: *c.dirent = @as(*c.dirent, @ptrCast(@alignCast(dirent_address)));
    dirp.d_ino = 0xdead;
    dirp.d_off = 0xbeef;
    dirp.d_reclen = @intCast(required_space);
    std.mem.copyForwards(u8, dirp.d_name[0..], filename.get_name());
    dirp.d_name[filename.get_name().len] = 0;
    return @intCast(required_space);
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

pub const VForkContext = extern struct {
    lr: usize,
    result: *volatile c.pid_t,
};

extern fn switch_to_next_task() void;
extern fn start_first_task(lr: *usize) void;
extern fn push_return_address() void;
extern fn switch_to_main_task(lr: usize) void;
var sp: usize = 0;

pub fn sys_start_root_process(arg: *const volatile anyopaque) !i32 {
    sp = @as(*const volatile usize, @ptrCast(@alignCast(arg))).*;
    switch_to_next_task();
    return 0;
}

pub fn sys_stop_root_process(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    hal.time.systick.disable();
    switch_to_main_task(sp);
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
        var maybe_file = process.fds.get(@intCast(fd.*));
        if (maybe_file) |*file| {
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
        const maybe_file = fs.get_ivfs().get(path_slice, process.get_memory_allocator());
        if (maybe_file) |file| {
            // defer file.destroy();
            const fd = process.get_free_fd();
            // const maybe_ifile = file.dupe();
            // if (maybe_ifile) |ifile| {
            process.fds.put(fd, .{
                .file = file,
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
            // }
        } else if ((context.flags & c.O_CREAT) != 0) {
            const fd = process.get_free_fd();
            const maybe_ifile = fs.get_ivfs().create(path_slice, context.mode, process.get_memory_allocator());
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
        var maybe_file = process.fds.get(@intCast(fd.*));
        if (maybe_file) |*file| {
            _ = file.file.close();
            file.file.delete();
            _ = process.fds.remove(@intCast(fd.*));
            return 0;
        }
    }
    return -1;
}

pub fn sys_exit(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    // const context: *const volatile c_int = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process_manager.instance.delete_process(process.pid);
    } else {
        @panic("No process found");
    }
    // log.print("Process exited with code {d}\n", .{context.*});
    return 0;
}

pub fn sys_read(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.read_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (context.buf == null) {
        return errno(c.EFAULT);
    }
    if (maybe_process) |process| {
        var maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |*file| {
            context.result.* = file.file.read(@as([*]u8, @ptrCast(context.buf.?))[0..context.count]);
            return 0;
        }
    }
    return 0;
}
pub fn sys_kill(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    // const context: *const volatile c_int = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process_manager.instance.delete_process(process.pid);
    } else {
        @panic("No process found");
    }
    // log.print("Process killed with code {d}\n", .{context.*});
    return 0;
}

pub fn sys_write(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.write_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();

    if (context.buf == null) {
        return errno(c.EFAULT);
    }

    if (maybe_process) |process| {
        var maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |*file| {
            context.result.* = file.file.write(@as([*]const u8, @ptrCast(context.buf.?))[0..context.count]);
            return 0;
        }
    }
    return -1;
}

pub fn sys_vfork(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    const result = try process_manager.instance.vfork();
    hal.irq.trigger(.pendsv);
    return result;
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
        var maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |*file| {
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

    context.result.* = -1;
    if (context.dirp == null) {} else {
        const maybe_process = process_manager.instance.get_current_process();
        if (maybe_process) |process| {
            const maybe_entity = process.fds.getPtr(@intCast(context.fd));
            if (maybe_entity) |entity| {
                // if iterator not exists create one
                if (entity.diriter == null) {
                    entity.diriter = fs.get_ivfs().iterator(std.mem.span(@as([*:0]const u8, @ptrCast(&entity.path))));
                }

                // still can be null if path not exists or is not a directory
                if (entity.diriter) |*diriter| {
                    var maybe_file = diriter.next();
                    if (maybe_file) |*file| {
                        defer file.delete();
                        context.result.* = fill_dirent(file, context.dirp);
                    } else {
                        diriter.delete();
                        entity.diriter = null;
                    }
                }
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
        var maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |*file| {
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
    return process_manager.instance.prepare_exec(std.mem.span(context.filename), context.argv, context.envp);
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
        var maybe_file = fs.get_ivfs().get(path_slice, process.get_memory_allocator());
        if (maybe_file) |*file| {
            defer file.delete();
            if (file.filetype() == FileType.Directory) {
                process.change_directory(path_slice) catch {
                    // log.print("chdir: failed to change directory: {s}\n", .{@errorName(err)});
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
        var maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |*file| {
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

pub fn sys_dlopen(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.dlopen_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const library = dynamic_loader.load_shared_library(std.mem.span(@as([*:0]const u8, @ptrCast(context.path))), process.get_memory_allocator(), process.get_process_memory_allocator(), process.pid) catch {
            // log.print("dlopen: failed to load library: {s}\n", .{@errorName(err)});
            return -1;
        };
        context.*.result.* = library;
        return 0;
    }
    return -1;
}

pub fn sys_dlclose(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.dlclose_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    const library: *yasld.Module = @ptrCast(@alignCast(context.handle));
    if (maybe_process) |process| {
        dynamic_loader.release_shared_library(process.pid, library);
        return 0;
    }
    return -1;
}

pub fn sys_dlsym(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.dlsym_context = @ptrCast(@alignCast(arg));
    const library: *yasld.Module = @ptrCast(@alignCast(context.handle));
    const maybe_symbol = library.find_symbol(std.mem.span(@as([*:0]const u8, @ptrCast(context.symbol))));
    if (maybe_symbol) |symbol| {
        context.result.* = @ptrFromInt(symbol.address);
        return 0;
    }
    return -1;
}
