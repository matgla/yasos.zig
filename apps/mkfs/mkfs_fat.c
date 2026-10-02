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

/* mkfs.fat: make a FAT filesystem with FatFs, the same code the kernel and
 * the bootloader read it with. The options are dosfstools' where they
 * overlap; -p is ours (see blockdev.h). */

#include "blockdev.h"

#include <ff.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void usage(const char *argv0) {
  printf("usage: %s [-n LABEL] [-F 12|16|32] [-s SECTORS] [-p N] DEVICE\n"
         "\n"
         "Make a FAT filesystem on DEVICE (a partition, a disk or an image\n"
         "file). EVERYTHING ON IT IS LOST.\n"
         "\n"
         "  -n LABEL    volume label, up to 11 characters (/etc/fstab's LABEL=)\n"
         "  -F BITS     FAT32, or FAT12/16 (FatFs picks which by size); default\n"
         "              FAT32 from 512 MiB up, what fits below that\n"
         "  -s SECTORS  sectors per cluster, a power of two (default: by size)\n"
         "  -p N        format partition N of DEVICE's MBR instead of all of it\n",
         argv0);
}

static const char *fresult_name(FRESULT result) {
  switch (result) {
  case FR_OK: return "ok";
  case FR_DISK_ERR: return "disk error";
  case FR_NOT_READY: return "not ready";
  case FR_NO_FILESYSTEM: return "no filesystem";
  case FR_MKFS_ABORTED: return "mkfs aborted (the volume is too small or too "
                               "big for that FAT type)";
  case FR_INVALID_PARAMETER: return "invalid parameter";
  case FR_INVALID_NAME: return "invalid label";
  case FR_INT_ERR: return "internal error";
  case FR_NOT_ENOUGH_CORE: return "out of memory";
  default: {
    static char unknown[24];
    snprintf(unknown, sizeof(unknown), "FatFs error %d", (int)result);
    return unknown;
  }
  }
}

/* FAT12 or FAT16, decided by the cluster count as the spec says, for a
 * FAT12/16 boot sector. */
static int fat12_or_16(const unsigned char *sector) {
  unsigned bytes_per_sector = sector[11] | (sector[12] << 8);
  unsigned per_cluster = sector[13];
  unsigned reserved = sector[14] | (sector[15] << 8);
  unsigned fats = sector[16];
  unsigned root_entries = sector[17] | (sector[18] << 8);
  unsigned long total = sector[19] | (sector[20] << 8);
  if (total == 0)
    total = sector[32] | (sector[33] << 8) | ((unsigned long)sector[34] << 16) |
            ((unsigned long)sector[35] << 24);
  unsigned fat_size = sector[22] | (sector[23] << 8);
  if (bytes_per_sector == 0 || per_cluster == 0)
    return 16;
  unsigned root_sectors =
      (root_entries * 32 + bytes_per_sector - 1) / bytes_per_sector;
  unsigned long data = total - reserved - fats * fat_size - root_sectors;
  return data / per_cluster < 4085 ? 12 : 16;
}

/* Put the label into the boot sector too, where the kernel looks for it
 * (source/kernel/drivers/block.zig) -- f_setlabel only writes the root
 * directory's label entry. FAT32 keeps a backup boot sector to update as
 * well. Returns the FAT flavour found: 12, 16 or 32; 0 on error. */
static int stamp_boot_sector(const volume *vol, const char *label) {
  unsigned char sector[VOLUME_SECTOR];
  if (volume_io(vol, 0, 0, sector, 1) != 0)
    return 0;
  int fat32 = sector[22] == 0 && sector[23] == 0;
  int bits = fat32 ? 32 : fat12_or_16(sector);
  size_t signature = fat32 ? 0x42 : 0x26;
  size_t offset = fat32 ? 0x47 : 0x2B;
  if (sector[signature] == 0x29) {
    memset(sector + offset, ' ', 11);
    memcpy(sector + offset, label[0] ? label : "NO NAME", label[0] ? strlen(label) : 7);
    /* FatFs R0.16 writes a generic "FAT     " type for FAT12/16; say which,
     * as dosfstools does -- toybox blkid identifies the volume by it. */
    if (!fat32)
      memcpy(sector + 0x36, bits == 12 ? "FAT12   " : "FAT16   ", 8);
    if (volume_io(vol, 1, 0, sector, 1) != 0)
      return 0;
    if (fat32) {
      unsigned backup = sector[50] | (sector[51] << 8);
      if (backup != 0 && backup < 32 && volume_io(vol, 1, backup, sector, 1) != 0)
        return 0;
    }
  }
  return bits;
}

int main(int argc, char *argv[]) {
  const char *path = NULL;
  char label[12] = "";
  int bits = 0, partition = 0;
  unsigned long per_cluster = 0;

  /* No getopt in the yasos libc: options first, then the device. */
  int i = 1;
  for (; i < argc && argv[i][0] == '-' && argv[i][1] != '\0'; ++i) {
    char opt = argv[i][1];
    if (opt == 'h' || strcmp(argv[i], "--help") == 0) {
      usage(argv[0]);
      return 0;
    }
    if (argv[i][2] != '\0' || !strchr("nFsp", opt) || i + 1 >= argc) {
      usage(argv[0]);
      return 2;
    }
    const char *value = argv[++i];
    switch (opt) {
    case 'n':
      if (strlen(value) > 11) {
        fprintf(stderr, "mkfs.fat: label %s: at most 11 characters\n", value);
        return 2;
      }
      /* FAT labels are upper case; FatFs would refuse lower case. */
      for (size_t k = 0; value[k]; ++k)
        label[k] = (char)toupper((unsigned char)value[k]);
      label[strlen(value)] = '\0';
      break;
    case 'F':
      bits = atoi(value);
      if (bits != 12 && bits != 16 && bits != 32) {
        fprintf(stderr, "mkfs.fat: -F takes 12, 16 or 32\n");
        return 2;
      }
      break;
    case 's':
      per_cluster = strtoul(value, NULL, 0);
      if (per_cluster == 0 || per_cluster > 128 ||
          (per_cluster & (per_cluster - 1)) != 0) {
        fprintf(stderr, "mkfs.fat: -s takes a power of two up to 128\n");
        return 2;
      }
      break;
    case 'p':
      partition = atoi(value);
      break;
    }
  }
  if (i != argc - 1) {
    usage(argv[0]);
    return 2;
  }
  path = argv[i];

  volume vol;
  if (volume_open("mkfs.fat", path, partition, &vol) != 0)
    return 1;
  volume_bind_fatfs(&vol);

  /* FM_SFD: FatFs sees the volume as a whole and must not put a partition
   * table of its own in it. From 512 MiB up it is FAT32, as dosfstools does
   * -- FatFs alone would pick FAT16 with 32 KiB clusters up to 2 GiB. */
  BYTE format = bits == 32                    ? FM_FAT32
                : bits != 0                   ? FM_FAT
                : vol.sectors >= 1048576u     ? FM_FAT32
                                              : FM_ANY;
  MKFS_PARM options = {.fmt = (BYTE)(format | FM_SFD),
                       .n_fat = 2,
                       .align = 0,
                       .n_root = 0,
                       .au_size = (DWORD)(per_cluster * VOLUME_SECTOR)};
  /* mkfs's scratch: bigger means fewer, larger writes while it clears the
   * FATs, which on a big card is most of the run. */
  size_t work_size = 32 * 1024;
  BYTE *work = malloc(work_size);
  if (!work) {
    work_size = 4096;
    work = malloc(work_size);
  }
  if (!work) {
    fprintf(stderr, "mkfs.fat: out of memory\n");
    return 1;
  }
  FRESULT result = f_mkfs("", &options, work, (UINT)work_size);
  if (result == FR_MKFS_ABORTED && bits == 0 && format == FM_FAT32) {
    options.fmt = FM_ANY | FM_SFD;
    result = f_mkfs("", &options, work, (UINT)work_size);
  }
  free(work);
  if (result != FR_OK) {
    fprintf(stderr, "mkfs.fat: %s\n", fresult_name(result));
    return 1;
  }

  int made = stamp_boot_sector(&vol, label);
  if (made == 0) {
    fprintf(stderr, "mkfs.fat: cannot write the boot sector\n");
    return 1;
  }
  if (label[0]) {
    FATFS fs;
    result = f_mount(&fs, "", 1);
    if (result == FR_OK)
      result = f_setlabel(label);
    f_unmount("");
    if (result != FR_OK)
      fprintf(stderr, "mkfs.fat: warning: label entry: %s\n",
              fresult_name(result));
  }
  fsync(vol.fd);
  close(vol.fd);
  printf("%s: FAT%d, %u sectors%s%s\n", path, made, (unsigned)vol.sectors,
         label[0] ? ", label " : "", label);
  return 0;
}
