/* Host disk I/O backend for fatimg: a single FAT image file is the disk.
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>

#include <ff.h>
#include <diskio.h>

static FILE *g_img = NULL;
static DWORD g_sectors = 0;

int fatimg_open(const char *path);
int fatimg_open(const char *path) {
  g_img = fopen(path, "r+b");
  if (!g_img)
    return -1;
  fseek(g_img, 0, SEEK_END);
  long sz = ftell(g_img);
  fseek(g_img, 0, SEEK_SET);
  g_sectors = (DWORD)(sz / 512);
  return 0;
}

void fatimg_close(void);
void fatimg_close(void) {
  if (g_img) {
    fflush(g_img);
    fclose(g_img);
    g_img = NULL;
  }
}

DSTATUS disk_initialize(BYTE pdrv) {
  (void)pdrv;
  return g_img ? 0 : STA_NOINIT;
}

DSTATUS disk_status(BYTE pdrv) {
  (void)pdrv;
  return g_img ? 0 : STA_NOINIT;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
  (void)pdrv;
  if (!g_img)
    return RES_NOTRDY;
  if (fseek(g_img, (long)sector * 512, SEEK_SET) != 0)
    return RES_ERROR;
  if (fread(buff, 512, count, g_img) != count)
    return RES_ERROR;
  return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
  (void)pdrv;
  if (!g_img)
    return RES_NOTRDY;
  if (fseek(g_img, (long)sector * 512, SEEK_SET) != 0)
    return RES_ERROR;
  if (fwrite(buff, 512, count, g_img) != count)
    return RES_ERROR;
  return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
  (void)pdrv;
  switch (cmd) {
  case CTRL_SYNC:
    if (g_img)
      fflush(g_img);
    return RES_OK;
  case GET_SECTOR_COUNT:
    *(LBA_t *)buff = g_sectors;
    return RES_OK;
  case GET_SECTOR_SIZE:
    *(WORD *)buff = 512;
    return RES_OK;
  case GET_BLOCK_SIZE:
    *(DWORD *)buff = 1;
    return RES_OK;
  default:
    return RES_PARERR;
  }
}

DWORD get_fattime(void) { return 0; }
