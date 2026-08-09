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

#define _GNU_SOURCE

#include "acutest.h"

#include "../mbr.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Helper to create a temporary file with given size
static char* create_temp_file(size_t size) {
    static char template[] = "/tmp/yasdisk_test_XXXXXX";
    char* path = malloc(strlen(template) + 1);
    strcpy(path, template);

    int fd = mkstemp(path);
    if (fd < 0) {
        free(path);
        return NULL;
    }

    // Write zeros to create file of given size
    char* zeros = calloc(1, 4096);
    size_t written = 0;
    while (written < size) {
        size_t to_write = (size - written < 4096) ? (size - written) : 4096;
        ssize_t n = write(fd, zeros, to_write);
        if (n < 0) {
            close(fd);
            free(zeros);
            unlink(path);
            free(path);
            return NULL;
        }
        written += n;
    }

    free(zeros);
    close(fd);
    return path;
}

void test_disk_get_size_regular_file(void) {
    size_t test_size = 1024 * 1024;  // 1 MB
    char* path = create_temp_file(test_size);
    TEST_CHECK(path != NULL);

    uint64_t size;
    int result = disk_get_size(path, &size);
    TEST_CHECK(result == 0);
    TEST_CHECK(size == test_size);

    unlink(path);
    free(path);
}

void test_disk_get_size_nonexistent(void) {
    uint64_t size;
    int result = disk_get_size("/nonexistent/path/12345", &size);
    TEST_CHECK(result != 0);
}

void test_disk_get_sector_size_regular_file(void) {
    char* path = create_temp_file(1024);
    TEST_CHECK(path != NULL);

    uint32_t size;
    int result = disk_get_sector_size(path, &size);
    // Should return default sector size for regular files
    TEST_CHECK(result == 0 || result == -1);  // May fail but should set default
    TEST_CHECK(size == MBR_SECTOR_SIZE);

    unlink(path);
    free(path);
}

void test_disk_open_close_regular_file(void) {
    size_t test_size = MBR_SECTOR_SIZE * 10;  // 10 sectors
    char* path = create_temp_file(test_size);
    TEST_CHECK(path != NULL);

    Disk disk;
    int result = disk_open(&disk, path);
    TEST_CHECK(result == 0);
    TEST_CHECK(disk.fd >= 0);
    TEST_CHECK(disk.device_size == test_size);
    TEST_CHECK(disk.sector_size == MBR_SECTOR_SIZE);
    TEST_CHECK(strcmp(disk.device_path, path) == 0);

    disk_close(&disk);
    TEST_CHECK(disk.fd == -1);

    unlink(path);
    free(path);
}

void test_disk_open_nonexistent(void) {
    Disk disk;
    int result = disk_open(&disk, "/nonexistent/path/12345");
    TEST_CHECK(result != 0);
}

void test_disk_read_mbr(void) {
    // Create file with valid MBR
    size_t test_size = MBR_SECTOR_SIZE * 10;
    char* path = create_temp_file(test_size);
    TEST_CHECK(path != NULL);

    // Write valid MBR signature
    int fd = open(path, O_RDWR);
    TEST_CHECK(fd >= 0);

    // Write MBR signature at offset 510
    uint8_t mbr_sig[2] = {0x55, 0xAA};
    lseek(fd, 510, SEEK_SET);
    write(fd, mbr_sig, 2);
    close(fd);

    Disk disk;
    int result = disk_open(&disk, path);
    TEST_CHECK(result == 0);
    TEST_CHECK(mbr_is_valid(&disk.mbr));

    disk_close(&disk);
    unlink(path);
    free(path);
}

void test_disk_read_mbr_invalid(void) {
    // Create file with invalid MBR (zeros)
    size_t test_size = MBR_SECTOR_SIZE * 10;
    char* path = create_temp_file(test_size);
    TEST_CHECK(path != NULL);

    Disk disk;
    int result = disk_open(&disk, path);
    // Should succeed but initialize empty MBR
    TEST_CHECK(result == 0);
    // MBR should be initialized with valid signature
    TEST_CHECK(mbr_is_valid(&disk.mbr));

    disk_close(&disk);
    unlink(path);
    free(path);
}

void test_disk_write_mbr(void) {
    size_t test_size = MBR_SECTOR_SIZE * 10;
    char* path = create_temp_file(test_size);
    TEST_CHECK(path != NULL);

    Disk disk;
    int result = disk_open(&disk, path);
    TEST_CHECK(result == 0);

    // Create a partition (within the 10-sector file, starting at sector 1)
    // Sector 0 is the MBR, so partition starts at sector 1
    result = partition_create(&disk, 0, 1, 5, PART_TYPE_LINUX);
    TEST_CHECK(result == 0);
    TEST_CHECK(disk.dirty == 1);

    // Write MBR
    result = disk_write_mbr(&disk);
    TEST_CHECK(result == 0);
    TEST_CHECK(disk.dirty == 0);

    disk_close(&disk);

    // Reopen and verify
    result = disk_open(&disk, path);
    TEST_CHECK(result == 0);
    TEST_CHECK(mbr_is_valid(&disk.mbr));
    TEST_CHECK(disk.mbr.partitions[0].type == PART_TYPE_LINUX);
    TEST_CHECK(disk.mbr.partitions[0].start_lba == 1);
    TEST_CHECK(disk.mbr.partitions[0].sector_count == 5);

    disk_close(&disk);
    unlink(path);
    free(path);
}

void test_disk_persistence_multiple_partitions(void) {
    size_t test_size = MBR_SECTOR_SIZE * 100;
    char* path = create_temp_file(test_size);
    TEST_CHECK(path != NULL);

    Disk disk;

    // Create multiple partitions (within 100-sector file)
    disk_open(&disk, path);
    partition_create(&disk, 0, 1, 30, PART_TYPE_LINUX);
    partition_create(&disk, 1, 32, 30, PART_TYPE_FAT32);
    partition_set_bootable(&disk.mbr.partitions[0], 1);
    disk_write_mbr(&disk);
    disk_close(&disk);

    // Reopen and verify
    disk_open(&disk, path);

    TEST_CHECK(disk.mbr.partitions[0].type == PART_TYPE_LINUX);
    TEST_CHECK(disk.mbr.partitions[0].start_lba == 1);
    TEST_CHECK(disk.mbr.partitions[0].sector_count == 30);
    TEST_CHECK(partition_is_bootable(&disk.mbr.partitions[0]));

    TEST_CHECK(disk.mbr.partitions[1].type == PART_TYPE_FAT32);
    TEST_CHECK(disk.mbr.partitions[1].start_lba == 32);
    TEST_CHECK(disk.mbr.partitions[1].sector_count == 30);

    TEST_CHECK(partition_is_empty(&disk.mbr.partitions[2]));
    TEST_CHECK(partition_is_empty(&disk.mbr.partitions[3]));

    disk_close(&disk);
    unlink(path);
    free(path);
}

void test_disk_delete_and_rewrite(void) {
    size_t test_size = MBR_SECTOR_SIZE * 100;
    char* path = create_temp_file(test_size);
    TEST_CHECK(path != NULL);

    Disk disk;

    // Create, delete, and recreate
    disk_open(&disk, path);
    partition_create(&disk, 0, 1, 30, PART_TYPE_LINUX);
    disk_write_mbr(&disk);
    disk_close(&disk);

    disk_open(&disk, path);
    partition_delete(&disk, 0);
    disk_write_mbr(&disk);
    disk_close(&disk);

    disk_open(&disk, path);
    TEST_CHECK(partition_is_empty(&disk.mbr.partitions[0]));

    // Create new partition in same slot
    partition_create(&disk, 0, 1, 20, PART_TYPE_FAT32);
    disk_write_mbr(&disk);
    disk_close(&disk);

    disk_open(&disk, path);
    TEST_CHECK(disk.mbr.partitions[0].type == PART_TYPE_FAT32);
    TEST_CHECK(disk.mbr.partitions[0].sector_count == 20);
    disk_close(&disk);

    unlink(path);
    free(path);
}

TEST_LIST = {
    {"test_disk_get_size_regular_file", test_disk_get_size_regular_file},
    {"test_disk_get_size_nonexistent", test_disk_get_size_nonexistent},
    {"test_disk_get_sector_size_regular_file", test_disk_get_sector_size_regular_file},
    {"test_disk_open_close_regular_file", test_disk_open_close_regular_file},
    {"test_disk_open_nonexistent", test_disk_open_nonexistent},
    {"test_disk_read_mbr", test_disk_read_mbr},
    {"test_disk_read_mbr_invalid", test_disk_read_mbr_invalid},
    {"test_disk_write_mbr", test_disk_write_mbr},
    {"test_disk_persistence_multiple_partitions", test_disk_persistence_multiple_partitions},
    {"test_disk_delete_and_rewrite", test_disk_delete_and_rewrite},
    {NULL, NULL}
};
