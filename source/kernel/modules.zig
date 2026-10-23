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

// This file contains preconfigured dynamic loader for the kernel.
// It keeps track of loaded modules and their addresses, for further deallocation when died.

const std = @import("std");
const vfmt = @import("vfmt.zig");
const hal = @import("hal");
const config = @import("config");

const yasld = @import("yasld");

const IFile = @import("fs/fs.zig").IFile;
const fs = @import("fs/vfs.zig");
const FileMemoryMapAttributes = @import("fs/ifile.zig").FileMemoryMapAttributes;
const IoctlCommonCommands = @import("fs/ifile.zig").IoctlCommonCommands;

const c = @import("libc_imports").c;

var kernel_allocator: std.mem.Allocator = undefined;

// Only immutable romfs mappings can outlive the resolved node.
const ResolvedLibrary = struct { image: ?yasld.Image };
var resolver_cache: std.StringHashMap(ResolvedLibrary) = undefined;
const max_negative_entries = 32;
const max_negative_bytes = 4096;
var negative_entries: usize = 0;
var negative_bytes: usize = 0;
var resolver_token: ?u64 = null;

/// Serialises the dynamic loader: rank 8, a sleeping mutex, held across a whole
/// load rather than just the tables. `Loader.get_shared_data` is check-then-act
/// across a hash-map lookup and an insert, so the lock has to span
/// miss -> create -> insert, and the create *is* the load. It sleeps because a
/// load is milliseconds of card I/O, and sits outside `mount`/`fs`/`dev`
/// because it reads the executable through the VFS.
pub var loader_lock: kernel.sync.RankedMutex(.loader) = .{};

const ModuleContext = struct {
    name: []const u8,
    image: ?yasld.Image,
};

const kernel = @import("kernel.zig");
const perf = @import("interrupts/perf_profile.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.loader);

/// Elapsed us of the most recent executable load, captured before any tracing
/// output. process_manager copies it into the process so sys_perf_dump and the
/// exit line report the load itself.
///
/// It exists because timing the call from the caller does not work on a
/// profiling build: the trace lines below are written from inside it, and
/// UART writes busy-wait. That measured a /bin/tcc load at 22.5 ms while the
/// load was 3.5 ms and the other 19 ms was the profiler printing about it.
pub var last_executable_load_us: u64 = 0;

/// Per-phase load attribution: nine serial lines per load, ~14 ms at 460800
/// baud, which is four times the load they describe and lands inside whatever
/// window is being measured. The split has already been taken (plan item 0.2),
/// so it is off by default; flip it when a specific load needs breaking down
/// again.
const dump_phases = false;

fn log_loader_timing(kind: []const u8, path: []const u8, pid: c.pid_t, start_us: u64) void {
    const elapsed_us = hal.time.get_time_us() - start_us;
    // Include kernel-heap usage so an accumulating leak across the suite (the
    // suspected "memory full" cause) is visible on every load, not only on
    // release. A monotonically climbing kernel_used here is the smoking gun.
    log.debug("yasld-bench {s} path={s} pid={d} us={d} kernel_used={d} allocs={d}", .{
        kind,                                  path,                                    pid, elapsed_us,
        kernel.memory.heap.malloc.get_usage(), kernel.memory.heap.malloc.get_counter(),
    });
    // Mirror the load/relocate time to serial (the log.debug above is file-only)
    // so the smoke harness captures the dynamic-load cost per spawn.
    perf.trace("load kind={s} path={s} pid={d} us={d}", .{ kind, path, pid, elapsed_us });
    dump_load_phases(kind, path);
}

/// Temporary: attribute a module load to its phases. The loader has no clock of
/// its own, so it exposes a hook and a set of accumulators; this installs the
/// hook on first use, prints the split next to the `load kind=` line, and
/// re-arms. Costs nothing when perf tracing is compiled out -- the hook stays
/// null and the loader's probes are null checks.
fn loader_clock_us() u64 {
    // `hal.time` is an instance, so its method cannot be taken by address.
    return hal.time.get_time_us();
}

fn dump_load_phases(kind: []const u8, path: []const u8) void {
    if (!perf.enabled or !dump_phases) return;
    if (yasld.load_profile.time_us_hook == null) {
        yasld.load_profile.time_us_hook = &loader_clock_us;
        return; // the load just measured ran without a clock; start from the next
    }
    inline for (@typeInfo(yasld.load_profile.Phase).@"enum".fields) |field| {
        const value = yasld.load_profile.phase_us[field.value];
        if (value != 0) {
            perf.trace("loadphase kind={s} path={s} phase={s} us={d}", .{ kind, path, field.name, value });
        }
    }
    yasld.load_profile.reset();
}

fn valid_library_name(name: []const u8) bool {
    return name.len != 0 and !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\x00") == null;
}

fn clear_resolver_cache() void {
    var keys = resolver_cache.keyIterator();
    while (keys.next()) |key| kernel_allocator.free(key.*);
    resolver_cache.clearRetainingCapacity();
    negative_entries = 0;
    negative_bytes = 0;
}

fn cache_resolution(name: []const u8, image: ?yasld.Image) void {
    if (resolver_token == null or resolver_cache.contains(name)) return;
    if (image == null and (negative_entries >= max_negative_entries or name.len > max_negative_bytes - negative_bytes)) return;
    const key = kernel_allocator.dupe(u8, name) catch return;
    resolver_cache.put(key, .{ .image = image }) catch {
        kernel_allocator.free(key);
        return;
    };
    if (image == null) {
        negative_entries += 1;
        negative_bytes += key.len;
    }
}

fn file_resolver(name: []const u8) ?yasld.Image {
    if (!valid_library_name(name)) return null;
    const token = fs.get_vfs().immutable_token("/lib");
    if (token != resolver_token) {
        clear_resolver_cache();
        resolver_token = token;
    }
    if (resolver_cache.get(name)) |hit| return hit.image;
    // A loader dependency must keep its mapping for the life of the process.
    // Mutable/unknown filesystems do not provide that contract.
    if (token == null) return null;
    // Iterator EOF also masks allocation/I/O failures. Only a direct NoEntry
    // from this immutable namespace establishes absence.
    var authoritative = false;
    var path_buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&path_buf, "/lib/{s}", .{name})) |path| {
        var maybe_node = fs.get_ivfs().interface.get(path) catch |err| blk: {
            authoritative = err == kernel.errno.ErrnoSet.NoEntry;
            break :blk null;
        };
        if (maybe_node) |*node| {
            defer node.delete();
            if (!node.immutable_backing) return null;
            if (node.as_file()) |file| {
                var context: ModuleContext = .{ .name = name, .image = null };
                if (is_requested_file(file, &context)) {
                    cache_resolution(name, context.image);
                    return context.image;
                }
                // Mapping/ioctl failure may be transient, so do not cache absence.
                authoritative = false;
            }
        }
    } else |_| {}

    var context: ModuleContext = .{ .name = name, .image = null };
    var node = fs.get_ivfs().interface.get("/lib") catch |err| {
        if (authoritative and err == kernel.errno.ErrnoSet.NoEntry) cache_resolution(name, null);
        return null;
    };
    defer node.delete();
    if (!node.immutable_backing) return null;
    var dir = node.as_directory() orelse return null;
    var it = dir.interface.iterator() catch return null;
    defer it.interface.delete();
    while (it.interface.next()) |*entry| {
        var child: kernel.fs.Node = undefined;
        dir.interface.get(entry.name, &child) catch {
            authoritative = false;
            continue;
        };
        defer child.delete();
        if (child.as_file()) |file| {
            if (is_requested_file(file, &context)) {
                cache_resolution(name, context.image);
                return context.image;
            }
            if (std.mem.eql(u8, entry.name, name)) authoritative = false;
        }
    }
    if (authoritative) cache_resolution(name, null);
    return null;
}

fn is_requested_file(file: kernel.fs.IFile, context: *ModuleContext) bool {
    if (!std.mem.eql(u8, context.name, file.interface.name())) return false;
    var attr: FileMemoryMapAttributes = .{ .is_memory_mapped = false, .mapped_address_r = null, .mapped_address_w = null };
    var fc = file;
    if (fc.interface.ioctl(@backingInt(IoctlCommonCommands.GetMemoryMappingStatus), &attr) < 0) return false;
    const address = attr.mapped_address_r orelse return false;
    const size = std.math.cast(usize, fc.interface.size()) orelse return false;
    if (@intFromPtr(address) % 4 != 0) return false;
    const bytes: [*]align(4) const u8 = @ptrCast(@alignCast(address));
    context.image = bytes[0..size];
    return true;
}

const ExecutableHandle = struct {
    allocator: std.mem.Allocator,
    executable: ?yasld.Executable,
    memory: ?[]align(16) u8,
};

var modules_list: yasld.IntegerHashMap(c.pid_t, ExecutableHandle) = undefined;
var libraries_list: yasld.IntegerHashMap(c.pid_t, std.DoublyLinkedList) = undefined;

/// Whether the two lists above hold a map at all. They are `undefined` before
/// `init` and again after `deinit` -- `HashMap.deinit` leaves them that way --
/// and a hash lookup on `undefined` reads a garbage metadata pointer, which
/// `@alignCast` turns into a panic. Nothing on the normal paths can observe
/// that, but `dump_fault_maps` runs from the hardfault handler, which is exactly
/// where an early-boot fault or the breakpoint at the end of `main` lands. There
/// the panic replaces the fault report with a bogus "incorrect alignment".
var lists_live: bool = false;

/// What this build of yasos can execute, handed to the loader so it can refuse
/// images built for a different part. Everything here comes from KConfig, the
/// same source the rootfs toolchain is configured from, so an image that
/// disagrees genuinely was built for another machine.
const machine_profile: yasld.MachineProfile = .{
    .arch = arch: {
        const arch = config.cpu.arch;
        if (std.mem.eql(u8, arch, "armv8-m")) break :arch .Armv8_m;
        if (std.mem.eql(u8, arch, "armv6-m")) break :arch .Armv6_m;
        break :arch .Unknown;
    },
    // yasos is softfp throughout: -mfpu decides only which instructions may be
    // inlined, never how FP arguments are passed, which is what keeps objects
    // link-compatible across the hardware-FP switch (see
    // docs/userspace_floating_point.md). Images built -mfloat-abi=soft pass FP
    // arguments the same way and are accepted; hard float is not.
    .float_abi = .Softfp,
    // The FPU name is picked by the CPU's KConfig because it names silicon
    // (CONFIG_BUILD_USERSPACE_FP_MFPU). It is only advertised when the kernel
    // actually turns the unit on -- with CONFIG_CPU_USE_FPU off, CPACR is never
    // programmed, so an image with inline FP instructions would fault. On
    // RP2350 the same CPACR write enables CP4, which is why the DCP rides along
    // with the FPU here (hal/source/raspberry/rp2350/startup/crt.zig).
    .features = features: {
        if (!(config.cpu.has_fpu and config.cpu.use_fpu)) break :features .{};
        if (!@hasDecl(config.build, "userspace_fp_mfpu")) break :features .{};
        const mfpu = config.build.userspace_fp_mfpu;
        if (std.mem.eql(u8, mfpu, "rp2350")) break :features .{ .fpu_sp = true, .dcp = true };
        if (std.mem.eql(u8, mfpu, "fpv5-sp-d16")) break :features .{ .fpu_sp = true };
        if (std.mem.eql(u8, mfpu, "fpv4-sp-d16")) break :features .{ .fpu_sp = true };
        if (std.mem.eql(u8, mfpu, "fpv5-d16")) break :features .{ .fpu_sp = true, .fpu_dp = true };
        @compileError("unknown CONFIG_BUILD_USERSPACE_FP_MFPU '" ++ mfpu ++
            "': add it here and to the case in build_rootfs.sh");
    },
};

/// A YAFF image this machine cannot run is a bad executable format, not an
/// internal error: exec must report it as ENOEXEC so the shell says so instead
/// of failing with something unrelated.
fn map_load_error(err: anyerror) anyerror {
    return switch (err) {
        error.IncorrectSignature,
        error.UnsupportedYaffVersion,
        error.MissingArchSection,
        error.UnsupportedArchitecture,
        error.UnsupportedFloatAbi,
        error.UnsupportedCpuFeatures,
        error.InvalidDataAlignment,
        error.InvalidImageLayout,
        error.DependencyIsNotLibrary,
        => kernel.errno.ErrnoSet.ExecFormatError,
        else => err,
    };
}

/// Owner of the loader cache's pages in the process pool. No process has a
/// negative pid, so nothing exits and releases them by accident.
pub const loader_cache_pid: c.pid_t = -2;

var cache_lock: kernel.sync.locks.Ranked(.loader_cache) = .{};

fn cache_lock_acquire() usize {
    return cache_lock.lock_irqsave();
}

fn cache_lock_release(flags: usize) void {
    cache_lock.unlock_irqrestore(flags);
}

/// Pages for yasld's relocated-image templates: from the slow end of the
/// process pool, owned by `loader_cache_pid`, and handed back whenever some
/// other allocation finds the pool full (`reclaim_hook`). So the cache holds
/// what nothing else wants and costs a running program nothing.
const CachePages = struct {
    const Pool = kernel.memory.heap.ProcessMemoryPool;

    fn pool() *Pool {
        return kernel.process.process_manager.instance.get_process_memory_pool();
    }

    fn pages_for(len: usize) i32 {
        return @intCast((len + Pool.page_size - 1) / Pool.page_size);
    }

    fn alloc(_: *anyopaque, len: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const memory = pool().allocate_pages_from(pages_for(len), loader_cache_pid, .cache) orelse return null;
        return memory.ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        pool().free_pages(memory.ptr, pages_for(memory.len), loader_cache_pid);
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };
};

fn reclaim_loader_cache(bytes: usize) usize {
    return yasld.template.reclaim(bytes);
}

/// Where build_rootfs.sh puts the loader precache (yasld-prelink).
const precache_path = "/lib/yasld.cache";
var precache_looked = false;

/// Hand the loader its precache, the first time anything is loaded -- by
/// then the root filesystem is mounted, which it is not yet at `init`. Read
/// in place, so only a memory-mapped (romfs) file will do.
fn find_precache() void {
    if (precache_looked) return;
    precache_looked = true;
    var node = fs.get_ivfs().interface.get(precache_path) catch return;
    defer node.delete();
    if (!node.immutable_backing) return;
    var file = node.as_file() orelse return;
    var attr: FileMemoryMapAttributes = .{
        .is_memory_mapped = false,
        .mapped_address_r = null,
        .mapped_address_w = null,
    };
    _ = file.interface.ioctl(@backingInt(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
    const address = attr.mapped_address_r orelse return;
    const bytes: [*]const u8 = @ptrCast(address);
    yasld.template.set_precache(bytes[0..@intCast(file.interface.size())], yasld.thunk_size()) catch |err| {
        log.warn("{s} ignored: {s}", .{ precache_path, @errorName(err) });
        return;
    };
    log.info("loader precache: {s}", .{precache_path});
}

pub fn init(allocator: std.mem.Allocator) void {
    log.info("yasld initialization started", .{});
    yasld.loader_init(&file_resolver, allocator, machine_profile);
    if (!builtin.is_test) {
        yasld.template.enable(CachePages.allocator, .{ .lock = &cache_lock_acquire, .unlock = &cache_lock_release });
        kernel.memory.heap.ProcessMemoryPool.reclaim_hook = &reclaim_loader_cache;
    }
    // The per-load section-base line is blocking console UART on every spawn, so
    // it rides with the rest of the profiling output rather than being paid for
    // by every run. Faults dump the map anyway (dump_fault_maps below) and
    // /proc/<pid>/maps serves it on demand.
    yasld.set_load_map_logging(perf.enabled);
    modules_list = yasld.IntegerHashMap(c.pid_t, ExecutableHandle).init(allocator);
    libraries_list = yasld.IntegerHashMap(c.pid_t, std.DoublyLinkedList).init(allocator);
    resolver_cache = std.StringHashMap(ResolvedLibrary).init(allocator);
    resolver_token = null;
    negative_entries = 0;
    negative_bytes = 0;
    vfork_snapshots = yasld.IntegerHashMap(c.pid_t, *VForkSnapshot).init(allocator);
    kernel_allocator = allocator;
    lists_live = true;
}

pub fn deinit() void {
    lists_live = false;
    var it = modules_list.iterator();
    while (it.next()) |item| {
        if (item.value_ptr.memory) |mem| {
            item.value_ptr.allocator.free(mem);
        }
    }
    modules_list.deinit();
    libraries_list.deinit();
    var rit = resolver_cache.keyIterator();
    while (rit.next()) |key| {
        kernel_allocator.free(key.*);
    }
    resolver_cache.deinit();
    var vit = vfork_snapshots.valueIterator();
    while (vit.next()) |snap| snap.*.free();
    vfork_snapshots.deinit();
    yasld.loader_deinit();
}

pub fn load_executable(path: []const u8, process_allocator: std.mem.Allocator, pid: c.pid_t) !*yasld.Executable {
    last_executable_load_us = 0; // a load that fails reports nothing, not the previous one
    // Start the clock at the path lookup, not at the relocation. For an image
    // the filesystem cannot memory-map (anything outside the XIP romfs -- /tmp,
    // /root on MMC) the copy below reads the whole file, which is the larger
    // half of the load; a window that began after it reported the loader as
    // cheap while the read it hides is exactly what an IO investigation is
    // looking for.
    const load_start_us = hal.time.get_time_us();
    var node = try fs.get_ivfs().interface.get(path);
    return load_executable_node(&node, path, process_allocator, pid, load_start_us);
}

/// Reads are streams: positive partial reads are progress, EOF is final.
fn read_image(file: *kernel.fs.IFile, allocator: std.mem.Allocator, size: usize) ![]align(16) u8 {
    const pos = try file.interface.seek(0, c.SEEK_SET);
    if (pos != 0) return kernel.errno.ErrnoSet.InputOutputError;
    const memory = try allocator.alignedAlloc(u8, .@"16", size);
    errdefer allocator.free(memory);
    var filled: usize = 0;
    while (filled < memory.len) {
        const got = file.interface.read(memory[filled..]);
        if (got < 0) return kernel.errno.ErrnoSet.InputOutputError;
        if (got == 0) return kernel.errno.ErrnoSet.ExecFormatError;
        const count: usize = @intCast(got);
        if (count > memory.len - filled) return kernel.errno.ErrnoSet.InputOutputError;
        filled += count;
    }
    return memory;
}

/// The body of `load_executable` for a node the caller has already resolved.
/// `sys_execve` looks the path up once to sniff its `#!` line and hands that
/// node over here instead of resolving the same path a second time -- on a
/// filesystem without a lookup cache (FAT, MMC) that second `get` is another
/// full directory walk per exec. The node is the caller's to own and this
/// consumes it: `defer node.delete()` runs on every exit, including the ones
/// that install no image, so nothing holds it once this returns -- which is
/// what the vfork handoff in `prepare_exec` relies on.
pub fn load_executable_node(node: *kernel.fs.Node, path: []const u8, process_allocator: std.mem.Allocator, pid: c.pid_t, load_start_us: u64) !*yasld.Executable {
    loader_lock.lock();
    defer loader_lock.unlock();
    last_executable_load_us = 0;
    const cache_before = perf.cache_summary();
    defer perf.dump_load_cache(pid, cache_before);
    log.debug("load_executable: pid={d} path={s}", .{ pid, path });
    if (!builtin.is_test) find_precache();
    defer node.delete();
    var maybe_file = node.as_file();
    if (maybe_file) |*f| {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = f.interface.ioctl(@backingInt(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        const size = std.math.cast(usize, f.interface.size()) orelse return kernel.errno.ErrnoSet.ExecFormatError;
        if (size < yasld.header_size) return kernel.errno.ErrnoSet.ExecFormatError;
        var image: yasld.Image = undefined;
        var entry = ExecutableHandle{
            .allocator = process_allocator,
            .executable = null,
            .memory = null,
        };
        errdefer if (entry.memory) |memory| process_allocator.free(memory);
        if (attr.mapped_address_r) |address| {
            if (@intFromPtr(address) % 4 != 0) return kernel.errno.ErrnoSet.ExecFormatError;
            const bytes: [*]align(4) const u8 = @ptrCast(@alignCast(address));
            image = bytes[0..size];
        } else {
            const memory = try read_image(f, process_allocator, size);
            entry.memory = memory;
            image = memory;
        }
        if (yasld.get_loader()) |loader| {
            // Only a mapped (romfs XIP) image keeps its address; a RAM copy's
            // address is recycled, so nothing computed against it may outlive it.
            const executable = loader.*.load_executable(image, process_allocator, entry.memory == null and node.immutable_backing) catch |err| {
                log.err("loading '{s}' failed: {s}", .{ path, @errorName(err) });
                return map_load_error(err);
            };
            last_executable_load_us = hal.time.get_time_us() - load_start_us;
            log_loader_timing("executable", path, pid, load_start_us);
            entry.executable = executable;
            errdefer entry.executable.?.deinit();
            try modules_list.ensureUnusedCapacity(1);
            release_executable_locked(pid);
            modules_list.putAssumeCapacity(pid, entry);
            const exec_ptr: *yasld.Executable = &modules_list.getPtr(pid).?.executable.?;
            return exec_ptr;
        } else {
            log.err("yasld is not initialized", .{});
            return kernel.errno.ErrnoSet.NotPermitted;
        }
    }
    return kernel.errno.ErrnoSet.IsADirectory;
}

/// The stack an executable asks for in its YAFF header, or null when it
/// declares none or is not a YAFF image -- read from the header alone, without
/// loading the image.  The boot shell needs it: `kernel_process` loads /bin/sh
/// into the root process and calls its main on the root process's own stack,
/// so the exec-time hint (`exec_stack_limit`) never reaches pid 1.
pub fn executable_stack_hint(path: []const u8) ?u32 {
    var node = fs.get_ivfs().interface.get(path) catch return null;
    defer node.delete();
    var file = node.as_file() orelse return null;
    var header: yasld.Header = undefined;
    const bytes = std.mem.asBytes(&header);
    if (file.interface.read(bytes) != @as(isize, @intCast(bytes.len))) return null;
    if (!std.mem.eql(u8, std.mem.asBytes(&header.magic), "YAFF")) return null;
    if (header.stack_size == 0 or header.stack_size == 0xFFFFFFFF) return null;
    return header.stack_size;
}

pub fn load_shared_library(path: []const u8, process_allocator: std.mem.Allocator, pid: c.pid_t) !*yasld.Module {
    loader_lock.lock();
    defer loader_lock.unlock();
    // Same window as load_executable: from the lookup, not from the relocation.
    const load_start_us = hal.time.get_time_us();
    var node = try fs.get_ivfs().interface.get(path);
    defer node.delete();
    var maybe_file = node.as_file();
    if (maybe_file) |*f| {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = f.interface.ioctl(@backingInt(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        // dlopen must retain a stable mapping after this node is released.
        if (!node.immutable_backing) return kernel.errno.ErrnoSet.NotImplemented;
        var header_address: *const anyopaque = undefined;

        if (attr.mapped_address_r) |address| {
            header_address = address;
        } else {
            // dlopen cannot retain an unmapped backing image yet.
            return kernel.errno.ErrnoSet.NotImplemented;
        }
        if (yasld.get_loader()) |loader| {
            const size = std.math.cast(usize, f.interface.size()) orelse return kernel.errno.ErrnoSet.ExecFormatError;
            if (size < yasld.header_size or @intFromPtr(header_address) % 4 != 0) return kernel.errno.ErrnoSet.ExecFormatError;
            const bytes: [*]align(4) const u8 = @ptrCast(@alignCast(header_address));
            const library = loader.*.load_library(bytes[0..size], process_allocator, node.immutable_backing) catch |err| {
                log.err("loading library '{s}' failed: {s}", .{ path, @errorName(err) });
                return map_load_error(err);
            };
            errdefer library.destroy();
            log_loader_timing("library", path, pid, load_start_us);

            if (!libraries_list.contains(pid)) {
                libraries_list.put(pid, .{}) catch |err| return err;
            }
            const maybe_list = libraries_list.getPtr(pid);
            if (maybe_list) |list| {
                list.append(&library.list_node);
            }
            return library;
        } else {
            log.err("yasld is not initialized", .{});
            return kernel.errno.ErrnoSet.NotPermitted;
        }
    }
    return kernel.errno.ErrnoSet.IsADirectory;
}

pub fn release_executable(pid: c.pid_t) void {
    loader_lock.lock();
    defer loader_lock.unlock();
    release_executable_locked(pid);
}

/// `release_executable` with `loader_lock` already held. Split out because
/// `load_executable` drops the previous image before installing the new one,
/// and `RankedMutex` is not recursive.
fn release_executable_locked(pid: c.pid_t) void {
    loader_lock.assert_held();
    // Kernel-heap accounting around the release: a climbing kernel_used or
    // alloc_count across the (no-reboot) suite is the signature of the leak that
    // ends in tcc "memory full" on a tiny input. It used to print at info, which
    // the `.loader` scope pins on, so both lines went out over the console UART
    // on every spawn — `Uart.write` busy-waits for TX space, so the suite paid
    // the serial time thousands of times to watch a counter that only matters
    // when something is being diagnosed. perf.trace emits only when the build is
    // configured for profiling, which is when anyone is reading it.
    perf.trace("relexec pid={d} kernel_used={d} allocs={d}", .{ pid, kernel.memory.heap.malloc.get_usage(), kernel.memory.heap.malloc.get_counter() });
    log.debug("release_executable: pid={d} kernel_used={d} alloc_count={d}", .{ pid, kernel.memory.heap.malloc.get_usage(), kernel.memory.heap.malloc.get_counter() });
    var maybe_entry = modules_list.getPtr(pid);
    if (maybe_entry) |*entry| {
        if (entry.*.executable) |*executable| {
            executable.deinit();
            if (entry.*.memory) |memory| entry.*.allocator.free(memory);
            _ = modules_list.remove(pid);
            const maybe_list = libraries_list.getPtr(pid);
            if (maybe_list) |list| {
                var next = list.pop();
                while (next) |node| {
                    const library: *yasld.Module = @fieldParentPtr("list_node", node);
                    library.destroy();
                    next = list.pop();
                }
            }
        } else {
            log.warn("release_executable: pid={d} has entry but no executable", .{pid});
        }
        _ = libraries_list.remove(pid);
    }
    perf.trace("relexec-done pid={d} kernel_used={d} allocs={d}", .{ pid, kernel.memory.heap.malloc.get_usage(), kernel.memory.heap.malloc.get_counter() });
    log.debug("release_executable: pid={d} done kernel_used={d} alloc_count={d}", .{ pid, kernel.memory.heap.malloc.get_usage(), kernel.memory.heap.malloc.get_counter() });
}

fn append_section(buffer: []u8, name: []const u8, section: []const u8, address: usize, size: usize) usize {
    const written = vfmt.print(buffer, "{s} {s} 0x{x} 0x{x}\n", .{ name, section, address, size });
    return written.len;
}

fn format_module(module: *const yasld.Module, buffer: []u8, depth: usize) usize {
    const name = module.name orelse "?";
    var written: usize = 0;
    const text = module.get_text();
    const plt = module.get_plt();
    const data = module.get_data();
    const bss = module.get_bss();
    const got = module.get_got();
    written += append_section(buffer[written..], name, ".text", @intFromPtr(text.ptr), text.len);
    written += append_section(buffer[written..], name, ".plt", @intFromPtr(plt.ptr), plt.len);
    written += append_section(buffer[written..], name, ".data", @intFromPtr(data.ptr), data.len);
    written += append_section(buffer[written..], name, ".bss", @intFromPtr(bss.ptr), bss.len);
    written += append_section(buffer[written..], name, ".got", @intFromPtr(got.ptr), got.len);

    // Shared libraries imported by this module are tracked as child modules
    // (module.children), not in the kernel libraries_list. Recurse so the map
    // includes libc/libm/etc. The depth guard bounds runaway/cyclic graphs;
    // a shared dependency may legitimately appear under more than one parent.
    if (depth < 8) {
        var maybe_child = module.children.first;
        while (maybe_child) |node| : (maybe_child = node.next) {
            const child: *yasld.Module = @fieldParentPtr("child_list_node", node);
            written += format_module(child, buffer[written..], depth + 1);
        }
    }
    return written;
}

/// Fault-context dump of a process's module map. Called from the ARM hardfault
/// handler so a crash's stacked_pc/lr can be mapped to <module>+offset without
/// guessing load bases. Logs each section line via the loader scope.
export fn dump_fault_maps(pid: c.pid_t) void {
    var buffer: [4096]u8 = undefined;
    const n = format_maps(pid, buffer[0..]);
    log.err("maps for pid={d}:", .{pid});
    // Says so out loud rather than printing a bare header: an empty map means
    // the loader is not up (see `lists_live`), which is itself a fact about
    // where the fault happened.
    if (n == 0) log.err("  <none>", .{});
    var it = std.mem.splitScalar(u8, buffer[0..n], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        log.err("  {s}", .{line});
    }
}

/// Render the load mapping (executable then shared libraries) for `pid` into
/// `buffer` as lines of "<module> <section> 0x<addr> 0x<size>". Returns the
/// number of bytes written. Used by /proc/<pid>/maps so module load addresses
/// can be retrieved on demand instead of scraped from log output.
pub fn format_maps(pid: c.pid_t, buffer: []u8) usize {
    // The fault handler reaches here at times the loader is not up; see
    // `lists_live`. "No map" is the honest answer, and the caller prints it.
    if (!lists_live) return 0;
    var written: usize = 0;
    if (modules_list.getPtr(pid)) |entry| {
        if (entry.executable) |*executable| {
            written += format_module(executable.module, buffer[written..], 0);
        }
    }
    if (libraries_list.getPtr(pid)) |list| {
        var maybe_node = list.first;
        while (maybe_node) |node| : (maybe_node = node.next) {
            const library: *yasld.Module = @fieldParentPtr("list_node", node);
            written += format_module(library, buffer[written..], 0);
        }
    }
    return written;
}

/// Is `library` a handle this process actually holds? dlclose/dlsym receive the
/// handle straight from userspace; without this, `release_shared_library` would
/// unlink an attacker-chosen address, which is an arbitrary write. The
/// per-process list is a handful of entries, so a linear scan is enough.
pub fn owns_shared_library(pid: c.pid_t, library: *const yasld.Module) bool {
    const list = libraries_list.getPtr(pid) orelse return false;
    var maybe_node = list.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const module: *yasld.Module = @alignCast(@fieldParentPtr("list_node", node));
        if (module == library) return true;
    }
    return false;
}

pub fn release_shared_library(pid: c.pid_t, library: *yasld.Module) void {
    loader_lock.lock();
    defer loader_lock.unlock();
    const maybe_list = libraries_list.getPtr(pid);
    if (maybe_list) |list| {
        list.remove(&library.list_node);
        if (yasld.get_loader()) |loader| {
            loader.*.unload_module(library);
        }
        if (list.first == null) {
            _ = libraries_list.remove(pid);
        }
    }
}

/// Look up a pid's executable. Caller must hold `loader_lock`; split out so the
/// entry points that already hold it can reuse the lookup.
fn executable_for_pid_locked(pid: c.pid_t) ?*yasld.Executable {
    if (!modules_list.contains(pid)) {
        return null;
    }
    if (modules_list.getPtr(pid).?.executable) |*exec| {
        return exec;
    }
    return null;
}

/// The executable loaded for `pid`, or null. Takes `loader_lock` for the lookup,
/// because `modules_list` is a `HashMap` the other core may be rehashing.
///
/// The lock covers the lookup, not the lifetime of what is returned: the pointer
/// stays valid while that pid's executable is loaded, which both callers already
/// depend on -- each is asking about a process that is running.
pub fn get_executable_for_pid(pid: c.pid_t) ?*yasld.Executable {
    loader_lock.lock();
    defer loader_lock.unlock();
    return executable_for_pid_locked(pid);
}

const SectionBackup = struct {
    original: []u8,
    copy: []u8,
};

pub const VForkSnapshot = struct {
    backups: []SectionBackup,
    allocator: std.mem.Allocator,

    pub fn restore_and_free(self: *VForkSnapshot) void {
        for (self.backups) |backup| {
            @memcpy(backup.original, backup.copy);
            self.allocator.free(backup.copy);
        }
        self.allocator.free(self.backups);
        self.allocator.destroy(self);
    }

    // Free the backing copies WITHOUT restoring (system teardown, or a stale entry
    // whose target memory is gone — restoring it would corrupt unrelated memory).
    pub fn free(self: *VForkSnapshot) void {
        for (self.backups) |backup| self.allocator.free(backup.copy);
        self.allocator.free(self.backups);
        self.allocator.destroy(self);
    }
};

// Per-(child)-pid snapshots of a vfork parent's writable sections. The vfork child
// runs on the parent's shared memory and can corrupt it before exec (toybox subshell
// children malloc + write environ/toys.argv), so the parent's sections are restored
// when that child execs (prepare_exec) or exits (delete_process). Keyed by the CHILD
// pid — the in-hand process at both restore sites. This replaced a single global that
// save() overwrote without freeing: a vfork child can itself vfork before exec,
// orphaning the prior snapshot and leaking ~5.8 KB each (observed 10 live ≈ 56 KB,
// 89% of the kernel-heap peak). The map, freed on both exec and exit, removes the leak
// while keeping the protection.
var vfork_snapshots: yasld.IntegerHashMap(c.pid_t, *VForkSnapshot) = undefined;

// The vfork writable-section snapshot copies the parent executable's + every loaded
// library's writable image (.data+.bss+.got) to the kernel heap on each vfork so the
// parent can be restored if the child corrupts shared memory before exec. For toybox
// that snapshot is ~57 KB (toybox 41 KB + libc 16 KB), which was the entire kernel
// heap peak (device-measured: 64 KB -> 12 KB tracked with this off) and added a 57 KB
// memcpy to every process spawn.
//
// It is OFF because the only vfork path toybox currently uses (sh_exec, the simple
// command path) is intentionally exec-only / malloc-free — a correct POSIX vfork child
// — so it never corrupts the parent. (Verified: the full vfork-heavy smoke set passes
// with this disabled.) The malloc-using subshell path (subshell_callback) and pipes
// are not implemented in this toybox build ("TODO: Implement pipe").
//
// Re-enable ONLY if a vfork child that writes parent memory before exec is introduced
// (e.g. a malloc-using subshell/pipe). The proper fix then is to make that child
// exec-only (like sh_exec), not to pay this snapshot. When enabled it uses the
// per-pid map below (freed on exec and exit) to avoid leaking on nested vforks.
// NOTE: kernel_ram is now sized (~64 KB heap) on the assumption this stays OFF.
// Enabling it adds ~57 KB of kernel heap per concurrent spawn and would need a
// correspondingly larger kernel_ram (see hal/.../linker_script.ld).
const vfork_snapshot_enabled = false;

/// Snapshot the parent's writable sections before a vfork child runs on them.
/// Takes `loader_lock`: it walks `modules_list` and mutates `vfork_snapshots`,
/// both of which the other core touches on its own exec/exit path. The caller
/// must therefore be preemptible, since a sleeping mutex may not be taken with
/// preemption off.
pub fn save_parent_writable_sections(parent_pid: c.pid_t, child_pid: c.pid_t) void {
    if (!vfork_snapshot_enabled) return;
    loader_lock.lock();
    defer loader_lock.unlock();
    const exec = executable_for_pid_locked(parent_pid) orelse return;

    // Count modules with unique_data (executable + its library children)
    var count: usize = 0;
    if (exec.module.unique_data != null) count += 1;
    var it = exec.module.children.first;
    while (it) |node| : (it = node.next) {
        const child: *yasld.Module = @fieldParentPtr("child_list_node", node);
        if (child.unique_data != null) count += 1;
    }
    if (count == 0) return;

    const snapshot = kernel_allocator.create(VForkSnapshot) catch return;
    const backups = kernel_allocator.alloc(SectionBackup, count) catch {
        kernel_allocator.destroy(snapshot);
        return;
    };

    var idx: usize = 0;

    if (exec.module.unique_data) |ud| {
        const copy = kernel_allocator.dupe(u8, ud._underlaying_memory) catch {
            kernel_allocator.free(backups);
            kernel_allocator.destroy(snapshot);
            return;
        };
        backups[idx] = .{ .original = ud._underlaying_memory, .copy = copy };
        idx += 1;
    }

    it = exec.module.children.first;
    while (it) |node| : (it = node.next) {
        const child: *yasld.Module = @fieldParentPtr("child_list_node", node);
        if (child.unique_data) |ud| {
            const copy = kernel_allocator.dupe(u8, ud._underlaying_memory) catch {
                for (backups[0..idx]) |b| kernel_allocator.free(b.copy);
                kernel_allocator.free(backups);
                kernel_allocator.destroy(snapshot);
                return;
            };
            backups[idx] = .{ .original = ud._underlaying_memory, .copy = copy };
            idx += 1;
        }
    }

    snapshot.* = .{ .backups = backups[0..idx], .allocator = kernel_allocator };
    // Defensive: a leftover snapshot for a reused child pid should have been removed
    // at the prior child's exec/exit; drop it without restoring (its target is gone).
    if (vfork_snapshots.fetchRemove(child_pid)) |kv| kv.value.free();
    vfork_snapshots.put(child_pid, snapshot) catch snapshot.free();
}

/// Put a suspended parent's writable sections back, and drop the snapshot.
/// Takes `loader_lock`, because `vfork_snapshots` is mutated here and in
/// `save_parent_writable_sections`, which the other core can be running: one
/// core exec'ing while the other vforks is the ordinary shape of a shell running
/// a command. Both callers are in preemptible thread context, which is what
/// makes a sleeping mutex legal here.
pub fn restore_parent_writable_sections(child_pid: c.pid_t) void {
    loader_lock.lock();
    defer loader_lock.unlock();
    if (vfork_snapshots.fetchRemove(child_pid)) |kv| {
        kv.value.restore_and_free();
    }
}

test "Modules.ShouldInitializeAndDeinitialize" {
    init(std.testing.allocator);
    defer deinit();

    try std.testing.expect(modules_list.count() == 0);
    try std.testing.expect(libraries_list.count() == 0);
}

const FileSystemMock = @import("fs/tests/filesystem_mock.zig").FileSystemMock;
fn create_vfs_for_test(allocator: std.mem.Allocator) !*FileSystemMock {
    var fs_mock = try FileSystemMock.create(allocator);
    defer fs_mock.delete();
    kernel.fs.vfs_init(allocator);
    try fs.get_vfs().mount_filesystem_with_info("/", fs_mock.get_interface(), kernel.fs.MountInfo.init("mock", "romfs", "ro"));
    return fs_mock;
}

const FileMock = @import("fs/tests/file_mock.zig").FileMock;
const interface = @import("interface");
const test_mapped_address: usize = 0x1000;
fn create_filemock(allocator: std.mem.Allocator) !*FileMock {
    var file_mock = try FileMock.create(allocator);
    const IoctlCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: @Tuple(&[_]type{ i32, ?*anyopaque })) !i32 {
            const cmd = args[0];
            try std.testing.expectEqual(cmd, @as(i32, @backingInt(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)));

            const a = args[1];
            var attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(a.?));
            attr.is_memory_mapped = true;
            attr.mapped_address_w = null;
            attr.mapped_address_r = ctx.?;
            return 0;
        }
    };

    _ = file_mock
        .expectCall("ioctl")
        .invoke(&IoctlCallback.call, &test_mapped_address)
        .times(interface.mock.any{})
        .willReturn(0);

    _ = file_mock.expectCall("size").times(interface.mock.any{}).willReturn(@as(u64, 512));
    return file_mock;
}

test "Modules.ShouldLoadExecutableFromFileSystem" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(file_node);

    const pid: c.pid_t = 123;
    _ = try load_executable("/test_executable", std.testing.allocator, pid);

    try std.testing.expect(get_executable_for_pid(pid) != null);
    release_executable(pid);

    try std.testing.expect(get_executable_for_pid(pid) == null);
}

test "Modules.ShouldLoadSharedLibrariesFromFileSystem" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_lib"})
        .willReturn(file_node);

    const pid: c.pid_t = 123;
    const lib = try load_shared_library("/test_lib", std.testing.allocator, pid);

    try std.testing.expect(get_executable_for_pid(pid) == null);
    try std.testing.expect(libraries_list.getPtr(pid) != null);
    try std.testing.expect(libraries_list.getPtr(pid).?.len() == 1);
    release_shared_library(pid, lib);

    try std.testing.expect(get_executable_for_pid(pid) == null);
    try std.testing.expect(libraries_list.getPtr(pid) == null);
}

test "Modules.ShouldHandleExecutableDependantOnSharedLibraries" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(file_node);

    var lib1_mock = try create_filemock(std.testing.allocator);
    const lib1_node = kernel.fs.Node.create_file(lib1_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"libdependency1.so"})
        .willReturn(lib1_node);

    var lib2_mock = try create_filemock(std.testing.allocator);
    const lib2_node = kernel.fs.Node.create_file(lib2_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"libdependency2.so"})
        .willReturn(lib2_node);

    const pid: c.pid_t = 123;
    _ = try load_executable("/test_executable", std.testing.allocator, pid);
    _ = try load_shared_library("/libdependency1.so", std.testing.allocator, pid);
    _ = try load_shared_library("/libdependency2.so", std.testing.allocator, pid);

    try std.testing.expect(get_executable_for_pid(pid) != null);
    const libs = libraries_list.getPtr(pid);
    try std.testing.expect(libs != null);
    try std.testing.expect(libs.?.len() == 2);
    release_executable(pid);

    try std.testing.expect(get_executable_for_pid(pid) == null);
    try std.testing.expectEqual(null, libraries_list.getPtr(pid));
}

test "Modules.ShouldForwardLoadingErrors" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // Create a mock ELF file
    var file_mock = try create_filemock(std.testing.allocator);
    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(file_node);

    const pid: c.pid_t = 123;
    yasld.get_loader().?.load_should_fail(kernel.errno.ErrnoSet.ExecFormatError);
    try std.testing.expectError(kernel.errno.ErrnoSet.ExecFormatError, load_executable("/test_executable", std.testing.allocator, pid));
}

// The entry `sys_execve` uses: it resolved the path once to sniff the file's
// `#!` line and hands that node over, so the image must be installed without
// asking the filesystem again. The mounted mock expects no call at all here,
// and it panics on one it has not been told about -- a second `get` of the
// path would fail the test rather than go unnoticed.
test "Modules.LoadsAnExecutableFromANodeTheCallerAlreadyResolved" {
    // No expectation is set on the mounted filesystem: it panics on a call it
    // was not told about, so the absence of a `get` for the path is the
    // assertion that the loader worked from the node the caller handed over.
    _ = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var file_mock = try create_filemock(std.testing.allocator);
    var file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    const pid: c.pid_t = 123;
    _ = try load_executable_node(&file_node, "/test_executable", std.testing.allocator, pid, hal.time.get_time_us());

    try std.testing.expect(get_executable_for_pid(pid) != null);
    release_executable(pid);

    try std.testing.expect(get_executable_for_pid(pid) == null);
}

// An image outside the XIP romfs is copied before it runs, and a copy that
// came up short is not executable: the bytes past the read are untouched
// allocation, and the loader would happily relocate a header whose section
// list points into them.
test "Modules.ShouldRejectAnImageThatCameUpShort" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var file_mock = try FileMock.create(std.testing.allocator);
    // Unmapped: the ioctl leaves `mapped_address_r` alone, so the image is
    // read into a copy -- and that stream ends before the image is whole.
    _ = file_mock.expectCall("ioctl").willReturn(0);
    _ = file_mock.expectCall("size").willReturn(@as(u64, 512));
    _ = file_mock.expectCall("read").willReturn(@as(isize, 300));
    _ = file_mock.expectCall("seek").withArgs(.{ @as(i64, 0), @as(i32, c.SEEK_SET) }).willReturn(@as(i64, 0));
    _ = file_mock.expectCall("read").willReturn(@as(isize, 0));

    const file_node = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(file_node);

    const pid: c.pid_t = 123;
    try std.testing.expectError(kernel.errno.ErrnoSet.ExecFormatError, load_executable("/test_executable", std.testing.allocator, pid));
}

const DirectoryMock = @import("fs/tests/directory_mock.zig").DirectoryMock;
test "Modules.ShouldFailIfDirectoryProvidedInsteadOfFile" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(dirnode);

    var dirmock2 = try DirectoryMock.create(std.testing.allocator);
    const dirnode2 = kernel.fs.Node.create_directory(dirmock2.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(dirnode2);

    const pid: c.pid_t = 123;
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, load_executable("/test_executable", std.testing.allocator, pid));
    try std.testing.expectError(kernel.errno.ErrnoSet.IsADirectory, load_shared_library("/test_executable", std.testing.allocator, pid));
}

test "Modules.ShouldFailIfDynamicLoaderUninitialized" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var file_mock = try create_filemock(std.testing.allocator);
    const filenode1 = kernel.fs.Node.create_file(file_mock.get_interface());
    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(filenode1);

    var filemock2 = try create_filemock(std.testing.allocator);
    const filenode2 = kernel.fs.Node.create_file(filemock2.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"test_executable"})
        .willReturn(filenode2);

    const pid: c.pid_t = 123;
    yasld.loader_deinit();
    try std.testing.expectError(kernel.errno.ErrnoSet.NotPermitted, load_executable("/test_executable", std.testing.allocator, pid));
    try std.testing.expectError(kernel.errno.ErrnoSet.NotPermitted, load_shared_library("/test_executable", std.testing.allocator, pid));
}

const DirectoryIteratorMock = @import("fs/tests/directory_mock.zig").DirectoryIteratorMock;

test "Modules.ResolverShouldReturnNullIfFileNotFoundInFileSystem" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    // The direct probe of `/lib/<name>` runs first, so it is the first call
    // the mock has to answer.
    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    // A failing get() makes the VFS probe the path for symlink components,
    // but only on a filesystem that can hold one -- so it asks first.
    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(true);

    // Having said it can, it is probed via stat(); the mock reports /lib is
    // not a symlink so resolution gives up.
    _ = fs_mock
        .expectCall("stat")
        .withArgs(.{ interface.mock.any{}, interface.mock.any{}, interface.mock.any{} })
        .times(interface.mock.any{})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    try std.testing.expect(file_resolver("libtest.so") == null);
}

test "Modules.ResolverSkipsTheSymlinkProbeOnAFilesystemThatCannotHoldOne" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(false);

    // No `stat` expectation on purpose: that is the assertion. A stat here
    // would be a directory walk asking a filesystem whose format has already
    // answered, which is what this capability exists to avoid -- and the mock
    // panics on an unexpected call, so the absence proves the absence.
    try std.testing.expect(file_resolver("libtest.so") == null);
}

test "Modules.ResolverShouldReturnNullIfIteratorCreationFails" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    // A failed probe of the direct path is not conclusive: the VFS first asks
    // whether the path could name a symlink. This mock says no, so the scan
    // below is what decides.
    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(false);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    try std.testing.expect(file_resolver("libtest.so") == null);
}

test "Modules.ResolverShouldReturnNullIfFileNotFoundInDirectory" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    // A failed probe of the direct path is not conclusive: the VFS first asks
    // whether the path could name a symlink. This mock says no, so the scan
    // below is what decides.
    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(false);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    var itmock = try DirectoryIteratorMock.create(std.testing.allocator);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(itmock.get_interface());

    _ = itmock
        .expectCall("next")
        .willReturn(null);

    try std.testing.expect(file_resolver("libtest.so") == null);
}

test "Modules.ResolverShouldReturnAddressIfFileFoundInDirectory" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    // A failed probe of the direct path is not conclusive: the VFS first asks
    // whether the path could name a symlink. This mock says no, so the scan
    // below is what decides.
    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(false);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    var itmock = try DirectoryIteratorMock.create(std.testing.allocator);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(itmock.get_interface());

    _ = itmock
        .expectCall("next")
        .willReturn(.{
        .name = "libtest.so",
        .kind = .File,
    });

    var file_mock = try create_filemock(std.testing.allocator);
    const filenode = kernel.fs.Node.create_file(file_mock.get_interface());

    _ = file_mock
        .expectCall("name")
        .willReturn("libtest.so");

    const GetCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: @Tuple(&[_]type{ []const u8, *kernel.fs.Node })) anyerror!anyerror!void {
            const node_name = args[0];
            const node = args[1];
            node.* = @as(*const kernel.fs.Node, @ptrCast(@alignCast(ctx))).*;
            try std.testing.expectEqualSlices(u8, node_name, "libtest.so");
        }
    };
    _ = dirmock
        .expectCall("get")
        .withArgs(.{"libtest.so"})
        .invoke(&GetCallback.call, &filenode);

    try std.testing.expectEqual(@intFromPtr(&test_mapped_address), @intFromPtr(file_resolver("libtest.so").?.ptr));
}

test "Modules.ResolverShouldReturnNullIfFileIsNotMemoryMapped" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var dirmock = try DirectoryMock.create(std.testing.allocator);
    const dirnode = kernel.fs.Node.create_directory(dirmock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    // A failed probe of the direct path is not conclusive: the VFS first asks
    // whether the path could name a symlink. This mock says no, so the scan
    // below is what decides.
    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(false);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    var itmock = try DirectoryIteratorMock.create(std.testing.allocator);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(itmock.get_interface());

    _ = itmock
        .expectCall("next")
        .willReturn(.{
        .name = "libtest.so",
        .kind = .File,
    });

    _ = itmock
        .expectCall("next")
        .willReturn(null);

    var filemock = try FileMock.create(std.testing.allocator);

    const filenode = kernel.fs.Node.create_file(filemock.get_interface());
    _ = filemock
        .expectCall("ioctl")
        .withArgs(.{ @as(i32, @backingInt(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)), interface.mock.any{} })
        .willReturn(0);

    _ = filemock
        .expectCall("name")
        .willReturn("libtest.so");

    const GetCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: @Tuple(&[_]type{ []const u8, *kernel.fs.Node })) anyerror!anyerror!void {
            const node_name = args[0];
            const node = args[1];
            node.* = @as(*const kernel.fs.Node, @ptrCast(@alignCast(ctx))).*;
            try std.testing.expectEqualSlices(u8, node_name, "libtest.so");
        }
    };
    _ = dirmock
        .expectCall("get")
        .withArgs(.{"libtest.so"})
        .invoke(&GetCallback.call, &filenode);

    try std.testing.expect(file_resolver("libtest.so") == null);
}

test "Modules.ResolverFindsTheLibraryFromTheDirectProbe" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    var filemock = try create_filemock(std.testing.allocator);

    _ = filemock
        .expectCall("name")
        .willReturn("libtest.so");

    const filenode = kernel.fs.Node.create_file(filemock.get_interface());

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(filenode);

    // No directory mock on purpose: a resolution that still walked /lib would
    // ask the filesystem a second time, which this mock rejects.
    try std.testing.expectEqual(@intFromPtr(&test_mapped_address), @intFromPtr(file_resolver("libtest.so").?.ptr));
}

test "Modules.ResolverRemembersALibraryThatIsNotThere" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib/libtest.so"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    _ = fs_mock
        .expectCall("get")
        .withArgs(.{"/lib"})
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    _ = fs_mock
        .expectCall("supports_symlinks")
        .times(interface.mock.any{})
        .willReturn(false);

    // The second lookup must ask the filesystem nothing: the miss is cached,
    // so any call the mock receives here is a failure.
    try std.testing.expect(file_resolver("libtest.so") == null);
    try std.testing.expect(file_resolver("libtest.so") == null);
}

test "Modules.ReadImageRewindsAndCompletesPartialReads" {
    var mock = try FileMock.create(std.testing.allocator);
    var file = mock.get_interface();
    defer file.interface.delete();
    _ = mock.expectCall("seek").withArgs(.{ @as(i64, 0), @as(i32, c.SEEK_SET) }).willReturn(@as(i64, 0));
    const Reader = struct {
        pub fn call(_: ?*const anyopaque, args: @Tuple(&.{[]u8})) anyerror!isize {
            const n = @min(args[0].len, 37);
            @memset(args[0][0..n], 0x5a);
            return @intCast(n);
        }
    };
    _ = mock.expectCall("read").times(interface.mock.any{}).invoke(&Reader.call, null);
    const image = try read_image(&file, std.testing.allocator, 512);
    defer std.testing.allocator.free(image);
    for (image) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
}

test "Modules.ReadImageReleasesMemoryOnReadAndSeekErrors" {
    for ([_]isize{ -1, 513, 0 }) |result| {
        var mock = try FileMock.create(std.testing.allocator);
        var file = mock.get_interface();
        defer file.interface.delete();
        _ = mock.expectCall("seek").willReturn(@as(i64, 0));
        _ = mock.expectCall("read").willReturn(result);
        const expected = if (result == 0) kernel.errno.ErrnoSet.ExecFormatError else kernel.errno.ErrnoSet.InputOutputError;
        try std.testing.expectError(expected, read_image(&file, std.testing.allocator, 512));
    }
    var mock = try FileMock.create(std.testing.allocator);
    var file = mock.get_interface();
    defer file.interface.delete();
    _ = mock.expectCall("seek").willReturn(kernel.errno.ErrnoSet.InputOutputError);
    try std.testing.expectError(kernel.errno.ErrnoSet.InputOutputError, read_image(&file, std.testing.allocator, 512));
}

test "Modules.ResolverRejectsInvalidComponentsWithoutFilesystemCalls" {
    _ = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();
    for ([_][]const u8{ "", ".", "..", "../libc.so", "a/b", "a\x00b" }) |name| {
        try std.testing.expect(file_resolver(name) == null);
    }
}

test "Modules.ResolverBoundsNegativeEntriesAndKeyBytes" {
    init(std.testing.allocator);
    defer deinit();
    resolver_token = 1;
    var buffer: [32]u8 = undefined;
    for (0..max_negative_entries + 10) |i| {
        cache_resolution(try std.fmt.bufPrint(&buffer, "missing-{d}", .{i}), null);
    }
    try std.testing.expectEqual(max_negative_entries, negative_entries);
    clear_resolver_cache();
    var large: [3000]u8 = @splat('a');
    cache_resolution(&large, null);
    large[0] = 'b';
    cache_resolution(&large, null);
    try std.testing.expectEqual(@as(usize, 1), negative_entries);
    try std.testing.expectEqual(@as(usize, 3000), negative_bytes);
}

test "Modules.ResolverRetriesTransientFailures" {
    var mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();
    _ = mock.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(false);
    _ = mock.expectCall("get").withArgs(.{"/lib/libretry.so"}).willReturn(kernel.errno.ErrnoSet.InputOutputError);
    _ = mock.expectCall("get").withArgs(.{"/lib"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    try std.testing.expect(file_resolver("libretry.so") == null);
    try std.testing.expectEqual(@as(usize, 0), negative_entries);
    var file = try create_filemock(std.testing.allocator);
    _ = file.expectCall("name").willReturn("libretry.so");
    _ = mock.expectCall("get").withArgs(.{"/lib/libretry.so"}).willReturn(kernel.fs.Node.create_file(file.get_interface()));
    try std.testing.expect(file_resolver("libretry.so") != null);
}

test "Modules.ResolverDiscardsResultsWhenNamespaceChanges" {
    var mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();
    _ = mock.expectCall("supports_symlinks").times(interface.mock.any{}).willReturn(false);
    _ = mock.expectCall("get").withArgs(.{"/lib/libnew.so"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    _ = mock.expectCall("get").withArgs(.{"/lib"}).willReturn(kernel.errno.ErrnoSet.NoEntry);
    try std.testing.expect(file_resolver("libnew.so") == null);
    try std.testing.expectEqual(@as(usize, 1), negative_entries);
    // MountPoints tests exercise real mount/umount operations. Advance that
    // generation here to check the resolver consumes the invalidation token.
    fs.get_vfs().mount_points.generation += 1;
    var file = try create_filemock(std.testing.allocator);
    _ = file.expectCall("name").willReturn("libnew.so");
    _ = mock.expectCall("get").withArgs(.{"/lib/libnew.so"}).willReturn(kernel.fs.Node.create_file(file.get_interface()));
    try std.testing.expect(file_resolver("libnew.so") != null);
    try std.testing.expectEqual(@as(usize, 0), negative_entries);
    fs.get_vfs().mount_points.root.?.info = @import("fs/mount_points.zig").MountInfo.init("root", "romfs", "rw");
    try std.testing.expect(file_resolver("libnew.so") == null);
    try std.testing.expectEqual(@as(usize, 0), resolver_cache.count());
}

test "Modules.ResolverCacheAllocationFailuresLeaveAnswersUncached" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        init(failing.allocator());
        defer deinit();
        resolver_token = 1;
        cache_resolution("missing.so", null);
        try std.testing.expectEqual(@as(usize, 0), resolver_cache.count());
        try std.testing.expectEqual(@as(usize, 0), negative_entries);
    }
}

test "Modules.UnmappedDlopenReturnsAnErrorWithoutPanicking" {
    var mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();
    var file = try FileMock.create(std.testing.allocator);
    _ = file.expectCall("ioctl").willReturn(0);
    _ = mock.expectCall("get").withArgs(.{"unmapped"}).willReturn(kernel.fs.Node.create_file(file.get_interface()));
    try std.testing.expectError(kernel.errno.ErrnoSet.NotImplemented, load_shared_library("/unmapped", std.testing.allocator, 123));
}
