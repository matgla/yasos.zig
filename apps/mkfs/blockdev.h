/*
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version
 * 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General
 * Public License along with this program. If not, see
 * <https://www.gnu.org/licenses/>.
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

/* The volume a mkfs formats: a device or image file, whole, or one primary
 * partition of its MBR (-p N). The partition form is how an image file on a
 * PC is formatted -- it has no /dev/...p1 nodes -- and works on a device too.
 * Plain lseek + read/write on a descriptor, so the same code drives
 * /dev/mmc0p2 on yasos, /dev/sdX on Linux and an image file on either. */

#define VOLUME_SECTOR 512u

typedef struct {
  int fd;
  uint64_t start;   /* first sector of the volume on the device */
  uint32_t sectors; /* its length */
} volume;

/* Open *path* for formatting: the whole of it when *partition* is 0,
 * otherwise MBR partition 1..4. Refuses anything mounted. 0, or -1 after
 * printing why (prefixed with *tool*). */
int volume_open(const char *tool, const char *path, int partition,
                volume *out);

/* Read or write *count* sectors at *sector*, counted from the volume's
 * start. 0 or -1. */
int volume_io(const volume *vol, int write_mode, uint64_t sector, void *buffer,
              uint32_t count);

/* The volume FatFs's disk layer (disk_read, disk_write, ...) works on. */
void volume_bind_fatfs(const volume *vol);
