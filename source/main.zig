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

const c = @cImport({
    @cInclude("stdio.h");
});

const std = @import("std");

const board = @import("board");
const config = @import("config");
const hal = @import("hal");

var log = &@import("log/kernel_log.zig").kernel_log;

const DumpHardware = @import("hwinfo/dump_hardware.zig").DumpHardware;

const spawn = @import("kernel/spawn.zig");
const process = @import("kernel/process.zig");
const process_manager = @import("kernel/process_manager.zig");
const RoundRobinScheduler = @import("kernel/round_robin.zig").RoundRobin;

const malloc_allocator = @import("kernel/malloc.zig").malloc_allocator;

const time = @import("kernel/time.zig");

const Mutex = @import("kernel/mutex.zig").Mutex;

const yasld = @import("yasld");

const IFile = @import("kernel/fs/fs.zig").IFile;
const IoctlCommonCommands = @import("kernel/fs/ifile.zig").IoctlCommonCommands;
const FileMemoryMapAttributes = @import("kernel/fs/ifile.zig").FileMemoryMapAttributes;

const fs = @import("kernel/fs/fs.zig");
const RomFs = @import("fs/romfs/romfs.zig").RomFs;
const RamFs = @import("fs/ramfs/ramfs.zig").RamFs;

const DriverFs = @import("kernel/drivers/driverfs.zig").DriverFs;

const UartDriver = @import("kernel/drivers/uart/uart_driver.zig").UartDriver;

comptime {
    _ = @import("kernel/interrupts/systick.zig");
    _ = @import("kernel/system_stubs.zig");
}

fn initialize_board() void {
    try board.uart.uart0.init(.{
        .baudrate = 115200,
    });

    log.attach_to(.{
        .state = &board.uart.uart0,
        .method = @TypeOf(board.uart.uart0).write_some_opaque,
    });
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

export fn some_other_process() void {
    while (true) {
        time.sleep_ms(50);
        mutex.lock();
        log.write("Other process working\n");
        process_manager.instance.dump_processes(log);
        mutex.unlock();
    }
    log.write("Died\n");
}

var module: ?*anyopaque = null;

const ModuleContext = struct {
    path: []const u8,
    address: ?*const anyopaque,
};

fn traverse_directory(file: *IFile, context: *anyopaque) bool {
    var module_context: *ModuleContext = @ptrCast(@alignCast(context));
    log.print("file: {s} == {s}\n", .{ file.name(), module_context.path });
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

    const maybe_driverfs = DriverFs.init(malloc_allocator);
    if (maybe_driverfs == null) {
        log.write("Can't initialize DriverFs\n");
        return;
    }
    var driverfs = maybe_driverfs.?;
    fs.vfs().mount_filesystem("/dev", driverfs.ifilesystem()) catch |err| {
        log.print("Can't mount '/dev' with type '{s}': {s}\n", .{ driverfs.ifilesystem().name(), @errorName(err) });
        return;
    };

    log.write(" - register drivers\n");
    var uart_driver = UartDriver(board.uart.uart0).create(malloc_allocator);
    var iuart_driver = uart_driver.idriver();
    driverfs.append(iuart_driver) catch |err| {
        log.print("Can't create uart driver instance: '{s}'\n", .{@errorName(err)});
        return;
    };

    var driver = driverfs.container.first;
    while (driver) |node| : (driver = node.next) {
        if (!node.data.load()) {
            log.write("Can't load driver\n");
        }
    }

    const maybe_process = process_manager.instance.get_current_process();
    if (maybe_process) |p| {
        log.write("- setting default streams\n");
        const maybe_uart_file = iuart_driver.ifile();
        if (maybe_uart_file) |uart_file| {
            p.fds.put(0, uart_file) catch {
                log.write("Can't register: stdin\n");
            };
            p.fds.put(1, uart_file) catch {
                log.write("Can't register: stdout\n");
            };
            p.fds.put(2, uart_file) catch {
                log.write("Can't register: stderr\n");
            };
        }
    }

    log.write(" - loading yasld\n");
    const symbols = [_]yasld.SymbolEntry{};
    const environment = yasld.Environment{
        .symbols = &symbols,
    };
    const loader: yasld.Loader = yasld.Loader.create(malloc_allocator, environment, &file_resolver);

    const maybe_shell = fs.ivfs().get("/bin/sh");
    if (maybe_shell) |shell| {
        log.write("starting: /bin/sh");
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = shell.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        log.print("File {} at: 0x{x}", .{ attr.is_memory_mapped, attr.mapped_address_r.? });
        const maybeExecutable: ?yasld.Executable = loader.load_executable(
            attr.mapped_address_r.?,
            log,
        ) catch |err| blk: {
            log.print("Executable loading failed with error: {s}\n", .{@errorName(err)});
            break :blk null;
        };

        if (maybeExecutable) |executable| {
            const args: []const [*:0]const u8 = &.{
                "arg1",
                "arg2",
                "arg3",
                "10",
                "12",
            };
            process_manager.instance.dump_processes(log);
            _ = executable.main(args.ptr, args.len) catch |err| {
                log.print("Cannot execute main: {s}\n", .{@errorName(err)});
            };
        }
    }
    while (true) {
        time.sleep_ms(20);
    }
}

pub export fn main() void {
    initialize_board();
    log.print("-----------------------------------------\n", .{});
    log.print("|               YASOS                   |\n", .{});
    DumpHardware.print_hardware();

    log.write(" - initializing process manager\n");
    log.write(" - scheduler: round robin\n");

    process_manager.initialize_process_manager(malloc_allocator);
    process_manager.instance.set_scheduler(RoundRobinScheduler(process_manager.ProcessManager){
        .manager = &process_manager.instance,
    });
    process.init();
    spawn.root_process(&kernel_process, null, 1024 * 8) catch @panic("Can't spawn root process: ");
    while (true) {}
}
