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

#pragma once

#include <stddef.h>
#include <stdint.h>

/* An MBR partition table in memory: the four primary entries, what fdisk
 * edits. Parsing, placement and encoding only -- no I/O -- so the same code
 * runs on yasos and in the host build's tests. */

#define MBR_PARTS 4
#define MBR_SECTOR 512u
/* Partitions start on 1 MiB boundaries, as every modern partitioner places
 * them: a multiple of any SD card's write page, and the first one leaves the
 * bootloader its gap after the MBR. */
#define MBR_ALIGN 2048u

typedef struct {
  uint8_t boot; /* 0x80 bootable, 0x00 not */
  uint8_t type; /* 0 = unused entry */
  uint32_t start;
  uint32_t sectors;
} mbr_part;

typedef struct {
  /* Sector 0 as read, so a rewrite keeps the boot code in front of the
   * table (a bootloader's stage 0 lives there). */
  uint8_t raw[MBR_SECTOR];
  mbr_part parts[MBR_PARTS];
  uint32_t disk_id;
  /* Usable sectors: the device size, capped at what 32-bit LBAs reach. */
  uint32_t disk_sectors;
} mbr_table;

typedef enum {
  MBR_OK,
  MBR_EMPTY,      /* no 0x55AA: a blank disk */
  MBR_FILESYSTEM, /* a FAT boot sector: the disk is one unpartitioned volume */
  MBR_GPT,        /* a protective MBR in front of a GPT */
} mbr_kind;

/* Read *sector0* into *table*. Anything but MBR_OK leaves an empty table,
 * still holding the sector for mbr_encode to judge. */
mbr_kind mbr_parse(const uint8_t *sector0, uint64_t disk_sectors,
                   mbr_table *table);

/* A new, empty table with a fresh disk identifier. */
void mbr_clear(mbr_table *table, uint32_t disk_id);

/* Sector 0 for *table*: boot code kept when sector 0 was a real MBR, zeroed
 * when it was anything else. */
void mbr_encode(const mbr_table *table, uint8_t *sector0);

int mbr_used(const mbr_table *table, int index);
int mbr_count(const mbr_table *table);

/* The lowest aligned sector at least *from* that starts a free run, or 0
 * when the disk is full. */
uint32_t mbr_first_free(const mbr_table *table, uint32_t from);

/* The last sector of the free run that *first* starts. */
uint32_t mbr_last_free(const mbr_table *table, uint32_t first);

/* Is [first, last] free of every partition except *skip* (-1 for none)? */
int mbr_range_free(const mbr_table *table, uint32_t first, uint32_t last,
                   int skip);

/* Parse fdisk's "Last sector" answer for a partition starting at *first*:
 *   ""            *dflt*
 *   N             sector N
 *   +N            N more sectors
 *   +N{K,M,G,T}   that much (KiB, MiB, ... -- a trailing "iB" or "B" is fine)
 *   +N%           that share of the whole disk (a yasos extension), rounded
 *                 down to MBR_ALIGN so the next partition starts aligned
 * Returns 0 and the last sector in *last*, -1 on nonsense. */
int mbr_parse_last(const char *text, uint32_t first, uint32_t dflt,
                   uint32_t disk_sectors, uint32_t *last);

/* A sector count as "64M", "1.5G": into buf, returned. */
const char *mbr_format_size(uint64_t sectors, char *buf, size_t len);

/* "Linux", "W95 FAT32 (LBA)", ..., or "unknown". */
const char *mbr_type_name(uint8_t type);

/* Every type mbr_type_name knows, in order: the code at *index*, or -1 past
 * the end. */
int mbr_type_at(int index);
