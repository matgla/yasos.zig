/*
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include "acutest.h"

#include "../mbr.h"

#include <string.h>

void test_mbr_init(void) {
    MBR mbr;
    mbr_init(&mbr);

    TEST_CHECK(mbr.signature == MBR_SIGNATURE);
    TEST_CHECK(mbr.boot_code[0] == 0);
    TEST_CHECK(mbr.boot_code[MBR_BOOT_CODE_SIZE - 1] == 0);

    for (int i = 0; i < MBR_PARTITION_COUNT; i++) {
        TEST_CHECK(partition_is_empty(&mbr.partitions[i]));
        TEST_CHECK(!partition_is_bootable(&mbr.partitions[i]));
    }
}

void test_mbr_is_valid(void) {
    MBR mbr;
    mbr_init(&mbr);
    TEST_CHECK(mbr_is_valid(&mbr));

    mbr.signature = 0x1234;
    TEST_CHECK(!mbr_is_valid(&mbr));

    mbr.signature = 0x55AA;  // Wrong byte order
    TEST_CHECK(!mbr_is_valid(&mbr));
}

void test_partition_is_empty(void) {
    PartitionEntry pe;
    partition_init(&pe);
    TEST_CHECK(partition_is_empty(&pe));

    pe.type = PART_TYPE_LINUX;
    TEST_CHECK(!partition_is_empty(&pe));

    pe.type = PART_TYPE_EMPTY;
    TEST_CHECK(partition_is_empty(&pe));
}

void test_partition_bootable(void) {
    PartitionEntry pe;
    partition_init(&pe);

    TEST_CHECK(!partition_is_bootable(&pe));

    partition_set_bootable(&pe, 1);
    TEST_CHECK(partition_is_bootable(&pe));
    TEST_CHECK(pe.boot_flag == 0x80);

    partition_set_bootable(&pe, 0);
    TEST_CHECK(!partition_is_bootable(&pe));
    TEST_CHECK(pe.boot_flag == 0x00);
}

void test_partition_type_names(void) {
    TEST_CHECK(strcmp(partition_get_type_name(PART_TYPE_EMPTY), "Empty") == 0);
    TEST_CHECK(strcmp(partition_get_type_name(PART_TYPE_LINUX), "Linux") == 0);
    TEST_CHECK(strcmp(partition_get_type_name(PART_TYPE_FAT32), "FAT32") == 0);
    TEST_CHECK(strcmp(partition_get_type_name(PART_TYPE_NTFS), "NTFS/exFAT") == 0);
    TEST_CHECK(strcmp(partition_get_type_name(0xFF), "Unknown") == 0);
}

void test_lba_to_chs_conversion(void) {
    uint8_t head, sector, cylinder;

    // LBA 0 should give CHS (head=0, sector=1, cylinder=0)
    lba_to_chs(0, &head, &sector, &cylinder, 1024, 255, 63);
    TEST_CHECK(head == 0);
    TEST_CHECK((sector & 0x3F) == 1);  // Sector bits 0-5
    TEST_CHECK(cylinder == 0);

    // LBA 62: (0 heads, 63 sector, 0 cylinder)
    // cylinder = 62 / (255 * 63) = 0
    // temp = 62 % 16065 = 62
    // head = 62 / 63 = 0
    // sector = 62 % 63 + 1 = 63
    lba_to_chs(62, &head, &sector, &cylinder, 1024, 255, 63);
    TEST_CHECK(head == 0);
    TEST_CHECK((sector & 0x3F) == 63);
    TEST_CHECK(cylinder == 0);

    // LBA 63: (0 heads, 1 sector, 0 cylinder) - next track
    // Actually with 255 heads, 63 sectors:
    // cylinder = 63 / 16065 = 0
    // temp = 63 % 16065 = 63
    // head = 63 / 63 = 1
    // sector = 63 % 63 + 1 = 1
    lba_to_chs(63, &head, &sector, &cylinder, 1024, 255, 63);
    TEST_CHECK(head == 1);
    TEST_CHECK((sector & 0x3F) == 1);
    TEST_CHECK(cylinder == 0);
}

void test_chs_to_lba_conversion(void) {
    // CHS (0, 1, 0) should give LBA 0
    uint32_t lba = chs_to_lba(0, 1, 0, 255, 63);
    TEST_CHECK(lba == 0);

    // CHS (0, 63, 0) should give LBA 62
    lba = chs_to_lba(0, 63, 0, 255, 63);
    TEST_CHECK(lba == 62);

    // CHS (1, 1, 0) should give LBA 63
    lba = chs_to_lba(1, 1, 0, 255, 63);
    TEST_CHECK(lba == 63);
}

void test_chs_lba_roundtrip(void) {
    // Test round-trip conversion for various LBAs
    uint8_t head, sector, cylinder;

    for (uint32_t test_lba = 0; test_lba < 100000; test_lba += 1000) {
        lba_to_chs(test_lba, &head, &sector, &cylinder, 1024, 255, 63);
        uint32_t back_to_lba = chs_to_lba(head, sector, cylinder, 255, 63);

        // Note: Due to cylinder clamping at 1023, large LBAs may not round-trip exactly
        // 1024 cylinders * 255 heads * 63 sectors = 16,450,560 sectors max for CHS
        if (test_lba < 1024U * 255 * 63) {
            TEST_CHECK(back_to_lba == test_lba);
        }
    }
}

void test_align_sector(void) {
    // Test 1MiB alignment (2048 sectors)
    TEST_CHECK(align_sector(0) == 0);
    TEST_CHECK(align_sector(1) == 2048);
    TEST_CHECK(align_sector(2047) == 2048);
    TEST_CHECK(align_sector(2048) == 2048);
    TEST_CHECK(align_sector(2049) == 4096);
    TEST_CHECK(align_sector(10000) == 10240);  // 10240 = 5 * 2048
}

void test_format_size(void) {
    char buf[32];

    format_size(0, buf, sizeof(buf));
    TEST_CHECK(strcmp(buf, "0 B") == 0);

    format_size(512, buf, sizeof(buf));
    TEST_CHECK(strcmp(buf, "512 B") == 0);

    format_size(1024, buf, sizeof(buf));
    TEST_CHECK(strcmp(buf, "1.00 KB") == 0);

    format_size(1024 * 1024, buf, sizeof(buf));
    TEST_CHECK(strcmp(buf, "1.00 MB") == 0);

    format_size(1024ULL * 1024 * 1024, buf, sizeof(buf));
    TEST_CHECK(strcmp(buf, "1.00 GB") == 0);

    format_size(1024ULL * 1024 * 1024 * 1024, buf, sizeof(buf));
    TEST_CHECK(strcmp(buf, "1.00 TB") == 0);
}

void test_partitions_overlap(void) {
    PartitionEntry p1, p2;

    // p1: sectors 2048-10239 (8192 sectors)
    partition_init(&p1);
    p1.type = PART_TYPE_LINUX;
    p1.start_lba = 2048;
    p1.sector_count = 8192;

    // p2: sectors 10240-18431 (8192 sectors) - adjacent but not overlapping
    partition_init(&p2);
    p2.type = PART_TYPE_LINUX;
    p2.start_lba = 10240;
    p2.sector_count = 8192;

    TEST_CHECK(!partitions_overlap(&p1, &p2));
    TEST_CHECK(!partitions_overlap(&p2, &p1));

    // p2: sectors 10239-18430 - overlaps by 1 sector
    p2.start_lba = 10239;
    TEST_CHECK(partitions_overlap(&p1, &p2));
    TEST_CHECK(partitions_overlap(&p2, &p1));

    // p2: completely inside p1
    p2.start_lba = 4096;
    p2.sector_count = 1024;
    TEST_CHECK(partitions_overlap(&p1, &p2));
    TEST_CHECK(partitions_overlap(&p2, &p1));

    // Empty partitions don't overlap
    partition_init(&p2);
    TEST_CHECK(!partitions_overlap(&p1, &p2));
}

void test_partition_create_basic(void) {
    Disk disk;
    memset(&disk, 0, sizeof(disk));
    disk.device_size = 10ULL * 1024 * 1024 * 1024;  // 10 GB
    disk.sector_size = 512;
    mbr_init(&disk.mbr);

    // Create a 1GB partition
    uint32_t start = 2048;
    uint32_t sectors = 2 * 1024 * 1024;  // 1 GB

    int result = partition_create(&disk, 0, start, sectors, PART_TYPE_LINUX);
    TEST_CHECK(result == 0);
    TEST_CHECK(disk.dirty == 1);

    PartitionEntry* pe = &disk.mbr.partitions[0];
    TEST_CHECK(pe->type == PART_TYPE_LINUX);
    TEST_CHECK(pe->start_lba == start);
    TEST_CHECK(pe->sector_count == sectors);
    TEST_CHECK(!partition_is_empty(pe));
}

void test_partition_create_out_of_bounds(void) {
    Disk disk;
    memset(&disk, 0, sizeof(disk));
    disk.device_size = 1024 * 1024 * 1024;  // 1 GB
    disk.sector_size = 512;
    mbr_init(&disk.mbr);

    // Try to create partition that extends past device
    uint32_t start = 2048;
    uint32_t sectors = 10 * 1024 * 1024;  // 5 GB - too big

    int result = partition_create(&disk, 0, start, sectors, PART_TYPE_LINUX);
    TEST_CHECK(result != 0);
}

void test_partition_create_overlap(void) {
    Disk disk;
    memset(&disk, 0, sizeof(disk));
    disk.device_size = 10ULL * 1024 * 1024 * 1024;  // 10 GB
    disk.sector_size = 512;
    mbr_init(&disk.mbr);

    // Create first partition
    partition_create(&disk, 0, 2048, 2 * 1024 * 1024, PART_TYPE_LINUX);
    disk.dirty = 0;

    // Try to create overlapping partition
    int result = partition_create(&disk, 1, 2048, 1024 * 1024, PART_TYPE_FAT32);
    TEST_CHECK(result != 0);
    TEST_CHECK(disk.dirty == 0);  // Should not mark dirty on failure
}

void test_partition_delete(void) {
    Disk disk;
    memset(&disk, 0, sizeof(disk));
    disk.device_size = 10ULL * 1024 * 1024 * 1024;
    disk.sector_size = 512;
    mbr_init(&disk.mbr);

    // Create and then delete
    partition_create(&disk, 0, 2048, 2 * 1024 * 1024, PART_TYPE_LINUX);
    TEST_CHECK(!partition_is_empty(&disk.mbr.partitions[0]));

    disk.dirty = 0;
    partition_delete(&disk, 0);
    TEST_CHECK(partition_is_empty(&disk.mbr.partitions[0]));
    TEST_CHECK(disk.dirty == 1);
}

void test_partition_invalid_index(void) {
    Disk disk;
    memset(&disk, 0, sizeof(disk));
    disk.device_size = 10ULL * 1024 * 1024 * 1024;
    disk.sector_size = 512;
    mbr_init(&disk.mbr);

    // Invalid index
    int result = partition_create(&disk, -1, 2048, 1024, PART_TYPE_LINUX);
    TEST_CHECK(result != 0);

    result = partition_create(&disk, 4, 2048, 1024, PART_TYPE_LINUX);
    TEST_CHECK(result != 0);

    // Zero size
    result = partition_create(&disk, 0, 2048, 0, PART_TYPE_LINUX);
    TEST_CHECK(result != 0);
}

TEST_LIST = {
    {"test_mbr_init", test_mbr_init},
    {"test_mbr_is_valid", test_mbr_is_valid},
    {"test_partition_is_empty", test_partition_is_empty},
    {"test_partition_bootable", test_partition_bootable},
    {"test_partition_type_names", test_partition_type_names},
    {"test_lba_to_chs_conversion", test_lba_to_chs_conversion},
    {"test_chs_to_lba_conversion", test_chs_to_lba_conversion},
    {"test_chs_lba_roundtrip", test_chs_lba_roundtrip},
    {"test_align_sector", test_align_sector},
    {"test_format_size", test_format_size},
    {"test_partitions_overlap", test_partitions_overlap},
    {"test_partition_create_basic", test_partition_create_basic},
    {"test_partition_create_out_of_bounds", test_partition_create_out_of_bounds},
    {"test_partition_create_overlap", test_partition_create_overlap},
    {"test_partition_delete", test_partition_delete},
    {"test_partition_invalid_index", test_partition_invalid_index},
    {NULL, NULL}
};
