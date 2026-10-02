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

/* FatFs's disk layer over the volume mkfs.fat formats (blockdev.c). */

#include "blockdev.h"

#include <ff.h>
#include <diskio.h>

#include <time.h>

static const volume *bound;

void volume_bind_fatfs(const volume *vol) { bound = vol; }

DSTATUS disk_initialize(BYTE pdrv) {
  (void)pdrv;
  return bound ? 0 : STA_NOINIT;
}

DSTATUS disk_status(BYTE pdrv) {
  (void)pdrv;
  return bound ? 0 : STA_NOINIT;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
  (void)pdrv;
  if (!bound)
    return RES_NOTRDY;
  return volume_io(bound, 0, sector, buff, count) == 0 ? RES_OK : RES_ERROR;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
  (void)pdrv;
  if (!bound)
    return RES_NOTRDY;
  return volume_io(bound, 1, sector, (void *)buff, count) == 0 ? RES_OK
                                                                : RES_ERROR;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
  (void)pdrv;
  if (!bound)
    return RES_NOTRDY;
  switch (cmd) {
  case CTRL_SYNC:
    return RES_OK; /* writes go straight to the descriptor */
  case GET_SECTOR_COUNT:
    *(LBA_t *)buff = bound->sectors;
    return RES_OK;
  case GET_SECTOR_SIZE:
    *(WORD *)buff = VOLUME_SECTOR;
    return RES_OK;
  case GET_BLOCK_SIZE:
    /* The erase block, in sectors: mkfs aligns the data area to it. 1 MiB
     * matches fdisk's partition alignment; tiny volumes (test images) would
     * lose too much of themselves to it. */
    *(DWORD *)buff = bound->sectors >= 131072u ? 2048u : 1u;
    return RES_OK;
  default:
    return RES_PARERR;
  }
}

DWORD get_fattime(void) {
  time_t now = time(NULL);
  struct tm *tm = gmtime(&now);
  if (!tm || tm->tm_year < 80)
    return ((DWORD)(2026 - 1980) << 25) | (1u << 21) | (1u << 16);
  return ((DWORD)(tm->tm_year - 80) << 25) | ((DWORD)(tm->tm_mon + 1) << 21) |
         ((DWORD)tm->tm_mday << 16) | ((DWORD)tm->tm_hour << 11) |
         ((DWORD)tm->tm_min << 5) | ((DWORD)tm->tm_sec >> 1);
}
