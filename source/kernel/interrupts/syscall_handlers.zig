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

const kernel = @import("../kernel.zig");
const log = std.log.scoped(.syscall);

const systick = @import("systick.zig");

const config = @import("config");

const c = @import("libc_imports").c;

const dynamic_loader = @import("../modules.zig");
const yasld = @import("yasld");

const hal = @import("hal");
const arch = @import("arch");

var kernel_allocator: std.mem.Allocator = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    kernel_allocator = allocator;
}

// most stupid way to keep track of the last file
fn fill_dirent(entry: kernel.fs.DirectoryEntry, dirent_address: *anyopaque) isize {
    const required_space = std.mem.alignForward(usize, @sizeOf(c.dirent) - 1 + entry.name.len, @alignOf(c.dirent));
    // skip files that were already traversed
    const dirp: *c.dirent = @as(*c.dirent, @ptrCast(@alignCast(dirent_address)));
    dirp.d_ino = 0xdead;
    dirp.d_off = 0xbeef;
    dirp.d_reclen = @intCast(required_space);
    std.mem.copyForwards(u8, dirp.d_name[0..], entry.name);
    dirp.d_name[entry.name.len] = 0;
    return @intCast(required_space);
}

fn get_file_from_process(fd: u16) !kernel.fs.IFile {
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_handle = process.get_file_handle(fd);
        if (maybe_handle) |handle| {
            const maybe_file = handle.node.as_file();
            if (maybe_file) |file| {
                return file;
            }
            return kernel.errno.ErrnoSet.IsADirectory;
        }
    }
    return kernel.errno.ErrnoSet.NoSuchProcess;
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

pub fn sys_start_root_process(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    sp = @as(*const volatile usize, @ptrCast(@alignCast(arg))).*;
    if (sp & 1 == 1) {
        with_fpu = true;
        sp -= 1;
    }
    std.log.info("Starting root process with stack pointer: {x}", .{sp});
    switch_to_the_first_task();
    return 0;
}

pub fn sys_stop_root_process(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    hal.time.systick.disable();
    std.log.info("Stopping root process with stack pointer: {x}", .{sp});
    switch_to_main_task(sp, with_fpu);
    return 0;
}

pub fn sys_create_process(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile CreateProcessCall = @ptrCast(@alignCast(arg));
    process_manager.instance.create_process(context.stack_size, context.entry, context.arg, "/") catch |err| {
        return err;
    };
    return 0;
}

pub fn sys_semaphore_acquire(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
    return KernelSemaphore.acquire(context.object);
}

pub fn sys_semaphore_release(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
    return KernelSemaphore.release(context.object);
}

pub fn sys_getpid(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
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

pub fn sys_mkdir(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.mkdir_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.path, context.fd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.mkdir(path, @intCast(context.mode));
    return 0;
}

pub fn sys_fstat(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}

pub fn sys_isatty(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const fd: *const volatile c_int = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_handle = process.get_file_handle(@intCast(fd.*));
        if (maybe_handle) |handle| {
            if (handle.node.is_file()) {
                const maybe_file = handle.node.as_file();
                if (maybe_file) |file| {
                    if (file.interface.filetype() == FileType.CharDevice) {
                        return 1;
                    }
                }
            }
        }
    }
    return 0;
}

fn determine_path_for_file(allocator: std.mem.Allocator, maybe_path: [*c]const u8, fd: i32) ![]const u8 {
    var prefix: []const u8 = "";
    if (maybe_path) |cpath| {
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(cpath)));
        if (fd >= 0) {
            if (process_manager.instance.get_current_process()) |current_process| {
                prefix = current_process.get_current_directory();
                const maybe_handle = current_process.get_file_handle(@intCast(fd));
                if (maybe_handle) |handle| {
                    if (handle.node.is_directory()) {
                        prefix = handle.path;
                    }
                } else {
                    return error.CannotDeterminePathForFd;
                }
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, path });
                defer allocator.free(full_path);
                const real = try std.fs.path.resolve(allocator, &.{full_path});
                return real;
            }
        } else {
            if (path.len > 0 and path[0] != '/') {
                if (process_manager.instance.get_current_process()) |current_process| {
                    const pwd = current_process.get_current_directory();
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ pwd, prefix, path });
                    defer allocator.free(full_path);
                    const real = try std.fs.path.resolve(allocator, &.{full_path});
                    return real;
                }
            } else {
                return try allocator.dupe(u8, path);
            }
        }
    } else if (fd >= 0) {
        if (process_manager.instance.get_current_process()) |current_process| {
            const maybe_handle = current_process.get_file_handle(@intCast(fd));
            if (maybe_handle) |handle| {
                return try allocator.dupe(u8, handle.path);
            }
        }
    }
    return error.CannotDeterminePath;
}

pub fn sys_open(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.open_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.path, context.fd);
    defer kernel_allocator.free(path);
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_node: ?kernel.fs.Node = fs.get_ivfs().interface.get(path) catch |err| blk: {
            break :blk switch (err) {
                error.NoEntry => null,
                else => return err,
            };
        };
        if (maybe_node) |file| {
            const fd = try process.attach_file(path, file);
            kernel.log.err("Opended file at path: {s} with fd: {d}", .{ path, fd });
            return fd;
        } else if ((context.flags & c.O_CREAT) != 0) {
            try fs.get_ivfs().interface.create(path, context.mode);
            const ifile = try fs.get_ivfs().interface.get(path);
            const fd = try process.attach_file(path, ifile);
            kernel.log.err("Created file at path: {s} with fd: {d}", .{ path, fd });
            return fd;
        }
    }
    return kernel.errno.ErrnoSet.NoEntry;
}

fn close_fd(fd: i32) i32 {
    if (fd < 0) {
        return -1;
    }
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process.release_file(@intCast(fd));
        return 0;
    }
    return -1;
}

pub fn sys_close(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const fd: *const volatile c_int = @ptrCast(@alignCast(arg));
    return close_fd(fd.*);
}

pub fn sys_exit(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c_int = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process_manager.instance.delete_process(process.pid, context.*);
    } else {
        @panic("No process found");
    }
    return context.*;
}

var tasks: std.DoublyLinkedList = std.DoublyLinkedList{};
const AsyncTask = struct {
    node: std.DoublyLinkedList.Node,
    allocator: std.mem.Allocator,
    callback: *const fn (arg: *anyopaque) bool,
    context: *anyopaque,
    process: *kernel.process.Process,
};

const AsyncReadContext = struct {
    buf: []u8,
    out: *isize,
    process: *kernel.process.Process,
    fd: u16,
    allocator: std.mem.Allocator,
    timeout: usize,
    start_time: usize,
};

pub fn process_async_tasks() void {
    var it = tasks.first;
    while (it) |task_node| {
        const task: *AsyncTask = @fieldParentPtr("node", task_node);
        if (task.callback(task.context)) {
            tasks.remove(task_node);
            task.allocator.destroy(task);
        }
        it = task_node.next;
    }
}

pub fn remove_async_tasks_for_process(process: *kernel.process.Process) void {
    var it = tasks.first;
    while (it) |task_node| {
        const task: *AsyncTask = @fieldParentPtr("node", task_node);
        if (task.process == process) {
            tasks.remove(task_node);
            task.allocator.destroy(task);
        }
        it = task_node.next;
    }
}

pub fn write_result(ptr: *volatile anyopaque, result_or_error: anyerror!i32) linksection(".time_critical") void {
    const c_result: *volatile c.syscall_result = @ptrCast(@alignCast(ptr));
    const result: i32 = result_or_error catch |err| {
        c_result.*.err = kernel.errno.to_errno(err);
        c_result.*.result = -1;
        return;
    };

    c_result.*.result = result;
    c_result.*.err = -1;
}

pub fn sys_read(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.read_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (context.buf == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }
    if (maybe_process) |process| {
        const allocator = process.get_process_memory_allocator();
        var file = try get_file_from_process(@intCast(context.fd));
        if (file.interface.filetype() != FileType.CharDevice) {
            const result = file.interface.read(@as([*]u8, @ptrCast(context.buf.?))[0..context.count]);
            context.result.* = @intCast(result);
            return 0;
        }

        var termios: c.termios = undefined;
        _ = file.interface.ioctl(c.TCGETS, &termios);
        const async_read_context = try allocator.create(AsyncReadContext);
        async_read_context.* = AsyncReadContext{
            .buf = @as([*]u8, @ptrCast(context.buf.?))[0..context.count],
            .out = context.result,
            .process = process,
            .fd = @intCast(context.fd),
            .allocator = allocator,
            .timeout = @as(usize, @intCast(termios.c_cc[c.VTIME])) * 100,
            .start_time = @intCast(hal.time.get_time_ms()),
        };

        const ReadFunctor = struct {
            pub fn call(read_context: *anyopaque) bool {
                const read_ctx: *AsyncReadContext = @ptrCast(@alignCast(read_context));
                const maybe_handle = read_ctx.process.get_file_handle(read_ctx.fd);
                if (maybe_handle) |h| {
                    var maybe_file = h.node.as_file();
                    if (maybe_file) |*f| {
                        const size = f.interface.size();
                        if (size == 0) {
                            if (read_ctx.timeout != 0) {
                                const current_time = hal.time.get_time_ms();
                                if (read_ctx.timeout > 0 and current_time - read_ctx.start_time >= read_ctx.timeout) {
                                    // log.err("Read timeout reached after {d} ms", .{read_ctx.timeout});
                                    read_ctx.out.* = 0;
                                    read_ctx.process.wait_for_io(false);
                                    read_ctx.allocator.destroy(read_ctx);
                                    return true;
                                }
                            }
                            return false;
                        }
                        const to_read = @min(size, read_ctx.buf.len);
                        const result = f.interface.read(read_ctx.buf[0..to_read]);
                        read_ctx.process.wait_for_io(false);
                        read_ctx.out.* = @intCast(result);
                        read_ctx.allocator.destroy(read_ctx);
                        return true;
                    }
                }
                return false;
            }
        };

        const task = try allocator.create(AsyncTask);
        task.* = AsyncTask{
            .allocator = allocator,
            .callback = ReadFunctor.call,
            .context = async_read_context,
            .node = std.DoublyLinkedList.Node{},
            .process = process,
        };
        process.wait_for_io(true);
        tasks.append(&task.node);
        kernel.process.yield();
    }
    return 0;
}
pub fn sys_kill(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
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

pub fn sys_write(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.write_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();

    if (context.buf == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }

    if (maybe_process) |process| {
        const maybe_handle = process.get_file_handle(@intCast(context.fd));

        if (maybe_handle) |handle| {
            var maybe_file = handle.node.as_file();
            if (maybe_file) |*file| {
                context.result.* = file.interface.write(@as([*]const u8, @ptrCast(context.buf.?))[0..context.count]);
            }
            return 0;
        }
    }
    return -1;
}

pub fn sys_vfork(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.vfork_context = @ptrCast(@alignCast(arg));
    const result = try process_manager.instance.vfork(context);
    // hal.irq.trigger(.pendsv);
    return result;
}

pub fn sys_unlink(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.unlink_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.dirfd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.unlink(path);
    return 0;
}
pub fn sys_link(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.link_context = @ptrCast(@alignCast(arg));
    const old_path = try determine_path_for_file(kernel_allocator, context.oldpath, context.olddirfd);
    defer kernel_allocator.free(old_path);
    const new_path = try determine_path_for_file(kernel_allocator, context.newpath, context.newdirfd);
    defer kernel_allocator.free(new_path);
    try fs.get_ivfs().interface.link(old_path, new_path);
    return 0;
}

pub fn sys_stat(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.stat_context = @ptrCast(@alignCast(arg));
    if (context.statbuf == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.fd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.stat(path, context.statbuf, context.follow_links != 0);
    return 0;
}

pub fn sys_getentropy(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}

pub fn sys_lseek(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.lseek_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    context.result.* = try file.interface.seek(context.offset, context.whence);
    return 0;
}

pub fn sys_wait(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}
pub fn sys_times(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}

pub fn sys_getdents(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.getdents_context = @ptrCast(@alignCast(arg));

    context.result.* = -1;
    if (context.dirp == null) {} else {
        const maybe_process = process_manager.instance.get_current_process();
        if (maybe_process) |process| {
            const maybe_handle = process.get_file_handle(@intCast(context.fd));
            if (maybe_handle) |handle| {
                // if iterator not exists create one
                const diriter: ?*kernel.fs.IDirectoryIterator = handle.get_iterator() catch null;
                // still can be null if path not exists or is not a directory
                if (diriter) |it| {
                    const maybe_entry = it.interface.next();
                    if (maybe_entry) |entry| {
                        context.result.* = fill_dirent(entry, context.dirp);
                    } else {
                        handle.remove_iterator();
                    }
                }
                return 0;
            }
        }
        return -1;
    }
    return -1;
}

pub fn sys_ioctl(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.ioctl_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    return file.interface.ioctl(context.op, context.arg);
}

pub fn sys_gettimeofday(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}
pub fn sys_waitpid(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.waitpid_context = @ptrCast(@alignCast(arg));
    return process_manager.instance.waitpid(context.pid, context.status);
}

pub fn sys_execve(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.execve_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.filename, -1);
    defer kernel_allocator.free(path);
    return try process_manager.instance.prepare_exec(path, context.argv, context.envp);
}

pub fn sys_nanosleep(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}
pub fn sys_mmap(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
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

pub fn sys_munmap(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.munmap_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        process.munmap(context.addr, context.length);
        return 0;
    }
    return -1;
}

pub fn sys_getcwd(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
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

pub fn sys_chdir(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.chdir_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        var slice_allocated = false;
        var path_slice: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(context.path.?)));
        if (path_slice[0] != '/') {
            if (process.cwd[process.cwd.len - 1] == '/') {
                path_slice = try std.fmt.allocPrint(kernel_allocator, "{s}{s}", .{ process.cwd, path_slice });
                slice_allocated = true;
            }
        }
        defer if (slice_allocated) kernel_allocator.free(path_slice);

        const resolved_path = try std.fs.path.resolve(kernel_allocator, &.{ process.cwd, path_slice });
        defer kernel_allocator.free(resolved_path);

        if (resolved_path.len == 0) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }

        var node = try fs.get_ivfs().interface.get(resolved_path);
        defer node.delete();
        if (node.is_directory()) {
            try process.change_directory(resolved_path);
            return 0;
        }
        return kernel.errno.ErrnoSet.NotADirectory;
    }
    return kernel.errno.ErrnoSet.NoSuchProcess;
}

pub fn sys_time(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.time_context = @ptrCast(@alignCast(arg));
    const ticks: c.time_t = @intCast(systick.get_system_ticks().*);
    context.result.* = ticks;
    return 0;
}
pub fn sys_fcntl(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.fcntl_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    return file.interface.fcntl(context.op, context.arg);
}
pub fn sys_remove(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}
pub fn sys_realpath(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}
pub fn sys_mprotect(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    return -1;
}

pub fn sys_dlopen(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.dlopen_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const library = dynamic_loader.load_shared_library(std.mem.span(@as([*:0]const u8, @ptrCast(context.path))), process.get_process_memory_allocator(), process.pid) catch {
            // log.print("dlopen: failed to load library: {s}\n", .{@errorName(err)});
            return -1;
        };
        context.*.result.* = library;
        return 0;
    }
    return -1;
}

pub fn sys_dlclose(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.dlclose_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    const library: *yasld.Module = @ptrCast(@alignCast(context.handle));
    if (maybe_process) |process| {
        dynamic_loader.release_shared_library(process.pid, library);
        return 0;
    }
    return -1;
}

pub fn sys_dlsym(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.dlsym_context = @ptrCast(@alignCast(arg));
    const library: *yasld.Module = @ptrCast(@alignCast(context.handle));
    const maybe_symbol = library.find_symbol(std.mem.span(@as([*:0]const u8, @ptrCast(context.symbol))));
    if (maybe_symbol) |symbol| {
        context.result.* = @ptrFromInt(symbol.address);
        return 0;
    }
    return -1;
}

pub fn sys_getuid(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    // we are always root until we implement user management
    return 0;
}

pub fn sys_geteuid(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = arg;
    _ = out;
    // we are always root until we implement user management
    return 0;
}

pub fn sys_dup(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.dup_context = @ptrCast(@alignCast(arg));
    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        const maybe_handle = process.get_file_handle(@intCast(context.fd));
        if (maybe_handle) |handle| {
            var fd: i32 = 0;
            if (context.newfd >= 0) {
                fd = context.newfd;
                _ = close_fd(fd);
            } else {
                fd = process.get_free_fd();
            }
            return try process.attach_file_with_fd(@intCast(fd), handle.path, handle.node.share());
        }
    }
    return -1;
}

pub fn sys_sysinfo(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.sysinfo_context = @ptrCast(@alignCast(arg));
    if (context.info == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }
    const info = context.info.?;
    info.*.uptime = @intCast(systick.get_system_ticks().*);
    info.*.totalram = 1;
    info.*.freeram = 0;
    info.*.procs = @intCast(process_manager.instance.processes.len());
    return 0;
}

pub fn sys_sysconf(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.sysconf_context = @ptrCast(@alignCast(arg));
    switch (context.name) {
        c._SC_CLK_TCK => {
            context.result.* = 1000;
            return 0;
        },
        else => {
            return kernel.errno.ErrnoSet.InvalidArgument;
        },
    }
}

pub fn sys_access(arg: *const volatile anyopaque, out: *volatile anyopaque) !i32 {
    _ = out;
    const context: *const volatile c.access_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.dirfd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.access(path, context.mode, context.flags);
    return 0;
}
