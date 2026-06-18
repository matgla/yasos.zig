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
const FatFs = @import("fs/fatfs/fatfs.zig").FatFs;

const panic_helper = @import("arch").panic;
const arch = @import("arch");

const mpu_kernel_protection = if (@hasDecl(config.process, "use_mpu_kernel_protection"))
    config.process.use_mpu_kernel_protection
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
        return .warning;
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
    .log_scope_levels = &[_]std.log.ScopeLevel{ .{
        .scope = .yasld,
        .level = .info,
    }, .{
        .scope = .@"mmc/sdio",
        .level = .debug,
    }, .{
        // Surface `release_executable: pid=.. kernel_used=.. alloc_count=..` so
        // a kernel-heap leak that accumulates across the (no-reboot) suite —
        // the suspected cause of tcc "memory full" on tiny inputs — shows up as
        // a climbing kernel_used/alloc_count trend in the serial log.
        .scope = .loader,
        .level = .info,
    } },
};

pub const os = struct {
    pub const PATH_MAX = 128;
};

fn initialize_board() void {
    try board.uart.uart0.init(.{
        .baudrate = 921600,
    });

    kernel.stdout.set_output(&board.uart.uart0, @TypeOf(board.uart.uart0).write_some_opaque);

    if (comptime is_rp2350) {
        const oc_result = apply_overclock();

        // Reconfigure UART baud — apply_overclock switches clk_peri to PLL_USB (48 MHz)
        board.uart.uart0.set_baudrate(921600);

        // Dump registers AFTER overclock
        if (oc_result != 0) {
            kernel.log.err("overclock FAILED with code {d}", .{oc_result});
        }

        if (hal.external_memory.enable()) {
            hal.external_memory.dump_configuration();
            if (hal.external_memory.perform_post()) {} else {
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

fn mount_fatdisk(allocator: std.mem.Allocator) !void {
    const fat_driver_base = try kernel.driver.FlashDriver(@TypeOf(board.flash.fatdisk0)).InstanceType.create(allocator, board.flash.fatdisk0, "fatdisk0");
    var fat_driver = try fat_driver_base.interface.new(allocator);
    var fnode = try fat_driver.interface.node();
    defer fnode.delete();
    var maybe_file = fnode.as_file();
    if (maybe_file) |*file| {
        const rootfs = try allocate_filesystem(allocator, FatFs.InstanceType.init(allocator, file.*));
        file.interface.delete();
        try mount_filesystem(rootfs, "/mnt");
    }
}

fn add_mmc_partition_drivers(mmcfile: *kernel.fs.IFile, allocator: std.mem.Allocator, driverfs: anytype) !void {
    var buffer: [1024]u8 = [_]u8{0x00} ** 1024;
    _ = mmcfile.interface.read(buffer[0..]);
    const mbr = kernel.fs.MBR.create(buffer[0..]);
    if (mbr.is_valid()) {
        kernel.log.debug("MBR is valid, partition count: {d}", .{mbr.partitions.len});
        comptime var i: i32 = 0;
        inline for (mbr.partitions) |part| {
            if (part.size_in_sectors != 0) {
                kernel.log.debug("Mounting partition {d}:\n  boot_indicator: {x}\n  start_chs: {d}\n  partition_type: {x}\n  end_chs: {d}\n  start_lba: {x}\n  size: {x} sectors", .{
                    i,
                    part.boot_indicator,
                    part.start_chs,
                    part.partition_type,
                    part.end_chs,
                    part.start_lba,
                    part.size_in_sectors,
                });
                const partname = std.fmt.comptimePrint("mmc{d}p{d}", .{ 0, i });
                const partition_driver_data = try kernel.driver.MmcPartitionDriver.InstanceType.create(allocator, mmcfile.*, partname, part.start_lba, part.size_in_sectors);
                const partition_driver = partition_driver_data.interface.new(allocator) catch |err| {
                    kernel.log.err("Can't create partition driver: {s}", .{@errorName(err)});
                    return;
                };
                driverfs.data().append(partition_driver, partname) catch |err| {
                    kernel.log.err("Can't append partition driver: {s}", .{@errorName(err)});
                    return;
                };
            }
            i += 1;
        }
    } else {
        kernel.log.err("Invalid MBR found", .{});
    }
}

fn initialize_filesystem(allocator: std.mem.Allocator) !void {
    kernel.fs.vfs_init(allocator);
    var driverfs = try kernel.driver.fs.DriverFs.InstanceType.init(allocator);
    const uart0name = "uart0";
    const uart_driver = try (try kernel.driver.UartDriver(board.uart.uart0).InstanceType.create(allocator, uart0name)).interface.new(allocator);
    try driverfs.data().append(uart_driver, uart0name);
    try driverfs.data().append(try uart_driver.clone(), "stdin");
    try driverfs.data().append(try uart_driver.clone(), "stdout");
    try driverfs.data().append(try uart_driver.clone(), "stderr");

    const flash0name = "flash0";
    const flash_driver_base = try kernel.driver.FlashDriver(@TypeOf(board.flash.flash0)).InstanceType.create(allocator, board.flash.flash0, flash0name);
    var flash_driver = try flash_driver_base.interface.new(allocator);
    try driverfs.data().append(flash_driver, flash0name);
    var maybe_mmcnode: ?kernel.fs.Node = null;
    var maybe_mmcdriver: ?kernel.driver.IDriver = null;
    if (@hasDecl(board, "mmc")) {
        inline for (@typeInfo(board.mmc).@"struct".decls) |m| {
            comptime var i: i32 = 0;
            const name = std.fmt.comptimePrint("mmc{d}", .{i});

            maybe_mmcdriver = try (try kernel.driver.MmcDriver.InstanceType.create(allocator, &@field(board.mmc, name), name)).interface.new(allocator);
            driverfs.data().append(maybe_mmcdriver.?, name) catch {};
            kernel.log.info("adding mmc driver: {s}", .{m.name});
            i = i + 1;
            maybe_mmcnode = try maybe_mmcdriver.?.interface.node();
        }
    } else {
        kernel.log.debug("Board has no mmc interfaces", .{});
    }
    try driverfs.data().load_all();

    if (maybe_mmcnode) |*mmcnode| {
        var maybe_mmcfile = mmcnode.as_file();
        if (maybe_mmcfile) |*file| {
            try add_mmc_partition_drivers(file, allocator, &driverfs);
        }
        mmcnode.delete();
    }

    var node = try flash_driver.interface.node();
    const maybe_flashfile = node.as_file();
    if (maybe_flashfile) |flash| {
        // On the rp2350 board the rootfs lives 1 MB into flash; boards may
        // override this (e.g. the QEMU build embeds the romfs at the mapping base).
        const romfs_offset: usize = if (@hasDecl(board, "romfs_offset")) board.romfs_offset else 0x100000;
        try mount_filesystem(try allocate_filesystem(allocator, RomFs.InstanceType.init(allocator, flash, romfs_offset)), "/");
        var root_mounted = false;
        var maybe_mmcpart0 = driverfs.data().get("mmc0p0") catch null;
        if (maybe_mmcpart0) |*mmcnode| {
            var maybe_file = mmcnode.as_file();
            if (maybe_file) |*file| {
                const maybe_rootfs: ?kernel.fs.IFileSystem = allocate_filesystem(allocator, FatFs.InstanceType.init(allocator, file.*)) catch null;
                file.interface.delete();
                if (maybe_rootfs) |rootfs| {
                    if (mount_filesystem(rootfs, "/root")) |_| {
                        root_mounted = true;
                    } else |err| {
                        kernel.log.err("can't mount mmc rootfs at /root: {s}", .{@errorName(err)});
                    }
                }

                mmcnode.delete();
            }
        }

        // Boards without a persistent MMC-backed rootfs (e.g. the QEMU
        // mps2-an505 host-test target) leave /root as a read-only romfs
        // directory, which breaks anything that needs to write there (the tcc
        // smoke suite uploads sources into /root/ci). Fall back to a writable
        // RamFs so /root is usable; it is volatile across resets, which is fine
        // because the smoke harness re-uploads its sources after each relaunch.
        if (!root_mounted) {
            mount_filesystem(try allocate_filesystem(allocator, RamFs.InstanceType.init(allocator)), "/root") catch |err| {
                kernel.log.err("can't mount fallback RamFs at /root: {s}", .{@errorName(err)});
            };
        }
        // /tmp is a romfs symlink to /root/tmp (so the fast process memory pool
        // can reclaim the SRAM the old /tmp RamFs used). Ensure the target dir
        // exists on whichever filesystem backs /root (SD FatFs or RamFs fallback).
        kernel.fs.get_ivfs().interface.mkdir("/root/tmp", 0o777) catch |err| {
            if (err != kernel.errno.ErrnoSet.FileExists) {
                kernel.log.err("can't create /root/tmp: {s}", .{@errorName(err)});
            }
        };
        try mount_filesystem(try allocate_filesystem(allocator, driverfs), "/dev");
        try mount_filesystem(try allocate_filesystem(allocator, kernel.process.ProcFs.InstanceType.init(allocator)), "/proc");

        // Persist the kernel log to the SD card (only when /root is the real
        // MMC-backed rootfs; on the volatile RamFs fallback we skip it to avoid
        // growing the kernel heap without bound).
        if (root_mounted) {
            kernel.file_log.init();
        }

        // Host-readable FAT block device (QEMU host-test target only). When the
        // guest runs under a host-mmap'd RAM the host pre-loads a FAT image into
        // the `fatdisk0` window, so this mounts at /mnt and the host can exchange
        // files with the guest (test sources in, compiled binaries out) without
        // a kernel rebuild. Under a plain-RAM launch the window is garbage so the
        // FatFs mount fails; that is caught and /mnt is simply left unmounted.
        if (@hasDecl(board.flash, "fatdisk0")) {
            mount_fatdisk(allocator) catch |err| {
                kernel.log.info("fatdisk not mounted at /mnt: {s}", .{@errorName(err)});
            };
        }
    }

    return;
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
        splashscreen();

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

        // we need to get real return address to get back from user mode successfully
        @call(.never_inline, kernel.spawn.root_process, .{ &kernel_process, kernel.process.process_manager.instance.get_default_stack_size() }) catch |err| {
            kernel.log.err("Cannot start root process: {s}", .{@errorName(err)});
        };
        kernel.log.warn("Root process died", .{});
    }
    _ = @call(.never_inline, KernelAllocator.detect_leaks, .{});
    // kernel system calls are not available here
    _ = board.uart.uart0.write_some("Kernel has halted.\nYou can turn off your PC now!\n") catch 0;
}
