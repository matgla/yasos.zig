//
// system_call.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
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

const hal = @import("hal");

const c = @import("libc_imports").c;

const syscall = @import("arch").syscall;

const kernel = @import("kernel");
const log = std.log.scoped(.syscall);

const process_manager = @import("../process_manager.zig");

const handlers = @import("syscall_handlers.zig");
const arch = @import("arch");
comptime {
    _ = @import("arch");
    const config = @import("config");
    if (config.build.use_newlib) {
        _ = @import("system_stubs.zig");
    }
}

extern fn store_and_switch_to_next_task(lr: usize) void;

const SyscallHandler = *const fn (arg: *const volatile anyopaque) anyerror!i32;

fn context_switch_handler(lr: usize) void {
    if (process_manager.instance.scheduler.schedule_next()) {
        store_and_switch_to_next_task(lr);
    }
}

fn sys_unhandled_factory(comptime i: usize) type {
    return struct {
        fn handler(arg: *const volatile anyopaque) !i32 {
            _ = arg;
            log.err("\nUnhandled system call id: {d}\n", .{i});
            return -1;
        }
    };
}

fn SyscallFactory(comptime index: usize) SyscallHandler {
    comptime {
        switch (index) {
            c.sys_start_root_process => return handlers.sys_start_root_process,
            c.sys_stop_root_process => return handlers.sys_stop_root_process,
            c.sys_create_process => return handlers.sys_create_process,
            c.sys_semaphore_acquire => return handlers.sys_semaphore_acquire,
            c.sys_semaphore_release => return handlers.sys_semaphore_release,
            c.sys_getpid => return handlers.sys_getpid,
            c.sys_mkdir => return handlers.sys_mkdir,
            c.sys_fstat => return handlers.sys_fstat,
            c.sys_isatty => return handlers.sys_isatty,
            c.sys_open => return handlers.sys_open,
            c.sys_close => return handlers.sys_close,
            c.sys_exit => return handlers.sys_exit,
            c.sys_read => return handlers.sys_read,
            c.sys_kill => return handlers.sys_kill,
            c.sys_write => return handlers.sys_write,
            c.sys_vfork => return handlers.sys_vfork,
            c.sys_unlink => return handlers.sys_unlink,
            c.sys_link => return handlers.sys_link,
            c.sys_stat => return handlers.sys_stat,
            c.sys_getentropy => return handlers.sys_getentropy,
            c.sys_lseek => return handlers.sys_lseek,
            c.sys_wait => return handlers.sys_wait,
            c.sys_times => return handlers.sys_times,
            c.sys_getdents => return handlers.sys_getdents,
            c.sys_ioctl => return handlers.sys_ioctl,
            c.sys_gettimeofday => return handlers.sys_gettimeofday,
            c.sys_waitpid => return handlers.sys_waitpid,
            c.sys_execve => return handlers.sys_execve,
            c.sys_nanosleep => return handlers.sys_nanosleep,
            c.sys_mmap => return handlers.sys_mmap,
            c.sys_munmap => return handlers.sys_munmap,
            c.sys_getcwd => return handlers.sys_getcwd,
            c.sys_chdir => return handlers.sys_chdir,
            c.sys_time => return handlers.sys_time,
            c.sys_fcntl => return handlers.sys_fcntl,
            c.sys_remove => return handlers.sys_remove,
            c.sys_realpath => return handlers.sys_realpath,
            c.sys_mprotect => return handlers.sys_mprotect,
            c.sys_dlopen => return handlers.sys_dlopen,
            c.sys_dlclose => return handlers.sys_dlclose,
            c.sys_dlsym => return handlers.sys_dlsym,
            else => return sys_unhandled_factory(index).handler,
        }
    }
}

fn create_syscall_lookup_table(comptime count: usize) [count]SyscallHandler {
    var syscalls: [count]SyscallHandler = undefined;
    for (&syscalls, 0..) |*f, index| {
        f.* = SyscallFactory(index);
    }
    return syscalls;
}

const syscall_lookup_table = create_syscall_lookup_table(c.SYSCALL_COUNT);

pub fn write_result(ptr: *volatile anyopaque, result_or_error: anyerror!i32) void {
    const c_result: *volatile c.syscall_result = @ptrCast(@alignCast(ptr));
    const result: i32 = result_or_error catch |err| {
        c_result.*.err = @intFromError(err);
        c_result.*.result = -1;
        return;
    };

    c_result.*.result = result;
    c_result.*.err = -1;
}

pub fn system_call_handler(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void {
    write_result(out, syscall_lookup_table[number](arg));
}

// can be called only from the user process, not from the kernel
pub fn trigger(number: c.SystemCall, arg: ?*const anyopaque, out: ?*anyopaque) void {
    var svc_arg: *const anyopaque = undefined;
    var svc_out: *anyopaque = undefined;

    if (arg) |a| {
        svc_arg = a;
    } else {
        const a: i32 = 0;
        svc_arg = @ptrCast(&a);
    }
    if (out) |o| {
        svc_out = o;
    } else {
        var o: c.syscall_result = .{
            .result = 0,
            .err = 0,
        };
        svc_out = @ptrCast(&o);
    }

    hal.irq.trigger_supervisor_call(number, svc_arg, svc_out);
}

pub fn init(kernel_allocator: std.mem.Allocator) void {
    log.info("initialization...", .{});
    arch.irq_handlers.set_system_call_handler(system_call_handler);
    arch.irq_handlers.set_context_switch_handler(context_switch_handler);
    handlers.init(kernel_allocator);
}
