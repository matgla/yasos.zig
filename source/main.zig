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

const DumpHardware = @import("hwinfo/dump_hardware.zig").DumpHardware;

const spawn = @import("kernel/spawn.zig");
const process = @import("kernel/process.zig");
const process_manager = @import("kernel/process_manager.zig");
const RoundRobinScheduler = @import("kernel/round_robin.zig").RoundRobin;

const malloc_allocator = @import("kernel/malloc.zig").malloc_allocator;

const time = @import("kernel/time.zig");

const Mutex = @import("kernel/mutex.zig").Mutex;

comptime {
    _ = @import("kernel/interrupts/systick.zig");
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

export fn kernel_process() void {
    log.write("Kernel process is running\n");
    spawn.spawn(malloc_allocator, &some_other_process, null, 4096) catch @panic("Can't spawn child process");
    while (true) {
        time.sleep_ms(20);
        mutex.lock();
        log.write("Kernel is running\n");
        process_manager.instance.dump_processes(log);
        mutex.unlock();
    }
}

pub export fn main() void {
    initialize_board();
    log.print("-----------------------------------------\n", .{});
    log.print("|               YASOS                   |\n", .{});
    DumpHardware.print_hardware();

    log.write("Kernel started successfully\n");

    process_manager.instance.set_scheduler(RoundRobinScheduler(process_manager.ProcessManager){
        .manager = &process_manager.instance,
    });
    process.init();

    spawn.root_process(malloc_allocator, &kernel_process, null, config.process.root_stack_size) catch @panic("Can't spawn root process: ");
    while (true) {}
}
