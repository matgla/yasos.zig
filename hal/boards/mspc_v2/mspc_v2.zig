const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");

pub const uart = struct {
    pub const uart0 = hal.uart.Uart(0, .{ .tx = 44, .rx = 45 }, hal.internal.Uart).create();
};

pub const psram = struct {
    pub const cs = 0;
};

pub const flash = struct {
    pub const flash0 = hal.flash.Flash(hal.internal.Flash(0x10000000, 16 * 1024 * 1024)).create(0);
};

pub const mmc = struct {
    pub const mmc0 = hal.mmc.Mmc(.{
        .clk = 32,
        .cmd = 33,
        .d0 = 34,
    });
};

// pub const mmc = struct {
//     pub var mmc0 = hal.mmc.Mmc(0, 0, 1, 2, .{
//         .clk = 32,
//         .cmd = 33,
//         .d0 = 34,
//     }, hal.internal.Mmc).create();
// };
