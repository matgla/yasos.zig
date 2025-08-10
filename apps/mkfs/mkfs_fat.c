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

#include <ff.h>

#include "platform.h"

uint8_t buffer[4096] = {0};

int main(int argc, char *argv[]) {
  if (argc < 2) {
    printf("Usage: %s <command>\n", argv[0]);
    return 1;
  }

  printf("Formatting FAT filesystem on device: %s\n", argv[1]);
  printf("Using blocks: %s\n", argv[2]);
  initialize_platform(argv[1]);
  MKFS_PARM params = {
      .fmt = FM_FAT32,
      .n_fat = 0,
      .align = 0,
      .n_root = 0,
      .au_size = 8,
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