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

/* mkfs.ext4: make an ext4 filesystem with lwext4, the same code the kernel
 * mounts it with (source/fs/ext4): 1 KiB blocks, extents, no journal -- what
 * lwext4 is built for here. A volume from Linux's mke2fs defaults (journal,
 * 64bit, flex_bg, metadata_csum) is not. The options are mke2fs's where they
 * overlap; -p is ours (see blockdev.h). */

#include "blockdev.h"

#include <ext4.h>
#include <ext4_blockdev.h>
#include <ext4_fs.h>
#include <ext4_mkfs.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *argv0) {
  printf("usage: %s [-L LABEL] [-p N] DEVICE\n"
         "\n"
         "Make an ext4 filesystem on DEVICE (a partition, a disk or an image\n"
         "file): 1 KiB blocks, no journal. EVERYTHING ON IT IS LOST.\n"
         "\n"
         "  -L LABEL  volume label, up to 16 characters (/etc/fstab's LABEL=)\n"
         "  -p N      format partition N of DEVICE's MBR instead of all of it\n",
         argv0);
}

static volume vol;
static uint8_t sector_buffer[VOLUME_SECTOR];

static int bd_open(struct ext4_blockdev *bdev) {
  (void)bdev;
  return EOK;
}

static int bd_close(struct ext4_blockdev *bdev) {
  (void)bdev;
  return EOK;
}

static int bd_read(struct ext4_blockdev *bdev, void *buf, uint64_t blk_id,
                   uint32_t blk_cnt) {
  (void)bdev;
  return volume_io(&vol, 0, blk_id, buf, blk_cnt) == 0 ? EOK : EIO;
}

static int bd_write(struct ext4_blockdev *bdev, const void *buf,
                    uint64_t blk_id, uint32_t blk_cnt) {
  (void)bdev;
  return volume_io(&vol, 1, blk_id, (void *)buf, blk_cnt) == 0 ? EOK : EIO;
}

static struct ext4_blockdev_iface iface = {
    .open = bd_open,
    .bread = bd_read,
    .bwrite = bd_write,
    .close = bd_close,
    .ph_bsize = VOLUME_SECTOR,
    .ph_bbuf = sector_buffer,
};

static struct ext4_blockdev bdev = {
    .bdif = &iface,
    .part_offset = 0,
};

static struct ext4_fs fs;

static uint32_t now_seconds(void) {
  time_t now = time(NULL);
  return now > 0 ? (uint32_t)now : 0;
}

/* Everything mkfs made carries a zero time; date it like the rest. */
static void stamp(const char *path) {
  uint32_t now = now_seconds();
  ext4_atime_set(path, now);
  ext4_mtime_set(path, now);
  ext4_ctime_set(path, now);
}

int main(int argc, char *argv[]) {
  const char *label = "";
  int partition = 0;

  /* No getopt in the yasos libc: options first, then the device. */
  int i = 1;
  for (; i < argc && argv[i][0] == '-' && argv[i][1] != '\0'; ++i) {
    char opt = argv[i][1];
    if (opt == 'h' || strcmp(argv[i], "--help") == 0) {
      usage(argv[0]);
      return 0;
    }
    if (argv[i][2] != '\0' || (opt != 'L' && opt != 'p') || i + 1 >= argc) {
      usage(argv[0]);
      return 2;
    }
    const char *value = argv[++i];
    if (opt == 'L') {
      if (strlen(value) > 16) {
        fprintf(stderr, "mkfs.ext4: label %s: at most 16 characters\n", value);
        return 2;
      }
      label = value;
    } else {
      partition = atoi(value);
    }
  }
  if (i != argc - 1) {
    usage(argv[0]);
    return 2;
  }
  const char *path = argv[i];

  if (volume_open("mkfs.ext4", path, partition, &vol) != 0)
    return 1;
  iface.ph_bcnt = vol.sectors;
  bdev.part_size = (uint64_t)vol.sectors * VOLUME_SECTOR;

  struct ext4_mkfs_info info;
  memset(&info, 0, sizeof(info));
  info.len = bdev.part_size;
  info.block_size = 1024;
  info.journal = false;
  info.label = label;
  /* One inode per 8 KiB, 16 KiB from 1 GiB up -- mke2fs's ratios, near
   * enough. lwext4's default is one per 4 KiB: 1.5 million on a 6 GiB /home,
   * 365 MiB of inode tables nothing will ever fill. */
  uint64_t ratio = bdev.part_size >= (1ull << 30) ? 16384 : 8192;
  info.inodes = (uint32_t)(bdev.part_size / ratio);
  memset(&fs, 0, sizeof(fs));
  int rc = ext4_mkfs(&fs, &bdev, &info, F_SET_EXT4);
  if (rc != EOK) {
    fprintf(stderr, "mkfs.ext4: mkfs failed (%d)\n", rc);
    return 1;
  }

  /* lwext4's mkfs leaves the root and lost+found undated and lost+found
   * world-writable; fix both, as mke2fs makes them. */
  ext4_set_clock(now_seconds);
  rc = ext4_device_register(&bdev, "vol");
  if (rc == EOK)
    rc = ext4_mount("vol", "/mp/", false);
  if (rc != EOK) {
    fprintf(stderr, "mkfs.ext4: cannot mount the new filesystem (%d)\n", rc);
    ext4_device_unregister("vol");
    return 1;
  }
  ext4_mode_set("/mp/", 0755);
  stamp("/mp/");
  ext4_mode_set("/mp/lost+found", 0700);
  stamp("/mp/lost+found");
  rc = ext4_umount("/mp/");
  ext4_device_unregister("vol");
  if (rc != EOK) {
    fprintf(stderr, "mkfs.ext4: unmounting the new filesystem failed (%d)\n",
            rc);
    return 1;
  }
  fsync(vol.fd);
  close(vol.fd);
  printf("%s: ext4, %u blocks of 1024, %u inodes%s%s\n", path,
         (unsigned)(bdev.part_size / 1024), (unsigned)info.inodes,
         label[0] ? ", label " : "", label);
  return 0;
}
