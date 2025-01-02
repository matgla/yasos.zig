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

const board = @import("board");

const kernel_log = @import("log/kernel_log.zig");
const log: *@TypeOf(kernel_log.kernel_log) = &kernel_log.kernel_log;

fn initialize_board() void {
    try board.uart.uart0.init(.{
        .baudrate = 115200,
    });
    _ = board.uart.uart0.write_some("Hello\n") catch {};
}

pub export fn main() void {
    initialize_board();
    log.*.attach_to(.{
        .state = &board.uart.uart0,
        .method = @TypeOf(board.uart.uart0).write_some_opaque,
    });
    _ = board.uart.uart0.write_some("From main\n") catch {};
    _ = board.uart.uart0.writer().print("address of log object: {*}\n", .{log}) catch {};
    log.*.print("-----------------------------------------\n", .{});
    // log.*.print("-               YASOS                   -\n", .{});
    // log.*.print("-----------------------------------------\n", .{});
    // log.*.write("Kernel booted\n");

    while (true) {}
}
