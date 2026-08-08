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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "mbr.h"
#include "ui.h"

static void print_usage(const char* program) {
    printf("Usage: %s [options] <device>\n", program);
    printf("\nOptions:\n");
    printf("  -h, --help     Show this help message\n");
    printf("  -l, --list     List partitions and exit (non-interactive)\n");
    printf("  -n, --new      Create new partition table (DESTRUCTIVE)\n");
    printf("\nExamples:\n");
    printf("  %s /dev/sdb           # Interactive mode\n", program);
    printf("  %s -l /dev/sdb        # List partitions\n", program);
    printf("  %s -n /dev/sdb        # Create new empty partition table\n", program);
}

static int is_block_device(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return 0;
    }
    return S_ISBLK(st.st_mode);
}

int main(int argc, char* argv[]) {
    int list_mode = 0;
    int new_table = 0;
    const char* device_path = NULL;

    // Parse arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-l") == 0 || strcmp(argv[i], "--list") == 0) {
            list_mode = 1;
        } else if (strcmp(argv[i], "-n") == 0 || strcmp(argv[i], "--new") == 0) {
            new_table = 1;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            return 1;
        } else {
            device_path = argv[i];
        }
    }

    if (device_path == NULL) {
        fprintf(stderr, "Error: No device specified\n");
        print_usage(argv[0]);
        return 1;
    }

    // Check if device exists and is accessible
    if (access(device_path, F_OK) != 0) {
        fprintf(stderr, "Error: Device '%s' does not exist\n", device_path);
        return 1;
    }

    if (!is_block_device(device_path)) {
        // Allow regular files for testing (e.g., disk images)
        // but warn the user
        struct stat st;
        if (stat(device_path, &st) == 0 && S_ISREG(st.st_mode)) {
            printf("Note: '%s' is a regular file, not a block device\n", device_path);
        }
    }

    Disk disk;
    if (disk_open(&disk, device_path) != 0) {
        fprintf(stderr, "Error: Cannot open device '%s'\n", device_path);
        return 1;
    }

    // List mode - just print and exit
    if (list_mode) {
        printf("Disk: %s\n", disk.device_path);
        char size_str[32];
        format_size(disk.device_size, size_str, sizeof(size_str));
        printf("Size: %s (%lu bytes)\n", size_str, (unsigned long)disk.device_size);
        printf("Sector size: %u bytes\n", disk.sector_size);
        printf("\n");

        if (!mbr_is_valid(&disk.mbr)) {
            printf("Warning: MBR signature is invalid (0x%04X)\n", disk.mbr.signature);
        }

        mbr_print(&disk.mbr);
        disk_close(&disk);
        return 0;
    }

    // New table mode - create empty MBR and write
    if (new_table) {
        printf("WARNING: This will DESTROY the partition table on %s\n", device_path);
        printf("All data on this device may become inaccessible!\n");
        printf("Are you sure? (type 'yes' to confirm): ");

        char confirm[10];
        if (fgets(confirm, sizeof(confirm), stdin) == NULL) {
            printf("Aborted.\n");
            disk_close(&disk);
            return 1;
        }

        // Remove newline
        size_t len = strlen(confirm);
        if (len > 0 && confirm[len - 1] == '\n') {
            confirm[len - 1] = '\0';
        }

        if (strcmp(confirm, "yes") != 0) {
            printf("Aborted.\n");
            disk_close(&disk);
            return 1;
        }

        mbr_init(&disk.mbr);
        disk.dirty = 1;

        if (disk_write_mbr(&disk) != 0) {
            fprintf(stderr, "Error: Failed to write new partition table\n");
            disk_close(&disk);
            return 1;
        }

        printf("New partition table created on %s\n", device_path);
        disk_close(&disk);
        return 0;
    }

    // Interactive mode with ncurses UI
    ui_init();
    ui_run(&disk);
    ui_cleanup();

    disk_close(&disk);
    return 0;
}
