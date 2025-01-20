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

var log = @import("log/kernel_log.zig").kernel_log;

const DumpHardware = @import("hwinfo/dump_hardware.zig").DumpHardware;

const spawn = @import("arch").spawn;
const process = @import("kernel/process.zig");

fn initialize_board() void {
    try board.uart.uart0.init(.{
        .baudrate = 115200,
    });

    log.attach_to(.{
        .state = &board.uart.uart0,
        .method = @TypeOf(board.uart.uart0).write_some_opaque,
    });
}

fn kernel_process() void {
    while (true) {
        log.write("Kernel process is running\n");
    }
}

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.write("****************** PANIC **********************\n");
    log.print("KERNEL PANIC: {s}.\n", .{msg});

    if (stack_trace) |trace| {
        var frames_left: usize = trace.instruction_addresses.len;
        var frame_index: usize = 0;
        log.print("Frames: {d}\n", .{frames_left});
        while (frames_left != 0) : ({
            frames_left -= 1;
            frame_index += 1;
        }) {
            const address = trace.instruction_addresses[frame_index];
            log.print("  {d}: 0x{x}\n", .{ frame_index, address - 1 });
        }
    }
    log.write("***********************************************\n");
    while (true) {}
}

pub export fn main() void {
    initialize_board();
    log.print("-----------------------------------------\n", .{});
    log.print("|               YASOS                   |\n", .{});
    log.print("-----------------------------------------\n", .{});
    DumpHardware.print_hardware(log);

    log.write("Kernel booted\n");
    process.init();

    spawn.root_process(&kernel_process, null, config.process.root_stack_size);

    while (true) {}
}
