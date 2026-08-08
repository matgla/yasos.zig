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

#ifndef YASDISK_MBR_H
#define YASDISK_MBR_H

#include <stddef.h>
#include <stdint.h>

#define MBR_BOOT_CODE_SIZE 446
#define MBR_PARTITION_COUNT 4
#define MBR_SIGNATURE 0xAA55
#define MBR_SECTOR_SIZE 512

// Common partition types
#define PART_TYPE_EMPTY     0x00
#define PART_TYPE_FAT12     0x01
#define PART_TYPE_FAT16_S   0x04
#define PART_TYPE_FAT16_L   0x06
#define PART_TYPE_NTFS      0x07
#define PART_TYPE_FAT32     0x0B
#define PART_TYPE_FAT32_LBA 0x0C
#define PART_TYPE_FAT16_LBA 0x0E
#define PART_TYPE_LINUX_SWAP 0x82
#define PART_TYPE_LINUX     0x83
#define PART_TYPE_LINUX_LVM 0x8E
#define PART_TYPE_FREEBSD   0xA5
#define PART_TYPE_OPENBSD   0xA6
#define PART_TYPE_NETBSD    0xA9
#define PART_TYPE_GPT       0xEE
#define PART_TYPE_EFI       0xEF

typedef struct __attribute__((packed)) {
    uint8_t boot_flag;        // 0x80 = bootable, 0x00 = not bootable
    uint8_t start_head;       // CHS start
    uint8_t start_sector;     // CHS start (bits 0-5), high cyl bits
    uint8_t start_cylinder;   // CHS start (low bits)
    uint8_t type;             // Partition type
    uint8_t end_head;         // CHS end
    uint8_t end_sector;       // CHS end (bits 0-5), high cyl bits
    uint8_t end_cylinder;     // CHS end (low bits)
    uint32_t start_lba;       // LBA start sector (little endian)
    uint32_t sector_count;    // Number of sectors (little endian)
} PartitionEntry;

typedef struct __attribute__((packed)) {
    uint8_t boot_code[MBR_BOOT_CODE_SIZE];  // Boot loader code
    PartitionEntry partitions[MBR_PARTITION_COUNT];  // 4 partition entries
    uint16_t signature;                      // 0xAA55
} MBR;

typedef struct {
    MBR mbr;
    char device_path[256];
    uint64_t device_size;
    uint32_t sector_size;
    int dirty;                // 1 if modified, 0 if clean
    int fd;                   // File descriptor (-1 if not open)
} Disk;

// MBR operations
void mbr_init(MBR* mbr);
int mbr_is_valid(const MBR* mbr);
void mbr_print(const MBR* mbr);

// Partition operations
void partition_init(PartitionEntry* pe);
int partition_is_empty(const PartitionEntry* pe);
int partition_is_bootable(const PartitionEntry* pe);
void partition_set_bootable(PartitionEntry* pe, int bootable);
const char* partition_get_type_name(uint8_t type);

// CHS conversions
void lba_to_chs(uint32_t lba, uint8_t* head, uint8_t* sector, uint8_t* cylinder,
                uint32_t cylinders, uint32_t heads, uint32_t sectors_per_track);
uint32_t chs_to_lba(uint8_t head, uint8_t sector, uint8_t cylinder,
                    uint32_t heads, uint32_t sectors_per_track);

// Disk operations
int disk_open(Disk* disk, const char* path);
void disk_close(Disk* disk);
int disk_read_mbr(Disk* disk);
int disk_write_mbr(Disk* disk);
int disk_get_size(const char* path, uint64_t* size);
int disk_get_sector_size(const char* path, uint32_t* size);

// Partition management
int partition_create(Disk* disk, int index, uint32_t start_lba, uint32_t sector_count, uint8_t type);
void partition_delete(Disk* disk, int index);
int partition_validate(const Disk* disk, int index);
int partitions_overlap(const PartitionEntry* p1, const PartitionEntry* p2);

// Utility
uint64_t align_sector(uint64_t sector);
void format_size(uint64_t bytes, char* buf, size_t buf_size);

#endif // YASDISK_MBR_H
