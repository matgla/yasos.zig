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

const c = @cImport({
    @cInclude("syscalls.h");
});

const syscall = @import("../system_stubs.zig");

const kernel_log = @import("../../log/kernel_log.zig");
const log = &kernel_log.kernel_log;

const process_manager = @import("../process_manager.zig");
const Semaphore = @import("../semaphore.zig").Semaphore;
const KernelSemaphore = @import("kernel_semaphore.zig").KernelSemaphore;
const config = @import("config");

extern fn switch_to_next_task() void;
extern fn store_and_switch_to_next_task() void;

pub const CreateProcessCall = struct {
    allocator: std.mem.Allocator,
    entry: *const anyopaque,
    stack_size: u32,
    arg: ?*const anyopaque,
};

pub const SemaphoreEvent = struct {
    object: *Semaphore,
};

// mov to arch file

inline fn get_lr() usize {
    return asm volatile (
        \\ mov %[ret], lr
        : [ret] "=r" (-> usize),
    );
}

export fn irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) void {
    // those operations must be secure since both cores may be executing that code in the same time
    const lr = get_lr();
    hal.hw_atomic.lock(config.process.hw_spinlock_number);
    defer hal.hw_atomic.unlock(config.process.hw_spinlock_number);
    switch (number) {
        c.sys_start_root_process => {
            switch_to_next_task();
        },
        c.sys_create_process => {
            const context: *const volatile CreateProcessCall = @ptrCast(@alignCast(arg));
            const result: *volatile bool = @ptrCast(out);
            process_manager.instance.create_process(context.stack_size, context.entry, context.arg, "/") catch {
                return;
            };
            result.* = true;
        },
        c.sys_semaphore_acquire => {
            const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
            const result: *volatile bool = @ptrCast(@alignCast(out));
            result.* = KernelSemaphore.acquire(context.object);
        },
        c.sys_semaphore_release => {
            const context: *const volatile SemaphoreEvent = @ptrCast(@alignCast(arg));
            KernelSemaphore.release(context.object);
        },
        c.sys_isatty => {
            const fd: *const volatile c_int = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._isatty(fd.*);
        },
        c.sys_open => {
            const context: *const volatile c.open_context = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._open(context.path, context.flags, context.mode);
        },
        c.sys_close => {
            const fd: *const volatile c_int = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._close(fd.*);
        },
        c.sys_write => {
            const context: *const volatile c.write_context = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._write(context.fd, context.buf.?, context.count);
        },
        c.sys_read => {
            const context: *const volatile c.read_context = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._read(context.fd, context.buf.?, context.count);
        },
        c.sys_vfork => {
            const result: *volatile c.pid_t = @ptrCast(@alignCast(out));
            result.* = @intCast(process_manager.instance.vfork(lr, @intFromPtr(result)));
        },
        c.sys_waitpid => {
            const context: *const volatile c.waitpid_context = @ptrCast(@alignCast(arg));
            const result: *volatile c.pid_t = @ptrCast(@alignCast(out));
            result.* = process_manager.instance.waitpid(context.pid, context.status);
        },
        c.sys_ioctl => {
            const context: *const volatile c.ioctl_context = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._ioctl(context.fd, context.op, context.arg);
        },
        c.sys_exit => {
            const context: *const volatile c_int = @ptrCast(@alignCast(arg));
            syscall._exit(context.*);
        },
        c.sys_mmap => {
            const context: *const volatile c.mmap_context = @ptrCast(@alignCast(arg));
            const result: *volatile c.mmap_result = @ptrCast(@alignCast(out));
            result.memory = syscall._mmap(context.addr, context.length, context.prot, context.flags, context.fd, context.offset);
        },
        c.sys_munmap => {
            const context: *const volatile c.munmap_context = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._munmap(context.addr, context.length);
        },
        c.sys_execve => {
            asm volatile (
                \\ cpsid i 
            );
            const context: *const volatile c.execve_context = @ptrCast(@alignCast(arg));
            const result: *volatile c.execve_result = @ptrCast(@alignCast(out));
            const exec_result = process_manager.instance.prepare_exec(std.mem.span(context.filename), context.argv, context.envp);
            result.result = exec_result;
            asm volatile (
                \\ cpsie i 
            );
        },
        c.sys_getcwd => {
            const context: *const volatile c.getcwd_context = @ptrCast(@alignCast(arg));
            const result: *volatile *allowzero c_char = @ptrCast(@alignCast(out));
            if (process_manager.instance.get_current_process()) |current_process| {
                const cwd = current_process.get_current_directory();
                const cwd_len = @min(cwd.len, context.size);
                std.mem.copyForwards(u8, context.buf[0..cwd_len], cwd[0..cwd_len]);
                var last_index = cwd.len;
                if (last_index > context.size) {
                    last_index = context.size - 1;
                }
                context.buf[last_index] = 0;
                result.* = context.buf;
            } else {
                context.buf[0] = 0;
                result.* = @ptrFromInt(0);
            }
        },
        c.sys_getdents => {
            const context: *const volatile c.getdents_context = @ptrCast(@alignCast(arg));
            const result: *volatile isize = @ptrCast(@alignCast(out));
            if (context.dirp == null) {
                result.* = -1;
            } else {
                result.* = syscall._getdents(context.fd, context.dirp.?, context.count);
            }
        },
        c.sys_chdir => {
            const context: *const volatile c.chdir_context = @ptrCast(@alignCast(arg));
            const result: *volatile c_int = @ptrCast(@alignCast(out));
            result.* = syscall._chdir(context.path.?);
        },
        else => {
            log.print("Unhandled system call id: {d}\n", .{number});
        },
    }
}

pub export fn unlock_pendsv_spinlock() void {
    hal.hw_atomic.unlock(config.process.hw_spinlock_number);
}

export fn irq_pendsv() void {
    hal.hw_atomic.lock(config.process.hw_spinlock_number);
    if (process_manager.instance.scheduler.schedule_next()) {
        store_and_switch_to_next_task();
    } else {
        hal.hw_atomic.unlock(config.process.hw_spinlock_number);
    }
}

export fn irq_hard_fault() void {
    log.print("PANIC: Hard Fault occured!\n", .{});
    while (true) {
        asm volatile (
            \\ wfi
        );
    }
}

pub fn trigger(number: c.SystemCall, arg: ?*const anyopaque, out: ?*anyopaque) void {
    var svc_arg: *const anyopaque = undefined;
    var svc_out: *anyopaque = undefined;

    if (arg) |a| {
        svc_arg = a;
    }
    if (out) |o| {
        svc_out = o;
    }

    hal.irq.trigger_supervisor_call(number, svc_arg, svc_out);
}
