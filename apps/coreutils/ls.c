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
  char cwd[256] = {0};
  getcwd(cwd, sizeof(cwd));
  DIR *dir = opendir(cwd);
  if (dir == NULL) {
    return 1;
  }
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    printf("%s ", entry->d_name);
  }
  printf("\n");
  closedir(dir);

  return 0;
}