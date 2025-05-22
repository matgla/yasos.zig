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

#include <stdint.h>
#include <stdio.h>
int main() {
  printf("Hello, World!\n");

  /* Compute and store final offset */
  uint32_t x = 0x1a2;
  uint16_t lo = 0xf7ff;
  uint16_t hi = 0xfffe;
  int s = (x >> 24) & 1;
  printf("x: %x, x >> 24: %x, after s: %x\n", x, x >> 24, s);
  int i1 = (x >> 23) & 1;
  printf("x >> 23: %x, after i1: %x\n", x >> 24, i1);

  int j1 = s ^ (i1 ^ 1);
  printf("i1 ^ 1: %x, s ^: %x\n", i1 ^ 1, s ^ (i1 ^ 1));

  return 0;
}
