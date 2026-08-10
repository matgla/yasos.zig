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

const uaccess = kernel.uaccess;
const ErrnoSet = kernel.errno.ErrnoSet;

/// Landing size for a path copied out of user memory.
///
/// Twice the system PATH_MAX (main.zig: 128), matching the symlink working
/// buffer in fs/vfs.zig. This bound only decides when a caller gets
/// ENAMETOOLONG; the safety property comes from `strncpy_from_user`, which
/// additionally clamps its scan to the end of the memory region the pointer
/// lands in, so it cannot walk out of the caller's own memory.
const max_user_path = 256;

pub fn init(allocator: std.mem.Allocator) void {
    kernel_allocator = allocator;
}

/// True when the pointers in the current syscall came from an untrusted caller.
///
/// Mirrors `system_call.caller_is_untrusted`: the root/init process runs
/// privileged and can already reach any address directly, and the kernel issues
/// syscalls of its own during boot with arguments on the MSP stack.
fn untrusted_caller() bool {
    if (comptime !uaccess.enabled) return false;
    if (!process_manager.is_initialized()) return false;
    return !process_manager.instance.get_current_process().is_privileged();
}

/// Validate a user buffer the kernel is about to write into.
fn user_out_slice(ptr: ?*anyopaque, len: usize) ![]u8 {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    if (untrusted_caller()) try uaccess.check(@intFromPtr(p), len, .write);
    return @as([*]u8, @ptrCast(p))[0..len];
}

/// Validate a user buffer the kernel is about to read from.
fn user_in_slice(ptr: ?*const anyopaque, len: usize) ![]const u8 {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    if (untrusted_caller()) try uaccess.check(@intFromPtr(p), len, .read);
    return @as([*]const u8, @ptrCast(p))[0..len];
}

/// Validate a user pointer the kernel is about to write a `T` through.
fn user_out(comptime T: type, ptr: ?*T) !*T {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    if (untrusted_caller()) try uaccess.check(@intFromPtr(p), @sizeOf(T), .write);
    return p;
}

/// Validate a user pointer the kernel is about to read a `T` from.
fn user_in(comptime T: type, ptr: ?*const T) !*const T {
    const p = ptr orelse return ErrnoSet.InvalidArgument;
    if (untrusted_caller()) try uaccess.check(@intFromPtr(p), @sizeOf(T), .read);
    return p;
}

/// Copy a NUL-terminated user string into `dst`, bounded.
fn user_string(dst: []u8, ptr: [*c]const u8) ![]u8 {
    if (ptr == null) return ErrnoSet.InvalidArgument;
    if (comptime !uaccess.enabled) {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        if (span.len >= dst.len) return ErrnoSet.NameTooLong;
        @memcpy(dst[0..span.len], span);
        return dst[0..span.len];
    }
    if (!untrusted_caller()) {
        const span = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        if (span.len >= dst.len) return ErrnoSet.NameTooLong;
        @memcpy(dst[0..span.len], span);
        return dst[0..span.len];
    }
    return uaccess.strncpy_from_user(dst, ptr, dst.len);
}

/// Syscalls that hand the kernel a raw kernel-object pointer or a function
/// pointer to call, and therefore cannot be made safe by validating a range.
///
/// `sys_create_process` takes a `CreateProcessCall` carrying an `entry` function
/// pointer *and* a Zig `Allocator` (an interface with a vtable pointer); the
/// handler calls both. `sys_semaphore_acquire`/`_release` take a raw
/// `*Semaphore` and increment through it. From an unprivileged process each is a
/// direct privileged-arbitrary-code / arbitrary-write primitive.
///
/// None of the three has a caller outside the kernel's own dead
/// `mutex.zig`/`semaphore.zig` (both unused; see docs/smp_plan.md), so refusing
/// them for unprivileged callers costs nothing and removes the surface.
fn reject_if_unprivileged() !void {
    if (untrusted_caller()) return ErrnoSet.NotPermitted;
}

/// Caps on what execve will accept, so a malformed vector cannot be walked
/// forever. Both are far above anything real: the longest command line in the
/// tree is a tcc invocation of a couple of dozen arguments.
const max_argv_entries = 256;
const max_arg_length = 4096;

/// Validate a NULL-terminated array of C strings handed in by userspace.
///
/// `ProcessManager.clone_exec_args` counts these arrays with
/// `while (argv[argc] != null)` and then `std.mem.span`s every entry. Given an
/// array that is not NULL-terminated inside memory the caller owns -- or one
/// whose entries are not -- that walk runs off the end while privileged. This
/// proves, before the walk starts, that the terminator and every string are
/// present and readable.
fn check_user_string_vector(vector: [*c][*c]u8) !void {
    if (!untrusted_caller()) return;
    if (vector == null) return;
    var i: usize = 0;
    while (i < max_argv_entries) : (i += 1) {
        try uaccess.check(@intFromPtr(vector + i), @sizeOf([*c]u8), .read);
        const entry = vector[i];
        if (entry == null) return;
        _ = try uaccess.strnlen_user(entry, max_arg_length);
    }
    return ErrnoSet.ArgumentListTooLong;
}

// most stupid way to keep track of the last file
/// Write one directory entry into the caller's buffer, capped at `capacity`.
///
/// The record is variable-length (the name is inline), so without the cap a
/// long enough name runs off the end of a buffer the caller sized itself.
fn fill_dirent(entry: kernel.fs.DirectoryEntry, dirent_address: *anyopaque, capacity: usize) isize {
    const required_space = std.mem.alignForward(usize, @sizeOf(c.dirent) - 1 + entry.name.len, @alignOf(c.dirent));
    if (required_space > capacity) return -1;
    // skip files that were already traversed
    const dirp: *c.dirent = @as(*c.dirent, @ptrCast(@alignCast(dirent_address)));
    dirp.d_ino = 0xdead;
    dirp.d_off = 0xbeef;
    dirp.d_reclen = @intCast(required_space);
    std.mem.copyForwards(u8, dirp.d_name[0..entry.name.len], entry.name);
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

pub fn sys_start_root_process(arg: *const anyopaque) !i32 {
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

pub fn sys_stop_root_process(arg: *const anyopaque) !i32 {
    _ = arg;
    hal.time.systick.disable();
    std.log.info("Stopping root process with stack pointer: {x}", .{main_process_stack_pointer_before_scheduler_started});
    switch_to_main_task(main_process_stack_pointer_before_scheduler_started, config.cpu.use_fpu);
    return 0;
}

pub fn sys_create_process(arg: *const anyopaque) !i32 {
    // `entry` is called and `allocator` is an interface with a vtable pointer:
    // both are taken from the caller verbatim, so this is arbitrary privileged
    // code execution if an unprivileged process is allowed in.
    try reject_if_unprivileged();
    const context: *const CreateProcessCall = @ptrCast(@alignCast(arg));
    process_manager.instance.create_process(context.stack_size, context.entry, context.arg, "/") catch |err| {
        return err;
    };
    return 0;
}

pub fn sys_semaphore_acquire(arg: *const anyopaque) !i32 {
    // `object` is a raw pointer to a kernel Semaphore, incremented through and
    // used to walk the process list. An arbitrary-write primitive if unprivileged
    // callers are allowed in.
    try reject_if_unprivileged();
    const context: *const SemaphoreEvent = @ptrCast(@alignCast(arg));
    return KernelSemaphore.acquire(context.object);
}

pub fn sys_semaphore_release(arg: *const anyopaque) !i32 {
    try reject_if_unprivileged();
    const context: *const SemaphoreEvent = @ptrCast(@alignCast(arg));
    return KernelSemaphore.release(context.object);
}

    // Preemptible: see `sys_open`. Everything the window covered is under a
    // named lock now, or needs none.
pub fn sys_getpid(arg: *const anyopaque) !i32 {
    const check_parent: *const u8 = @ptrCast(@alignCast(arg));
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

pub fn sys_mkdir(arg: *const anyopaque) !i32 {
    const context: *const c.mkdir_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.path, context.fd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.mkdir(path, @intCast(context.mode));
    return 0;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_fstat(arg: *const anyopaque) !i32 {
    const context: *const c.fstat_context = @ptrCast(@alignCast(arg));
    _ = try user_out(c.struct_stat, context.buf);
    const path = try determine_path_for_file(kernel_allocator, null, context.fd);
    defer kernel_allocator.free(path);
    fs.get_ivfs().interface.stat(path, context.buf, true) catch |err| {
        return err;
    };
    return 0;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_isatty(arg: *const anyopaque) !i32 {
    const fd: *const c_int = @ptrCast(@alignCast(arg));
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
        // Every path-taking syscall funnels through here, so this is the one
        // place the unbounded `std.mem.span` on a user pointer had to go: it
        // scanned for a NUL with no limit and no notion of whether it was still
        // inside memory the caller owns.
        var path_storage: [max_user_path]u8 = undefined;
        const path = try user_string(&path_storage, cpath);
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

// Deliberately preemptible -- the first of the phase 3(B) conversions, and the
// pattern for the rest.
//
// The `block_context_switch()` window this had was doing three jobs, and every
// one of them now has a named lock underneath it:
//
//   * the kernel-heap allocations in `determine_path_for_file` -> `kheap`;
//   * the VFS walk and the filesystem work -> `mount`, `fs`, `dev`;
//   * `get_current_process()` -> per-CPU, and the caller *is* the current
//     process, so it cannot change under its own syscall.
//
// The fourth candidate, the fd table, needs no lock yet: `_fds` is per-process
// and there is one thread per process, so two cores means two separate tables.
// It becomes shared the moment phase 9 adds threads, and that is where its lock
// belongs.
//
// Removing the window is not merely tidying. Holding it across filesystem I/O
// is what made `fs_lock` deadlockable on a single core: `sys_read` releases its
// window *before* touching the file, so it can park holding `fs_lock` while
// preemptible, and a `sys_open` contending for the same lock with preemption
// disabled could never be rescheduled to get it. See `RankedMutex.lock`.
pub fn sys_open(arg: *const anyopaque) !i32 {
    const context: *const c.open_context = @ptrCast(@alignCast(arg));
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

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_close(arg: *const anyopaque) !i32 {
    const fd: *const c_int = @ptrCast(@alignCast(arg));
    return close_fd(fd.*);
}

pub fn sys_exit(arg: *const anyopaque) !i32 {
    // Category (C): this window is not protecting data, it is holding PendSV
    // off until `delete_process` has moved this process off the run queue and
    // handed the core away. It is closed there, or by the assembly on the vfork
    // path -- which is why it is a bare disable with no `defer`.
    preempt.preempt_disable();
    const context: *const c_int = @ptrCast(@alignCast(arg));
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

// Preemptible throughout, and this one is worth a note beyond "see sys_open".
//
// The window used to cover the validation and the fd lookup and then be
// released explicitly *before* the read, which left the transfer preemptible
// while everything else in the file path held its window across the I/O. That
// asymmetry is what made `fs_lock` deadlockable on a single core: this syscall
// could park holding it while preemptible, and a `sys_open` contending for it
// with preemption disabled could never be rescheduled to get it (see
// `RankedMutex.lock`). With both sides preemptible the asymmetry is gone, and
// the three hand-written `unblock` calls on the error paths go with it.
pub fn sys_read(arg: *const anyopaque) !i32 {
    const context: *const c.read_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    // The kernel is about to write `count` bytes of file data through `buf`
    // while running privileged. Unchecked, read(fd, &kernel_ram, n) overwrites
    // the kernel with attacker-chosen file contents.
    const destination = try user_out_slice(context.buf, context.count);
    const result_out = try user_out(isize, context.result);
    const maybe_handle = process.get_file_handle(@intCast(context.fd));
    if (maybe_handle) |handle| {
        var maybe_file = handle.node.as_file();
        if (maybe_file) |*file| {
            result_out.* = file.interface.read(destination);
            // Safe, serialized point to flush the buffered kernel log to SD
            // (no-op unless CONFIG_INSTRUMENTATION_LOG_TO_SD and data pending).
            kernel.file_log.drain();
            return 0;
        }
    }
    return 0;
}
pub fn sys_kill(arg: *const anyopaque) !i32 {
    _ = arg;
    // Same hand-off as `sys_exit`; closed by `delete_process`.
    preempt.preempt_disable();
    const process = process_manager.instance.get_current_process();
    process_manager.instance.delete_process(process.pid, -1);
    return 0;
}

// Preemptible throughout; see `sys_read` for why the old release-before-the-I/O
// shape was actively harmful rather than merely inconsistent.
pub fn sys_write(arg: *const anyopaque) !i32 {
    const context: *const c.write_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();

    // Unchecked, write(fd, &kernel_ram, n) copies kernel memory out to a file.
    const data = try user_in_slice(context.buf, context.count);
    const result_out = try user_out(isize, context.result);

    const maybe_handle = process.get_file_handle(@intCast(context.fd));
    if (maybe_handle) |handle| {
        var maybe_file = handle.node.as_file();
        if (maybe_file) |*file| {
            const is_tty = file.interface.filetype() == FileType.CharDevice;
            result_out.* = file.interface.write(data);
            if (is_tty and result_out.* > 0) {
                process.record_tty_output(context.fd, data[0..@intCast(result_out.*)]);
            }
        }
        // Safe, serialized point to flush the buffered kernel log to SD.
        kernel.file_log.drain();
        return 0;
    }
    return -1;
}

pub fn sys_vfork(arg: *const anyopaque) !i32 {
    const context: *const c.vfork_context = @ptrCast(@alignCast(arg));
    // The child's pid is written back through this pointer from inside vfork.
    _ = try user_out(c.pid_t, context.pid);
    return try process_manager.instance.vfork(context);
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_unlink(arg: *const anyopaque) !i32 {
    const context: *const c.unlink_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.dirfd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.unlink(path);
    return 0;
}
pub fn sys_link(arg: *const anyopaque) !i32 {
    const context: *const c.link_context = @ptrCast(@alignCast(arg));
    const old_path = try determine_path_for_file(kernel_allocator, context.oldpath, context.olddirfd);
    defer kernel_allocator.free(old_path);
    const new_path = try determine_path_for_file(kernel_allocator, context.newpath, context.newdirfd);
    defer kernel_allocator.free(new_path);
    try fs.get_ivfs().interface.link(old_path, new_path);
    return 0;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_stat(arg: *const anyopaque) !i32 {
    const context: *const c.stat_context = @ptrCast(@alignCast(arg));
    _ = try user_out(c.struct_stat, context.statbuf);
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.fd);
    defer kernel_allocator.free(path);
    fs.get_ivfs().interface.stat(path, context.statbuf, context.follow_links != 0) catch |err| {
        return err;
    };
    return 0;
}

pub fn sys_getentropy(arg: *const anyopaque) !i32 {
    _ = arg;
    return -1;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_lseek(arg: *const anyopaque) !i32 {
    const context: *const c.lseek_context = @ptrCast(@alignCast(arg));
    const result_out = try user_out(c.off_t, context.result);
    var file = try get_file_from_process(@intCast(context.fd));
    result_out.* = @intCast(try file.interface.seek(@intCast(context.offset), context.whence));
    return 0;
}

pub fn sys_wait(arg: *const anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_times(arg: *const anyopaque) !i32 {
    _ = arg;
    return -1;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_getdents(arg: *const anyopaque) !i32 {
    const context: *const c.getdents_context = @ptrCast(@alignCast(arg));

    const result_out = try user_out(isize, context.result);
    result_out.* = -1;
    if (context.dirp == null) return -1;
    // `fill_dirent` writes a variable-length record whose size depends on the
    // entry name, so the caller's buffer has to be good for all `count` bytes
    // and the write has to be capped to them.
    _ = try user_out_slice(@ptrCast(context.dirp), context.count);

    const process = process_manager.instance.get_current_process();
    const maybe_handle = process.get_file_handle(@intCast(context.fd));
    if (maybe_handle) |handle| {
        // if iterator not exists create one
        const diriter: ?*kernel.fs.IDirectoryIterator = handle.get_iterator() catch null;
        // still can be null if path not exists or is not a directory
        if (diriter) |it| {
            const maybe_entry = it.interface.next();
            if (maybe_entry) |entry| {
                result_out.* = fill_dirent(entry, context.dirp, context.count);
            } else {
                handle.remove_iterator();
            }
        }
        return 0;
    }
    return -1;
}

/// Validate the pointer an ioctl op carries in its integer-or-pointer `arg`.
///
/// The set of ops whose `arg` is a pointer is small and closed (this is not a
/// general driver ioctl interface), so it can be enumerated. Anything not listed
/// takes an integer and has no pointer to check. Adding a pointer-taking op
/// without adding it here leaves that op unvalidated -- which is why the list
/// sits next to the dispatch rather than in a driver.
fn check_ioctl_arg(op: i32, raw: isize) !void {
    if (!untrusted_caller()) return;
    const ptr: usize = @bitCast(raw);
    const access: uaccess.Access, const size: usize = switch (op) {
        c.TCGETS => .{ .write, @sizeOf(c.termios) },
        c.TCSETS, c.TCSETSW, c.TCSETSF => .{ .read, @sizeOf(c.termios) },
        c.TIOCGWINSZ => .{ .write, @sizeOf(c.struct_winsize) },
        c.FIONREAD => .{ .write, @sizeOf(c_int) },
        @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus) => .{ .write, @sizeOf(kernel.fs.FileMemoryMapAttributes) },
        else => return,
    };
    switch (access) {
        .read => try uaccess.check(ptr, size, .read),
        .write => try uaccess.check(ptr, size, .write),
    }
}

pub fn sys_ioctl(arg: *const anyopaque) !i32 {
    const context: *const c.ioctl_context = @ptrCast(@alignCast(arg));
    try check_ioctl_arg(context.op, context.arg);
    var file = try get_file_from_process(@intCast(context.fd));
    // arg is a signed ssize_t carrying "int or void*"; a user pointer at/above
    // 0x80000000 is negative as ssize_t, so reinterpret the bits (@bitCast)
    // rather than @intCast (which would trip "integer does not fit").
    return file.interface.ioctl(context.op, @ptrFromInt(@as(usize, @bitCast(context.arg))));
}

pub fn sys_gettimeofday(arg: *const anyopaque) !i32 {
    const context: *const c.gettimeofday_context = @ptrCast(@alignCast(arg));
    const now_us = hal.time.get_time_us();

    if (context.tv) |tv| {
        const out = try user_out(c.struct_timeval, tv);
        out.tv_sec = @intCast(@divTrunc(now_us, 1_000_000));
        out.tv_usec = @intCast(@mod(now_us, 1_000_000));
    }

    if (context.tz) |tz| {
        const out = try user_out(c.struct_timezone, tz);
        out.tz_minuteswest = 0;
        out.tz_dsttime = 0;
    }

    return 0;
}

pub fn sys_waitpid(arg: *const anyopaque) !i32 {
    const context: *const c.waitpid_context = @ptrCast(@alignCast(arg));
    if (context.status) |status| _ = try user_out(c_int, status);
    return process_manager.instance.waitpid(context.pid, context.status);
}

pub fn sys_execve(arg: *const anyopaque) !i32 {
    const context: *const c.execve_context = @ptrCast(@alignCast(arg));
    if (context.argv == null) return ErrnoSet.InvalidArgument;
    // prepare_exec -> clone_exec_args walks both vectors and spans every entry,
    // so they have to be proven well-formed before it starts.
    try check_user_string_vector(context.argv);
    try check_user_string_vector(context.envp);
    const path = try determine_path_for_file(kernel_allocator, context.filename, -1);
    // Path is freed inside prepare_exec after load_executable, because
    // prepare_exec may not return normally (vfork context switch bypasses defers).
    return process_manager.instance.prepare_exec(path, context.argv.?, context.envp.?, kernel_allocator);
}

pub fn sys_nanosleep(arg: *const anyopaque) !i32 {
    const context: *const c.nanosleep_context = @ptrCast(@alignCast(arg));
    if (context.req) |req| {
        const in = try user_in(c.struct_timespec, req);
        const seconds = in.tv_sec;
        const nanoseconds = in.tv_nsec;
        if (seconds != 0) {
            time.sleep_ms(@intCast(seconds * 1000));
        }
        if (nanoseconds != 0) {
            time.sleep_us(@intCast(@divTrunc(nanoseconds, 1000)));
        }
    }
    return 0;
}
    // Preemptible: the page pool is behind `pagepool_lock`, and the heap/loader
    // accounting tag that used to require serialisation is an argument now
    // rather than a one-shot flag on the pool (`allocate_pages_from`).
pub fn sys_mmap(arg: *const anyopaque) !i32 {
    const context: *const c.mmap_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    const result_out = try user_out(?*anyopaque, context.result);
    result_out.* = process.mmap(context.addr, context.length, context.prot, context.flags, context.fd, context.offset) catch {
        result_out.* = c.MAP_FAILED;
        return -1;
    };
    return 0;
}

    // Preemptible: the page pool is behind `pagepool_lock`, and the heap/loader
    // accounting tag that used to require serialisation is an argument now
    // rather than a one-shot flag on the pool (`allocate_pages_from`).
pub fn sys_munmap(arg: *const anyopaque) !i32 {
    const context: *const c.munmap_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    process.munmap(context.addr, context.length);
    return 0;
}

    // Preemptible: the page pool is behind `pagepool_lock`, and the heap/loader
    // accounting tag that used to require serialisation is an argument now
    // rather than a one-shot flag on the pool (`allocate_pages_from`).
pub fn sys_mremap(arg: *const anyopaque) !i32 {
    const context: *const c.mremap_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    const result_out = try user_out(?*anyopaque, context.result);
    result_out.* = process.mremap(context.addr.?, context.old_length, context.new_length, context.flags) catch {
        result_out.* = c.MAP_FAILED;
        return -1;
    };
    return 0;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_getcwd(arg: *const anyopaque) !i32 {
    const context: *const c.getcwd_context = @ptrCast(@alignCast(arg));
    if (context.size == 0) return ErrnoSet.InvalidArgument;
    const buffer = try user_out_slice(@ptrCast(context.buf), context.size);
    const result_out = try user_out([*c]u8, context.result);

    const current_process = process_manager.instance.get_current_process();
    const cwd = current_process.get_current_directory();
    // Leave room for the terminator: `cwd_len` was previously allowed to reach
    // `size`, and the NUL then went to buf[size] -- one past the end of the
    // caller's buffer.
    const cwd_len = @min(cwd.len, context.size - 1);
    std.mem.copyForwards(u8, buffer[0..cwd_len], cwd[0..cwd_len]);
    buffer[cwd_len] = 0;
    result_out.* = context.buf;
    return 0;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_chdir(arg: *const anyopaque) !i32 {
    const context: *const c.chdir_context = @ptrCast(@alignCast(arg));
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

pub fn sys_time(arg: *const anyopaque) !i32 {
    const context: *const c.time_context = @ptrCast(@alignCast(arg));
    const now_seconds: c.time_t = @intCast(hal.time.get_time());
    if (context.timep) |timep| {
        (try user_out(c.time_t, timep)).* = now_seconds;
    }
    (try user_out(c.time_t, context.result)).* = now_seconds;
    return 0;
}
    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_fcntl(arg: *const anyopaque) !i32 {
    const context: *const c.fcntl_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    // See sys_ioctl: arg is a signed ssize_t that may hold a high user pointer.
    return file.interface.fcntl(context.op, @ptrFromInt(@as(usize, @bitCast(context.arg))));
}
pub fn sys_remove(arg: *const anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_realpath(arg: *const anyopaque) !i32 {
    _ = arg;
    return -1;
}
pub fn sys_mprotect(arg: *const anyopaque) !i32 {
    _ = arg;
    return -1;
}

pub fn sys_dlopen(arg: *const anyopaque) !i32 {
    const context: *const c.dlopen_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    var path_storage: [max_user_path]u8 = undefined;
    const path = try user_string(&path_storage, context.path);
    const result_out = try user_out(?*anyopaque, context.result);
    const library = dynamic_loader.load_shared_library(path, process.get_process_memory_allocator(), process.pid) catch {
        // log.print("dlopen: failed to load library: {s}\n", .{@errorName(err)});
        return -1;
    };
    result_out.* = library;
    return 0;
}

pub fn sys_dlclose(arg: *const anyopaque) !i32 {
    const context: *const c.dlclose_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    const library: *yasld.Module = @ptrCast(@alignCast(context.handle orelse return ErrnoSet.InvalidArgument));
    // The handle comes straight from userspace; releasing an unowned one
    // unlinks a list node at an attacker-chosen address.
    if (untrusted_caller() and !dynamic_loader.owns_shared_library(process.pid, library)) {
        return ErrnoSet.InvalidArgument;
    }
    dynamic_loader.release_shared_library(process.pid, library);
    return 0;
}

pub fn sys_dlsym(arg: *const anyopaque) !i32 {
    const context: *const c.dlsym_context = @ptrCast(@alignCast(arg));
    const process = process_manager.instance.get_current_process();
    const library: *yasld.Module = @ptrCast(@alignCast(context.handle orelse return ErrnoSet.InvalidArgument));
    if (untrusted_caller() and !dynamic_loader.owns_shared_library(process.pid, library)) {
        return ErrnoSet.InvalidArgument;
    }
    var symbol_storage: [max_user_path]u8 = undefined;
    const symbol_name = try user_string(&symbol_storage, context.symbol);
    const result_out = try user_out(?*anyopaque, context.result);
    const maybe_symbol = library.find_symbol(symbol_name);
    if (maybe_symbol) |symbol| {
        result_out.* = @ptrFromInt(symbol.address);
        return 0;
    }
    return -1;
}

pub fn sys_getuid(arg: *const anyopaque) !i32 {
    _ = arg;
    // we are always root until we implement user management
    return 0;
}

pub fn sys_geteuid(arg: *const anyopaque) !i32 {
    _ = arg;
    // we are always root until we implement user management
    return 0;
}

// Preemptible. The window here was justified by the kernel heap being
// unguarded -- "frees ... and allocates ... on the kernel heap, which newlib's
// allocator does not guard". That premise no longer holds: `__malloc_lock` is a
// ranked recursive spinlock and the allocator wrapper's own accounting is under
// it too, so the heap guards itself. The fd table this walks is per-process.
pub fn sys_dup(arg: *const anyopaque) !i32 {
    const context: *const c.dup_context = @ptrCast(@alignCast(arg));
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

pub fn sys_sysinfo(arg: *const anyopaque) !i32 {
    const context: *const c.sysinfo_context = @ptrCast(@alignCast(arg));
    const info = try user_out(c.struct_sysinfo, context.info);
    info.uptime = @intCast(systick.get_system_ticks());
    info.totalram = 1;
    info.freeram = 0;
    info.procs = @intCast(process_manager.instance.processes.len());
    return 0;
}

pub fn sys_sysconf(arg: *const anyopaque) !i32 {
    const context: *const c.sysconf_context = @ptrCast(@alignCast(arg));
    switch (context.name) {
        c._SC_CLK_TCK => {
            (try user_out(c_long, context.result)).* = 1000;
            return 0;
        },
        else => {
            return kernel.errno.ErrnoSet.InvalidArgument;
        },
    }
}

    // Preemptible: see `sys_open`. Everything the window covered is under a
    // named lock now, or needs none.
pub fn sys_prlimit(arg: *const anyopaque) !i32 {

    const context: *const c.prlimit_context = @ptrCast(@alignCast(arg));
    if (context.pid < 0) {
        return kernel.errno.ErrnoSet.InvalidArgument;
    }

    const process = if (context.pid == 0)
        process_manager.instance.get_current_process()
    else
        process_manager.instance.get_process_for_pid(context.pid) orelse return kernel.errno.ErrnoSet.NoSuchProcess;

    if (context.old_limit) |old_limit| {
        (try user_out(c.struct_rlimit, old_limit)).* = try process.get_resource_limit(context.resource);
    }

    if (context.new_limit) |new_limit| {
        const limit = try user_in(c.struct_rlimit, new_limit);
        try process.set_resource_limit(context.resource, limit.*);
    }

    return 0;
}

    // Preemptible: see `sys_open` for the reasoning. Everything this window
    // used to protect -- the kernel-heap allocations, the VFS walk and the
    // filesystem work, `get_current_process()`, and the per-process fd table --
    // is either under a named lock now or needs none.
pub fn sys_access(arg: *const anyopaque) !i32 {
    const context: *const c.access_context = @ptrCast(@alignCast(arg));
    const path = try determine_path_for_file(kernel_allocator, context.pathname, context.dirfd);
    defer kernel_allocator.free(path);
    try fs.get_ivfs().interface.access(path, context.mode, context.flags);
    return 0;
}

pub fn sys_klog_ctl(arg: *const anyopaque) !i32 {
    const context: *const c.klog_ctl_context = @ptrCast(@alignCast(arg));
    kernel.stdout.suppress(context.enable == 0);
    return 0;
}

    // Preemptible: see `sys_open`. Everything the window covered is under a
    // named lock now, or needs none.
pub fn sys_ftruncate(arg: *const anyopaque) !i32 {
    const context: *const c.ftruncate_context = @ptrCast(@alignCast(arg));
    var file = try get_file_from_process(@intCast(context.fd));
    try file.interface.truncate(@intCast(context.length));
    return 0;
}

const perf = @import("perf_profile.zig");
const preempt = @import("../sync/preempt.zig");
const system_stubs = @import("system_stubs.zig");

pub fn sys_perf_dump(arg: *const anyopaque) !i32 {
    // The caller owns the struct and expects the summary fields written back
    // into it, so the const on `arg` (shared by every syscall handler) is not
    // the contract here.
    const context: *volatile c.perf_dump_context = @ptrCast(@alignCast(@constCast(arg)));
    // Deliberately excluded from the copy-in table in system_call.zig (the
    // caller expects the summary fields written back into its own struct), so
    // this handler is the one that has to validate its own arguments.
    if (untrusted_caller()) {
        try uaccess.check(@intFromPtr(context), @sizeOf(c.perf_dump_context), .write);
        if (context.max_entries < 0) return ErrnoSet.InvalidArgument;
        _ = try user_out(c_int, context.num_entries);
        _ = try user_out_slice(
            @ptrCast(context.entries),
            @as(usize, @intCast(context.max_entries)) * @sizeOf(c.perf_syscall_entry),
        );
    }
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
