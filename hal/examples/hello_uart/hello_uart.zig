const std = @import("std");

const board = @import("board");
const hal = @import("hal");

pub export fn main() void {
    const uart = board.uart.uart0;
    try uart.init(.{
        .baudrate = 115200,
    });

    _ = uart.writer().write("Hello from UART 0\n") catch unreachable;
    if (@hasDecl(board.uart, "uart1")) {
        const uart2 = board.uart.uart1;
        try uart2.init(.{
            .baudrate = 115200,
        });
        _ = uart2.writer().write("Hello from UART 1\n") catch unreachable;
    }
    while (true) {}
}
