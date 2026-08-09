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
const hal = @import("hal");
const config = @import("config");

const yasld = @import("yasld");

const IFile = @import("fs/fs.zig").IFile;
const fs = @import("fs/vfs.zig");
const FileMemoryMapAttributes = @import("fs/ifile.zig").FileMemoryMapAttributes;
const IoctlCommonCommands = @import("fs/ifile.zig").IoctlCommonCommands;

const c = @import("libc_imports").c;

var kernel_allocator: std.mem.Allocator = undefined;

// Memoizes library-name -> XIP base resolved by file_resolver. /lib is a
// read-only memory-mapped (romfs/XIP) directory, so a name's mapped address is
// fixed for the lifetime of the system. Without this, every imported library
// of every spawned process triggered a full linear /lib directory scan (FAT
// iteration + per-entry ioctl), which the loader phase timing showed dominates
// load time (~1-1.7 ms per imported lib, vs ~0.1 ms relocating its GOT).
var resolver_cache: std.StringHashMap(*const anyopaque) = undefined;

const ModuleContext = struct {
    name: []const u8,
    address: ?*const anyopaque,
};

const kernel = @import("kernel.zig");
const perf = @import("interrupts/perf_profile.zig");

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

fn file_resolver(name: []const u8) ?*const anyopaque {
    if (resolver_cache.get(name)) |address| {
        return address;
    }

    var context: ModuleContext = .{
        .name = name,
        .address = null,
    };

    var maybe_node = fs.get_ivfs().interface.get("/lib") catch null;
    if (maybe_node) |*node| {
        defer node.delete();
        var maybe_dir = node.as_directory();
        if (maybe_dir) |*dir| {
            var it = dir.interface.iterator() catch return null;
            defer it.interface.delete();
            while (it.interface.next()) |*entry| {
                var filenode: kernel.fs.Node = undefined;
                dir.interface.get(entry.name, &filenode) catch continue;
                defer filenode.delete();
                if (filenode.as_file()) |f| {
                    if (is_requested_file(f, &context)) {
                        break;
                    }
                }
            }
        }
    }

    if (context.address) |address| {
        // Cache for subsequent lookups. The key must outlive `name` (which
        // points into the transient module being parsed), so dupe it. On any
        // allocation failure just skip caching — correctness is unaffected.
        if (kernel_allocator.dupe(u8, name)) |key| {
            resolver_cache.put(key, address) catch {
                kernel_allocator.free(key);
            };
        } else |_| {}
        return address;
    }
    return null;
}

fn is_requested_file(file: kernel.fs.IFile, context: *ModuleContext) bool {
    if (std.mem.eql(u8, context.name, file.interface.name())) {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };

        var fc: kernel.fs.IFile = file;
        _ = fc.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        if (attr.mapped_address_r) |address| {
            context.address = address;
            return true;
        }
    }
    return false;
}

const ExecutableHandle = struct {
    allocator: std.mem.Allocator,
    executable: ?yasld.Executable,
    memory: ?[]align(16) u8,
};

var modules_list: std.AutoHashMap(c.pid_t, ExecutableHandle) = undefined;
var libraries_list: std.AutoHashMap(c.pid_t, std.DoublyLinkedList) = undefined;

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
        error.DependencyIsNotLibrary,
        => kernel.errno.ErrnoSet.ExecFormatError,
        else => err,
    };
}

pub fn init(allocator: std.mem.Allocator) void {
    log.info("yasld initialization started", .{});
    yasld.loader_init(&file_resolver, allocator, machine_profile);
    // The per-load section-base line is blocking console UART on every spawn, so
    // it rides with the rest of the profiling output rather than being paid for
    // by every run. Faults dump the map anyway (dump_fault_maps below) and
    // /proc/<pid>/maps serves it on demand.
    yasld.set_load_map_logging(perf.enabled);
    modules_list = std.AutoHashMap(c.pid_t, ExecutableHandle).init(allocator);
    libraries_list = std.AutoHashMap(c.pid_t, std.DoublyLinkedList).init(allocator);
    resolver_cache = std.StringHashMap(*const anyopaque).init(allocator);
    vfork_snapshots = std.AutoHashMap(c.pid_t, *VForkSnapshot).init(allocator);
    kernel_allocator = allocator;
}

pub fn deinit() void {
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
    log.debug("load_executable: pid={d} path={s}", .{ pid, path });
    // Start the clock at the path lookup, not at the relocation. For an image
    // the filesystem cannot memory-map (anything outside the XIP romfs -- /tmp,
    // /root on MMC) the copy below reads the whole file, which is the larger
    // half of the load; a window that began after it reported the loader as
    // cheap while the read it hides is exactly what an IO investigation is
    // looking for.
    const load_start_us = hal.time.get_time_us();
    last_executable_load_us = 0; // a load that fails reports nothing, not the previous one
    var node = try fs.get_ivfs().interface.get(path);
    defer node.delete();
    var maybe_file = node.as_file();
    if (maybe_file) |*f| {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = f.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        var header_address: *const anyopaque = undefined;
        var entry = ExecutableHandle{
            .allocator = process_allocator,
            .executable = null,
            .memory = null,
        };
        if (attr.mapped_address_r) |address| {
            header_address = address;
        } else {
            var memory: []align(16) u8 = try process_allocator.alignedAlloc(u8, .@"16", @intCast(f.interface.size()));
            header_address = @ptrCast(&memory[0]);
            entry.memory = memory;
            _ = f.interface.read(memory);
        }
        if (yasld.get_loader()) |loader| {
            const executable = loader.*.load_executable(header_address, process_allocator) catch |err| {
                log.err("loading '{s}' failed: {s}", .{ path, @errorName(err) });
                return map_load_error(err);
            };
            last_executable_load_us = hal.time.get_time_us() - load_start_us;
            log_loader_timing("executable", path, pid, load_start_us);
            release_executable(pid);
            entry.executable = executable;
            modules_list.put(pid, entry) catch |err| return err;
            const exec_ptr: *yasld.Executable = &modules_list.getPtr(pid).?.executable.?;
            return exec_ptr;
        } else {
            log.err("yasld is not initialized", .{});
            return kernel.errno.ErrnoSet.NotPermitted;
        }
    }
    return kernel.errno.ErrnoSet.IsADirectory;
}

pub fn load_shared_library(path: []const u8, process_allocator: std.mem.Allocator, pid: c.pid_t) !*yasld.Module {
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
        _ = f.interface.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        // f.destroy();
        var header_address: *const anyopaque = undefined;

        if (attr.mapped_address_r) |address| {
            header_address = address;
        } else {
            // copy file to memory before running
            @panic("Implement image copying to memory");
        }
        if (yasld.get_loader()) |loader| {
            const library = loader.*.load_library(header_address, process_allocator) catch |err| {
                log.err("loading library '{s}' failed: {s}", .{ path, @errorName(err) });
                return map_load_error(err);
            };
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
    const written = std.fmt.bufPrint(buffer, "{s} {s} 0x{x} 0x{x}\n", .{ name, section, address, size }) catch return 0;
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

pub fn release_shared_library(pid: c.pid_t, library: *yasld.Module) void {
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

pub fn get_executable_for_pid(pid: c.pid_t) ?*yasld.Executable {
    if (!modules_list.contains(pid)) {
        return null;
    }
    if (modules_list.getPtr(pid).?.executable) |*exec| {
        return exec;
    }
    return null;
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
var vfork_snapshots: std.AutoHashMap(c.pid_t, *VForkSnapshot) = undefined;

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

pub fn save_parent_writable_sections(parent_pid: c.pid_t, child_pid: c.pid_t) void {
    if (!vfork_snapshot_enabled) return;
    const exec = get_executable_for_pid(parent_pid) orelse return;

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

pub fn restore_parent_writable_sections(child_pid: c.pid_t) void {
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
    try fs.get_vfs().mount_filesystem("/", fs_mock.get_interface());
    return fs_mock;
}

const FileMock = @import("fs/tests/file_mock.zig").FileMock;
const interface = @import("interface");
const test_mapped_address: usize = 0x1000;
fn create_filemock(allocator: std.mem.Allocator) !*FileMock {
    var file_mock = try FileMock.create(allocator);
    const IoctlCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: std.meta.Tuple(&[_]type{ i32, ?*anyopaque })) !i32 {
            const cmd = args[0];
            try std.testing.expectEqual(cmd, @as(i32, @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)));

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

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
}

test "Modules.ResolverSkipsTheSymlinkProbeOnAFilesystemThatCannotHoldOne" {
    var fs_mock = try create_vfs_for_test(std.testing.allocator);
    defer fs.vfs_deinit();
    init(std.testing.allocator);
    defer deinit();

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
    try std.testing.expectEqual(null, file_resolver("libtest.so"));
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
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(kernel.errno.ErrnoSet.NoEntry);

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
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
        .withArgs(.{"/lib"})
        .willReturn(dirnode);

    var itmock = try DirectoryIteratorMock.create(std.testing.allocator);

    _ = dirmock
        .expectCall("iterator")
        .willReturn(itmock.get_interface());

    _ = itmock
        .expectCall("next")
        .willReturn(null);

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
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
        pub fn call(ctx: ?*const anyopaque, args: std.meta.Tuple(&[_]type{ []const u8, *kernel.fs.Node })) anyerror!anyerror!void {
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

    try std.testing.expectEqual(@as(*const anyopaque, &test_mapped_address), file_resolver("libtest.so"));
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
        .withArgs(.{ @as(i32, @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)), interface.mock.any{} })
        .willReturn(0);

    _ = filemock
        .expectCall("name")
        .willReturn("libtest.so");

    const GetCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: std.meta.Tuple(&[_]type{ []const u8, *kernel.fs.Node })) anyerror!anyerror!void {
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

    try std.testing.expectEqual(null, file_resolver("libtest.so"));
}
