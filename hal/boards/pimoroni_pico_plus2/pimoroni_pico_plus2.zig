const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");
const config = @import("config");

pub const uart = struct {
    pub const uart0 = hal.uart.Uart(0, .{ .tx = 32, .rx = 33 }, hal.internal.Uart).create();
};

pub const psram = struct {
    pub const cs = 47;
};

pub const flash = struct {
    pub const flash0 = hal.flash.Flash(hal.internal.Flash(0x10000000, 16 * 1024 * 1024)).create(0);
};

pub const mmc = struct {
    // Pimoroni Pico Plus 2 SD card pinout:
    //   SD_CLK  -> GP5
    //   SD_CMD  -> GP18
    //   SD_DAT0 -> GP19
    //   SD_DAT1 -> GP20
    //   SD_DAT2 -> GP21
    //   SD_DAT3 -> GP22
    pub var mmc0 = hal.mmc.Mmc.create(.{
        .bus_width = if (config.mmc.bus_mode_sdio) 4 else 1,
        .clock_speed = 50 * 1000 * 1000,
        .timeout_ms = 1000,
        .use_dma = false,
        .mode = if (config.mmc.bus_mode_sdio) .SDIO else .SPI,
        .pins = .{
            .clk = 5,
            .cmd = 18,
            .d0 = 19,
        },
    });
};
