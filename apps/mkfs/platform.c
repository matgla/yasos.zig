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

#include <ff.h>

#include <diskio.h>

#include <fcntl.h>
#include <unistd.h>

#include <stdio.h>

int fd = -1;

DSTATUS disk_initialize(BYTE pdrv) {
  printf("Initializing disk with pdrv: %d\n", pdrv);
  DSTATUS status = (1 << STA_NOINIT);
  return status;
}

DSTATUS disk_status(BYTE pdrv) {
  printf("Checking disk status for pdrv: %d\n", pdrv);
  return (1 << STA_NOINIT); // Example status
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
  printf("Reading from disk pdrv: %d, sector: %llu, count: %u\n", pdrv, sector,
         count);
  // Simulate a read operation
  for (UINT i = 0; i < count; i++) {
    buff[i] = (BYTE)(sector + i); // Example data
  }
  return RES_OK; // Indicate success
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
  lseek(fd, sector * 512, SEEK_SET); // Move to the correct sector
  for (UINT i = 0; i < count; i++) {
    write(fd, &buff[i * 512], 512); // Write 512 bytes per sector
  }
  return RES_OK; // Indicate success
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
  printf("Disk ioctl command: %d for pdrv: %d\n", cmd, pdrv);
  // Handle different commands
  switch (cmd) {
  case CTRL_SYNC:
    printf("Syncing disk pdrv: %d\n", pdrv);
    return RES_OK;
  case GET_SECTOR_COUNT:
    printf("Getting sector count: %d\n", 2097152);
    *(DWORD *)buff = 2097152; // Example sector count
    return RES_OK;
  case GET_SECTOR_SIZE:
    printf("Getting sector size: %d\n", 512);
    *(WORD *)buff = 512; // Example sector size
    return RES_OK;
  case GET_BLOCK_SIZE:
    printf("Getting block size: %d\n", 8);
    *(DWORD *)buff = 8; // Example block size
    return RES_OK;
  default:
    return RES_PARERR; // Invalid command
  }
}

DWORD get_fattime() {
  return 0;
}

void initialize_platform(const char *device) {
  printf("Initializing platform with device: %s\n", device);
  // Open the device file
  fd = open(device, O_RDWR);
  if (fd < 0) {
    perror("Failed to open device");
    return;
  }
  printf("Device opened successfully with fd: %d\n", fd);
}

void deinitialize_platform(void) {
  printf("Deinitializing platform\n");
  if (fd >= 0) {
    close(fd);
    fd = -1;
    printf("Device closed successfully\n");
  } else {
    printf("No device to close\n");
  }
}
