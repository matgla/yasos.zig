/**
 * stdio.c
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

#include "stdio.h"

#include <unistd.h>

#include <stdarg.h>
#include <string.h>

#include "libs/Baselibc/include/stdio.h"

int puts(const char *str) {
  const int n = strlen(str);
  write(STDOUT_FILENO, str, n);
  return n;
}

int scanf(const char *format, ...) {
  va_list ptr;
  size_t size;
  char line[255];
  getline(&line, &size, stdin);
  vsscanf(line, format, ptr);
  return 0;
}
