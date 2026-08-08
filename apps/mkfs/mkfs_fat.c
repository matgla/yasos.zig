/**
 * main.c
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
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

#include <stdio.h>
#include <stdlib.h>

#include <ff.h>

#include "platform.h"

uint8_t buffer[4096] = {0};

/* Cluster size in bytes, and it really is bytes: MKFS_PARM.au_size is
 * documented "Cluster size (byte)" and f_mkfs divides it by the sector size to
 * get sectors per cluster. The previous value here was 8, i.e. eight *bytes*,
 * which divides to zero sectors and silently falls back to FatFs's own
 * size-based default -- that is how this volume ended up with 8 KiB clusters
 * that nobody picked.
 *
 * The size matters more than it looks. FatFs clips every disk_write at the
 * cluster boundary (ff.c, "Clip at cluster boundary"), so the cluster is the
 * largest write the SD driver can ever be handed. That makes it look like a
 * throughput knob. It is not, on this hardware: 64 KiB clusters were tried on
 * the RP2350 rig, cutting a 32 KiB write from four disk_write calls to one, and
 * changed write throughput by nothing at all -- 4435 -> 4385 KiB/s, inside a
 * 3993-4542 noise band.
 *
 * The prediction that said otherwise (~7700 KiB/s) came from a two-point fit
 * that attributed all unexplained time to a *per-request* term. It reproduced
 * the measurement it was built from and had no predictive power. The real cost
 * is per-block -- doubling the driver's chunk size did not move it either -- so
 * how many requests those blocks arrive in simply does not matter.
 *
 * The default is therefore 8 KiB, which is what FatFs's own size heuristic had
 * been silently choosing all along. Do not raise it for write speed without new
 * evidence; it only buys wasted slack on a volume full of small sources. */
#define DEFAULT_CLUSTER_BYTES 8192u

int main(int argc, char *argv[]) {
  if (argc < 2) {
    printf("Usage: %s <device> [cluster-bytes]\n", argv[0]);
    printf("  cluster-bytes  power of two, default %u\n",
           DEFAULT_CLUSTER_BYTES);
    return 1;
  }

  unsigned long cluster_bytes = DEFAULT_CLUSTER_BYTES;
  if (argc >= 3) {
    cluster_bytes = strtoul(argv[2], NULL, 0);
    if (cluster_bytes == 0 || (cluster_bytes & (cluster_bytes - 1)) != 0) {
      printf("Cluster size must be a power of two, got: %s\n", argv[2]);
      return 1;
    }
  }

  printf("Formatting FAT filesystem on device: %s\n", argv[1]);
  printf("Cluster size: %lu bytes (%lu sectors)\n", cluster_bytes,
         cluster_bytes / 512u);
  initialize_platform(argv[1]);
  MKFS_PARM params = {
      .fmt = FM_FAT32,
      .n_fat = 0,
      .align = 0,
      .n_root = 0,
      .au_size = (DWORD)cluster_bytes,
  };

  FRESULT result = f_mkfs("0:", &params, buffer, sizeof(buffer));
  switch (result) {
  case FR_OK:
    printf("FAT filesystem created successfully.\n");
    break;
  case FR_DISK_ERR:
    printf("Disk error occurred.\n");
    break;
  case FR_INT_ERR:
    printf("Internal error occurred.\n");
    break;
  case FR_NOT_READY:
    printf("Disk not ready.\n");
    break;
  case FR_NO_FILESYSTEM:
    printf("No valid FAT volume found.\n");
    break;
  case FR_MKFS_ABORTED:
    printf("mkfs operation aborted.\n");
    break;
  default:
    printf("An unknown error occurred: %d\n", result);
  }
  deinitialize_platform();
}