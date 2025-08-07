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

#include <dirent.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
  char parent[256] = {0};
  getcwd(parent, sizeof(parent));
  if (argc > 1) {
    if (argv[1][0] == '/') {
      // If the first argument is an absolute path, use it as the file path
      snprintf(parent, sizeof(parent), "%s", argv[1]);
    } else {
      // Otherwise, treat it as a relative path
      snprintf(parent, sizeof(parent), "%s/%s", parent, argv[1]);
    }
    realpath(argv[1], parent);
  } else {
    printf("Usage: %s <path_to_file>\n", argv[0]);
    return -1;
  }

  printf("Opening parent: %s\n", parent);
  int pos = 0;
  for (int i = 255; i > 0; i--) {
    if (parent[i] == '/') {
      parent[i] = '\0'; // Temporarily terminate the string at the last slash
      pos = i;
      break;
    }
  }

  DIR *dir = opendir(parent);
  if (dir == NULL) {
    return -1;
  }
  closedir(dir);

  printf("Parent directory opened successfully.\n");
  printf("Creating file: %s\n", argv[1]);
  parent[pos] = '/';
  FILE *file = fopen(parent, "w");
  if (file == NULL) {
    printf("Failed to create file: %s\n", argv[1]);
    return -1;
  }
  fclose(file);

  return 0;
}