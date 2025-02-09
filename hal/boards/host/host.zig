const std = @import("std");

pub const hal = @import("hal");

pub const uart = struct {
    pub const uart0 = hal.uart.Uart(std.posix.STDOUT_FILENO, .{}, hal.internal.Uart).create();
    pub const uart1 = hal.uart.Uart(std.posix.STDERR_FILENO, .{}, hal.internal.Uart).create();
};
