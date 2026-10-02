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

#include "blockdev.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

/* Offsets past 2 GiB: yasos's off_t is 32 bits, so the device is addressed
 * through lseek64 there; the host build is compiled with a 64-bit off_t. */
#ifdef MKFS_HOST
typedef off_t vol_off_t;
#define vol_lseek lseek
#else
typedef off64_t vol_off_t;
#define vol_lseek lseek64
#endif

static uint64_t device_sectors(int fd) {
  unsigned long long bytes = 0;
  if (ioctl(fd, (int)BLKGETSIZE64, &bytes) == 0 && bytes > 0)
    return bytes / VOLUME_SECTOR;
  struct stat st;
  if (fstat(fd, &st) == 0 && st.st_size > 0)
    return (uint64_t)st.st_size / VOLUME_SECTOR;
  return 0;
}

/* Is *path*, or partition *partition* of it under its Linux name (/dev/mmc0
 * -> /dev/mmc0p2, /dev/sda -> /dev/sda2), in /proc/mounts? */
static int mounted(const char *tool, const char *path, int partition) {
  FILE *mounts = fopen("/proc/mounts", "r");
  if (!mounts)
    return 0;
  char name[128];
  size_t n = strlen(path);
  int digit = n > 0 && path[n - 1] >= '0' && path[n - 1] <= '9';
  if (partition)
    snprintf(name, sizeof(name), "%s%s%d", path, digit ? "p" : "", partition);
  else
    snprintf(name, sizeof(name), "%s", path);
  size_t len = strlen(name);
  char line[256];
  int found = 0;
  while (fgets(line, sizeof(line), mounts))
    if (strncmp(line, name, len) == 0 &&
        (line[len] == ' ' || line[len] == '\t')) {
      fprintf(stderr, "%s: %s is mounted: %s", tool, name, line);
      found = 1;
    }
  fclose(mounts);
  return found;
}

static uint32_t get32(const uint8_t *at) {
  return (uint32_t)at[0] | ((uint32_t)at[1] << 8) | ((uint32_t)at[2] << 16) |
         ((uint32_t)at[3] << 24);
}

int volume_open(const char *tool, const char *path, int partition,
                volume *out) {
  if (partition < 0 || partition > 4) {
    fprintf(stderr, "%s: partition %d: MBR partitions are 1 to 4\n", tool,
            partition);
    return -1;
  }
  if (mounted(tool, path, partition)) {
    fprintf(stderr, "%s: unmount it first\n", tool);
    return -1;
  }
  out->fd = open(path, O_RDWR);
  if (out->fd < 0) {
    fprintf(stderr, "%s: cannot open %s: %s\n", tool, path, strerror(errno));
    return -1;
  }
  uint64_t total = device_sectors(out->fd);
  if (total == 0) {
    fprintf(stderr, "%s: %s: cannot tell its size\n", tool, path);
    return -1;
  }
  out->start = 0;
  out->sectors = total > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)total;
  if (partition == 0)
    return 0;

  uint8_t mbr[VOLUME_SECTOR];
  if (volume_io(out, 0, 0, mbr, 1) != 0) {
    fprintf(stderr, "%s: cannot read %s: %s\n", tool, path, strerror(errno));
    return -1;
  }
  const uint8_t *entry = mbr + 446 + 16 * (partition - 1);
  uint32_t start = get32(entry + 8), sectors = get32(entry + 12);
  if (mbr[510] != 0x55 || mbr[511] != 0xAA || entry[4] == 0 || sectors == 0) {
    fprintf(stderr, "%s: %s has no partition %d (see fdisk -l)\n", tool, path,
            partition);
    return -1;
  }
  if (start == 0 || (uint64_t)start + sectors > total) {
    fprintf(stderr, "%s: partition %d of %s lies outside the disk\n", tool,
            partition, path);
    return -1;
  }
  out->start = start;
  out->sectors = sectors;
  return 0;
}

/* read/write may return short on a device; loop until the run is done. */
int volume_io(const volume *vol, int write_mode, uint64_t sector, void *buffer,
              uint32_t count) {
  if (sector + count > vol->sectors)
    return -1;
  vol_off_t offset = (vol_off_t)((vol->start + sector) * VOLUME_SECTOR);
  if (vol_lseek(vol->fd, offset, SEEK_SET) != offset)
    return -1;
  size_t total = (size_t)count * VOLUME_SECTOR;
  size_t done = 0;
  while (done < total) {
    ssize_t n = write_mode
                    ? write(vol->fd, (const char *)buffer + done, total - done)
                    : read(vol->fd, (char *)buffer + done, total - done);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return -1;
    done += (size_t)n;
  }
  return 0;
}
