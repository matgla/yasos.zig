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
const DumpHardware = @import("hwinfo/dump_hardware.zig").DumpHardware;

const RomFs = @import("fs/romfs/romfs.zig").RomFs;
const RamFs = @import("fs/ramfs/ramfs.zig").RamFs;

const panic_helper = @import("arch").panic;

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
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{
            .scope = .yasld,
            .level = .err,
        },
        .{
            .scope = .@"mmc/driver",
            .level = .debug,
        },
        // .{
        //     .scope = .@"yasld/module",
        //     .level = .info,
        // }, .{
        //     .scope = .malloc,
        //     .level = .info,
        // }, .{
        //     .scope = .@"kernel/memory_pool",
        //     .level = .info,
        // }, .{
        //     .scope = .@"kernel/process",
        //     .level = .info,
        // },
        .{
            .scope = .@"vfs/driverfs",
            .level = .debug,
        },
        .{
            .scope = .@"kernel/fs/mount_points",
            .level = .debug,
        },
    },
};

fn initialize_board() void {
    try board.uart.uart0.init(.{
        .baudrate = 921600,
    });

    kernel.stdout.set_output(&board.uart.uart0, @TypeOf(board.uart.uart0).write_some_opaque);
    kernel.log.info("initialization of external memory", .{});
    if (hal.external_memory.enable()) {
        hal.external_memory.dump_configuration();
        kernel.log.info("External memory found", .{});
        if (hal.external_memory.perform_post()) {
            kernel.log.info("External memory post test passed", .{});
        } else {
            kernel.log.err("External memory post test failed", .{});
        }
    }
}

// must be in root module file, otherwise won't be used
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    kernel.log.err("****************** PANIC **********************", .{});
    kernel.log.err("KERNEL PANIC: {s}", .{msg});
    panic_helper.dump_stack_trace(kernel.log, @returnAddress());
    kernel.log.err("***********************************************", .{});
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
        return err;
    };
}

fn initialize_filesystem(allocator: std.mem.Allocator) !void {
    kernel.fs.vfs_init(allocator);
    var driverfs = kernel.driver.fs.DriverFs.InstanceType.init(allocator);
    const uart0name = "uart0";
    const uart_driver = (kernel.driver.UartDriver(board.uart.uart0).InstanceType.create(uart0name)).interface.new(allocator) catch |err| {
        kernel.log.err("Can't create uart driver instance: '{s}'", .{@errorName(err)});
        return err;
    };
    try driverfs.data().append(uart_driver, uart0name);

    const flash0name = "flash0";
    var flash_driver = (kernel.driver.FlashDriver.InstanceType.create(board.flash.flash0, flash0name)).interface.new(allocator) catch |err| {
        kernel.log.err("Can't create flash driver instance: '{s}'\n", .{@errorName(err)});
        return err;
    };
    try driverfs.data().append(flash_driver, flash0name);

    if (@hasDecl(board, "mmc")) {
        inline for (@typeInfo(board.mmc).@"struct".decls) |m| {
            comptime var i: i32 = 0;
            const name = std.fmt.comptimePrint("mmc{d}", .{i});
            const mmc_driver = (kernel.driver.MmcDriver.InstanceType.create(@field(board.mmc, name), name)).interface.new(allocator) catch |err| {
                kernel.log.err("Can't create {s} driver instance: '{s}'", .{ name, @errorName(err) });
                return err;
            };
            driverfs.data().append(mmc_driver, name) catch {};
            kernel.log.info("adding mmc driver: {s}", .{m.name});
            i = i + 1;
        }
    } else {
        kernel.log.debug("Board has no mmc interfaces", .{});
    }
    try driverfs.data().load_all();

    var maybe_flash_file = flash_driver.interface.ifile(allocator);
    if (maybe_flash_file) |*flash| {
        try mount_filesystem(try allocate_filesystem(allocator, RomFs.InstanceType.init(allocator, flash.*, 0x80000)), "/");
        try mount_filesystem(try allocate_filesystem(allocator, RamFs.InstanceType.init(allocator)), "/tmp");
        try mount_filesystem(try allocate_filesystem(allocator, driverfs), "/dev");
        try mount_filesystem(try allocate_filesystem(allocator, kernel.process.ProcFs.InstanceType.init(allocator)), "/proc");
    } else {
        kernel.log.err("Can't get Flash Driver", .{});
    }
    return;
}

fn attach_default_filedescriptors_to_root_process(streamfile: *kernel.fs.IFile, process: *kernel.process.Process) void {
    kernel.log.info("setting default streams", .{});
    process.fds.put(0, .{
        .file = streamfile.share(),
        .path = blk: {
            var path: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
            const value = "/dev/stdin";
            std.mem.copyForwards(u8, path[0..value.len], value);
            break :blk path;
        },
        .diriter = null,
    }) catch {
        kernel.log.err("Can't register: stdin", .{});
    };
    process.fds.put(1, .{
        .file = streamfile.share(),
        .path = blk: {
            var path: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
            const value = "/dev/stdout";
            std.mem.copyForwards(u8, path[0..value.len], value);
            break :blk path;
        },
        .diriter = null,
    }) catch {
        kernel.log.err("Can't register: stdout", .{});
    };
    process.fds.put(2, .{
        .file = streamfile.share(),
        .path = blk: {
            var path: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
            const value = "/dev/stderr";
            std.mem.copyForwards(u8, path[0..value.len], value);
            break :blk path;
        },
        .diriter = null,
    }) catch {
        kernel.log.err("Can't register: stderr", .{});
    };
}
const KernelAllocator = kernel.memory.heap.malloc.MallocAllocator(.{
    .leak_detection = config.instrumentation.enable_memory_leak_detection,
    .verbose = config.instrumentation.verbose_allocators,
    .dump_stats = config.instrumentation.print_memory_usage,
});

export fn kernel_process(argument: *KernelAllocator) void {
    var malloc_allocator = argument.*;
    const allocator = malloc_allocator.allocator();

    const maybe_process = kernel.process.process_manager.instance.get_current_process();
    if (maybe_process) |process| {
        var maybe_uartfile = kernel.fs.get_ivfs().interface.get("/dev/uart0", process.get_memory_allocator());
        if (maybe_uartfile) |*uartfile| {
            defer uartfile.interface.delete();
            attach_default_filedescriptors_to_root_process(uartfile, process);
        } else {
            kernel.log.err("default streams were not assigned: /dev/uart0 do not exists", .{});
        }
        const pid = process.pid;
        // this loads executable replacing current image
        const sh = kernel.dynamic_loader.load_executable("/bin/sh", allocator, process.get_process_memory_allocator(), pid) catch |err| {
            kernel.log.err("Executable loading failed with error: {s}", .{@errorName(err)});
            return;
        };

        const args: [][]u8 = &.{};
        _ = sh.main(@ptrCast(args.ptr), args.len) catch |err| {
            kernel.log.err("Cannot execute main: {s}", .{@errorName(err)});
        };
    }
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

        kernel.process.process_manager.initialize_process_manager(allocator);
        defer kernel.process.process_manager.deinitialize_process_manager();

        kernel.irq.system_call.init(kernel_allocator.allocator());
        kernel.dynamic_loader.init(allocator);
        defer kernel.dynamic_loader.deinit();
        initialize_filesystem(allocator) catch |err| {
            kernel.log.err("Filesystem initialization failed: {s}", .{@errorName(err)});
            return;
        };
        defer kernel.fs.get_vfs().deinit();

        // we need to get real return address to get back from user mode successfully
        @call(.never_inline, kernel.spawn.root_process, .{ &kernel_process, &allocator, 1024 * 16 }) catch @panic("Can't spawn root process: ");
        kernel.log.warn("Root process died", .{});
    }
    @call(.never_inline, KernelAllocator.detect_leaks, .{});
    kernel.stdout.print("You can turn off your PC now!\n", .{});
}
