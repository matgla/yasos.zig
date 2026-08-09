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
const perf = @import("perf_profile.zig");
comptime {
    _ = @import("arch");
    const config = @import("config");
    if (config.build.use_newlib) {
        _ = @import("system_stubs.zig");
    }
}

extern fn store_and_switch_to_next_task(is_fpu_used: usize) void;

const SyscallHandler = *const fn (arg: *const volatile anyopaque) anyerror!i32;

var context_switch_enabled: bool = true;
var counter: i32 = 0;

// Set true once the very first task has been switched in by
// switch_to_the_first_task (via process_set_next_task). Until then PendSV must
// NOT perform a context switch: the first switch into the root process is done
// with a plain `bx entry` (the root's saved EXC_RETURN slot holds the raw entry
// address, not a 0xFFxxxxxx magic). Doing that from a PendSV handler is not an
// exception return, so PendSV would be left permanently ACTIVE
// (SHCSR.PENDSVACT), silently killing all future context switches.
var scheduler_running: bool = false;

pub fn mark_scheduler_running() void {
    const ptr: *volatile bool = &scheduler_running;
    ptr.* = true;
}

pub fn block_context_switch() void {
    const blocked: usize = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(blocked);
    counter += 1;
    const ptr: *volatile bool = &context_switch_enabled;
    ptr.* = false;
}

pub fn unblock_context_switch() void {
    const blocked: usize = arch.sync.save_and_disable_interrupts();
    defer arch.sync.restore_interrupts(blocked);
    counter -= 1;
    if (counter == 0) {
        const ptr: *volatile bool = &context_switch_enabled;
        ptr.* = true;
    } else if (counter < 0) {
        const ptr: *volatile bool = &context_switch_enabled;
        ptr.* = true;
        counter = 0;
    }
}

export fn do_context_switch(is_fpu_used: usize) linksection(".time_critical") usize {
    _ = is_fpu_used;
    const ptr: *volatile bool = &context_switch_enabled;

    if (!ptr.*) {
        return 3;
    }
    // The first task switch is performed by switch_to_the_first_task, not by
    // PendSV. Ignore PendSV until then so an early SysTick cannot strand
    // SHCSR.PENDSVACT (see scheduler_running above).
    const running: *volatile bool = &scheduler_running;
    if (!running.*) {
        return 3;
    }
    switch (process_manager.instance.schedule_next()) {
        .Switch => {
            return 2;
        },
        .StoreAndSwitch => {
            return 1;
        },
        .ReturnToMain => return 0,
        else => return 3,
    }
    return 3;
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
            c.sys_mremap => return handlers.sys_mremap,
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
            c.sys_prlimit => return handlers.sys_prlimit,
            c.sys_klog_ctl => return handlers.sys_klog_ctl,
            c.sys_ftruncate => return handlers.sys_ftruncate,
            c.sys_perf_dump => return handlers.sys_perf_dump,
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

// A "fast" syscall is one whose handler provably never blocks, never invokes the
// scheduler / triggers a context switch, and never vforks/execs. Such calls can
// run entirely in the SVCall handler (already privileged) and exception-return
// directly to the user, skipping the trampoline-to-thread-mode + second SVC +
// CONTROL juggling. The result is delivered through the `out` pointer, so no
// stacked-frame patching is needed. Keep this set conservative and audited:
// misclassifying a blocking syscall would deadlock at SVCall priority.
fn is_fast_syscall(comptime index: usize) bool {
    return switch (index) {
        c.sys_getpid,
        c.sys_getuid,
        c.sys_geteuid,
        c.sys_time,
        c.sys_gettimeofday,
        c.sys_sysconf,
        c.sys_getentropy,
        => true,
        else => false,
    };
}

fn create_fast_syscall_table(comptime count: usize) [count]bool {
    var table: [count]bool = undefined;
    for (&table, 0..) |*f, index| {
        f.* = is_fast_syscall(index);
    }
    return table;
}

const fast_syscall_table = create_fast_syscall_table(c.SYSCALL_COUNT);

/// The same predicate as a plain byte array, indexed by syscall number and read
/// directly by the SVCall stub (`process_syscall_fast_check` in
/// context_switch.S).
///
/// The stub used to reach this decision through an exported Zig function, and
/// that call was a real one -- push/pop of a frame pointer and link register
/// around three instructions of table lookup -- which *both* paths paid, the
/// trampoline included, before it had even been decided that they were slow.
/// Read inline at the call site it is a bounds check and one `ldrb`.
///
/// `u8` rather than `bool` because the assembler indexes it with `ldrb`: Zig
/// guarantees `bool` a size of one byte but not which bit patterns it uses, and
/// the stub tests the whole byte.
pub export const syscall_fast_table: [c.SYSCALL_COUNT]u8 linksection(".time_critical") = blk: {
    var table: [c.SYSCALL_COUNT]u8 = undefined;
    for (&table, 0..) |*f, index| {
        f.* = if (is_fast_syscall(index)) 1 else 0;
    }
    break :blk table;
};

test "SystemCall.FastTableMatchesPredicate" {
    // The stub indexes `syscall_fast_table` with no way to check it against the
    // predicate it is generated from, and a table that silently disagreed would
    // either strand a fast syscall on the trampoline or -- far worse -- run a
    // blocking one in handler mode, where it deadlocks at SVCall priority.
    for (0..c.SYSCALL_COUNT) |index| {
        try std.testing.expectEqual(fast_syscall_table[index], syscall_fast_table[index] != 0);
    }
}

test "SystemCall.FastTableCoversEverySyscall" {
    // The stub bounds-checks against YASOS_SYSCALL_COUNT from sys/syscall_ids.h,
    // which the assembler can read and the enum is not. sys/syscall.h fails to
    // compile if the two drift; this covers the Zig side of the same contract,
    // since the table it indexes is sized from the enum.
    try std.testing.expectEqual(@as(usize, c.SYSCALL_COUNT), syscall_fast_table.len);
    try std.testing.expectEqual(@as(usize, c.YASOS_SYSCALL_COUNT), syscall_fast_table.len);
}

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

// Debug aid for kernel-heap corruption, off in normal builds: revalidate the
// newlib free list after every syscall and name the first one that leaves it
// broken (the reported tag is the syscall number). The alternative is the bare
// _free_r HardFault, which fires an arbitrary number of syscalls after the write
// that actually did the damage -- that is how the dup2(fd, fd) refcount
// use-after-free in sys_dup was found. Costs a full free-list walk per syscall,
// so it is not something to leave on.
const trap_heap_corruption = false;

/// Bytes a just-completed read/write actually moved, 0 for anything else.
///
/// Not the syscall's return value: read and write return 0 through `out` and
/// deliver the count in their context's `result` pointer, which is why reading
/// `result` here reported 0 bytes moved against nonzero read/write time.
fn transferred_bytes(number: u32, arg: *const volatile anyopaque) u32 {
    const moved: isize = switch (number) {
        c.sys_read => blk: {
            const context: *const volatile c.read_context = @ptrCast(@alignCast(arg));
            break :blk if (context.result != null) context.result.* else 0;
        },
        c.sys_write => blk: {
            const context: *const volatile c.write_context = @ptrCast(@alignCast(arg));
            break :blk if (context.result != null) context.result.* else 0;
        },
        else => 0,
    };
    return if (moved > 0) @intCast(moved) else 0;
}

pub export fn _irq_svcall(number: u32, arg: *const volatile anyopaque, out: *volatile anyopaque) linksection(".time_critical") callconv(.c) isize {
    // Two stamps: `entry_cycles` was taken in the SVC handler before the
    // fast-path decision, so it carries exception entry plus (for a non-fast
    // syscall) the trampoline; `start_cycles` starts the handler body. The
    // difference between the two totals is what syscall *dispatch* costs, which
    // is the number that decides whether to make calls cheaper or make them
    // fewer.
    const entry_cycles = if (perf.enabled) perf.perf_svc_entry_cycles else 0;
    const start_cycles = if (perf.enabled) perf.read_cycles() else 0;
    // log.err("System call processing started for: {d}", .{number});
    if (number >= c.SYSCALL_COUNT) {
        return write_result(out, kernel.errno.ErrnoSet.NotImplemented);
    }
    const result = write_result(out, syscall_lookup_table[number](arg));
    if (trap_heap_corruption) kernel.memory.heap.malloc.probe(number);
    // log.err("System call processing finished for: {d}", .{number});
    // execve and vfork are deliberately not accounted, because neither one's
    // elapsed time belongs to the process it would be charged to:
    //
    //   execve resets the counters partway through (that is what makes the
    //   window mean "this image"), and its handler time *is* the dynamic load,
    //   already reported as load_us -- recording it bills the loader twice;
    //
    //   vfork in the parent does not complete until the child execs, so its
    //   window spans the child's whole pre-exec life *and* the image load, and
    //   it lands after the reset. Left in, it put ~22 ms of loader time into
    //   `cat`'s syscall total -- more than cat's entire run.
    if (perf.enabled and number != c.sys_execve and number != c.sys_vfork) {
        const now = perf.read_cycles();
        perf.record(number, now -% entry_cycles, now -% start_cycles, transferred_bytes(number, arg));
    }
    return result;
}

pub fn init(kernel_allocator: std.mem.Allocator) void {
    log.info("initialization...", .{});
    handlers.init(kernel_allocator);
    perf.init();
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
    try std.testing.expectEqual(handlers.sys_prlimit, syscall_lookup_table[c.sys_prlimit]);
    try std.testing.expectEqual(handlers.sys_perf_dump, syscall_lookup_table[c.sys_perf_dump]);
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
