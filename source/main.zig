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

var log = &@import("log/kernel_log.zig").kernel_log;
var null_log = &@import("log/kernel_log.zig").null_log;

const DumpHardware = @import("hwinfo/dump_hardware.zig").DumpHardware;

const spawn = @import("kernel/spawn.zig");
const process = @import("kernel/process.zig");
const process_manager = @import("kernel/process_manager.zig");
const RoundRobinScheduler = @import("kernel/round_robin.zig").RoundRobin;

const malloc_allocator = @import("kernel/malloc.zig").malloc_allocator;

const time = @import("kernel/time.zig");

const Mutex = @import("kernel/mutex.zig").Mutex;

const yasld = @import("yasld");
const dynamic_loader = @import("kernel/modules.zig");

const IFile = @import("kernel/fs/fs.zig").IFile;
const IoctlCommonCommands = @import("kernel/fs/ifile.zig").IoctlCommonCommands;
const FileMemoryMapAttributes = @import("kernel/fs/ifile.zig").FileMemoryMapAttributes;

const fs = @import("kernel/fs/fs.zig");
const RomFs = @import("fs/romfs/romfs.zig").RomFs;
const RamFs = @import("fs/ramfs/ramfs.zig").RamFs;

const DriverFs = @import("kernel/drivers/driverfs.zig").DriverFs;

const UartDriver = @import("kernel/drivers/uart/uart_driver.zig").UartDriver;

const process_memory_pool = @import("kernel/process_memory_pool.zig");
const ProcessPageAllocator = @import("kernel/malloc.zig").ProcessPageAllocator;

comptime {
    _ = @import("kernel/interrupts/systick.zig");
    _ = @import("kernel/system_stubs.zig");
}

fn qmi_delay(counter: usize) linksection(".kernel_ramfuncs") void {
    var index: usize = 0;
    while (index < counter) : (index += 1) {
        asm volatile (
            \\nop
        );
    }
}

fn slicify(ptr: [*]u8, len: usize) []u8 {
    return ptr[0..len];
}

fn initialize_board() void {
    try board.uart.uart0.init(.{
        .baudrate = 921600,
    });

    log.attach_to(.{
        .state = &board.uart.uart0,

        .method = @TypeOf(board.uart.uart0).write_some_opaque,
    });
    log.write(" - initialization of external memory\n\n");
    if (hal.external_memory.enable()) {
        hal.external_memory.dump_configuration(log);
        log.print("External memory found\n", .{});
        // asm volatile (
        //     \\bkpt 0
        // );
        if (hal.external_memory.perform_post(log)) {
            log.print("External memory post test passed\n", .{});
        } else {
            log.print("External memory post test failed\n", .{});
        }
    }
    log.write("Memory initialization finished\n");
}

// must be in root module file, otherwise won't be used
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.write("****************** PANIC **********************\n");
    log.print("KERNEL PANIC: {s}.\n", .{msg});

    var index: usize = 0;
    var stack = std.debug.StackIterator.init(@returnAddress(), null);
    while (stack.next()) |address| : (index += 1) {
        log.print("  {d: >3}: 0x{X:0>8}\n", .{ index, address - 1 });
    }
    log.write("***********************************************\n");
    while (true) {}
}

var mutex: Mutex = .{};

var module: ?*anyopaque = null;

const ModuleContext = struct {
    path: []const u8,
    address: ?*const anyopaque,
};

fn traverse_directory(file: *IFile, context: *anyopaque) bool {
    var module_context: *ModuleContext = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, module_context.path, file.name())) {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = file.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        if (attr.mapped_address_r) |address| {
            module_context.address = address;
            return false;
        }
    }
    return true;
}

fn file_resolver(name: []const u8) ?*const anyopaque {
    log.print("searching for dependency: {s}\n", .{name});
    var context: ModuleContext = .{
        .path = name,
        .address = null,
    };
    _ = fs.ivfs().traverse("/lib", traverse_directory, &context);
    if (context.address) |address| {
        return address;
    }
    return null;
}

export fn kernel_process() void {
    log.write(" - initializing dynamic loader\n");
    dynamic_loader.init(malloc_allocator);
    log.write(" - creating virtual file system\n");
    fs.vfs_init(malloc_allocator);
    const maybe_romfs = RomFs.init(malloc_allocator, @as([*]const u8, @ptrFromInt(0x10080000))[0..0x100000]);

    if (maybe_romfs == null) {
        log.print("RomFS not found at: 0x{x}\n", .{0x10080000});
        return;
    }

    var romfs = maybe_romfs.?;
    var ramfs = RamFs.init(malloc_allocator) catch |err| {
        log.print("Can't initialize ramfs: {s}\n", .{@errorName(err)});
        return;
    };

    fs.vfs().mount_filesystem("/", romfs.ifilesystem()) catch |err| {
        log.print("Can't mount '/' with type '{s}': {s}\n", .{ romfs.ifilesystem().name(), @errorName(err) });
        return;
    };

    fs.vfs().mount_filesystem("/tmp", ramfs.ifilesystem()) catch |err| {
        log.print("Can't mount '/tmp' with type '{s}': {s}\n", .{ ramfs.ifilesystem().name(), @errorName(err) });
        return;
    };

    const driverfs = DriverFs.new(malloc_allocator) catch |err| {
        log.print("Can't create driverfs: {s}\n", .{@errorName(err)});
        return;
    };

    fs.vfs().mount_filesystem("/dev", driverfs.ifilesystem()) catch |err| {
        log.print("Can't mount '/dev' with type '{s}': {s}\n", .{ driverfs.ifilesystem().name(), @errorName(err) });
        return;
    };

    log.write(" - register drivers\n");
    var uart_driver = UartDriver(board.uart.uart0).new(malloc_allocator) catch |err| {
        log.print("Can't create uart driver instance: '{s}'\n", .{@errorName(err)});
        return;
    };
    driverfs.append(uart_driver.idriver()) catch |err| {
        log.print("Can't create uart driver instance: '{s}'\n", .{@errorName(err)});
        return;
    };
    if (!driverfs.load_all()) {
        log.print("Can't load all drivers\n", .{});
        return;
    }

    const maybe_process = process_manager.instance.get_current_process();
    var pid: u32 = 0;
    if (maybe_process) |p| {
        log.write(" - setting default streams\n");
        const maybe_uart_file = uart_driver.idriver().ifile();
        if (maybe_uart_file) |uart_file| {
            p.fds.put(0, .{
                .file = uart_file,
                .path = blk: {
                    var path: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
                    const value = "/dev/stdin";
                    std.mem.copyForwards(u8, path[0..value.len], value);
                    break :blk path;
                },
                .diriter = null,
            }) catch {
                log.write("Can't register: stdin\n");
            };
            p.fds.put(1, .{
                .file = uart_file,
                .path = blk: {
                    var path: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
                    const value = "/dev/stdout";
                    std.mem.copyForwards(u8, path[0..value.len], value);
                    break :blk path;
                },
                .diriter = null,
            }) catch {
                log.write("Can't register: stdout\n");
            };
            p.fds.put(2, .{
                .file = uart_file,
                .path = blk: {
                    var path: [config.fs.max_path_length]u8 = [_]u8{0} ** config.fs.max_path_length;
                    const value = "/dev/stderr";
                    std.mem.copyForwards(u8, path[0..value.len], value);
                    break :blk path;
                },
                .diriter = null,
            }) catch {
                log.write("Can't register: stderr\n");
            };
        }
        pid = p.pid;
    } else {
        @panic("Process unavailable but called from it");
    }

    log.write(" - loading yasld\n");

    var process_memory_allocator = ProcessPageAllocator.create(maybe_process.?.pid);
    const sh = dynamic_loader.load_executable("/bin/sh", process_memory_allocator.std_allocator(), pid) catch |err| {
        log.print("Executable loading failed with error: {s}\n", .{@errorName(err)});
        return;
    };

    const args: [][]u8 = &.{};
    _ = sh.main(@ptrCast(args.ptr), args.len) catch |err| {
        log.print("Cannot execute main: {s}\n", .{@errorName(err)});
    };
    while (true) {
        time.sleep_ms(20);
    }
}

pub export fn main() void {
    initialize_board();
    log.print("\n-----------------------------------------\n", .{});
    log.print("|               YASOS                   |\n", .{});
    DumpHardware.print_hardware();

    log.write(" - initializing process memory pool\n");
    process_memory_pool.init() catch |err| {
        log.print("Can't initialize process memory pool: {s}\n", .{@errorName(err)});
        while (true) {}
    };

    log.write(" - initializing process manager\n");
    process_manager.initialize_process_manager(malloc_allocator);

    log.write(" - scheduler: round robin\n");
    process_manager.instance.set_scheduler(RoundRobinScheduler(process_manager.ProcessManager){
        .manager = &process_manager.instance,
    });
    spawn.root_process(&kernel_process, null, 1024 * 64) catch @panic("Can't spawn root process: ");
    process.init();
    while (true) {}
}
