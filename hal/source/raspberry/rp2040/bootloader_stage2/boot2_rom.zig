// Inspired by https://github.com/ZigEmbeddedGroup/microzig/blob/6631c436a038eeedc358990c9932f21ff78df798/port/raspberrypi/rp2xxx/src/boards/shared/bootrom.zig

const std = @import("std");

comptime {
    _ = Boot2Data.boot2_data;
}

const Boot2Data = struct {
    fn prepare_boot_sector(comptime stage2_rom: []const u8) [256]u8 {
        var boot2: [256]u8 = .{0xFF} ** 256;
        @memcpy(boot2[0..stage2_rom.len], stage2_rom);
        const Hash = std.hash.crc.Crc(u32, .{
            .polynomial = 0x04c11db7,
            .initial = 0xffffffff,
            .reflect_input = false,
            .reflect_output = false,
            .xor_output = 0x00000000,
        });
        std.mem.writeInt(u32, boot2[252..256], Hash.hash(boot2[0..252]), .little);
        return boot2;
    }
    export const boot2_data: [256]u8 linksection(".boot2") = prepare_boot_sector(@embedFile("rp2040_boot2_binary"));
};
