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

const kernel = @import("../kernel.zig");
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

extern fn store_and_switch_to_next_task(is_fpu_used: usize) void;
extern fn switch_to_the_next_task(is_fpu_used: usize) void;

const SyscallHandler = *const fn (arg: *const volatile anyopaque) anyerror!i32;
var context_switch_enabled: bool = true;

export fn block_context_switch() void {
    context_switch_enabled = false;
}

export fn unblock_context_switch() void {
    context_switch_enabled = true;
}

export fn do_context_switch(is_fpu_used: usize) linksection(".time_critical") usize {
    if (!context_switch_enabled) {
        return 1;
    }
    switch (process_manager.instance.schedule_next()) {
        .Switch => {
            switch_to_the_next_task(is_fpu_used);
            return 1;
        },
        .StoreAndSwitch => {
            store_and_switch_to_next_task(is_fpu_used);
            return 1;
        },
        .ReturnToMain => return 0,
        else => return 1,
    }
    return 1;
}

fn sys_unhandled_factory(comptime i: usize) linksection(".time_critical") type {
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
            c.sys_getuid => return handlers.sys_getuid,
            c.sys_geteuid => return handlers.sys_geteuid,
            c.sys_dup => return handlers.sys_dup,
            c.sys_sysinfo => return handlers.sys_sysinfo,
            c.sys_sysconf => return handlers.sys_sysconf,
            c.sys_access => return handlers.sys_access,
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

fn write_result(ptr: *volatile anyopaque, result_or_error: anyerror!i32) linksection(".time_critical") isize {
    const c_result: *volatile c.syscall_result = @ptrCast(@alignCast(ptr));
    const result: i32 = result_or_error catch |err| {
        c_result.*.err = kernel.errno.to_errno(err);
        c_result.*.result = -1;
        return -1;
    };

    c_result.*.result = result;
    c_result.*.err = -1;
    return result;
}

pub export fn _irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) linksection(".time_critical") callconv(.c) isize {
    process_manager.instance.get_current_process().processes_syscall = true;
    if (number >= c.SYSCALL_COUNT) {
        return write_result(out, kernel.errno.ErrnoSet.NotImplemented);
    }
    const result = write_result(out, syscall_lookup_table[number](arg));
    process_manager.instance.get_current_process().processes_syscall = false;
    return result;
}

// // can be called only from the user process, not from the kernel
// pub fn trigger(number: c.SystemCall, arg: *const anyopaque, out: *anyopaque) linksection(".time_critical") void {
//     hal.irq.trigger_supervisor_call(number, svc_arg, svc_out);
// }

pub fn init(kernel_allocator: std.mem.Allocator) void {
    log.info("initialization...", .{});
    // arch.irq_handlers.set_system_call_handler(system_call_handler);
    // arch.irq_handlers.set_context_switch_handler(context_switch_handler);
    handlers.init(kernel_allocator);
}

test "SystemCall.VerifyLookupTable" {
    try std.testing.expectEqual(handlers.sys_start_root_process, syscall_lookup_table[c.sys_start_root_process]);
    try std.testing.expectEqual(handlers.sys_stop_root_process, syscall_lookup_table[c.sys_stop_root_process]);
    try std.testing.expectEqual(handlers.sys_create_process, syscall_lookup_table[c.sys_create_process]);
    try std.testing.expectEqual(handlers.sys_semaphore_acquire, syscall_lookup_table[c.sys_semaphore_acquire]);
    try std.testing.expectEqual(handlers.sys_semaphore_release, syscall_lookup_table[c.sys_semaphore_release]);
    try std.testing.expectEqual(handlers.sys_getpid, syscall_lookup_table[c.sys_getpid]);
    try std.testing.expectEqual(handlers.sys_mkdir, syscall_lookup_table[c.sys_mkdir]);
    try std.testing.expectEqual(handlers.sys_fstat, syscall_lookup_table[c.sys_fstat]);
    try std.testing.expectEqual(handlers.sys_isatty, syscall_lookup_table[c.sys_isatty]);
    try std.testing.expectEqual(handlers.sys_open, syscall_lookup_table[c.sys_open]);
    try std.testing.expectEqual(handlers.sys_close, syscall_lookup_table[c.sys_close]);
    try std.testing.expectEqual(handlers.sys_exit, syscall_lookup_table[c.sys_exit]);
    try std.testing.expectEqual(handlers.sys_read, syscall_lookup_table[c.sys_read]);
    try std.testing.expectEqual(handlers.sys_kill, syscall_lookup_table[c.sys_kill]);
    try std.testing.expectEqual(handlers.sys_write, syscall_lookup_table[c.sys_write]);
    try std.testing.expectEqual(handlers.sys_vfork, syscall_lookup_table[c.sys_vfork]);
    try std.testing.expectEqual(handlers.sys_unlink, syscall_lookup_table[c.sys_unlink]);
    try std.testing.expectEqual(handlers.sys_link, syscall_lookup_table[c.sys_link]);
    try std.testing.expectEqual(handlers.sys_stat, syscall_lookup_table[c.sys_stat]);
    try std.testing.expectEqual(handlers.sys_getentropy, syscall_lookup_table[c.sys_getentropy]);
    try std.testing.expectEqual(handlers.sys_lseek, syscall_lookup_table[c.sys_lseek]);
    try std.testing.expectEqual(handlers.sys_wait, syscall_lookup_table[c.sys_wait]);
    try std.testing.expectEqual(handlers.sys_times, syscall_lookup_table[c.sys_times]);
    try std.testing.expectEqual(handlers.sys_getdents, syscall_lookup_table[c.sys_getdents]);
    try std.testing.expectEqual(handlers.sys_ioctl, syscall_lookup_table[c.sys_ioctl]);
    try std.testing.expectEqual(handlers.sys_gettimeofday, syscall_lookup_table[c.sys_gettimeofday]);
    try std.testing.expectEqual(handlers.sys_waitpid, syscall_lookup_table[c.sys_waitpid]);
    try std.testing.expectEqual(handlers.sys_execve, syscall_lookup_table[c.sys_execve]);
    try std.testing.expectEqual(handlers.sys_nanosleep, syscall_lookup_table[c.sys_nanosleep]);
    try std.testing.expectEqual(handlers.sys_mmap, syscall_lookup_table[c.sys_mmap]);
    try std.testing.expectEqual(handlers.sys_munmap, syscall_lookup_table[c.sys_munmap]);
    try std.testing.expectEqual(handlers.sys_getcwd, syscall_lookup_table[c.sys_getcwd]);
    try std.testing.expectEqual(handlers.sys_chdir, syscall_lookup_table[c.sys_chdir]);
    try std.testing.expectEqual(handlers.sys_time, syscall_lookup_table[c.sys_time]);
    try std.testing.expectEqual(handlers.sys_fcntl, syscall_lookup_table[c.sys_fcntl]);
    try std.testing.expectEqual(handlers.sys_remove, syscall_lookup_table[c.sys_remove]);
    try std.testing.expectEqual(handlers.sys_realpath, syscall_lookup_table[c.sys_realpath]);
    try std.testing.expectEqual(handlers.sys_mprotect, syscall_lookup_table[c.sys_mprotect]);
    try std.testing.expectEqual(handlers.sys_dlopen, syscall_lookup_table[c.sys_dlopen]);
    try std.testing.expectEqual(handlers.sys_dlclose, syscall_lookup_table[c.sys_dlclose]);
    try std.testing.expectEqual(handlers.sys_dlsym, syscall_lookup_table[c.sys_dlsym]);
    try std.testing.expectEqual(handlers.sys_getuid, syscall_lookup_table[c.sys_getuid]);
    try std.testing.expectEqual(handlers.sys_geteuid, syscall_lookup_table[c.sys_geteuid]);
    try std.testing.expectEqual(handlers.sys_dup, syscall_lookup_table[c.sys_dup]);
    try std.testing.expectEqual(handlers.sys_sysinfo, syscall_lookup_table[c.sys_sysinfo]);
    try std.testing.expectEqual(handlers.sys_sysconf, syscall_lookup_table[c.sys_sysconf]);
    try std.testing.expectEqual(handlers.sys_access, syscall_lookup_table[c.sys_access]);
}

test "SystemCall.UnhandledSyscallReturnsError" {
    const sut = sys_unhandled_factory(0);
    var data: i32 = 0;
    try std.testing.expectEqual(-1, sut.handler(&data));
}

test "SystemCall.ShouldWriteResult" {
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    var result_data: c.syscall_result = .{
        .result = 0,
        .err = 0,
    };
    _ = write_result(&result_data, 42);
    try std.testing.expectEqual(42, result_data.result);
    try std.testing.expectEqual(-1, result_data.err);

    result_data = .{
        .result = 0,
        .err = 0,
    };
    _ = write_result(&result_data, error.InvalidArgument);
    try std.testing.expectEqual(-1, result_data.result);
    try std.testing.expectEqual(kernel.errno.to_errno(error.InvalidArgument), result_data.err);
}

fn root_entry() void {}

test "SystemCall.ShouldErrorOnUnhandledSyscall" {
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    process_manager.instance.create_root_process(1024, root_entry, null, "/") catch {};

    var result_data: c.syscall_result = .{
        .result = 0,
        .err = 0,
    };
    var arg: i32 = 0;
    _ = _irq_svcall(c.SYSCALL_COUNT, &arg, &result_data);
    try std.testing.expectEqual(-1, result_data.result);
    try std.testing.expectEqual(kernel.errno.to_errno(kernel.errno.ErrnoSet.NotImplemented), result_data.err);
}
