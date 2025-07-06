const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");

pub const uart = struct {
    pub const uart0 = hal.uart.Uart(0, .{ .tx = 32, .rx = 33 }, hal.internal.Uart).create();
};

pub const psram = struct {
    pub const cs = 47;
};

pub const flash = struct {
    pub const flash0 = hal.flash.Flash(hal.internal.Flash(0x10000000, 16 * 1024 * 1024)).create(0);
};

// pub const mmc = struct {
//     pub var mmc0 = hal.mmc.Mmc(.{.clk = 0}, hal.internal.Mmc).create();
// };
