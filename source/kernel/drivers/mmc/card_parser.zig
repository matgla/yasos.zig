// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const builtin = @import("builtin");

const tran_speed_time_values: [16]f32 = [_]f32{
    0.0,
    1.0,
    1.2,
    1.3,
    1.5,
    2.0,
    2.5,
    3.0,
    3.5,
    4.0,
    4.5,
    5.0,
    5.5,
    6.0,
    7.0,
    8.0,
};

const tran_speed_rate_values: [8]u32 = [_]u32{
    100 * 1000,
    1 * 1000 * 1000,
    10 * 1000 * 1000,
    100 * 1000 * 1000,
    0,
    0,
    0,
    0,
};

pub const CID = packed struct {
    manufacturer_id: u8,
    oem_id: u16,
    product_name: u8[5],
    product_revision: u8,
    serial_number: u32,
    _reserved1: u4,
    manufacturer_date: u12,
    crc: u7,
    _reserved2: u1,
};

pub const CSDv1 = packed struct {
    csd_structure: u2,
    _r1: u6,
    taac: u8,
    nsac: u8,
    tran_speed: u8,
    ccc: u12,
    read_bl_len: u4,
    read_bl_partial: bool,
    write_blk_misalign: bool,
    read_blk_misalign: bool,
    dsr_implemented: bool,
    _r2: u6,
    c_size: u22,
    _r3: bool,
    erase_blk_en: bool,
    sector_size: u7,
    wp_grp_size: u7,
    wp_grp_enable: bool,
    _r4: u2,
    r2w_factor: u3,
    write_bl_len: u4,
    write_bl_partial: bool,
    _r5: u5,
    file_format_grp: bool,
    copy: bool,
    perm_write_protect: bool,
    tmp_write_protect: bool,
    file_format: u2,
    _r6: u2,
    crc: u7,
    always1: bool,
};

pub const CSDv2 = packed struct {
    csd_structure: u2,
    taac: u8,
    nsac: u8,
    tran_speed: u8,
    ccc: u12,
    read_bl_len: u4,
    read_bl_partial: bool,
    write_blk_misalign: bool,
    read_blk_misalign: bool,
    dsr_implemented: bool,
    c_size: u22,
    erase_blk_en: bool,
    sector_size: u7,
    wp_grp_size: u7,
    wp_grp_enable: bool,
    r2w_factor: u3,
    write_bl_len: u4,
    write_bl_partial: bool,
    file_format_grp: bool,
    copy: bool,
    perm_write_protect: bool,
    tmp_write_protect: bool,
    file_format: u2,
    crc: u7,
    always1: bool,

    pub fn get_speed(self: CSDv2) u32 {
        return @intFromFloat(tran_speed_time_values[self.tran_speed >> 3] * @as(f32, @floatFromInt(tran_speed_rate_values[self.tran_speed & 0x07])));
    }

    pub fn get_sector_size(self: CSDv2) u32 {
        return @as(u32, @intCast(@as(u32, 1) << self.read_bl_len));
    }

    pub fn get_size(self: CSDv2) u32 {
        return @as(u32, @intCast(self.c_size + 1)) * self.get_sector_size();
    }
};

pub const CSD = enum(u2) {
    CSDv1 = 0,
    CSDv2 = 1,
};

pub const CardParser = struct {
    pub fn parse_cid(buffer: []const u8) CID {
        return std.mem.bytesToValue(CID, buffer);
    }

    pub fn get_csd_version(buffer: []const u8) CSD {
        std.debug.assert(buffer.len == 16);
        return @enumFromInt(@as(u2, @intCast(buffer[0] >> 6)));
    }

    pub fn parse_csdv2(buffer: []const u8) anyerror!CSDv2 {
        std.debug.assert(buffer.len == 16);
        if (std.hash.crc.Crc7Mmc.hash(buffer[0..15]) != @as(u7, @intCast(buffer[15] >> 1))) {
            return error.InvalidCrc;
        }

        if (buffer[0] >> 6 != 1) {
            return error.InvalidCsdVersion;
        }

        if (buffer[15] & 0x01 != 1) {
            return error.InvalidCsdAlways1;
        }

        return .{
            .csd_structure = extract_bits(buffer, 126, u2),
            .taac = extract_bits(buffer, 112, u8),
            .nsac = extract_bits(buffer, 104, u8),
            .tran_speed = extract_bits(buffer, 96, u8),
            .ccc = extract_bits(buffer, 84, u12),
            .read_bl_len = extract_bits(buffer, 80, u4),
            .read_bl_partial = extract_bits(buffer, 79, u1) != 0,
            .write_blk_misalign = extract_bits(buffer, 78, u1) != 0,
            .read_blk_misalign = extract_bits(buffer, 77, u1) != 0,
            .dsr_implemented = extract_bits(buffer, 76, u1) != 0,
            .c_size = extract_bits(buffer, 48, u22),
            .erase_blk_en = extract_bits(buffer, 46, u1) != 0,
            .sector_size = extract_bits(buffer, 39, u7),
            .wp_grp_size = extract_bits(buffer, 32, u7),
            .wp_grp_enable = extract_bits(buffer, 31, u1) != 0,
            .r2w_factor = extract_bits(buffer, 26, u3),
            .write_bl_len = extract_bits(buffer, 22, u4),
            .write_bl_partial = extract_bits(buffer, 21, u1) != 0,
            .file_format_grp = extract_bits(buffer, 15, u1) != 0,
            .copy = extract_bits(buffer, 14, u1) != 0,
            .perm_write_protect = extract_bits(buffer, 13, u1) != 0,
            .tmp_write_protect = extract_bits(buffer, 12, u1) != 0,
            .file_format = extract_bits(buffer, 10, u2),
            .crc = extract_bits(buffer, 1, u7),
            .always1 = extract_bits(buffer, 0, u1) != 0,
        };
    }

    pub fn parse_csdv1(buffer: []const u8) CSDv1 {
        std.debug.assert(buffer.len == 16);
        return std.mem.bytesToValue(CSDv1, &buffer);
    }

    fn extract_bits(buffer: []const u8, start: u32, comptime T: type) T {
        const length = @bitSizeOf(T);
        std.debug.assert(start + length <= buffer.len << 3);
        var value: T = 0;
        var index: T = 0;
        for (start..start + length) |i| {
            const byte_index = if (builtin.cpu.arch.endian() == .big) i >> 3 else buffer.len - (i >> 3) - 1;
            const bit_index = i % 8;
            value |= @as(T, @intCast(((buffer[byte_index] >> @intCast(bit_index)) & 1))) << @intCast(index);
            index += 1;
        }
        return value;
    }
};
test "CardParser.ShouldParseCsd" {

    //400e00325b59000074cb7f800a40003d
    const csd_bytes: [16]u8 = [_]u8{
        0x40, 0x0E, 0x00, 0x32, 0x5B, 0x59, 0x00, 0x00,
        0x74, 0xcb, 0x7f, 0x80, 0x0a, 0x40, 0x00, 0x3d,
    };

    try std.testing.expectEqual(CSD.CSDv2, CardParser.get_csd_version(&csd_bytes));
    const csd = try CardParser.parse_csdv2(&csd_bytes);
    try std.testing.expectEqual(1, csd.csd_structure);
    try std.testing.expectEqual(0x0e, csd.taac);
    try std.testing.expectEqual(0x00, csd.nsac);
    try std.testing.expect(csd.tran_speed == 0x32);
    try std.testing.expect(csd.ccc == 0x5b5);
    try std.testing.expect(csd.read_bl_len == 0x9);
    try std.testing.expect(csd.read_bl_partial == false);
    try std.testing.expect(csd.write_blk_misalign == false);
    try std.testing.expect(csd.read_blk_misalign == false);
    try std.testing.expect(csd.dsr_implemented == false);
    try std.testing.expect(csd.c_size == 0x0074cb);
    try std.testing.expect(csd.erase_blk_en == true);
    try std.testing.expect(csd.sector_size == 0x7f);
    try std.testing.expect(csd.wp_grp_size == 0x00);
    try std.testing.expect(csd.wp_grp_enable == false);
    try std.testing.expect(csd.r2w_factor == 0x2);
    try std.testing.expect(csd.write_bl_len == 0x9);
    try std.testing.expect(csd.write_bl_partial == false);
    try std.testing.expect(csd.file_format_grp == false);
    try std.testing.expect(csd.copy == false);
    try std.testing.expect(csd.perm_write_protect == false);
    try std.testing.expect(csd.tmp_write_protect == false);
    try std.testing.expect(csd.file_format == 0x0);

    try std.testing.expectEqual(25000000, csd.get_speed());
}
