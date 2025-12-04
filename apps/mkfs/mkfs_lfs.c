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

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <lfs.h>

int user_read(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
              void *buffer, lfs_size_t size) {
  const int fd = *(const int *)c->context;
  printf("Reading block %u, offset %u, size %u\n", block, off, size);
  if (lseek(fd, block * c->block_size + off, SEEK_SET) < 0) {
    return -1;
  }
  if (read(fd, buffer, size) != size) {
    return -1;
  }
  return 0;
}

int blocks = 0;

int user_prog(const struct lfs_config *c, lfs_block_t block, lfs_off_t off,
              const void *buffer, lfs_size_t size) {
  const int fd = *(const int *)c->context;
  printf("Progress = %u/%d blocks\n", block + 1, blocks);
  if (lseek(fd, block * c->block_size + off, SEEK_SET) < 0) {
    return -1;
  }
  if (write(fd, buffer, size) != size) {
    return -1;
  }
  return 0;
}

int user_erase(const struct lfs_config *c, lfs_block_t block) {
  printf("Erasing block %u\n", block);
  return 0;
}

int user_sync(const struct lfs_config *c) {
  printf("Syncing\n");
  return 0;
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    printf("Usage: %s <command>\n", argv[0]);
    return 1;
  }

  printf("Formatting LittleFS filesystem on device: %s\n", argv[1]);
  printf("Using blocks: %s\n", argv[2]);

  const int device_fd = open(argv[1], O_RDWR);
  if (device_fd < 0) {
    perror("open");
    return 1;
  }

  struct stat st;
  if (fstat(device_fd, &st) != 0) {
    perror("fstat");
    close(device_fd);
    return 1;
  }

  printf("Device size: %d bytes, block size: %d\n", st.st_blocks,
         st.st_blksize);

  const struct lfs_config cfg = {
      .context = &device_fd,
      // block device operations
      .read = user_read,
      .prog = user_prog,
      .erase = user_erase,
      .sync = user_sync,

      .read_size = st.st_blksize,
      .prog_size = st.st_blksize,
      .block_size = st.st_blksize,
      .block_count = st.st_blocks,
      .cache_size = st.st_blksize,
      .lookahead_size = 16,
      .block_cycles = 500,
  };

  blocks = st.st_blocks;

  printf("Starting format...\n");
  lfs_t lfs;
  const int rc = lfs_format(&lfs, &cfg);
  printf("Format completed.\n");
  if (rc != 0) {
    printf("Error formatting LittleFS filesystem: %d\n", rc);
    close(device_fd);
    return 1;
  }

  if (lfs_mount(&lfs, &cfg) != 0) {
    printf("Error mounting LittleFS filesystem after format.\n");
    close(device_fd);
    return 1;
  }
  lfs_unmount(&lfs);
  close(device_fd);
}