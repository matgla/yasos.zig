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
const log = std.log.scoped(.syscall);

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
    var filename = file.interface.name(kernel_allocator);
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

extern fn switch_to_the_first_task() void;
extern fn push_return_address() void;
extern fn switch_to_main_task(lr: usize, with_fpu: bool) void;
var sp: usize = 0;
var with_fpu: bool = false;

pub fn sys_start_root_process(arg: *const volatile anyopaque) !i32 {
    sp = @as(*const volatile usize, @ptrCast(@alignCast(arg))).*;
    if (sp & 1 == 1) {
        with_fpu = true;
        sp -= 1;
    }
    std.log.info("Starting root process with stack pointer: {x}\n", .{sp});
    switch_to_the_first_task();
    return 0;
}

pub fn sys_stop_root_process(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    hal.time.systick.disable();
    std.log.info("Stopping root process with stack pointer: {x}\n", .{sp});
    switch_to_main_task(sp, with_fpu);
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
    const check_parent: *const volatile u8 = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        if (check_parent.* != 0) {
            const maybe_parent = process.get_parent();
            if (maybe_parent) |parent| {
                return @intCast(parent.pid);
            }
            return 0;
        }
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
            if (file.file.interface.filetype() == FileType.CharDevice) return 1;
        }
    }
    return 0;
}

pub fn sys_open(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.open_context = @ptrCast(@alignCast(arg));

    const maybe_process = process_manager.instance.get_current_process();
    var path_slice: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(context.path.?)));
    if (maybe_process) |process| {
        var relative_path = false;
        if (!std.mem.startsWith(u8, path_slice, "/")) {
            path_slice = std.fmt.allocPrint(kernel_allocator, "{s}/{s}", .{ process.cwd, path_slice }) catch {
                return -1;
            };
            relative_path = true;
        }

        defer if (relative_path) kernel_allocator.free(path_slice);
        const realpath = std.fs.path.resolve(kernel_allocator, &.{path_slice}) catch {
            return -1;
        };
        defer kernel_allocator.free(realpath);

        const maybe_file = fs.get_ivfs().interface.get(realpath, process.get_memory_allocator());
        if (maybe_file) |file| {
            const fd = process.get_free_fd();
            process.fds.put(fd, .{
                .file = file,
                .path = blk: {
                    var path_buffer: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
                    std.mem.copyForwards(u8, path_buffer[0..realpath.len], realpath);
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
            const maybe_ifile = fs.get_ivfs().interface.create(realpath, context.mode, process.get_memory_allocator());
            if (maybe_ifile) |ifile| {
                process.fds.put(fd, .{
                    .file = ifile,
                    .path = blk: {
                        var path_buffer: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
                        std.mem.copyForwards(u8, path_buffer[0..realpath.len], realpath);
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
            _ = file.file.interface.close();
            file.file.interface.delete();
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
        process_manager.instance.delete_process(process.pid, context.*);
    } else {
        @panic("No process found");
    }
    return context.*;
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
            context.result.* = file.file.interface.read(@as([*]u8, @ptrCast(context.buf.?))[0..context.count]);
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
        process_manager.instance.delete_process(process.pid, -1);
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
            context.result.* = file.file.interface.write(@as([*]const u8, @ptrCast(context.buf.?))[0..context.count]);
            return 0;
        }
    }
    return -1;
}

pub fn sys_vfork(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.vfork_context = @ptrCast(@alignCast(arg));
    const result = try process_manager.instance.vfork(context);
    // hal.irq.trigger(.pendsv);
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
    const context: *const volatile c.stat_context = @ptrCast(@alignCast(arg));
    if (context.pathname == null or context.statbuf == null) {
        return errno(c.EFAULT);
    }
    const path = std.mem.span(@as([*:0]const u8, @ptrCast(context.pathname.?)));
    if (path.len > 0 and path[0] != '/') {
        if (process_manager.instance.get_current_process()) |current_process| {
            const pwd = current_process.get_current_directory();
            const full_path = std.fmt.allocPrint(kernel_allocator, "{s}/{s}", .{ pwd, path }) catch {
                return -1;
            };
            defer kernel_allocator.free(full_path);
            const real = std.fs.path.resolve(kernel_allocator, &.{full_path}) catch {
                return -1;
            };
            defer kernel_allocator.free(real);
            return fs.get_ivfs().interface.stat(
                real,
                context.statbuf,
            );
        }
    }
    return fs.get_ivfs().interface.stat(
        path,
        context.statbuf,
    );
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
            context.result.* = file.file.interface.seek(context.offset, context.whence);
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
                    entity.diriter = fs.get_ivfs().interface.iterator(std.mem.span(@as([*:0]const u8, @ptrCast(&entity.path))));
                }

                // still can be null if path not exists or is not a directory
                if (entity.diriter) |*diriter| {
                    var maybe_file = diriter.interface.next();
                    if (maybe_file) |*file| {
                        defer file.interface.delete();
                        context.result.* = fill_dirent(file, context.dirp);
                    } else {
                        diriter.interface.delete();
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
            return file.file.interface.ioctl(context.op, context.arg);
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
    return try process_manager.instance.prepare_exec(std.mem.span(context.filename), context.argv, context.envp);
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
        var maybe_file = fs.get_ivfs().interface.get(path_slice, process.get_memory_allocator());
        if (maybe_file) |*file| {
            defer file.interface.delete();
            if (file.interface.filetype() == FileType.Directory) {
                process.change_directory(path_slice) catch |err| {
                    log.warn("chdir: failed to change directory: {s}\n", .{@errorName(err)});
                    return -1;
                };
                return 0;
            } else {
                log.warn("chdir: path is not a directory: {s}\n", .{path_slice});
                return -1;
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
            return file.file.interface.fcntl(context.op, context.arg);
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

pub fn sys_getuid(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    // we are always root until we implement user management
    return 0;
}

pub fn sys_geteuid(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    // we are always root until we implement user management
    return 0;
}

pub fn sys_dup(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.dup_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        var maybe_file = process.fds.get(@intCast(context.fd));
        if (maybe_file) |*file| {
            const fd = process.get_free_fd();
            process.fds.put(fd, .{
                .file = file.file.share(),
                .path = file.path,
                .diriter = null,
            }) catch {
                return -1;
            };
            return fd;
        }
    }
    return -1;
}
