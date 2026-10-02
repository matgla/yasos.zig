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

/* Host unit tests for mbr.c: `make test`. */

#include "../mbr.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      printf("%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #cond);         \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

#define CARD_8G (8ull * 1024 * 1024 * 2) /* sectors */

static void add(mbr_table *table, int index, uint8_t type, uint32_t start,
                uint32_t sectors) {
  table->parts[index].type = type;
  table->parts[index].start = start;
  table->parts[index].sectors = sectors;
}

static void blank_disk_is_empty(void) {
  uint8_t zero[MBR_SECTOR] = {0};
  mbr_table table;
  CHECK(mbr_parse(zero, CARD_8G, &table) == MBR_EMPTY);
  CHECK(mbr_count(&table) == 0);
  CHECK(table.disk_sectors == CARD_8G);
}

static void round_trips_a_table(void) {
  uint8_t zero[MBR_SECTOR] = {0}, sector[MBR_SECTOR];
  mbr_table table, back;
  mbr_parse(zero, CARD_8G, &table);
  mbr_clear(&table, 0x12345678);
  add(&table, 0, 0x0c, 2048, 131072);
  add(&table, 2, 0x83, 133120, 524288);
  table.parts[0].boot = 0x80;
  mbr_encode(&table, sector);
  CHECK(sector[510] == 0x55 && sector[511] == 0xAA);
  CHECK(mbr_parse(sector, CARD_8G, &back) == MBR_OK);
  CHECK(back.disk_id == 0x12345678);
  CHECK(mbr_count(&back) == 2);
  CHECK(back.parts[0].boot == 0x80 && back.parts[0].type == 0x0c);
  CHECK(back.parts[0].start == 2048 && back.parts[0].sectors == 131072);
  CHECK(!mbr_used(&back, 1));
  CHECK(back.parts[2].start == 133120 && back.parts[2].sectors == 524288);
}

static void keeps_mbr_boot_code(void) {
  uint8_t sector[MBR_SECTOR] = {0}, out[MBR_SECTOR];
  memcpy(sector, "BOOTCODE", 8);
  sector[510] = 0x55;
  sector[511] = 0xAA;
  mbr_table table;
  CHECK(mbr_parse(sector, CARD_8G, &table) == MBR_OK);
  mbr_clear(&table, 7);
  add(&table, 0, 0x83, 2048, 4096);
  mbr_encode(&table, out);
  CHECK(memcmp(out, "BOOTCODE", 8) == 0);
}

/* A whole-disk FAT volume: its jump and BPB must not survive in front of the
 * new table, or the disk still reads as one FAT volume. */
static void drops_fat_boot_sector(void) {
  uint8_t sector[MBR_SECTOR] = {0}, out[MBR_SECTOR];
  sector[0] = 0xEB;
  sector[1] = 0x3C;
  sector[2] = 0x90;
  sector[11] = 0x00; /* 512 bytes per sector */
  sector[12] = 0x02;
  sector[13] = 8;
  sector[14] = 1;
  sector[16] = 2;
  sector[446] = 0x33; /* boot code, not a valid boot flag */
  sector[510] = 0x55;
  sector[511] = 0xAA;
  mbr_table table;
  CHECK(mbr_parse(sector, CARD_8G, &table) == MBR_FILESYSTEM);
  mbr_clear(&table, 7);
  add(&table, 0, 0x83, 2048, 4096);
  mbr_encode(&table, out);
  CHECK(out[0] == 0 && out[11] == 0 && out[13] == 0);
  CHECK(out[446 + 4] == 0x83);
}

static void recognises_gpt(void) {
  uint8_t sector[MBR_SECTOR] = {0};
  sector[446 + 4] = 0xEE;
  sector[446 + 8] = 1;
  sector[446 + 12] = 0xFF;
  sector[446 + 13] = 0xFF;
  sector[510] = 0x55;
  sector[511] = 0xAA;
  mbr_table table;
  CHECK(mbr_parse(sector, CARD_8G, &table) == MBR_GPT);
}

static void finds_free_space(void) {
  uint8_t zero[MBR_SECTOR] = {0};
  mbr_table table;
  mbr_parse(zero, CARD_8G, &table);
  CHECK(mbr_first_free(&table, 0) == 2048);
  CHECK(mbr_last_free(&table, 2048) == CARD_8G - 1);
  add(&table, 0, 0x0c, 2048, 131072); /* to 133119 */
  add(&table, 1, 0x83, 1048576, 2048);
  CHECK(mbr_first_free(&table, 0) == 133120);
  CHECK(mbr_last_free(&table, 133120) == 1048575);
  CHECK(mbr_first_free(&table, 1048576) == 1050624);
  CHECK(mbr_range_free(&table, 133120, 1048575, -1));
  CHECK(!mbr_range_free(&table, 133120, 1048576, -1));
  CHECK(mbr_range_free(&table, 2048, 4095, 0)); /* skipping its owner */
  /* An unaligned end still gives the next partition an aligned start. */
  add(&table, 2, 0x83, 133120, 1000);
  CHECK(mbr_first_free(&table, 0) == 135168);
}

static void disk_full(void) {
  uint8_t zero[MBR_SECTOR] = {0};
  mbr_table table;
  mbr_parse(zero, 8192, &table);
  add(&table, 0, 0x83, 2048, 6144);
  CHECK(mbr_first_free(&table, 0) == 0);
}

static void parses_last_sector(void) {
  uint32_t last;
  uint32_t disk = (uint32_t)CARD_8G;
  CHECK(mbr_parse_last("", 2048, 999999, disk, &last) == 0 && last == 999999);
  CHECK(mbr_parse_last("+64M", 2048, 0, disk, &last) == 0 && last == 133119);
  CHECK(mbr_parse_last("+64MiB", 2048, 0, disk, &last) == 0 && last == 133119);
  CHECK(mbr_parse_last("+1G", 2048, 0, disk, &last) == 0 &&
        last == 2048 + 2097152 - 1);
  CHECK(mbr_parse_last("+512K", 2048, 0, disk, &last) == 0 && last == 3071);
  CHECK(mbr_parse_last("+100", 2048, 0, disk, &last) == 0 && last == 2147);
  CHECK(mbr_parse_last("4095", 2048, 0, disk, &last) == 0 && last == 4095);
  /* 25% of 8 GiB is 2 GiB, already 1 MiB aligned. */
  CHECK(mbr_parse_last("+25%", 2048, 0, disk, &last) == 0 &&
        last == 2048 + disk / 4 - 1);
  /* An odd share rounds down to whole MiB. */
  CHECK(mbr_parse_last("+33%", 2048, 0, disk, &last) == 0 &&
        (last + 1 - 2048) % MBR_ALIGN == 0);
  CHECK(mbr_parse_last("1000", 2048, 0, disk, &last) != 0); /* before first */
  CHECK(mbr_parse_last("+0", 2048, 0, disk, &last) != 0);
  CHECK(mbr_parse_last("+9T", 2048, 0, disk, &last) != 0); /* off the disk */
  CHECK(mbr_parse_last("+101%", 2048, 0, disk, &last) != 0);
  CHECK(mbr_parse_last("64M", 2048, 0, disk, &last) != 0); /* needs + */
  CHECK(mbr_parse_last("+64Q", 2048, 0, disk, &last) != 0);
  CHECK(mbr_parse_last("x", 2048, 0, disk, &last) != 0);
}

static void formats_sizes(void) {
  char buf[16];
  CHECK(strcmp(mbr_format_size(131072, buf, sizeof(buf)), "64M") == 0);
  CHECK(strcmp(mbr_format_size(3145728, buf, sizeof(buf)), "1.5G") == 0);
  CHECK(strcmp(mbr_format_size(2, buf, sizeof(buf)), "1K") == 0);
}

int main(void) {
  blank_disk_is_empty();
  round_trips_a_table();
  keeps_mbr_boot_code();
  drops_fat_boot_sector();
  recognises_gpt();
  finds_free_space();
  disk_full();
  parses_last_sector();
  formats_sizes();
  if (failures) {
    printf("%d check(s) failed\n", failures);
    return 1;
  }
  printf("mbr tests passed\n");
  return 0;
}
