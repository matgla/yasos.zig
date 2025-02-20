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
const fs = @import("kernel/fs/fs.zig");
const RomFs = @import("fs/romfs/romfs.zig").RomFs;
const RamFs = @import("fs/ramfs/ramfs.zig").RamFs;

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

fn file_resolver(_: []const u8) ?*anyopaque {
    return null;
}

fn traverse_directory(file: *IFile) void {
    log.print("file: {s}\n", .{file.name()});
}

export fn kernel_process() void {
    log.write(" - creating virtual file system\n");
    var vfs_instance = fs.VirtualFileSystem.init(malloc_allocator);
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
    vfs_instance.mount_filesystem("/", romfs.ifilesystem()) catch |err| {
        log.print("Can't mount '/' with type '{s}': {s}\n", .{ ramfs.ifilesystem().name(), @errorName(err) });
        return;
    };
    var vfs = vfs_instance.ifilesystem();
    _ = vfs.traverse("/", traverse_directory);
    log.write(" - loading yasld\n");
    const symbols = [_]yasld.SymbolEntry{
        .{ .address = @intFromPtr(&c.puts), .name = "puts" },
    };
    const environment = yasld.Environment{
        .symbols = &symbols,
    };
    const loader: yasld.Loader = yasld.Loader.create(malloc_allocator, environment, &file_resolver);

    const executable_memory: *anyopaque = @ptrFromInt(0x10080000);
    const maybeExecutable: ?yasld.Executable = loader.load_executable(
        executable_memory,
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
        _ = executable.main(args.ptr, args.len) catch |err| {
            log.print("Cannot execute main: {s}\n", .{@errorName(err)});
        };
    }
    while (true) {
        time.sleep_ms(20);
        // mutex.lock();
        // log.write("Kernel is running\n");
        // process_manager.instance.dump_processes(log);
        // mutex.unlock();
    }
}

pub export fn main() void {
    initialize_board();
    log.print("-----------------------------------------\n", .{});
    log.print("|               YASOS                   |\n", .{});
    DumpHardware.print_hardware();

    log.write(" - initializing process manager\n");
    log.write(" - scheduler: round robin\n");

    process_manager.instance.set_scheduler(RoundRobinScheduler(process_manager.ProcessManager){
        .manager = &process_manager.instance,
    });
    process.init();

    spawn.root_process(malloc_allocator, &kernel_process, null, 1024 * 8) catch @panic("Can't spawn root process: ");
    while (true) {}
}
