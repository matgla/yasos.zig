const std = @import("std");
const builtin = @import("builtin");

pub const hal = @import("hal");
const config = @import("config");

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
    // MSPC v2 SD card pinout (SPI in brackets):
    //   SD_CLK  -> GP32 (SCK)
    //   SD_CMD  -> GP33 (MOSI)
    //   SD_DAT0 -> GP34 (MISO)
    //   SD_DAT1 -> GP35
    //   SD_DAT2 -> GP36
    //   SD_DAT3 -> GP37 (CS)
    pub var mmc0 = hal.mmc.Mmc.create(.{
        .bus_width = if (config.mmc.bus_mode_sdio) 4 else 1,
        .clock_speed = 50 * 1000 * 1000,
        .timeout_ms = 1000,
        .use_dma = false,
        .mode = if (config.mmc.bus_mode_sdio) .SDIO else .SPI,
        .pins = .{
            .clk = 32,
            .cmd = 33,
            .d0 = 34,
        },
    });
};
