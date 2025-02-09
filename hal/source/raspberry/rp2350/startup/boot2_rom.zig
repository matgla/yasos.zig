// Inspired by https://github.com/ZigEmbeddedGroup/microzig/blob/6631c436a038eeedc358990c9932f21ff78df798/port/raspberrypi/rp2xxx/src/boards/shared/bootrom.zig

const std = @import("std");

comptime {
    _ = Boot2Data.boot2_data;
}

// Replace this with parition manager
const Boot2Data = struct {
    // this is taken from rp2350 datasheet, assuming first partition in first sector
    export const boot2_data: [5]u32 linksection(".bootmeta") = [5]u32{
        0xffffded3,
        0x10210142,
        0x000001ff,
        0x00000000,
        0xab123579,
    };
};
