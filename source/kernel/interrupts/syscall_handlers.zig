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
const vfmt = @import("../vfmt.zig");
const process_manager = @import("../process_manager.zig");

const Semaphore = @import("../semaphore.zig").Semaphore;
const KernelSemaphore = @import("kernel_semaphore.zig").KernelSemaphore;

const FileType = @import("../fs/ifile.zig").FileType;
const IFile = @import("../fs/ifile.zig").IFile;

const fs = @import("../fs/vfs.zig");

const kernel = @import("../kernel.zig");
const log = std.log.scoped(.syscall);

const systick = @import("systick.zig");
const time = @import("../time.zig");

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
    const process = process_manager.instance.get_current_process();
    const maybe_handle = process.get_file_handle(fd);
    if (maybe_handle) |handle| {
        const maybe_file = handle.node.as_file();
        if (maybe_file) |file| {
            return file;
        }
        return kernel.errno.ErrnoSet.IsADirectory;
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

extern fn switch_to_the_first_task(with_fpu: usize) void;
extern fn push_return_address() void;
extern fn switch_to_main_task(lr: usize, with_fpu: bool) void;
var main_process_stack_pointer_before_scheduler_started: usize = 0;

pub fn sys_start_root_process(arg: *const volatile anyopaque) !i32 {
    // Apply the (signed, usually negative) register-frame offset to the stack
    // pointer in unsigned/wrapping space. Casting the pointer through `isize`
    // first overflows on targets whose stacks live at/above 0x80000000 (e.g.
    // the QEMU mps2 kernel stack), tripping the "integer does not fit" panic.
    const base: usize = @intFromPtr(arg);
    const offset: isize = kernel.process.get_offset_of_hardware_stored_registers(config.cpu.use_fpu);
    main_process_stack_pointer_before_scheduler_started = base +% @as(usize, @bitCast(offset));
    std.log.info("Starting root process with stack pointer: {x}", .{main_process_stack_pointer_before_scheduler_started});
    switch_to_the_first_task(if (config.cpu.use_fpu) 1 else 0);
    return 0;
}

pub fn sys_stop_root_process(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    hal.time.systick.disable();
    std.log.info("Stopping root process with stack pointer: {x}", .{main_process_stack_pointer_before_scheduler_started});
    switch_to_main_task(main_process_stack_pointer_before_scheduler_started, config.cpu.use_fpu);
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
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const check_parent: *const volatile u8 = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    if (check_parent.* != 0) {
        const maybe_parent = process.get_parent();
        if (maybe_parent) |parent| {
            return @intCast(parent.pid);
        }
        return 0;
    }
    return @intCast(process.pid);
}

pub fn sys_mkdir(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.mkdir_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.path, context.fd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.mkdir(path, @intCast(context.mode));
    return 0;
}

pub fn sys_fstat(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.fstat_context = @ptrCast(@alignCast(arg));
    if (context.buf == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }
    const path = try determine_path_for_file(kernel_allocator, null, context.fd);
    defer kernel_allocator.free(path);
    fs.get_ivfs().interface.stat(path, context.buf, true) catch |err| {
        return err;
    };
    return 0;
}

pub fn sys_isatty(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const fd: *const volatile c_int = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
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
    return 0;
}

fn determine_path_for_file(allocator: std.mem.Allocator, maybe_path: [*c]const u8, fd: i32) ![]const u8 {
    var prefix: []const u8 = "";
    if (maybe_path) |cpath| {
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(cpath)));
        if (path.len > 0 and path[0] == '/') {
            return try allocator.dupe(u8, path);
        }
        if (fd >= 0) {
            const current_process = process_manager.instance.get_current_process();
            prefix = current_process.get_current_directory();
            const maybe_handle = current_process.get_file_handle(@intCast(fd));
            if (maybe_handle) |handle| {
                if (handle.node.is_directory()) {
                    prefix = handle.path;
                }
            } else {
                return error.CannotDeterminePathForFd;
            }
            const full_path = try vfmt.allocPrint(allocator, "{s}/{s}", .{ prefix, path });
            defer allocator.free(full_path);
            const real = try std.fs.path.resolve(allocator, &.{full_path});
            return real;
        } else {
            if (path.len > 0) {
                const current_process = process_manager.instance.get_current_process();
                const pwd = current_process.get_current_directory();
                const full_path = try vfmt.allocPrint(allocator, "{s}/{s}/{s}", .{ pwd, prefix, path });
                defer allocator.free(full_path);
                const real = try std.fs.path.resolve(allocator, &.{full_path});
                return real;
            } else {
                return try allocator.dupe(u8, path);
            }
        }
    } else if (fd >= 0) {
        const current_process = process_manager.instance.get_current_process();
        const maybe_handle = current_process.get_file_handle(@intCast(fd));
        if (maybe_handle) |handle| {
            return try allocator.dupe(u8, handle.path);
        }
    }
    return error.CannotDeterminePath;
}

pub fn sys_open(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.open_context = @ptrCast(@alignCast(arg));
    const t_resolve = if (perf.enabled) perf.read_cycles() else 0;
    const path = try determine_path_for_file(kernel_allocator, context.path, context.fd);
    defer kernel_allocator.free(path);
    const process = process_manager.instance.get_current_process();
    const t_lookup = if (perf.enabled) perf.read_cycles() else 0;
    perf.open_record(.resolve, t_lookup -% t_resolve);
    const maybe_node: ?kernel.fs.Node = fs.get_ivfs().interface.get(path) catch |err| blk: {
        break :blk switch (err) {
            error.NoEntry => null,
            else => {
                if (perf.enabled) {
                    perf.open_record(.lookup, perf.read_cycles() -% t_lookup);
                    perf.open_call(false);
                }
                return err;
            },
        };
    };
    const t_attach = if (perf.enabled) perf.read_cycles() else 0;
    perf.open_record(.lookup, t_attach -% t_lookup);
    if (maybe_node) |file| {
        const fd_result = try process.attach_file(path, file);
        if (perf.enabled) {
            perf.open_record(.attach, perf.read_cycles() -% t_attach);
            perf.open_call(true);
        }
        return fd_result;
    } else if ((context.flags & c.O_CREAT) != 0) {
        try fs.get_ivfs().interface.create(path, context.mode);
        const ifile = try fs.get_ivfs().interface.get(path);
        const fd_result = try process.attach_file(path, ifile);
        perf.open_call(true);
        return fd_result;
    }
    // Nothing there and no O_CREAT: a probe that walked the filesystem for
    // nothing. Library search is made of these, so they are counted apart.
    perf.open_call(false);
    return -1;
}

fn close_fd(fd: i32) i32 {
    if (fd < 0) {
        return -1;
    }
    const process = process_manager.instance.get_current_process();
    process.release_file(@intCast(fd));
    return 0;
}

pub fn sys_close(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const fd: *const volatile c_int = @ptrCast(@alignCast(arg));
    return close_fd(fd.*);
}

pub fn sys_exit(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    const context: *const volatile c_int = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    process.append_tty_newline_on_exit();
    // Report real execution time (load/relocate boundary → exit), separate from
    // the dynamic-load time emitted as `# tprof load`. Correlate by pid.
    if (perf.enabled and process._exec_loaded_time != 0) {
        const run_us = hal.time.get_time_us() - process._exec_loaded_time;
        perf.trace("run pid={d} us={d} code={d}", .{ process.pid, run_us, context.* });
        // The same syscall/IO totals tcc prints for itself under -bench, but
        // from the kernel at exit, so it works for every program -- ls, cat,
        // vi, a compiled test binary -- none of which can be asked to dump.
        // The window is this image's life (the counters were reset at exec);
        // for tcc it shows only what happened after its own dump reset them.
        const sys = perf.summary();
        // `cyc=` says whether the *_us figures mean anything: on a target
        // without a live DWT_CYCCNT (QEMU) they are all 0 while the call and
        // byte counts are still real.
        perf.trace("syscyc pid={d} cyc={s}", .{ process.pid, if (perf.has_cycle_counter()) "on" else "off" });
        perf.trace("sysprof pid={d} calls={d} us={d} handler_us={d} load_us={d} read={d}/{d} write={d}/{d} dropped={d} top={d}:{d}/{d},{d}:{d}/{d},{d}:{d}/{d}", .{
            process.pid,        sys.calls,          sys.total_us,
            sys.handler_us,     process._load_us,   sys.read_bytes,
            sys.read_us,        sys.write_bytes,    sys.write_us,
            sys.dropped,        sys.top[0].id,      sys.top[0].calls,
            sys.top[0].us,      sys.top[1].id,      sys.top[1].calls,
            sys.top[1].us,      sys.top[2].id,      sys.top[2].calls,
            sys.top[2].us,
        });
        // Where write()/close() time goes: the card, or the filesystem above it.
        const disk_stats = perf.disk_summary();
        if (disk_stats.writes != 0 or disk_stats.reads != 0) {
            perf.trace("diskprof pid={d} writes={d}/{d}blk/{d}us cardwait={d}us reads={d}/{d}blk/{d}us", .{
                process.pid,
                disk_stats.writes,     disk_stats.write_blocks, disk_stats.write_us,
                disk_stats.wait_us,
                disk_stats.reads,      disk_stats.read_blocks,  disk_stats.read_us,
            });
        }
        const open_stats = perf.open_summary();
        if (open_stats.calls != 0) {
            perf.trace("openprof pid={d} calls={d} misses={d} resolve_us={d} lookup_us={d} attach_us={d} rf_hdrs={d} rf_reads={d} rf_allocs={d} rf_hdr_us={d} kheap={d}/{d}us mount_us={d} fsget_us={d} walk_us={d} node_us={d}", .{
                process.pid,
                open_stats.calls,
                open_stats.misses,
                open_stats.us[@intFromEnum(perf.OpenPhase.resolve)],
                open_stats.us[@intFromEnum(perf.OpenPhase.lookup)],
                open_stats.us[@intFromEnum(perf.OpenPhase.attach)],
                open_stats.headers,
                open_stats.reads,
                open_stats.name_allocs,
                open_stats.header_us,
                open_stats.heap_calls,
                open_stats.heap_us,
                open_stats.mount_us,
                open_stats.fsget_us,
                open_stats.walk_us,
                open_stats.node_us,
            });
        }
        // Where mmap/munmap time actually goes. Printed next to sysprof so the
        // syscall total and its dominant contributor are read together.
        const pool_stats = perf.pool_summary();
        if (pool_stats.allocs != 0 or pool_stats.frees != 0) {
            perf.trace("poolclear pid={d} sram={d}B/{d}us psram={d}B/{d}us", .{
                process.pid,
                pool_stats.clear_bytes[0], pool_stats.clear_us[0],
                pool_stats.clear_bytes[1], pool_stats.clear_us[1],
            });
            perf.trace("poolprof pid={d} allocs={d} frees={d} pages={d} cleared={d} max={d} hits={d} misses={d} sram={d} psram={d} scan_us={d} mark_us={d} book_us={d} clear_us={d} flookup_us={d} fmark_us={d}", .{
                process.pid,             pool_stats.allocs,
                pool_stats.frees,        pool_stats.pages,
                pool_stats.cleared_bytes, pool_stats.max_bytes,
                pool_stats.cache_hits,   pool_stats.cache_misses,
                pool_stats.tier_allocs[0], pool_stats.tier_allocs[1],
                pool_stats.us[@intFromEnum(perf.PoolPhase.scan)],
                pool_stats.us[@intFromEnum(perf.PoolPhase.mark)],
                pool_stats.us[@intFromEnum(perf.PoolPhase.book)],
                pool_stats.us[@intFromEnum(perf.PoolPhase.clear)],
                pool_stats.us[@intFromEnum(perf.PoolPhase.free_lookup)],
                pool_stats.us[@intFromEnum(perf.PoolPhase.free_mark)],
            });
        }
        // Peak page usage per tier during this run: psram_pk > 0 means the
        // process spilled out of fast SRAM into slow PSRAM (a likely cause of
        // across-the-board slowness). Pages are 4 KiB.
        const pool = process_manager.instance.get_process_memory_pool();
        perf.trace("mem pid={d} sram_pk={d} sram_cap={d} psram_pk={d} psram_cap={d} kheap_now={d} kheap_pk={d} kheap_phys={d}", .{
            process.pid,
            pool.peak_used_pages(0), pool.region_page_count(0),
            pool.peak_used_pages(1), pool.region_page_count(1),
            kernel.memory.heap.malloc.get_usage(),
            kernel.memory.heap.malloc.get_peak_usage(),
            system_stubs.kernel_heap_physical_used(),
        });
        // Per-process footprint at this exit: attributes pool pages to each live
        // pid (the exiting process + any vfork-suspended parent shell still
        // resident) so toybox/tcc memory reductions are measurable per process.
        pool.dump_usage_by_pid();
    }
    // Encode in Linux wait-status format: normal exit = (code << 8)
    // so that WEXITSTATUS/WIFEXITED macros work correctly.
    const wait_status = @as(i32, context.*) << 8;
    if (process._parent) |parent| {
        parent.child_exit_code = wait_status;
    }
    process_manager.instance.delete_process(process.pid, wait_status);

    return context.*;
}

pub fn sys_read(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    const context: *const volatile c.read_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    if (context.buf == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }
    const maybe_handle = process.get_file_handle(@intCast(context.fd));
    kernel.process.unblock_context_switch();
    if (maybe_handle) |handle| {
        var maybe_file = handle.node.as_file();
        if (maybe_file) |*file| {
            context.result.* = file.interface.read(@as([*]u8, @ptrCast(context.buf.?))[0..context.count]);
            // Safe, serialized point to flush the buffered kernel log to SD
            // (no-op unless CONFIG_INSTRUMENTATION_LOG_TO_SD and data pending).
            kernel.file_log.drain();
            return 0;
        }
    }
    return 0;
}
pub fn sys_kill(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    kernel.process.block_context_switch();
    const process = process_manager.instance.get_current_process();
    process_manager.instance.delete_process(process.pid, -1);
    return 0;
}

pub fn sys_write(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    const context: *const volatile c.write_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();

    if (context.buf == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }

    const maybe_handle = process.get_file_handle(@intCast(context.fd));
    kernel.process.unblock_context_switch();
    if (maybe_handle) |handle| {
        var maybe_file = handle.node.as_file();
        if (maybe_file) |*file| {
            const data = @as([*]const u8, @ptrCast(context.buf.?))[0..context.count];
            const is_tty = file.interface.filetype() == FileType.CharDevice;
            context.result.* = file.interface.write(data);
            if (is_tty and context.result.* > 0) {
                process.record_tty_output(context.fd, data[0..@intCast(context.result.*)]);
            }
        }
        // Safe, serialized point to flush the buffered kernel log to SD.
        kernel.file_log.drain();
        return 0;
    }
    return -1;
}

pub fn sys_vfork(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.vfork_context = @ptrCast(@alignCast(arg));
    return try process_manager.instance.vfork(context);
}

pub fn sys_unlink(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.unlink_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.dirfd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.unlink(path);
    return 0;
}
pub fn sys_link(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.link_context = @ptrCast(@alignCast(arg));
    const old_path = try determine_path_for_file(kernel_allocator, context.oldpath, context.olddirfd);
    defer kernel_allocator.free(old_path);
    const new_path = try determine_path_for_file(kernel_allocator, context.newpath, context.newdirfd);
    defer kernel_allocator.free(new_path);
    try fs.get_ivfs().interface.link(old_path, new_path);
    return 0;
}

pub fn sys_stat(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.stat_context = @ptrCast(@alignCast(arg));
    if (context.statbuf == null) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.fd);
    defer kernel_allocator.free(path);
    fs.get_ivfs().interface.stat(path, context.statbuf, context.follow_links != 0) catch |err| {
        return err;
    };
    return 0;
}

pub fn sys_getentropy(arg: *const volatile anyopaque) !i32 {
    _ = arg;
    return -1;
}

pub fn sys_lseek(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.lseek_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    context.result.* = @intCast(try file.interface.seek(@intCast(context.offset), context.whence));
    return 0;
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
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.getdents_context = @ptrCast(@alignCast(arg));

    context.result.* = -1;
    if (context.dirp == null) {} else {
        const process = process_manager.instance.get_current_process();
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
        return -1;
    }
    return -1;
}

pub fn sys_ioctl(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.ioctl_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    // arg is a signed ssize_t carrying "int or void*"; a user pointer at/above
    // 0x80000000 is negative as ssize_t, so reinterpret the bits (@bitCast)
    // rather than @intCast (which would trip "integer does not fit").
    return file.interface.ioctl(context.op, @ptrFromInt(@as(usize, @bitCast(context.arg))));
}

pub fn sys_gettimeofday(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.gettimeofday_context = @ptrCast(@alignCast(arg));
    const now_us = hal.time.get_time_us();

    if (context.tv) |tv| {
        tv.*.tv_sec = @intCast(@divTrunc(now_us, 1_000_000));
        tv.*.tv_usec = @intCast(@mod(now_us, 1_000_000));
    }

    if (context.tz) |tz| {
        tz.*.tz_minuteswest = 0;
        tz.*.tz_dsttime = 0;
    }

    return 0;
}

pub fn sys_waitpid(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.waitpid_context = @ptrCast(@alignCast(arg));
    return process_manager.instance.waitpid(context.pid, context.status);
}

pub fn sys_execve(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.execve_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.filename, -1);
    // Path is freed inside prepare_exec after load_executable, because
    // prepare_exec may not return normally (vfork context switch bypasses defers).
    return process_manager.instance.prepare_exec(path, context.argv.?, context.envp.?, kernel_allocator);
}

pub fn sys_nanosleep(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.nanosleep_context = @ptrCast(@alignCast(arg));
    if (context.req) |req| {
        const seconds = req.*.tv_sec;
        const nanoseconds = req.*.tv_nsec;
        if (seconds != 0) {
            time.sleep_ms(@intCast(seconds * 1000));
        }
        if (nanoseconds != 0) {
            time.sleep_us(@intCast(@divTrunc(nanoseconds, 1000)));
        }
    }
    return 0;
}
pub fn sys_mmap(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.mmap_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    context.result.* = process.mmap(context.addr, context.length, context.prot, context.flags, context.fd, context.offset) catch {
        context.result.* = c.MAP_FAILED;
        return -1;
    };
    return 0;
}

pub fn sys_munmap(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.munmap_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    process.munmap(context.addr, context.length);
    return 0;
}

pub fn sys_mremap(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.mremap_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    context.result.* = process.mremap(context.addr.?, context.old_length, context.new_length, context.flags) catch {
        context.result.* = c.MAP_FAILED;
        return -1;
    };
    return 0;
}

pub fn sys_getcwd(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.getcwd_context = @ptrCast(@alignCast(arg));
    const current_process = process_manager.instance.get_current_process();
    const cwd = current_process.get_current_directory();
    const cwd_len = @min(cwd.len, context.size);
    std.mem.copyForwards(u8, context.buf[0..cwd_len], cwd[0..cwd_len]);
    var last_index = cwd_len;
    if (last_index > context.size) {
        last_index = context.size - 1;
    }
    context.buf[last_index] = 0;
    context.result.* = context.buf;
    return 0;
}

pub fn sys_chdir(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.chdir_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    var slice_allocated = false;
    var path_slice: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(context.path.?)));
    if (path_slice[0] != '/') {
        if (process.cwd[process.cwd.len - 1] == '/') {
            path_slice = try vfmt.allocPrint(kernel_allocator, "{s}{s}", .{ process.cwd, path_slice });
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

pub fn sys_time(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.time_context = @ptrCast(@alignCast(arg));
    const now_seconds: c.time_t = @intCast(hal.time.get_time());
    if (context.timep) |timep| {
        timep.* = now_seconds;
    }
    context.result.* = now_seconds;
    return 0;
}
pub fn sys_fcntl(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.fcntl_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    // See sys_ioctl: arg is a signed ssize_t that may hold a high user pointer.
    return file.interface.fcntl(context.op, @ptrFromInt(@as(usize, @bitCast(context.arg))));
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
    const process = process_manager.instance.get_current_process();
    const library = dynamic_loader.load_shared_library(std.mem.span(@as([*:0]const u8, @ptrCast(context.path))), process.get_process_memory_allocator(), process.pid) catch {
        // log.print("dlopen: failed to load library: {s}\n", .{@errorName(err)});
        return -1;
    };
    context.*.result.* = library;
    return 0;
}

pub fn sys_dlclose(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.dlclose_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    const library: *yasld.Module = @ptrCast(@alignCast(context.handle));
    dynamic_loader.release_shared_library(process.pid, library);
    return 0;
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
    // Frees (close_fd -> release_file -> FileHandle.close) and allocates
    // (attach_file_with_fd) on the kernel heap, which newlib's allocator does
    // not guard — the same contract sys_open and sys_close already follow.
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.dup_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    const maybe_handle = process.get_file_handle(@intCast(context.fd));
    if (maybe_handle) |handle| {
        // dup2(fd, fd) on an open fd is a no-op that returns fd (POSIX).
        // Falling through instead closed newfd first, which here IS the handle
        // we are about to copy from: release_file frees its path and drops the
        // node's last reference, so the share() below incremented an already
        // freed refcount cell. That cell is by then a chunk on newlib's free
        // list, and the increment lands on its `next` pointer -- the kernel
        // free list ends up with a next of <chunk>+1 and the next unrelated
        // free() faults walking it. toybox does exactly this dup2(0, 0) on
        // every shell redirection, so `echo x > file` corrupted the kernel heap
        // every single time.
        if (context.newfd == context.fd) {
            return context.fd;
        }
        // Take our own reference before releasing anything, so the acquire can
        // never be ordered after a release of the same object.
        var shared = handle.node.share();
        errdefer shared.delete();
        var fd: i32 = 0;
        if (context.newfd >= 0) {
            fd = context.newfd;
            _ = close_fd(fd);
        } else {
            fd = process.get_free_fd() orelse return kernel.errno.ErrnoSet.TooManyOpenFiles;
        }
        return try process.attach_file_with_fd(@intCast(fd), handle.path, shared);
    }
    return -1;
}

pub fn sys_sysinfo(arg: *const volatile anyopaque) !i32 {
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

pub fn sys_sysconf(arg: *const volatile anyopaque) !i32 {
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

pub fn sys_prlimit(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();

    const context: *const volatile c.prlimit_context = @ptrCast(@alignCast(arg));
    if (context.pid < 0) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }

    const process = if (context.pid == 0)
        process_manager.instance.get_current_process()
    else
        process_manager.instance.get_process_for_pid(context.pid) orelse return kernel.errno.ErrnoSet.NoSuchProcess;

    if (context.old_limit) |old_limit| {
        old_limit.* = try process.get_resource_limit(context.resource);
    }

    if (context.new_limit) |new_limit| {
        try process.set_resource_limit(context.resource, new_limit.*);
    }

    return 0;
}

pub fn sys_access(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.access_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.dirfd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.access(path, context.mode, context.flags);
    return 0;
}

pub fn sys_klog_ctl(arg: *const volatile anyopaque) !i32 {
    const context: *const volatile c.klog_ctl_context = @ptrCast(@alignCast(arg));
    kernel.stdout.suppress(context.enable == 0);
    return 0;
}

pub fn sys_ftruncate(arg: *const volatile anyopaque) !i32 {
    kernel.process.block_context_switch();
    defer kernel.process.unblock_context_switch();
    const context: *const volatile c.ftruncate_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    try file.interface.truncate(@intCast(context.length));
    return 0;
}

const perf = @import("perf_profile.zig");
const system_stubs = @import("system_stubs.zig");

pub fn sys_perf_dump(arg: *const volatile anyopaque) !i32 {
    // The caller owns the struct and expects the summary fields written back
    // into it, so the const on `arg` (shared by every syscall handler) is not
    // the contract here.
    const context: *volatile c.perf_dump_context = @ptrCast(@alignCast(@constCast(arg)));
    if (!perf.enabled) {
        context.num_entries.* = 0;
        return 0;
    }
    // A process cannot time its own dynamic load -- it does not run until the
    // load is over -- so the kernel hands it back here, which is what lets the
    // smoke harness separate loader time from compile time without an extra
    // serial round trip.
    const process = process_manager.instance.get_current_process();
    perf.dump(context, process._load_us);
    if (context.reset != 0) {
        perf.reset();
    }
    return 0;
}

fn test_process_entry() void {}

test "DeterminePathForFile.ShouldResolveRelativePathAgainstCurrentWorkingDirectory" {
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();

    init(std.testing.allocator);
    try process_manager.instance.create_root_process(4096, &test_process_entry, null, "/mnt/bin");

    const path = try std.testing.allocator.dupeSentinel(u8, "./a.out", 0);
    defer std.testing.allocator.free(path);

    const resolved_path = try determine_path_for_file(std.testing.allocator, path.ptr, -1);
    defer std.testing.allocator.free(resolved_path);

    try std.testing.expectEqualStrings("/mnt/bin/a.out", resolved_path);
}

test "DeterminePathForFile.ShouldKeepAbsolutePathUnchanged" {
    process_manager.initialize_process_manager(std.testing.allocator);
    defer process_manager.deinitialize_process_manager();

    init(std.testing.allocator);
    try process_manager.instance.create_root_process(4096, &test_process_entry, null, "/mnt/bin");

    const path = try std.testing.allocator.dupeSentinel(u8, "/usr/bin/a.out", 0);
    defer std.testing.allocator.free(path);

    const resolved_path = try determine_path_for_file(std.testing.allocator, path.ptr, -1);
    defer std.testing.allocator.free(resolved_path);

    try std.testing.expectEqualStrings("/usr/bin/a.out", resolved_path);
}
