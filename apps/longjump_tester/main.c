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

#include <setjmp.h>
#include <stdio.h>

int global;

static int compare(void *a, void *b) {
  global++;
  printf("global in compare: %d\n", global);
  return *(int *)a - *(int *)b;
}

int main() {
  char data[4] = {0, 7, 1, 3};
  global = 42;
  printf("global before qsort: %d\n", global);
  qsort(data, 4, 1, &compare);
  qsort(data, 4, 1, compare);
  return 0;
}