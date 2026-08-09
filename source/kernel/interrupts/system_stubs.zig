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
const hal = @import("hal");
const arch = @import("arch");

const c = @import("libc_imports").c;
const fs = @import("../fs/vfs.zig");
const IFile = @import("../fs/ifile.zig").IFile;
const systick = @import("systick.zig");
const time = @import("../time.zig");

const config = @import("config");

const process_manager = @import("../process_manager.zig");
const FileType = @import("../fs/ifile.zig").FileType;
const handlers = @import("syscall_handlers.zig");

// Issue a system call via the SVC trap so the work runs in the privileged
// kernel handler. These newlib porting stubs are resolved into user processes,
// which run unprivileged when kernel MPU protection is enabled; calling kernel
// code directly from them would fault on the protected kernel RAM, so they must
// trap instead. Mirrors libc's trigger_syscall (libs/libc/syscalls.c).
inline fn trigger_syscall(number: u32, args: *const anyopaque) i32 {
    var result: c.syscall_result = .{ .err = 0, .result = 0 };
    hal.irq.trigger_supervisor_call(number, args, &result);
    return result.result;
}

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
    var status: c_int = code;
    _ = trigger_syscall(c.sys_exit, &status);
    // sys_exit tears the process down and context-switches away, so this is
    // never reached; loop defensively rather than returning into freed state.
    while (true) {}
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
    var fd_arg: c_int = fd;
    return trigger_syscall(c.sys_isatty, &fd_arg);
}

pub export fn _close(fd: c_int) c_int {
    var fd_arg: c_int = fd;
    return trigger_syscall(c.sys_close, &fd_arg);
}

export fn _lseek(_: c_int, _: c.off_t, _: c_int) c_int {
    return 0;
}

pub export fn _read(fd: c_int, data: *anyopaque, size: usize) isize {
    var result: isize = 0;
    const context = c.read_context{
        .fd = fd,
        .buf = data,
        .count = size,
        .result = &result,
    };
    _ = trigger_syscall(c.sys_read, &context);
    return result;
}

pub export fn _write(fd: c_int, data: *const anyopaque, size: usize) isize {
    var result: isize = 0;
    const context = c.write_context{
        .fd = fd,
        .buf = data,
        .count = size,
        .result = &result,
    };
    _ = trigger_syscall(c.sys_write, &context);
    return result;
}

pub export fn _ioctl(fd: c_int, request: c_int, data: ?*anyopaque) c_int {
    const context = c.ioctl_context{
        .fd = fd,
        .op = request,
        .arg = @bitCast(@intFromPtr(data)),
    };
    return trigger_syscall(c.sys_ioctl, &context);
}

pub export fn _fcntl(fd: c_int, request: c_int, data: ?*anyopaque) c_int {
    const context = c.fcntl_context{
        .fd = fd,
        .op = request,
        .arg = @bitCast(@intFromPtr(data)),
    };
    return trigger_syscall(c.sys_fcntl, &context);
}

pub export fn _nanosleep(ts: c.timespec) c_int {
    const req = ts;
    const context = c.nanosleep_context{
        .req = &req,
        .rem = null,
    };
    return trigger_syscall(c.sys_nanosleep, &context);
}

pub fn _time(t: ?*c.time_t) c.time_t {
    const now_seconds: c.time_t = @intCast(hal.time.get_time());
    if (t) |time_ptr| {
        time_ptr.* = now_seconds;
    }
    return now_seconds;
}

extern var end: u8;
extern var __heap_limit__: u8;
var heap_end: *u8 = &end;

// newlib (and other C runtimes) expect sbrk() to report failure by returning
// (void*)-1, NOT NULL: malloc/sbrk_aligned check `p == (void*)-1` (compiled as
// `adds r,p,#1; beq fail`).  Returning 0 made newlib treat NULL as a valid
// allocation on heap exhaustion, so it wrote chunk metadata at low/invalid
// addresses and corrupted the kernel stack -> wild `pop {pc}` HardFault
// (seen as a kernel-context fault in sbrk_aligned under tcc at -O1/-O2).
const SBRK_FAILED: *allowzero anyopaque = @ptrFromInt(~@as(usize, 0));

export fn _sbrk(incr: usize) *allowzero anyopaque {
    const prev_heap_end: *u8 = heap_end;
    const next_heap_end: *u8 = @ptrFromInt(@intFromPtr(heap_end) + incr);

    if (@intFromPtr(next_heap_end) >= @intFromPtr(&__heap_limit__)) {
        // Kernel heap exhausted. Returning SBRK_FAILED lets newlib hand NULL
        // back to the caller (the documented contract), but a kernel allocation
        // that silently fails tends to resurface far away as corrupted
        // bookkeeping — e.g. the process-tracking structs that live in
        // kernel_ram get garbage, a process ends up pointed into kernel SRAM,
        // and we see a MemManage DACCVIOL in an unrelated user process instead
        // of here. The kernel heap is bounded kernel bookkeeping; running it dry
        // is unrecoverable, so fail loudly at the source rather than corrupt.
        std.log.scoped(.kernel_heap).err(
            "kernel heap exhausted: _sbrk(+{d}) heap_end=0x{x} limit=0x{x} used={d}B",
            .{ incr, @intFromPtr(heap_end), @intFromPtr(&__heap_limit__), kernel_heap_physical_used() },
        );
        @panic("kernel heap exhausted (_sbrk over __heap_limit__)");
    }
    heap_end = next_heap_end;
    return prev_heap_end;
}

/// True physical kernel-heap bytes claimed from the SRAM heap region. newlib's
/// malloc grows the break via _sbrk and (almost) never returns it, so this is an
/// accurate high-water of physical kernel_ram in use — and, unlike malloc.zig's
/// memory_in_use counter, it INCLUDES leak-detection trackers, newlib chunk
/// headers, and free-list fragmentation. This is the number to size kernel_ram by.
pub fn kernel_heap_physical_used() usize {
    return @intFromPtr(heap_end) - @intFromPtr(&end);
}

pub fn process_sbrk(incr: usize) *allowzero anyopaque {
    const process = process_manager.instance.get_current_process();
    const prev_heap_end: *u8 = process.heap_end;
    const next_heap_end: *u8 = @ptrFromInt(@intFromPtr(process.heap_end) + incr);
    if (@intFromPtr(next_heap_end) >= @intFromPtr(&__heap_limit__)) {
        return SBRK_FAILED;
    }
    process.heap_end = next_heap_end;
    return prev_heap_end;
}

// newlib guards its malloc free-list with __malloc_lock/__malloc_unlock, but the
// default retarget stubs are no-ops (`bx lr`).  The KERNEL heap is newlib malloc
// (used by the dynamic loader during execve / lazy PLT resolve), so without a
// real lock the free-list had NO protection against re-entrancy: a SysTick ->
// PendSV context switch could preempt a malloc/free mid free-list update and let
// another kernel allocation splice the chain, producing a wild `pop {pc}` == 0
// HardFault in sbrk_aligned / the loader's generate_thunk / lazy_resolve.  This
// is timing-dependent, so it only surfaced under heavy host load (parallel QEMU
// smoke runs) where the CPU-starved guest widens the preemption window.
//
// A blocking mutex/semaphore is the WRONG primitive here: Semaphore.acquire()
// issues an SVC, and the lazy resolver already runs in SVC/exception context
// (nested SVC -> HardFault); it would also yield the CPU while the heap invariant
// is half-updated.  The correct fix is a short interrupt-disabled critical
// section.  It must be nesting-safe because newlib's realloc takes the lock and
// then calls the (also-locking) _malloc_r / _free_r.
var malloc_lock_depth: usize = 0;
var malloc_lock_primask: usize = 0;

// On RP2350 the pico-sdk references malloc early, pulling newlib's strong mlock.o
// into the link ahead of this Zig compilation unit -> a duplicate-symbol error.
// There the override is provided by hal/source/raspberry/rp2350/malloc_lock.c
// (a C object linked before libc_nano.a), so this Zig export is compiled out.
const provide_malloc_lock_in_zig = !std.mem.eql(u8, config.cpu.cpu, "rp2350");

fn malloc_lock_impl(_: ?*anyopaque) callconv(.c) void {
    const primask = arch.sync.save_and_disable_interrupts();
    if (malloc_lock_depth == 0) {
        malloc_lock_primask = primask;
    }
    malloc_lock_depth += 1;
}

fn malloc_unlock_impl(_: ?*anyopaque) callconv(.c) void {
    malloc_lock_depth -= 1;
    if (malloc_lock_depth == 0) {
        arch.sync.restore_interrupts(malloc_lock_primask);
    }
}

comptime {
    if (provide_malloc_lock_in_zig) {
        @export(&malloc_lock_impl, .{ .name = "__malloc_lock" });
        @export(&malloc_unlock_impl, .{ .name = "__malloc_unlock" });
    }
}

export fn hard_assertion_failure() void {
    while (true) {}
}
