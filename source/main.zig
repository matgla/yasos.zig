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

var log = &@import("log/kernel_log.zig").kernel_log;

const DumpHardware = @import("hwinfo/dump_hardware.zig").DumpHardware;

const spawn = @import("arch/arch.zig").spawn;
const process = @import("kernel/process.zig");
const process_manager = @import("kernel/process_manager.zig");
const RoundRobinScheduler = @import("kernel/round_robin.zig").RoundRobin;

const malloc_allocator = @import("kernel/malloc.zig").malloc_allocator;

comptime {
    _ = @import("kernel/systick.zig");
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

export fn kernel_process() void {
    log.write("Kernel process is running\n");
    while (true) {}
}

export fn get_next_task() *const u8 {
    if (process_manager.instance.scheduler.get_next()) |task| {
        process_manager.instance.scheduler.update_current();
        return task.stack_pointer();
    }

    @panic("Context switch called without tasks available");
}

export fn update_stack_pointer(ptr: *const u8) void {
    if (process_manager.instance.scheduler.get_current()) |task| {
        task.set_stack_pointer(ptr);
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
