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

#include "mbr.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <linux/fs.h>
#include <sys/ioctl.h>

// Standard CHS geometry for large disks
#define CHS_CYLINDERS 1024
#define CHS_HEADS 255
#define CHS_SECTORS 63

void format_size(uint64_t bytes, char* buf, size_t buf_size) {
    const char* units[] = {"B", "KB", "MB", "GB", "TB"};
    int unit_idx = 0;
    double size = (double)bytes;

    while (size >= 1024.0 && unit_idx < 4) {
        size /= 1024.0;
        unit_idx++;
    }

    if (unit_idx == 0) {
        snprintf(buf, buf_size, "%.0f %s", size, units[unit_idx]);
    } else {
        snprintf(buf, buf_size, "%.2f %s", size, units[unit_idx]);
    }
}

void mbr_init(MBR* mbr) {
    memset(mbr, 0, sizeof(MBR));
    mbr->signature = MBR_SIGNATURE;
}

int mbr_is_valid(const MBR* mbr) {
    return mbr->signature == MBR_SIGNATURE;
}

void mbr_print(const MBR* mbr) {
    printf("MBR Signature: 0x%04X (%s)\n", mbr->signature,
           mbr_is_valid(mbr) ? "valid" : "INVALID");
    printf("\nPartition Table:\n");
    printf("%-4s %-10s %-10s %-12s %-12s %-8s %s\n",
           "#", "Boot", "Type", "Start", "End", "Sectors", "Size");
    printf("----------------------------------------------------------------\n");

    for (int i = 0; i < MBR_PARTITION_COUNT; i++) {
        const PartitionEntry* pe = &mbr->partitions[i];
        if (partition_is_empty(pe)) {
            printf("%-4d %-10s %-10s %-12s %-12s %-8s %s\n",
                   i + 1, "No", "Empty", "-", "-", "-", "-");
        } else {
            char size_str[16];
            uint64_t bytes = (uint64_t)pe->sector_count * MBR_SECTOR_SIZE;
            format_size(bytes, size_str, sizeof(size_str));

            printf("%-4d %-10s 0x%02X %-8s %-12u %-12u %-8u %s\n",
                   i + 1,
                   partition_is_bootable(pe) ? "Yes" : "No",
                   pe->type,
                   partition_get_type_name(pe->type),
                   pe->start_lba,
                   pe->start_lba + pe->sector_count - 1,
                   pe->sector_count,
                   size_str);
        }
    }
}

void partition_init(PartitionEntry* pe) {
    memset(pe, 0, sizeof(PartitionEntry));
}

int partition_is_empty(const PartitionEntry* pe) {
    return pe->type == PART_TYPE_EMPTY;
}

int partition_is_bootable(const PartitionEntry* pe) {
    return pe->boot_flag == 0x80;
}

void partition_set_bootable(PartitionEntry* pe, int bootable) {
    pe->boot_flag = bootable ? 0x80 : 0x00;
}

const char* partition_get_type_name(uint8_t type) {
    switch (type) {
        case PART_TYPE_EMPTY:     return "Empty";
        case PART_TYPE_FAT12:     return "FAT12";
        case PART_TYPE_FAT16_S:   return "FAT16";
        case PART_TYPE_FAT16_L:   return "FAT16";
        case PART_TYPE_NTFS:      return "NTFS/exFAT";
        case PART_TYPE_FAT32:     return "FAT32";
        case PART_TYPE_FAT32_LBA: return "FAT32 LBA";
        case PART_TYPE_FAT16_LBA: return "FAT16 LBA";
        case PART_TYPE_LINUX_SWAP: return "Linux swap";
        case PART_TYPE_LINUX:     return "Linux";
        case PART_TYPE_LINUX_LVM: return "Linux LVM";
        case PART_TYPE_FREEBSD:   return "FreeBSD";
        case PART_TYPE_OPENBSD:   return "OpenBSD";
        case PART_TYPE_NETBSD:    return "NetBSD";
        case PART_TYPE_GPT:       return "GPT";
        case PART_TYPE_EFI:       return "EFI";
        default:                  return "Unknown";
    }
}

// Standard CHS calculation:
// For a given LBA:
//   cylinder = LBA / (heads * sectors_per_track)
//   temp = LBA % (heads * sectors_per_track)
//   head = temp / sectors_per_track
//   sector = temp % sectors_per_track + 1

void lba_to_chs(uint32_t lba, uint8_t* head, uint8_t* sector, uint8_t* cylinder,
                uint32_t cylinders, uint32_t heads, uint32_t sectors_per_track) {
    (void)cylinders; // Not used in calculation, for validation only

    uint32_t h = heads;
    uint32_t s = sectors_per_track;

    uint32_t cyl_val = lba / (h * s);
    uint32_t temp = lba % (h * s);
    uint32_t head_val = temp / s;
    uint32_t sector_val = (temp % s) + 1;

    // Clamp cylinder to 1023 (10 bits max for CHS)
    if (cyl_val > 1023) {
        cyl_val = 1023;
    }

    *head = (uint8_t)head_val;
    // Sector: bits 0-5 = sector number, bits 6-7 = high 2 bits of cylinder
    *sector = (uint8_t)(sector_val | ((cyl_val >> 8) << 6));
    // Cylinder: low 8 bits
    *cylinder = (uint8_t)(cyl_val & 0xFF);
}

uint32_t chs_to_lba(uint8_t head, uint8_t sector, uint8_t cylinder,
                    uint32_t heads, uint32_t sectors_per_track) {
    // Extract cylinder: lower 8 bits from cylinder byte, upper 2 from sector byte
    uint32_t cyl = cylinder | ((sector >> 6) << 8);
    uint32_t sec = sector & 0x3F;

    // LBA = (cylinder * heads + head) * sectors_per_track + (sector - 1)
    return (cyl * heads + head) * sectors_per_track + (sec - 1);
}

int disk_open(Disk* disk, const char* path) {
    memset(disk, 0, sizeof(Disk));
    strncpy(disk->device_path, path, sizeof(disk->device_path) - 1);
    disk->device_path[sizeof(disk->device_path) - 1] = '\0';
    disk->sector_size = MBR_SECTOR_SIZE;
    disk->fd = -1;

    // Get device size
    if (disk_get_size(path, &disk->device_size) != 0) {
        return -1;
    }

    // Get sector size
    disk_get_sector_size(path, &disk->sector_size);

    // Open device
    disk->fd = open(path, O_RDWR);
    if (disk->fd < 0) {
        // Try read-only
        disk->fd = open(path, O_RDONLY);
        if (disk->fd < 0) {
            return -1;
        }
    }

    // Read existing MBR
    if (disk_read_mbr(disk) != 0) {
        // Initialize empty MBR if read fails
        mbr_init(&disk->mbr);
    }

    return 0;
}

void disk_close(Disk* disk) {
    if (disk->fd >= 0) {
        close(disk->fd);
        disk->fd = -1;
    }
}

int disk_read_mbr(Disk* disk) {
    if (disk->fd < 0) {
        return -1;
    }

    if (lseek(disk->fd, 0, SEEK_SET) != 0) {
        return -1;
    }

    ssize_t n = read(disk->fd, &disk->mbr, sizeof(MBR));
    if (n != sizeof(MBR)) {
        return -1;
    }

    return mbr_is_valid(&disk->mbr) ? 0 : -1;
}

int disk_write_mbr(Disk* disk) {
    if (disk->fd < 0) {
        return -1;
    }

    // Reopen for writing if needed
    int writable_fd = disk->fd;
    struct stat st;
    if (fstat(disk->fd, &st) == 0) {
        // Check if we can write
        int flags = fcntl(disk->fd, F_GETFL);
        if ((flags & O_ACCMODE) == O_RDONLY) {
            // Reopen read-write
            writable_fd = open(disk->device_path, O_RDWR);
            if (writable_fd < 0) {
                return -1;
            }
        }
    }

    if (lseek(writable_fd, 0, SEEK_SET) != 0) {
        if (writable_fd != disk->fd) {
            close(writable_fd);
        }
        return -1;
    }

    ssize_t n = write(writable_fd, &disk->mbr, sizeof(MBR));

    if (writable_fd != disk->fd) {
        close(writable_fd);
    }

    if (n != sizeof(MBR)) {
        return -1;
    }

    // Sync to ensure write completes
    fsync(writable_fd == disk->fd ? disk->fd : writable_fd);

    disk->dirty = 0;
    return 0;
}

int disk_get_size(const char* path, uint64_t* size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;
    }

    // Try BLKGETSIZE64 for block devices
    if (ioctl(fd, BLKGETSIZE64, size) == 0) {
        close(fd);
        return 0;
    }

    // Fall back to file size
    struct stat st;
    if (fstat(fd, &st) == 0) {
        *size = st.st_size;
        close(fd);
        return 0;
    }

    close(fd);
    return -1;
}

int disk_get_sector_size(const char* path, uint32_t* size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        *size = MBR_SECTOR_SIZE;
        return -1;
    }

    int sect_size = 0;
    if (ioctl(fd, BLKSSZGET, &sect_size) == 0 && sect_size > 0) {
        *size = (uint32_t)sect_size;
    } else {
        *size = MBR_SECTOR_SIZE;
    }

    close(fd);
    return 0;
}

int partition_create(Disk* disk, int index, uint32_t start_lba, uint32_t sector_count, uint8_t type) {
    if (index < 0 || index >= MBR_PARTITION_COUNT) {
        return -1;
    }

    if (sector_count == 0) {
        return -1;
    }

    // Check bounds
    uint64_t end_sector = (uint64_t)start_lba + sector_count;
    uint64_t max_sectors = disk->device_size / disk->sector_size;
    if (end_sector > max_sectors) {
        return -1;
    }

    // Check for overlaps with existing partitions
    PartitionEntry temp_pe;
    partition_init(&temp_pe);
    temp_pe.type = type;
    temp_pe.start_lba = start_lba;
    temp_pe.sector_count = sector_count;

    for (int i = 0; i < MBR_PARTITION_COUNT; i++) {
        if (i != index && !partition_is_empty(&disk->mbr.partitions[i])) {
            if (partitions_overlap(&temp_pe, &disk->mbr.partitions[i])) {
                return -1;
            }
        }
    }

    PartitionEntry* pe = &disk->mbr.partitions[index];
    partition_init(pe);

    pe->boot_flag = 0x00;
    pe->type = type;
    pe->start_lba = start_lba;
    pe->sector_count = sector_count;

    // Calculate CHS (using standard 1024/255/63 geometry)
    lba_to_chs(start_lba, &pe->start_head, &pe->start_sector, &pe->start_cylinder,
               CHS_CYLINDERS, CHS_HEADS, CHS_SECTORS);

    uint32_t end_lba = start_lba + sector_count - 1;
    lba_to_chs(end_lba, &pe->end_head, &pe->end_sector, &pe->end_cylinder,
               CHS_CYLINDERS, CHS_HEADS, CHS_SECTORS);

    disk->dirty = 1;
    return 0;
}

void partition_delete(Disk* disk, int index) {
    if (index < 0 || index >= MBR_PARTITION_COUNT) {
        return;
    }
    partition_init(&disk->mbr.partitions[index]);
    disk->dirty = 1;
}

int partitions_overlap(const PartitionEntry* p1, const PartitionEntry* p2) {
    if (partition_is_empty(p1) || partition_is_empty(p2)) {
        return 0;
    }

    uint32_t p1_start = p1->start_lba;
    uint32_t p1_end = p1->start_lba + p1->sector_count - 1;
    uint32_t p2_start = p2->start_lba;
    uint32_t p2_end = p2->start_lba + p2->sector_count - 1;

    return (p1_start <= p2_end && p2_start <= p1_end);
}

int partition_validate(const Disk* disk, int index) {
    if (index < 0 || index >= MBR_PARTITION_COUNT) {
        return -1;
    }

    const PartitionEntry* pe = &disk->mbr.partitions[index];
    if (partition_is_empty(pe)) {
        return 0;
    }

    // Check bounds
    uint64_t end_sector = (uint64_t)pe->start_lba + pe->sector_count;
    uint64_t max_sectors = disk->device_size / disk->sector_size;
    if (end_sector > max_sectors) {
        return -1;
    }

    // Check for overlaps with other partitions
    for (int i = 0; i < MBR_PARTITION_COUNT; i++) {
        if (i != index && !partition_is_empty(&disk->mbr.partitions[i])) {
            if (partitions_overlap(pe, &disk->mbr.partitions[i])) {
                return -1;
            }
        }
    }

    return 0;
}

uint64_t align_sector(uint64_t sector) {
    // Align to 1 MiB boundary (2048 sectors of 512 bytes)
    const uint64_t alignment = 2048;
    return ((sector + alignment - 1) / alignment) * alignment;
}
