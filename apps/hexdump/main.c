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

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  char buffer[256] = {0};
  int offset = 0;
  if (argc < 2) {
    fprintf(stderr, "Usage: %s <directory>\n", argv[0]);
    return 1;
  }
  if (argv[1][0] == '/') {
    // Absolute path
    strcpy(buffer, argv[1]);
  } else {
    // Relative path
    getcwd(buffer, sizeof(buffer));
    strcat(buffer, "/");
    strcat(buffer, argv[1]);
  }
  int fd = open(buffer, O_RDONLY);
  if (fd < 0) {
    printf("Error opening file: %s\n", buffer);
    return 1;
  }
  int readed = 1;
  while (readed != 0) {
    printf("%08x ", offset);
    readed = read(fd, buffer, 0x10);
    for (int i = 0; i < readed; i += 2) {
      printf("%04x ", (*(uint16_t *)(&buffer[i]) & 0xffff));
    }
    printf("\n");
    offset += 0x10;
  }
  printf("\n");
  close(fd);
  return 0;
}
