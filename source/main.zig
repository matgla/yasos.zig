//
// main.zig
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

const board = @import("board");
const config = @import("config");
const hal = @import("hal");

const kernel = @import("kernel");
const yasld = @import("yasld");
const DumpHardware = kernel.DumpHardware;

const RomFs = @import("fs/romfs/romfs.zig").RomFs;
const RamFs = @import("fs/ramfs/ramfs.zig").RamFs;
const RamFsTier = @import("fs/ramfs/ramfs.zig").Tier;
const FatFs = @import("fs/fatfs/fatfs.zig").FatFs;
const mounter = @import("fs/mounter.zig");

const panic_helper = @import("arch").panic;
const arch = @import("arch");

const mpu_kernel_protection = if (@hasDecl(config.process, "use_mpu_kernel_protection"))
    config.process.use_mpu_kernel_protection
else
    false;

// Off unless a config asks for it: the whole-PSRAM write/read-back was a
// bring-up check and costs about half the boot (see the Kconfig help).
const external_memory_post = if (@hasDecl(config, "instrumentation") and
    @hasDecl(config.instrumentation, "external_memory_post"))
    config.instrumentation.external_memory_post
else
    false;

// RP2350-only board bring-up (overclock + external PSRAM). Other targets (e.g.
// the QEMU mps2-an505 build) skip it entirely — see initialize_board().
const is_rp2350 = std.mem.eql(u8, config.cpu.cpu, "rp2350");

// Overclock support — exported from crt.zig, called after UART init
extern fn apply_overclock() u32;
extern fn overclock_get_target_khz() u32;
extern fn overclock_get_vreg_code() u32;
extern fn overclock_get_vco_freq() u32;
extern fn overclock_get_postdiv1() u32;
extern fn overclock_get_postdiv2() u32;
extern fn overclock_is_enabled() u32;
// Clock verification — FC0 readings taken at the end of apply_overclock()
extern fn overclock_get_measured_clk_peri_khz() u32;
extern fn overclock_get_measured_clk_sys_khz() u32;
extern fn overclock_get_expected_clk_peri_khz() u32;
extern fn overclock_clk_peri_mismatch() u32;
extern fn overclock_clk_sys_mismatch() u32;
// Register dump functions
extern fn overclock_read_qmi_timing() u32;
extern fn overclock_read_qmi_rfmt() u32;
extern fn overclock_read_qmi_rcmd() u32;
extern fn overclock_read_pll_sys_cs() u32;
extern fn overclock_read_pll_sys_fbdiv() u32;
extern fn overclock_read_pll_sys_prim() u32;
extern fn overclock_read_clk_sys_selected() u32;
extern fn overclock_read_clk_ref_selected() u32;
extern fn overclock_read_powman_vreg() u32;

comptime {
    _ = @import("arch");
}

fn get_log_level() std.log.Level {
    if (config.instrumentation.log_debug) {
        return .debug;
    }
    if (config.instrumentation.log_info) {
        return .info;
    }
    if (config.instrumentation.log_warning) {
        // `.warn`, not `.warning`: std.log.Level spells it the short way, so
        // this branch failed to compile and CONFIG_INSTRUMENTATION_LOG_WARNING
        // could never be turned on -- the one log level nothing had selected.
        return .warn;
    }
    if (config.instrumentation.log_error) {
        return .err;
    }
    return .err;
}

pub const std_options: std.Options = .{
    .page_size_max = 4 * 1024,
    .page_size_min = 1 * 1024,
    .logFn = kernel.kernel_stdout_log,
    .log_level = get_log_level(),
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{
            .scope = .yasld,
            .level = .info,
        },
        .{
            .scope = .@"mmc/sdio",
            .level = .debug,
        },
        // `.loader` deliberately has no override any more. It used to sit at
        // info to surface `release_executable: pid=.. kernel_used=..
        // alloc_count=..`, the kernel-heap-leak trend behind tcc "memory full"
        // on tiny inputs — but that is two blocking console writes on every
        // spawn, and the suite spawns thousands of times. Those counters now go
        // out through perf.trace (source/kernel/modules.zig), which speaks only
        // when the build is configured for profiling.
    },
};

pub const os = struct {
    pub const PATH_MAX = 128;
};

// ----------------------------------------------------------------------------
// Hybrid /tmp
//
// A RamFs mounted at /tmp over the board's `temp_ram` region: a compile writes
// its output there and the loader reads it straight back, so both are memcpy
// rather than SD-card traffic. The arena is deliberately a dedicated region and
// not the process pool — an unbounded /tmp RamFs carved out of `process_ram`
// starved code and heap and was a net loss. A file that outgrows
// `max_file_size`, or that the arena can no longer hold, spills to
// `spill_directory` on the SD card and behaves exactly as it did before.
//
// /tmp is an empty directory in the romfs (build_rootfs.sh) that this mounts
// over. On a board whose memory layout exposes no Temp-owned region the mount
// still happens, with a per-file limit of zero: every body spills on its first
// write, which is what /tmp did back when it was a symlink into the spill
// directory.
// ----------------------------------------------------------------------------
const tmpfs = struct {
    const has_config = @hasDecl(config, "tmpfs");
    const enabled: bool = if (has_config) config.tmpfs.enable else false;
    const page_size: usize = if (has_config) config.tmpfs.page_size else 256;
    const max_file_size: usize = if (has_config) config.tmpfs.max_file_size else 64 * 1024;
    const arena_reserve: usize = if (has_config) config.tmpfs.arena_reserve else 8 * 1024;
    /// Only a default now: /etc/fstab's `spill=` on the tmpfs line wins.
    const spill_directory: []const u8 = if (has_config) config.tmpfs.spill_directory else "/var/tmp";
};

const TmpMemoryPoolType = kernel.memory.heap.TmpMemoryPool(tmpfs.page_size);
const TmpPageAllocatorType = kernel.memory.heap.TmpPageAllocator(TmpMemoryPoolType);

var tmp_memory_pool: ?TmpMemoryPoolType = null;
var tmp_page_allocator: ?TmpPageAllocatorType = null;
var tmp_tier: ?RamFsTier = null;

/// The spill directory comes off with its mount (`umount /var`) once no /tmp
/// file has its body there, and is used again when a mount covers it.
var tmp_spill_user: kernel.fs.mount_api.User = undefined;

fn release_tmp_spill() anyerror!void {
    try tmp_tier.?.detach();
}

fn reattach_tmp_spill() void {
    mounter.mkdir_parents(tmp_tier.?.directory) catch |err| {
        kernel.log.warn("/tmp: can't create spill directory {s}: {s}", .{ tmp_tier.?.directory, @errorName(err) });
    };
    tmp_tier.?.reattach();
}

/// The kernel log lets go of /var the same way, and logs to it again once it
/// is real storage -- a RAM /var would grow the kernel heap without bound.
const log_user: kernel.fs.mount_api.User = .{
    .path = kernel.file_log.directory,
    .release = &kernel.file_log.release,
    .reattach = &reattach_file_log,
};

fn reattach_file_log() void {
    if (mounter.is_persistent("/var")) kernel.file_log.reattach();
}

/// Read by /proc/meminfo (source/kernel/process/meminfo_file.zig) through the
/// root module, so a target without a /tmp arena simply reports zero.
pub fn get_tmp_memory_usage() usize {
    if (tmp_memory_pool) |pool| {
        return pool.get_used_size();
    }
    return 0;
}

/// High-water mark of the /tmp arena. Reported next to the live figure because
/// the arena is sized below the largest file it may be handed: an overflow is
/// not an error, it is a quiet move to the SD card, and only the peak shows it.
pub fn get_tmp_memory_peak() usize {
    if (tmp_memory_pool) |pool| {
        return pool.get_peak_size();
    }
    return 0;
}

fn tmp_arena_free_bytes(context: *anyopaque) usize {
    const pool: *TmpMemoryPoolType = @ptrCast(@alignCast(context));
    const used = pool.get_used_size();
    return if (pool.memory_size > used) pool.memory_size - used else 0;
}

fn find_temp_memory_region() ?struct { start: usize, size: usize } {
    for (hal.memory.get_memory_layout()) |region| {
        if (region.owner == .Temp and region.size >= tmpfs.page_size) {
            return .{ .start = region.start_address, .size = region.size };
        }
    }
    return null;
}

/// Set up the arena over the board's Temp region, or return null when the board
/// has none — /tmp still mounts in that case, it just holds nothing in memory.
fn prepare_tmp_arena(kernel_allocator: std.mem.Allocator, spill_directory: []const u8) ?std.mem.Allocator {
    const region = find_temp_memory_region() orelse return null;

    const start = std.mem.alignForward(usize, region.start, tmpfs.page_size);
    const end = std.mem.alignBackward(usize, region.start + region.size, tmpfs.page_size);
    if (end <= start) {
        return null;
    }
    const arena_memory: [*]align(tmpfs.page_size) u8 = @ptrFromInt(start);

    tmp_memory_pool = TmpMemoryPoolType.init(kernel_allocator, arena_memory[0 .. end - start]) catch |err| {
        kernel.log.err("can't create the /tmp arena at 0x{x}: {s}", .{ start, @errorName(err) });
        return null;
    };
    tmp_page_allocator = TmpPageAllocatorType.init(&tmp_memory_pool.?);

    kernel.log.info("/tmp: {d} KiB arena at 0x{x}, files over {d} B spill to '{s}'", .{
        (end - start) / 1024,
        start,
        tmpfs.max_file_size,
        spill_directory,
    });
    return tmp_page_allocator.?.allocator();
}

/// Where the tiered /tmp spills. Copied here because the fstab text it came
/// from is freed once boot has mounted everything.
var tmp_spill_buffer: [64]u8 = undefined;

/// The mounter's `tmpfs` type: the hybrid RAM/disk /tmp over the board's Temp
/// region. There is one arena and one tier, so there is at most one tmpfs.
/// Without CONFIG_TMPFS_ENABLE it is a plain RamFs -- /tmp is still writable,
/// it just lives on the kernel heap.
fn make_tmp_filesystem(kernel_allocator: std.mem.Allocator, requested_spill: []const u8) anyerror!kernel.fs.IFileSystem {
    if (comptime !tmpfs.enabled) {
        @import("fs/ramfs/ramfs_data.zig").kernel_heap_headroom = &kernel.memory.heap.malloc.headroom;
        return try (try RamFs.InstanceType.init(kernel_allocator)).interface.new(kernel_allocator);
    }
    if (tmp_tier != null) return kernel.errno.ErrnoSet.DeviceOrResourceBusy;
    const spill = if (requested_spill.len != 0) requested_spill else tmpfs.spill_directory;
    if (spill.len > tmp_spill_buffer.len) return kernel.errno.ErrnoSet.NameTooLong;
    @memcpy(tmp_spill_buffer[0..spill.len], spill);
    const spill_directory = tmp_spill_buffer[0..spill.len];

    const maybe_arena = prepare_tmp_arena(kernel_allocator, spill_directory);
    // Without an arena every body spills on its first write, which is exactly
    // what /tmp did when it was a symlink into the spill directory — only the
    // tree stays in memory, and that is a few dozen bytes per file.
    const allocator = maybe_arena orelse kernel_allocator;
    const max_file_size: usize = if (maybe_arena == null) 0 else tmpfs.max_file_size;

    tmp_tier = RamFsTier.init(kernel.fs.get_ivfs(), spill_directory, max_file_size);
    tmp_spill_user = .{ .path = spill_directory, .release = &release_tmp_spill, .reattach = &reattach_tmp_spill };
    kernel.fs.mount_api.register_user(&tmp_spill_user) catch {};
    if (maybe_arena != null) {
        tmp_tier.?.set_arena(.{
            .context = &tmp_memory_pool.?,
            .free_bytes = &tmp_arena_free_bytes,
        }, tmpfs.arena_reserve);
    }

    return try (try RamFs.InstanceType.init_tiered(allocator, &tmp_tier.?)).interface.new(allocator);
}

fn initialize_board() void {
    try board.uart.uart0.init(.{
        .baudrate = kernel.driver.console_baudrate,
    });

    kernel.stdout.set_output(&board.uart.uart0, @TypeOf(board.uart.uart0).write_some_opaque);

    // Publish the console's receive-loss counters as /proc/uart. Backends that
    // do not track them report zeros.
    kernel.process.uart_stats.set_provider(&struct {
        fn get() kernel.process.uart_stats.Stats {
            const stats = board.uart.uart0.rx_stats();
            return .{
                .bytes = stats.bytes,
                .overruns = stats.overruns,
                .dropped = stats.dropped,
                .fifo_full = stats.fifo_full,
                .framing_errors = stats.framing_errors,
                .max_overrun_gap_us = stats.max_overrun_gap_us,
                .max_late_gap_us = stats.max_late_gap_us,
                .drain_skips = stats.drain_skips,
            };
        }
    }.get);

    if (comptime is_rp2350) {
        // Publish the XIP cache counters as /proc/xip. Always on rather than
        // behind the profiling config: the whole point is to be able to bracket
        // an ordinary compile on an ordinary build, and a measurement that
        // needs its own firmware is a measurement that does not get taken.
        kernel.process.xip_stats.set_sampler(&struct {
            fn get() kernel.process.xip_stats.Sample {
                const counters = hal.xip.sample_and_clear();
                return .{
                    .hit = counters.hit,
                    .acc = counters.acc,
                    .saturated = counters.acc == hal.xip.saturation_value or
                        counters.hit == hal.xip.saturation_value,
                };
            }
        }.get);

        const oc_result = apply_overclock();

        // Reconfigure UART baud — apply_overclock switches clk_peri to PLL_USB (48 MHz)
        board.uart.uart0.set_baudrate(kernel.driver.console_baudrate);

        // Dump registers AFTER overclock
        if (oc_result != 0) {
            kernel.log.err("overclock FAILED with code {d}", .{oc_result});
        }

        // apply_overclock() measured what the clocks actually became. Say so
        // loudly when they missed: a short clk_peri moves the console off the
        // baud the host is listening at, and without this line the only symptom
        // is a port full of garbage that reads as a dead board. The baud
        // programmed above already used the measured value, so this is legible.
        if (overclock_clk_peri_mismatch() != 0) {
            kernel.log.err("clk_peri is {d} kHz, expected {d} kHz -- console baud re-derived from the measurement; core voltage is likely too low for PLL_USB's 1200 MHz VCO", .{
                overclock_get_measured_clk_peri_khz(),
                overclock_get_expected_clk_peri_khz(),
            });
        }
        if (overclock_clk_sys_mismatch() != 0) {
            kernel.log.err("clk_sys is {d} kHz, expected {d} kHz -- PLL_SYS did not reach the configured frequency", .{
                overclock_get_measured_clk_sys_khz(),
                overclock_get_target_khz(),
            });
        }

        // Publish the core regulator's in-regulation flag as /proc/vreg, sampled
        // by the system tick. Registered only now that apply_overclock has moved
        // the regulator to its final setpoint and let it settle, so the move
        // itself is not counted as a sag.
        const setpoint_mv: u16 = if (hal.cpu.vreg_vsel()) |vsel| DumpHardware.vselToMv(vsel) else 0;
        kernel.process.vreg_stats.set_sampler(&hal.sensors.vreg_in_regulation, setpoint_mv);

        // Publish the die temperature sensor as /proc/temp.
        if (hal.sensors.enable_temperature_sensor()) {
            kernel.process.temp_stats.set_provider(&hal.sensors.read_temperature_raw);
        } else {
            kernel.log.err("ADC did not come up; /proc/temp reports nothing", .{});
        }

        if (hal.external_memory.enable()) {
            hal.external_memory.dump_configuration();
            if (external_memory_post and !hal.external_memory.perform_post()) {
                kernel.log.err("External memory post test failed", .{});
            }
        } else {
            kernel.log.err("No external memory found", .{});
        }
    }
}

// must be in root module file, otherwise won't be used
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    kernel.log.err("****************** PANIC **********************", .{});
    kernel.log.err("KERNEL PANIC: {s}", .{msg});
    panic_helper.dump_stack_trace(kernel.log, @returnAddress());
    kernel.log.err("***********************************************", .{});
    // Under QEMU (semihosting enabled) terminate the emulator with a non-zero
    // status instead of spinning forever, so a hard fault / panic ends the run
    // and surfaces as a failure to the test harness. No-op on real hardware.
    panic_helper.exit_if_emulated(134);
    while (true) {}
}

fn allocate_filesystem(allocator: std.mem.Allocator, fs: anytype) !kernel.fs.IFileSystem {
    if (@typeInfo(@TypeOf(fs)) == .error_union) {
        return (fs catch |err| {
            kernel.log.err("Can't initialize {s} with an error: {s}", .{ @typeName(@typeInfo(@TypeOf(fs)).error_union.payload), @errorName(err) });
            return err;
        }).interface.new(allocator) catch |err| {
            kernel.log.err("Can't allocate {s} with an error: {s}", .{ @typeName(@typeInfo(@TypeOf(fs)).error_union.payload), @errorName(err) });
            return err;
        };
    } else {
        return fs.interface.new(allocator) catch |err| {
            kernel.log.err("Can't allocate {s} with an error: {s}", .{ @typeName(@TypeOf(fs)), @errorName(err) });
            return err;
        };
    }
}

fn mount_filesystem(ifs: kernel.fs.IFileSystem, comptime point: []const u8) !void {
    kernel.fs.get_vfs().mount_filesystem(point, ifs) catch |err| {
        kernel.log.err("Can't mount '{s}' with type '{s}': {s}", .{ point, ifs.interface.name(), @errorName(err) });
    };
}

/// The QEMU host-exchange window as a disk, `/dev/fatdisk0`. Whether it holds
/// one FAT volume (the usual /mnt image) or a partitioned SD card image is for
/// the block layer to find out; /etc/fstab decides what gets mounted.
fn add_fatdisk(allocator: std.mem.Allocator, driverfs: *kernel.driver.fs.DriverFs) !void {
    const name = "fatdisk0";
    const fat_driver_base = try kernel.driver.FlashDriver(@TypeOf(board.flash.fatdisk0)).InstanceType.create(allocator, board.flash.fatdisk0, name);
    var fat_driver = try fat_driver_base.interface.new(allocator);
    try driverfs.data().append(fat_driver, name);
    var node = try fat_driver.interface.node();
    defer node.delete();
    // `as_file()` lends the node's interface; the block layer clones it.
    if (node.as_file()) |file| {
        try kernel.driver.block.add_disk(name, file);
    }
}

// fn initialize_virtual_terminals(allocator: std.mem.Allocator) !void {
//     const vt_driver = try kernel.driver.VtDriver(kernel.driver.).InstanceType.create(allocator, "vt");
//     var vt_node = try vt_driver.interface.node();
//     defer vt_node.delete();
//     var maybe_vtfile = vt_node.as_file();
//     if (maybe_vtfile) |*vtfile| {
//         try mount_filesystem(try allocate_filesystem(allocator, RomFs.InstanceType.init(allocator, vtfile.*, 0)), "/dev/vt");
//         vtfile.interface.delete();
//     }
// }

fn initialize_filesystem(allocator: std.mem.Allocator) !void {
    kernel.fs.vfs_init(allocator);
    var driverfs = try kernel.driver.fs.DriverFs.InstanceType.init(allocator);
    const uart0name = "uart0";
    const uart_driver = try (try kernel.driver.UartDriver(board.uart.uart0).InstanceType.create(allocator, uart0name)).interface.new(allocator);
    try driverfs.data().append(uart_driver, uart0name);
    try driverfs.data().append(try uart_driver.clone(), "stdin");
    try driverfs.data().append(try uart_driver.clone(), "stdout");
    try driverfs.data().append(try uart_driver.clone(), "stderr");
    try driverfs.data().append(try (try kernel.driver.MemoryDeviceDriver.InstanceType.create(allocator, .null, "null")).interface.new(allocator), "null");
    try driverfs.data().append(try (try kernel.driver.MemoryDeviceDriver.InstanceType.create(allocator, .zero, "zero")).interface.new(allocator), "zero");

    const flash0name = "flash0";
    const flash_driver_base = try kernel.driver.FlashDriver(@TypeOf(board.flash.flash0)).InstanceType.create(allocator, board.flash.flash0, flash0name);
    var flash_driver = try flash_driver_base.interface.new(allocator);
    try driverfs.data().append(flash_driver, flash0name);
    var maybe_mmcnode: ?kernel.fs.Node = null;
    var maybe_mmcdriver: ?kernel.driver.IDriver = null;
    if (@hasDecl(board, "mmc")) {
        inline for (@typeInfo(board.mmc).@"struct".decl_names) |m| {
            comptime var i: i32 = 0;
            const name = std.fmt.comptimePrint("mmc{d}", .{i});

            maybe_mmcdriver = try (try kernel.driver.MmcDriver.InstanceType.create(allocator, &@field(board.mmc, name), name)).interface.new(allocator);
            driverfs.data().append(maybe_mmcdriver.?, name) catch {};
            kernel.log.info("adding mmc driver: {s}", .{m});
            i = i + 1;
            maybe_mmcnode = try maybe_mmcdriver.?.interface.node();
        }
    } else {
        kernel.log.debug("Board has no mmc interfaces", .{});
    }

    // Display, when the board has one. Registered as /dev/fb0. On the QEMU
    // host-test target this is the shared-memory framebuffer that
    // scripts/fbview.py renders into a window; on a real board it will be the
    // VGA/DVI extension panel behind the same hal interface.
    if (@hasDecl(board, "display")) {
        inline for (@typeInfo(board.display).@"struct".decl_names, 0..) |decl_name, i| {
            const name = std.fmt.comptimePrint("fb{d}", .{i});
            const display = &@field(board.display, decl_name);
            const display_driver = try (try kernel.driver.DisplayDriver(@TypeOf(display.*)).InstanceType.create(allocator, display, name)).interface.new(allocator);
            driverfs.data().append(display_driver, name) catch {};
            kernel.log.info("adding display driver: {s}", .{name});
        }
    } else {
        kernel.log.debug("Board has no display interfaces", .{});
    }

    try driverfs.data().load_all();

    // Disks: publish their partitions as /dev/<disk>p<N>.
    kernel.driver.block.init(driverfs, allocator);
    if (maybe_mmcnode) |*mmcnode| {
        if (mmcnode.as_file()) |file| {
            kernel.driver.block.add_disk("mmc0", file) catch |err| {
                kernel.log.err("mmc0: {s}", .{@errorName(err)});
            };
        }
        mmcnode.delete();
    }
    // Host-readable FAT window (QEMU host-test targets only). The host
    // pre-loads an image into it (scripts/qemu_fatdisk_run.py) -- a plain FAT
    // volume for /mnt, or a whole partitioned SD image.
    if (@hasDecl(board.flash, "fatdisk0")) {
        add_fatdisk(allocator, &driverfs) catch |err| {
            kernel.log.err("fatdisk0: {s}", .{@errorName(err)});
        };
    }

    // Not released: RomFs keeps using the flash file it is handed without
    // taking a reference of its own, for as long as the system runs.
    var node = try flash_driver.interface.node();
    const flash = node.as_file() orelse return error.NoRootFilesystem;
    // On the rp2350 board the rootfs lives 1 MB into flash; boards may
    // override this (e.g. the QEMU build embeds the romfs at the mapping base).
    const romfs_offset: usize = if (@hasDecl(board, "romfs_offset")) board.romfs_offset else 0x100000;
    const romfs = try allocate_filesystem(allocator, RomFs.InstanceType.init(allocator, flash, romfs_offset));
    try kernel.fs.get_vfs().mount_filesystem_with_info("/", romfs, kernel.fs.MountInfo.init("/dev/flash0", "romfs", "ro"));
    // /dev before anything else: fstab sources are device paths.
    try kernel.fs.get_vfs().mount_filesystem_with_info("/dev", try allocate_filesystem(allocator, driverfs), kernel.fs.MountInfo.init("devfs", "devfs", "rw"));

    // Everything else comes from /etc/fstab (source/fs/mounter.zig), or from
    // a RAM-only default when the image has none.
    mounter.init(allocator, &make_tmp_filesystem, &kernel.memory.heap.malloc.headroom);
    if (mounter.read_file(allocator, "/etc/fstab")) |fstab| {
        defer allocator.free(fstab);
        mounter.mount_all(fstab);
    } else {
        kernel.log.err("no /etc/fstab, mounting RAM-only defaults", .{});
        mounter.mount_all(mounter.default_fstab);
    }

    // Persist the kernel log -- only onto real storage; on a RAM fallback it
    // would just grow the kernel heap without bound.
    if (mounter.is_persistent("/var")) {
        kernel.file_log.init();
    }
    kernel.fs.mount_api.register_user(&log_user) catch {};
}

fn attach_default_filedescriptors_to_root_process(process: *kernel.process.Process) !void {
    kernel.log.info("setting default streams", .{});
    const maybe_stdin = kernel.fs.get_ivfs().interface.get("/dev/stdin") catch null;
    if (maybe_stdin) |stdin| {
        _ = try process.attach_file_with_fd(0, "/dev/stdin", stdin);
    }

    const maybe_stdout = kernel.fs.get_ivfs().interface.get("/dev/stdout") catch null;
    if (maybe_stdout) |stdout| {
        _ = try process.attach_file_with_fd(1, "/dev/stdout", stdout);
    }

    const maybe_stderr = kernel.fs.get_ivfs().interface.get("/dev/stderr") catch null;
    if (maybe_stderr) |stderr| {
        _ = try process.attach_file_with_fd(2, "/dev/stderr", stderr);
    }
}
const KernelAllocator = kernel.memory.heap.malloc.KernelAllocatorType;

fn get_current_pid() i32 {
    const process = kernel.process.process_manager.instance.get_current_process();
    return @intCast(process.pid);
}

export fn kernel_process() void {
    const process = kernel.process.process_manager.instance.get_current_process();
    attach_default_filedescriptors_to_root_process(process) catch {
        kernel.log.err("Can't attach default streams to root process", .{});
    };
    const pid = process.pid;
    // this loads executable replacing current image
    const sh = kernel.dynamic_loader.load_executable("/bin/sh", process.get_process_memory_allocator(), pid) catch |err| {
        kernel.log.err("Executable loading failed with error: {s}", .{@errorName(err)});
        return;
    };
    // The root process is loaded here, never exec'd, so nothing else records
    // what it runs. Without this /proc/self/exe has no target, and a NOMMU
    // shell that re-execs itself for $(...) and ( ) cannot: pid 1 and every
    // shell vforked from it inherit the (missing) path.
    process.set_executable_path("/bin/sh") catch |err| {
        kernel.log.warn("pid={d}: could not record exe path: {s}", .{ pid, @errorName(err) });
    };

    var arg1: [8]u8 = [_]u8{ '/', 'b', 'i', 'n', '/', 's', 'h', 0 };
    // Layout: [ argv0, NULL (argv terminator), NULL (empty-env terminator) ].
    // crt1 derives `environ = &argv[argc + 1]`, so the trailing NULL must be
    // present even though the init process starts with an empty environment.
    var args: [3][*c]u8 = .{ @ptrCast(&arg1), @ptrFromInt(0), @ptrFromInt(0) };

    _ = sh.main(@ptrCast(&args[0]), 1) catch |err| {
        kernel.log.err("Cannot execute main: {s}", .{@errorName(err)});
    };
}

pub fn splashscreen() void {
    kernel.stdout.write("\n---------------------------------------------\n");
    kernel.stdout.write("|                 YASOS                     |\n");
    DumpHardware.print_hardware();
}

pub export fn main() void {
    var kernel_allocator = KernelAllocator{};
    {
        const allocator = kernel_allocator.allocator();
        initialize_board();
        // After the board, because the PSRAM window's size is only known once
        // external memory has been probed, and that is what the placement
        // assertion checks against.
        kernel.sync.init();
        splashscreen();

        // Release the other cores: after the console exists, so a failed
        // bring-up can say so, and before anything is scheduled, so the
        // cross-core self-test runs against a system nothing else is mutating.
        // A board that cannot start its secondary keeps booting on core 0.
        kernel.smp.start_secondary_cores();

        // Lock the kernel heap and stack away from unprivileged user processes.
        // Must run before any process is scheduled.
        if (mpu_kernel_protection) {
            arch.mpu.enable_kernel_protection();
        }

        kernel.process.process_manager.initialize_process_manager(allocator);
        defer kernel.process.process_manager.deinitialize_process_manager();

        kernel.memory.heap.malloc.set_get_current_pid(&get_current_pid);

        kernel.irq.system_call.init(kernel_allocator.allocator());
        kernel.dynamic_loader.init(allocator);
        defer kernel.dynamic_loader.deinit();
        initialize_filesystem(allocator) catch |err| {
            kernel.log.err("Filesystem initialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer kernel.fs.get_vfs().deinit();

        // Storage is up, so the external memory interface may now switch to a
        // faster read mode if the board has one. It waits until here because
        // changing how long an instruction fetch takes changes the timing of
        // every driver that is still bringing its hardware up -- SD card
        // bring-up on the rp2350 does not survive it. See `enable_fast_reads`
        // in hal/source/raspberry/rp2350/source/external_memory.zig.
        hal.external_memory.enable_fast_reads();

        // we need to get real return address to get back from user mode successfully
        //
        // This call returns twice over: once if creating or scheduling the root
        // process fails, and once at shutdown, when `switch_to_main_task` pops
        // the frame `switch_to_the_first_task` left on MSP a whole system
        // lifetime earlier. The second return needs r4-r11 back, because the
        // compiler parks `root_process`'s value in r4 across the call -- see
        // `switch_to_the_first_task` in source/arch/armv8-m/context_switch.S.
        @call(.never_inline, kernel.spawn.root_process, .{ &kernel_process, kernel.process.process_manager.instance.get_default_stack_size() }) catch |err| {
            kernel.log.err("Cannot start root process: {s}", .{@errorName(err)});
        };
        kernel.log.warn("Root process died", .{});
    }
    _ = @call(.never_inline, KernelAllocator.detect_leaks, .{});
    // kernel system calls are not available here
    _ = board.uart.uart0.write_some("Kernel has halted.\nYou can turn off your PC now!\n") catch 0;
}
