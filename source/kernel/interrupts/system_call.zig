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

const uaccess = @import("../uaccess.zig");
const ErrnoSet = kernel.errno.ErrnoSet;

// Not `*const volatile`: `arg` points at a kernel-owned copy of the caller's
// context (see `syscall_arg_bytes`), so it is stable for the life of the call.
// `volatile` would re-load every field access from the caller's memory, making a
// validate-then-use pair two reads of a value userspace can change in between.
const SyscallHandler = *const fn (arg: *const anyopaque) anyerror!i32;

const preempt = @import("../sync/preempt.zig");

const smp = @import("../smp.zig");

export fn do_context_switch(is_fpu_used: usize) linksection(".time_critical") usize {
    _ = is_fpu_used;
    // A core's first task switch is performed by switch_to_the_first_task, not
    // PendSV, so PendSV is ignored until then: that first switch is a plain
    // `bx entry`, which from a PendSV handler is not an exception return, and
    // would leave PENDSVACT permanently set. Per-core, because a secondary
    // core's SysTick runs from `init_secondary()` while it is still on MSP.
    //
    // Checked before the preempt count: a reschedule recorded now would be
    // re-triggered by the first `preempt_enable`, which is the same hazard.
    if (!smp.current_core_schedules()) {
        return 3;
    }
    if (preempt.preempt_disabled()) {
        // Record rather than drop: returning 3 alone makes a SysTick inside a
        // block window vanish, handing the running process a free timeslice.
        // `preempt_enable` re-pends PendSV when the outermost window closes.
        preempt.set_need_resched();
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
            c.sys_settimeofday => return handlers.sys_settimeofday,
            c.sys_utimensat => return handlers.sys_utimensat,
            c.sys_readlink => return handlers.sys_readlink,
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
            c.sys_pipe => return handlers.sys_pipe,
            c.sys_poll => return handlers.sys_poll,
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

/// How many bytes of `arg` to copy into kernel memory before dispatching, or
/// null for "do not copy". `arg` points into the caller's memory, so without the
/// copy a validate-then-use pair is two reads of a value the caller can change
/// in between.
///
/// null means the syscall ignores `arg`, or `arg` is not a context pointer at
/// all (`sys_start_root_process` gets a raw stack-pointer value), or the handler
/// writes back through the caller's struct and validates it itself
/// (`sys_perf_dump`). `SyscallArgTableCoversContexts` below is the reminder.
fn syscall_arg_bytes(comptime index: usize) ?usize {
    return switch (index) {
        c.sys_getpid => @sizeOf(u8),
        c.sys_isatty, c.sys_close, c.sys_exit => @sizeOf(c_int),
        c.sys_create_process => @sizeOf(handlers.CreateProcessCall),
        c.sys_semaphore_acquire, c.sys_semaphore_release => @sizeOf(handlers.SemaphoreEvent),
        c.sys_mkdir => @sizeOf(c.mkdir_context),
        c.sys_fstat => @sizeOf(c.fstat_context),
        c.sys_open => @sizeOf(c.open_context),
        c.sys_read => @sizeOf(c.read_context),
        c.sys_write => @sizeOf(c.write_context),
        c.sys_vfork => @sizeOf(c.vfork_context),
        c.sys_unlink => @sizeOf(c.unlink_context),
        c.sys_link => @sizeOf(c.link_context),
        c.sys_stat => @sizeOf(c.stat_context),
        c.sys_lseek => @sizeOf(c.lseek_context),
        c.sys_getdents => @sizeOf(c.getdents_context),
        c.sys_ioctl => @sizeOf(c.ioctl_context),
        c.sys_gettimeofday => @sizeOf(c.gettimeofday_context),
        c.sys_settimeofday => @sizeOf(c.settimeofday_context),
        c.sys_utimensat => @sizeOf(c.utimensat_context),
        c.sys_readlink => @sizeOf(c.readlink_context),
        c.sys_waitpid => @sizeOf(c.waitpid_context),
        c.sys_execve => @sizeOf(c.execve_context),
        c.sys_nanosleep => @sizeOf(c.nanosleep_context),
        c.sys_mmap => @sizeOf(c.mmap_context),
        c.sys_munmap => @sizeOf(c.munmap_context),
        c.sys_mremap => @sizeOf(c.mremap_context),
        c.sys_getcwd => @sizeOf(c.getcwd_context),
        c.sys_chdir => @sizeOf(c.chdir_context),
        c.sys_time => @sizeOf(c.time_context),
        c.sys_fcntl => @sizeOf(c.fcntl_context),
        c.sys_dlopen => @sizeOf(c.dlopen_context),
        c.sys_dlclose => @sizeOf(c.dlclose_context),
        c.sys_dlsym => @sizeOf(c.dlsym_context),
        c.sys_dup => @sizeOf(c.dup_context),
        c.sys_sysinfo => @sizeOf(c.sysinfo_context),
        c.sys_sysconf => @sizeOf(c.sysconf_context),
        c.sys_prlimit => @sizeOf(c.prlimit_context),
        c.sys_access => @sizeOf(c.access_context),
        c.sys_klog_ctl => @sizeOf(c.klog_ctl_context),
        c.sys_ftruncate => @sizeOf(c.ftruncate_context),
        c.sys_poll => @sizeOf(c.poll_context),
        else => null,
    };
}

const syscall_arg_size_table = blk: {
    var table: [c.SYSCALL_COUNT]?usize = undefined;
    for (&table, 0..) |*f, index| {
        f.* = syscall_arg_bytes(index);
    }
    break :blk table;
};

/// Size of the kernel-side landing buffer for the copy above.
const max_syscall_arg_bytes = blk: {
    var largest: usize = 0;
    for (syscall_arg_size_table) |maybe| {
        if (maybe) |n| {
            if (n > largest) largest = n;
        }
    }
    break :blk largest;
};

/// Whether the current caller's pointers have to be checked. Only unprivileged
/// processes are untrusted: root runs privileged and can reach any address
/// directly anyway, and the kernel issues syscalls of its own during boot with
/// `arg` and `out` on the MSP stack rather than in any user region.
fn caller_is_untrusted() bool {
    if (comptime !uaccess.enabled) return false;
    // "Is there a current process on this core yet?" -- which is per-core for
    // the same reason the switch gate above is: a secondary core has none until
    // it has taken its own first switch.
    if (!smp.current_core_schedules()) return false;
    if (!process_manager.is_initialized()) return false;
    return !process_manager.instance.get_current_process().is_privileged();
}

/// The same predicate as a plain byte array, indexed by syscall number and read
/// directly by the SVCall stub (`process_syscall_fast_check` in
/// context_switch.S) -- inline, that is a bounds check and one `ldrb`, where an
/// exported Zig function cost a real call on both paths. `u8` rather than `bool`
/// because the stub tests the whole byte and Zig does not guarantee `bool`'s bit
/// patterns.
pub export const syscall_fast_table: [c.SYSCALL_COUNT]u8 linksection(".time_critical") = blk: {
    var table: [c.SYSCALL_COUNT]u8 = undefined;
    for (&table, 0..) |*f, index| {
        f.* = if (is_fast_syscall(index)) 1 else 0;
    }
    break :blk table;
};

test "SystemCall.FastTableMatchesPredicate" {
    // The stub indexes `syscall_fast_table` with no way to check it against the
    // predicate it is generated from. A table that disagreed would strand a fast
    // syscall on the trampoline, or run a blocking one in handler mode, where it
    // deadlocks at SVCall priority.
    for (0..c.SYSCALL_COUNT) |index| {
        try std.testing.expectEqual(fast_syscall_table[index], syscall_fast_table[index] != 0);
    }
}

test "SystemCall.FastTableCoversEverySyscall" {
    // The stub bounds-checks against YASOS_SYSCALL_COUNT from sys/syscall_ids.h,
    // which the assembler can read and the enum is not. This covers the Zig side
    // of that contract, since the table it indexes is sized from the enum.
    try std.testing.expectEqual(@as(usize, c.SYSCALL_COUNT), syscall_fast_table.len);
    try std.testing.expectEqual(@as(usize, c.YASOS_SYSCALL_COUNT), syscall_fast_table.len);
}

test "SystemCall.ArgLandingBufferFitsEverySyscall" {
    // The landing buffer is sized from the same table the copy is driven by, so
    // the only way they can disagree is if someone hand-writes a size. Cheap
    // insurance against a copy that overruns the kernel stack frame.
    for (0..c.SYSCALL_COUNT) |index| {
        if (syscall_arg_size_table[index]) |bytes| {
            try std.testing.expect(bytes <= max_syscall_arg_bytes);
            try std.testing.expect(bytes > 0);
        }
    }
}

test "SystemCall.FastSyscallsCopyOrIgnoreTheirArgs" {
    // A fast syscall runs in handler mode, so it must not be one of the entries
    // left uncopied for write-back (sys_perf_dump) or because `arg` is a raw
    // value (sys_start_root_process).
    for (0..c.SYSCALL_COUNT) |index| {
        if (!fast_syscall_table[index]) continue;
        try std.testing.expect(index != c.sys_perf_dump);
        try std.testing.expect(index != c.sys_start_root_process);
    }
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
fn transferred_bytes(number: u32, arg: *const anyopaque, untrusted: bool) u32 {
    // Runs unconditionally after the handler, including on paths where the
    // handler bailed out before it ever looked at `result` -- so this cannot
    // assume the pointer was validated on the way in and has to check it here.
    const result_ptr: ?*const isize = switch (number) {
        c.sys_read => @as(*const c.read_context, @ptrCast(@alignCast(arg))).result,
        c.sys_write => @as(*const c.write_context, @ptrCast(@alignCast(arg))).result,
        else => null,
    };
    const ptr = result_ptr orelse return 0;
    if (untrusted and !uaccess.access_ok(@intFromPtr(ptr), @sizeOf(isize), .read)) return 0;
    const moved = ptr.*;
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

    // 0..4 are the SVCall stub's own protocol, not syscalls, which is why the
    // SystemCall enum starts at 5. Those call sites pass no arg/out pair at all,
    // so reporting through `out` writes eight bytes through a junk pointer --
    // often one inside the caller's own writable regions, where the validation
    // below waves it through and the corruption surfaces much later.
    if (number < c.sys_start_root_process) {
        log.err("reserved svc protocol id {d} reached the syscall dispatcher", .{number});
        return -1;
    }

    const untrusted = caller_is_untrusted();

    // `out` first, and before the range check: the out-of-range exit below
    // reports NotImplemented *through* `out`, which would be an unvalidated
    // 8-byte kernel write for a caller pairing a bogus syscall number with a
    // bogus result pointer. The stub sends every number it cannot classify down
    // this path rather than rejecting it, so both are caller-controlled.
    if (untrusted and !uaccess.access_ok(@intFromPtr(out), @sizeOf(c.syscall_result), .write)) {
        return -1;
    }

    if (number >= c.SYSCALL_COUNT) {
        return write_result(out, ErrnoSet.NotImplemented);
    }

    var call_arg: *const anyopaque = @volatileCast(arg);
    var landing: [max_syscall_arg_bytes]u8 align(8) = undefined;

    if (untrusted) {
        if (syscall_arg_size_table[number]) |bytes| {
            if (!uaccess.access_ok(@intFromPtr(arg), bytes, .read)) {
                return write_result(out, ErrnoSet.BadAddress);
            }
            @memcpy(landing[0..bytes], @as([*]const u8, @ptrCast(@volatileCast(arg)))[0..bytes]);
            call_arg = &landing;
        }
    }

    const result = write_result(out, syscall_lookup_table[number](call_arg));
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
        perf.record(number, now -% entry_cycles, now -% start_cycles, transferred_bytes(number, call_arg, untrusted));
    }
    return result;
}

pub fn init(kernel_allocator: std.mem.Allocator) void {
    log.info("initialization...", .{});
    // Snapshot the regions userspace is allowed to hand us pointers into. Must
    // happen before the first syscall from an unprivileged process; `main.zig`
    // calls this well before the root process is spawned.
    uaccess.init();
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
    try std.testing.expectEqual(handlers.sys_settimeofday, syscall_lookup_table[c.sys_settimeofday]);
    try std.testing.expectEqual(handlers.sys_utimensat, syscall_lookup_table[c.sys_utimensat]);
    try std.testing.expectEqual(handlers.sys_readlink, syscall_lookup_table[c.sys_readlink]);
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
    try std.testing.expectEqual(handlers.sys_poll, syscall_lookup_table[c.sys_poll]);
}

test "SystemCall.PollIsNotAFastSyscall" {
    // `sys_poll` sleeps until a descriptor is ready. Running it in the SVCall
    // handler would block at SVCall priority, which is the deadlock the
    // `is_fast_syscall` comment warns about.
    try std.testing.expect(!fast_syscall_table[c.sys_poll]);
    // ...and its context has to be copied in, or the handler would re-read
    // `nfds` from user memory after having bounds-checked it.
    try std.testing.expectEqual(@as(?usize, @sizeOf(c.poll_context)), syscall_arg_size_table[c.sys_poll]);
}

test "SystemCall.ReservedProtocolIdsAreNotSyscalls" {
    // The enum leaving 0..4 free is load-bearing: `irq_svcall` dispatches on the
    // raw r0 before it is a syscall number, so a member in that range would be
    // swallowed by the stub's own protocol and never reach the table.
    try std.testing.expect(c.sys_start_root_process >= 5);
    for (0..c.sys_start_root_process) |index| {
        // Nothing may be dispatched, run in handler mode, or have its arg copied
        // for an id the stub is supposed to have consumed before it got here.
        try std.testing.expect(!fast_syscall_table[index]);
        try std.testing.expectEqual(@as(?usize, null), syscall_arg_size_table[index]);
    }
}

test "SystemCall.ReservedProtocolIdWritesNothingThroughOut" {
    // A reserved id arriving here means the stub stopped consuming it. `out` is
    // then not an out pointer -- the sites that issue these leave junk in r2 --
    // so the one thing the dispatcher must not do is write a result through it.
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();
    process_manager.instance.create_root_process(1024, root_entry, null, "/") catch {};

    var result_data: c.syscall_result = .{ .result = 1234, .err = 5678 };
    var arg: i32 = 0;
    for (0..c.sys_start_root_process) |number| {
        try std.testing.expectEqual(-1, _irq_svcall(@intCast(number), &arg, &result_data));
        try std.testing.expectEqual(1234, result_data.result);
        try std.testing.expectEqual(5678, result_data.err);
    }
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
