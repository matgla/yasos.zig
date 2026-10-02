/*
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

#include "mbr.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t get32(const uint8_t *at) {
  return (uint32_t)at[0] | ((uint32_t)at[1] << 8) | ((uint32_t)at[2] << 16) |
         ((uint32_t)at[3] << 24);
}

static void put32(uint8_t *at, uint32_t value) {
  at[0] = (uint8_t)value;
  at[1] = (uint8_t)(value >> 8);
  at[2] = (uint8_t)(value >> 16);
  at[3] = (uint8_t)(value >> 24);
}

/* A FAT boot sector's BPB, checked the way the kernel does
 * (source/kernel/drivers/block.zig is_fat_boot_sector). */
static int is_fat_boot_sector(const uint8_t *sector) {
  if (sector[510] != 0x55 || sector[511] != 0xAA)
    return 0;
  if (sector[0] != 0xEB && sector[0] != 0xE9)
    return 0;
  unsigned bytes = sector[11] | (sector[12] << 8);
  if (bytes < 512 || bytes > 4096 || (bytes & (bytes - 1)) != 0)
    return 0;
  unsigned per_cluster = sector[13];
  if (per_cluster == 0 || (per_cluster & (per_cluster - 1)) != 0)
    return 0;
  unsigned reserved = sector[14] | (sector[15] << 8);
  return reserved != 0 && (sector[16] == 1 || sector[16] == 2);
}

/* As the kernel and Linux judge a table: every boot flag 0x00 or 0x80, at
 * least one entry in use, each used one on the disk. A leftover FAT boot
 * sector ends in 0x55AA too, so the signature alone proves nothing. */
static int has_partition_table(const uint8_t *sector, uint64_t disk_sectors) {
  if (sector[510] != 0x55 || sector[511] != 0xAA)
    return 0;
  int used = 0;
  for (int i = 0; i < MBR_PARTS; ++i) {
    const uint8_t *entry = sector + 446 + 16 * i;
    if (entry[0] != 0x00 && entry[0] != 0x80)
      return 0;
    uint32_t start = get32(entry + 8), sectors = get32(entry + 12);
    if (entry[4] == 0 || sectors == 0)
      continue;
    if (start == 0)
      return 0;
    if (disk_sectors && (uint64_t)start + sectors > disk_sectors)
      return 0;
    ++used;
  }
  return used != 0;
}

static uint32_t cap_sectors(uint64_t disk_sectors) {
  return disk_sectors > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)disk_sectors;
}

mbr_kind mbr_parse(const uint8_t *sector0, uint64_t disk_sectors,
                   mbr_table *table) {
  memset(table, 0, sizeof(*table));
  memcpy(table->raw, sector0, MBR_SECTOR);
  table->disk_sectors = cap_sectors(disk_sectors);
  if (!has_partition_table(sector0, disk_sectors)) {
    if (is_fat_boot_sector(sector0))
      return MBR_FILESYSTEM;
    /* A signed sector with an empty table is still an MBR (boot code and
     * all); only the table is blank. */
    if (sector0[510] == 0x55 && sector0[511] == 0xAA) {
      table->disk_id = get32(sector0 + 440);
      return MBR_OK;
    }
    return MBR_EMPTY;
  }
  for (int i = 0; i < MBR_PARTS; ++i) {
    const uint8_t *entry = sector0 + 446 + 16 * i;
    if (entry[4] == 0xEE)
      return MBR_GPT;
  }
  table->disk_id = get32(sector0 + 440);
  for (int i = 0; i < MBR_PARTS; ++i) {
    const uint8_t *entry = sector0 + 446 + 16 * i;
    mbr_part *part = &table->parts[i];
    part->boot = entry[0];
    part->type = entry[4];
    part->start = get32(entry + 8);
    part->sectors = get32(entry + 12);
    if (part->type == 0 || part->sectors == 0)
      memset(part, 0, sizeof(*part));
  }
  return MBR_OK;
}

void mbr_clear(mbr_table *table, uint32_t disk_id) {
  memset(table->parts, 0, sizeof(table->parts));
  table->disk_id = disk_id ? disk_id : 1;
}

void mbr_encode(const mbr_table *table, uint8_t *sector0) {
  memcpy(sector0, table->raw, MBR_SECTOR);
  /* Boot code is worth keeping only from a real MBR: a FAT boot sector's jump
   * and BPB in front of the new table would make the disk still look like one
   * whole FAT volume to anything that checks for that first. */
  if (is_fat_boot_sector(table->raw) &&
      !has_partition_table(table->raw, table->disk_sectors))
    memset(sector0, 0, 446);
  else if (table->raw[510] != 0x55 || table->raw[511] != 0xAA)
    memset(sector0, 0, 446);
  put32(sector0 + 440, table->disk_id);
  sector0[444] = 0;
  sector0[445] = 0;
  memset(sector0 + 446, 0, 64);
  for (int i = 0; i < MBR_PARTS; ++i) {
    const mbr_part *part = &table->parts[i];
    if (!mbr_used(table, i))
      continue;
    uint8_t *entry = sector0 + 446 + 16 * i;
    entry[0] = part->boot;
    /* CHS fields say "use LBA": every reader since the nineties does. */
    entry[1] = 0xFE;
    entry[2] = 0xFF;
    entry[3] = 0xFF;
    entry[4] = part->type;
    entry[5] = 0xFE;
    entry[6] = 0xFF;
    entry[7] = 0xFF;
    put32(entry + 8, part->start);
    put32(entry + 12, part->sectors);
  }
  sector0[510] = 0x55;
  sector0[511] = 0xAA;
}

int mbr_used(const mbr_table *table, int index) {
  return table->parts[index].type != 0 && table->parts[index].sectors != 0;
}

int mbr_count(const mbr_table *table) {
  int count = 0;
  for (int i = 0; i < MBR_PARTS; ++i)
    count += mbr_used(table, i);
  return count;
}

/* The partition covering *sector*, or -1. */
static int covering(const mbr_table *table, uint32_t sector) {
  for (int i = 0; i < MBR_PARTS; ++i) {
    const mbr_part *part = &table->parts[i];
    if (mbr_used(table, i) && sector >= part->start &&
        sector - part->start < part->sectors)
      return i;
  }
  return -1;
}

static uint32_t align_up(uint32_t sector) {
  uint64_t aligned = ((uint64_t)sector + MBR_ALIGN - 1) / MBR_ALIGN * MBR_ALIGN;
  return aligned > 0xFFFFFFFFull ? 0 : (uint32_t)aligned;
}

uint32_t mbr_first_free(const mbr_table *table, uint32_t from) {
  uint32_t sector = align_up(from < MBR_ALIGN ? MBR_ALIGN : from);
  while (sector != 0 && sector < table->disk_sectors) {
    int owner = covering(table, sector);
    if (owner < 0)
      return sector;
    const mbr_part *part = &table->parts[owner];
    sector = align_up(part->start + part->sectors);
  }
  return 0;
}

uint32_t mbr_last_free(const mbr_table *table, uint32_t first) {
  uint32_t last = table->disk_sectors - 1;
  for (int i = 0; i < MBR_PARTS; ++i) {
    const mbr_part *part = &table->parts[i];
    if (mbr_used(table, i) && part->start > first && part->start - 1 < last)
      last = part->start - 1;
  }
  return last;
}

int mbr_range_free(const mbr_table *table, uint32_t first, uint32_t last,
                   int skip) {
  if (first == 0 || last < first || last >= table->disk_sectors)
    return 0;
  for (int i = 0; i < MBR_PARTS; ++i) {
    const mbr_part *part = &table->parts[i];
    if (i == skip || !mbr_used(table, i))
      continue;
    uint32_t part_last = part->start + part->sectors - 1;
    if (first <= part_last && part->start <= last)
      return 0;
  }
  return 1;
}

static int parse_unsigned(const char **cursor, uint64_t *value) {
  const char *p = *cursor;
  if (!isdigit((unsigned char)*p))
    return -1;
  uint64_t result = 0;
  while (isdigit((unsigned char)*p)) {
    result = result * 10 + (uint64_t)(*p - '0');
    if (result > (1ull << 50))
      return -1;
    ++p;
  }
  *cursor = p;
  *value = result;
  return 0;
}

int mbr_parse_last(const char *text, uint32_t first, uint32_t dflt,
                   uint32_t disk_sectors, uint32_t *last) {
  while (isspace((unsigned char)*text))
    ++text;
  if (*text == '\0') {
    *last = dflt;
    return 0;
  }
  int relative = *text == '+';
  if (relative)
    ++text;
  uint64_t value;
  if (parse_unsigned(&text, &value) != 0)
    return -1;
  uint64_t sectors = value; /* plain: sectors */
  char unit = (char)toupper((unsigned char)*text);
  if (unit == '%') {
    if (!relative || value == 0 || value > 100)
      return -1;
    sectors = (uint64_t)disk_sectors * value / 100 / MBR_ALIGN * MBR_ALIGN;
    ++text;
  } else if (unit == 'K' || unit == 'M' || unit == 'G' || unit == 'T') {
    if (!relative)
      return -1;
    int shift = unit == 'K' ? 10 : unit == 'M' ? 20 : unit == 'G' ? 30 : 40;
    sectors = (value << shift) / MBR_SECTOR;
    ++text;
    if (toupper((unsigned char)text[0]) == 'I' &&
        toupper((unsigned char)text[1]) == 'B')
      text += 2;
    else if (toupper((unsigned char)text[0]) == 'B')
      ++text;
  }
  while (isspace((unsigned char)*text))
    ++text;
  if (*text != '\0')
    return -1;
  uint64_t result;
  if (relative) {
    if (sectors == 0)
      return -1;
    result = (uint64_t)first + sectors - 1;
  } else {
    result = value;
  }
  if (result < first || result >= disk_sectors)
    return -1;
  *last = (uint32_t)result;
  return 0;
}

const char *mbr_format_size(uint64_t sectors, char *buf, size_t len) {
  static const char units[] = "KMGT";
  uint64_t bytes = sectors * MBR_SECTOR;
  if (bytes < 1024) {
    snprintf(buf, len, "%uB", (unsigned)bytes);
    return buf;
  }
  int unit = 0;
  uint64_t scale = 1024;
  while (unit < 3 && bytes >= scale * 1024) {
    scale *= 1024;
    ++unit;
  }
  uint64_t whole = bytes / scale;
  uint64_t tenths = (bytes % scale) * 10 / scale;
  if (tenths == 0 || whole >= 100)
    snprintf(buf, len, "%u%c", (unsigned)whole, units[unit]);
  else
    snprintf(buf, len, "%u.%u%c", (unsigned)whole, (unsigned)tenths,
             units[unit]);
  return buf;
}

static const struct {
  uint8_t code;
  const char *name;
} types[] = {
    {0x00, "Empty"},
    {0x01, "FAT12"},
    {0x04, "FAT16 <32M"},
    {0x05, "Extended"},
    {0x06, "FAT16"},
    {0x07, "HPFS/NTFS/exFAT"},
    {0x0b, "W95 FAT32"},
    {0x0c, "W95 FAT32 (LBA)"},
    {0x0e, "W95 FAT16 (LBA)"},
    {0x0f, "W95 Ext'd (LBA)"},
    {0x82, "Linux swap / Solaris"},
    {0x83, "Linux"},
    {0x85, "Linux extended"},
    {0x8e, "Linux LVM"},
    {0xda, "Non-FS data"},
    {0xee, "GPT"},
    {0xef, "EFI (FAT-12/16/32)"},
    {0xfd, "Linux raid autodetect"},
};

const char *mbr_type_name(uint8_t type) {
  for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); ++i)
    if (types[i].code == type)
      return types[i].name;
  return "unknown";
}

int mbr_type_at(int index) {
  if (index < 0 || (size_t)index >= sizeof(types) / sizeof(types[0]))
    return -1;
  return types[index].code;
}
