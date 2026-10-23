const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");

// Raspberry Pi Pico 2: console on UART0 (GP0 TX / GP1 RX, the debug-probe
// header), 4 MB of flash, no SD socket and no PSRAM.
pub const uart = struct {
    pub const uart0 = hal.uart.Uart(0, .{ .tx = 0, .rx = 1 }, hal.internal.Uart).create();
};

pub const flash = struct {
    pub const flash0 = hal.flash.Flash(hal.internal.Flash(0x10000000, 4 * 1024 * 1024)).create(0);
};
