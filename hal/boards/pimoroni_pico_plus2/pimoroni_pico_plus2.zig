const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");

pub const uart = struct {
    pub const uart0 = hal.uart.Uart(0, .{ .tx = 0, .rx = 1 }, hal.internal.Uart).create();
};

pub const psram = struct {
    pub const cs = 47;
};

pub const mmc = struct {
    pub var mmc0 = hal.mmc.Mmc(0, 0, 1, 2, .{
        .clk = 7,
        .cmd = 24,
        .d0 = 25,
    }, hal.internal.Mmc).create();
};
