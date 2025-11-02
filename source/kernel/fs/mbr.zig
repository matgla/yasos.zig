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

pub const MBRPartitionEntry = packed struct {
    boot_indicator: u8,
    start_chs: u24,
    partition_type: u8,
    end_chs: u24,
    start_lba: u32,
    size_in_sectors: u32,
};

pub const MBR = struct {
    partitions: [4]MBRPartitionEntry,
    _signature: u16,

    pub fn create(buffer: []const u8) MBR {
        var mbr: MBR = undefined;
        for (0..4) |i| {
            mbr.partitions[i] = std.mem.bytesToValue(MBRPartitionEntry, &buffer[446 + i * @sizeOf(MBRPartitionEntry)]);
        }
        mbr._signature = std.mem.bytesToValue(u16, buffer[510..512]);
        return mbr;
    }

    pub fn is_valid(self: MBR) bool {
        return self._signature == 0xAA55;
    }
};

test "MBRPartitionEntry.ShouldHaveCorrectSize" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(MBRPartitionEntry));
}

test "MBR.Create.ShouldParseValidMBR" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    
    // Set up a valid MBR signature
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    // Set up first partition entry at offset 446
    buffer[446] = 0x80; // boot indicator
    buffer[447] = 0x01; // start CHS byte 1
    buffer[448] = 0x02; // start CHS byte 2
    buffer[449] = 0x03; // start CHS byte 3
    buffer[450] = 0x83; // partition type (Linux)
    buffer[451] = 0x04; // end CHS byte 1
    buffer[452] = 0x05; // end CHS byte 2
    buffer[453] = 0x06; // end CHS byte 3
    // start_lba = 0x00001000 (little endian)
    buffer[454] = 0x00;
    buffer[455] = 0x10;
    buffer[456] = 0x00;
    buffer[457] = 0x00;
    // size_in_sectors = 0x00002000 (little endian)
    buffer[458] = 0x00;
    buffer[459] = 0x20;
    buffer[460] = 0x00;
    buffer[461] = 0x00;
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(mbr.is_valid());
    try std.testing.expectEqual(@as(u8, 0x80), mbr.partitions[0].boot_indicator);
    try std.testing.expectEqual(@as(u8, 0x83), mbr.partitions[0].partition_type);
    try std.testing.expectEqual(@as(u32, 0x00001000), mbr.partitions[0].start_lba);
    try std.testing.expectEqual(@as(u32, 0x00002000), mbr.partitions[0].size_in_sectors);
}

test "MBR.Create.ShouldParseInvalidSignature" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    
    // Set up an invalid MBR signature
    buffer[510] = 0x00;
    buffer[511] = 0x00;
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(!mbr.is_valid());
}

test "MBR.Create.ShouldParseAllFourPartitions" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    
    // Set up valid signature
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    // Set up all four partition entries
    for (0..4) |i| {
        const offset = 446 + i * 16;
        buffer[offset] = @intCast(i); // boot indicator
        buffer[offset + 4] = @intCast(0x0C + i); // partition type
        // start_lba
        buffer[offset + 8] = @intCast((i + 1) * 0x10);
        buffer[offset + 9] = 0x00;
        buffer[offset + 10] = 0x00;
        buffer[offset + 11] = 0x00;
        // size_in_sectors
        buffer[offset + 12] = @intCast((i + 1) * 0x20);
        buffer[offset + 13] = 0x00;
        buffer[offset + 14] = 0x00;
        buffer[offset + 15] = 0x00;
    }
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(mbr.is_valid());
    
    for (0..4) |i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), mbr.partitions[i].boot_indicator);
        try std.testing.expectEqual(@as(u8, @intCast(0x0C + i)), mbr.partitions[i].partition_type);
        try std.testing.expectEqual(@as(u32, @intCast((i + 1) * 0x10)), mbr.partitions[i].start_lba);
        try std.testing.expectEqual(@as(u32, @intCast((i + 1) * 0x20)), mbr.partitions[i].size_in_sectors);
    }
}

test "MBR.IsValid.ShouldReturnTrueForValidSignature" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    const mbr = MBR.create(&buffer);
    try std.testing.expect(mbr.is_valid());
}

test "MBR.IsValid.ShouldReturnFalseForInvalidSignature" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    buffer[510] = 0xFF;
    buffer[511] = 0xFF;
    
    const mbr = MBR.create(&buffer);
    try std.testing.expect(!mbr.is_valid());
}

test "MBR.Create.ShouldHandleEmptyPartitions" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(mbr.is_valid());
    
    // All partitions should be zeroed
    for (mbr.partitions) |partition| {
        try std.testing.expectEqual(@as(u8, 0), partition.boot_indicator);
        try std.testing.expectEqual(@as(u8, 0), partition.partition_type);
        try std.testing.expectEqual(@as(u32, 0), partition.start_lba);
        try std.testing.expectEqual(@as(u32, 0), partition.size_in_sectors);
    }
}

test "MBR.Create.ShouldParseFAT32Partition" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    // FAT32 partition
    buffer[446] = 0x00; // not bootable
    buffer[450] = 0x0C; // FAT32 with LBA
    buffer[454] = 0x00; // start_lba = 0x00000800
    buffer[455] = 0x08;
    buffer[456] = 0x00;
    buffer[457] = 0x00;
    buffer[458] = 0x00; // size = 0x00100000
    buffer[459] = 0x00;
    buffer[460] = 0x10;
    buffer[461] = 0x00;
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(mbr.is_valid());
    try std.testing.expectEqual(@as(u8, 0x00), mbr.partitions[0].boot_indicator);
    try std.testing.expectEqual(@as(u8, 0x0C), mbr.partitions[0].partition_type);
    try std.testing.expectEqual(@as(u32, 0x00000800), mbr.partitions[0].start_lba);
    try std.testing.expectEqual(@as(u32, 0x00100000), mbr.partitions[0].size_in_sectors);
}

test "MBR.Create.ShouldParseLinuxPartition" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    // Linux partition
    buffer[446] = 0x80; // bootable
    buffer[450] = 0x83; // Linux filesystem
    buffer[454] = 0x00; // start_lba = 0x00001000
    buffer[455] = 0x10;
    buffer[456] = 0x00;
    buffer[457] = 0x00;
    buffer[458] = 0x00; // size = 0x00200000
    buffer[459] = 0x00;
    buffer[460] = 0x20;
    buffer[461] = 0x00;
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(mbr.is_valid());
    try std.testing.expectEqual(@as(u8, 0x80), mbr.partitions[0].boot_indicator);
    try std.testing.expectEqual(@as(u8, 0x83), mbr.partitions[0].partition_type);
    try std.testing.expectEqual(@as(u32, 0x00001000), mbr.partitions[0].start_lba);
    try std.testing.expectEqual(@as(u32, 0x00200000), mbr.partitions[0].size_in_sectors);
}

test "MBR.Create.ShouldParseCHSValues" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    // Set CHS values for first partition
    buffer[447] = 0x12; // start CHS byte 1
    buffer[448] = 0x34; // start CHS byte 2
    buffer[449] = 0x56; // start CHS byte 3
    buffer[451] = 0x78; // end CHS byte 1
    buffer[452] = 0x9A; // end CHS byte 2
    buffer[453] = 0xBC; // end CHS byte 3
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(mbr.is_valid());
    
    // Verify CHS values are packed correctly (24 bits each)
    const expected_start_chs: u24 = 0x563412; // little endian
    const expected_end_chs: u24 = 0xBC9A78; // little endian
    
    try std.testing.expectEqual(expected_start_chs, mbr.partitions[0].start_chs);
    try std.testing.expectEqual(expected_end_chs, mbr.partitions[0].end_chs);
}

test "MBR.Create.ShouldHandleMaxValues" {
    var buffer: [512]u8 = [_]u8{0} ** 512;
    
    buffer[510] = 0x55;
    buffer[511] = 0xAA;
    
    // Set maximum values for first partition
    buffer[446] = 0xFF; // boot indicator
    buffer[447] = 0xFF; // start CHS
    buffer[448] = 0xFF;
    buffer[449] = 0xFF;
    buffer[450] = 0xFF; // partition type
    buffer[451] = 0xFF; // end CHS
    buffer[452] = 0xFF;
    buffer[453] = 0xFF;
    buffer[454] = 0xFF; // start_lba
    buffer[455] = 0xFF;
    buffer[456] = 0xFF;
    buffer[457] = 0xFF;
    buffer[458] = 0xFF; // size_in_sectors
    buffer[459] = 0xFF;
    buffer[460] = 0xFF;
    buffer[461] = 0xFF;
    
    const mbr = MBR.create(&buffer);
    
    try std.testing.expect(mbr.is_valid());
    try std.testing.expectEqual(@as(u8, 0xFF), mbr.partitions[0].boot_indicator);
    try std.testing.expectEqual(@as(u24, 0xFFFFFF), mbr.partitions[0].start_chs);
    try std.testing.expectEqual(@as(u8, 0xFF), mbr.partitions[0].partition_type);
    try std.testing.expectEqual(@as(u24, 0xFFFFFF), mbr.partitions[0].end_chs);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), mbr.partitions[0].start_lba);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), mbr.partitions[0].size_in_sectors);
}
