const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");

pub const uart = struct {
    pub const uart0 = hal.uart.Uart(0, .{ .tx = 44, .rx = 45 }, hal.internal.Uart).create();
};

pub const mmc = struct {
    pub var mmc0 = hal.mmc.Mmc(0, 0, 1, 2, .{
        .clk = 32,
        .cmd = 33,
        .d0 = 34,
    }, hal.internal.Mmc).create();
};
