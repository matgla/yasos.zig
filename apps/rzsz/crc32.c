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

#include "crc32.h"

#include <stdbool.h>

#define CRC32_POLY 0xEDB88320

static uint32_t crc32_table[256];
static bool crc32_table_ready = false;

static void crc32_init_table(void) {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int j = 0; j < 8; j++) {
      if (c & 1)
        c = (c >> 1) ^ CRC32_POLY;
      else
        c >>= 1;
    }
    crc32_table[i] = c;
  }
  crc32_table_ready = true;
}

uint32_t crc32(uint32_t crc, const uint8_t *data, size_t len) {
  if (!crc32_table_ready)
    crc32_init_table();

  crc = ~crc;
  for (size_t i = 0; i < len; i++) {
    crc = (crc >> 8) ^ crc32_table[(crc ^ data[i]) & 0xFF];
  }
  return ~crc;
}
