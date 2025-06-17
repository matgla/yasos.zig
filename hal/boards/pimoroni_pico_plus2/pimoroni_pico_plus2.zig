const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");

pub const uart = struct {
    pub const uart0 = hal.uart.Uart(0, .{ .tx = 32, .rx = 33 }, hal.internal.Uart).create();
};

pub const psram = struct {
    pub const cs = 47;
};

// pub const mmc = struct {
//     pub var mmc0 = hal.mmc.Mmc(.{.clk = 0}, hal.internal.Mmc).create();
// };
