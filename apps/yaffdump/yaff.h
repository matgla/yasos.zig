/*
 Copyright (c) 2026 Mateusz Stadnik

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

/* Reader for the module metadata of a YAFF image.
 *
 * The struct layout comes from the compiler's own tccyaff.h, never from a copy
 * kept here: this tool exists to say what the writer produced, so a private
 * duplicate of the header is the one thing it must not have.  (readyaff.c kept
 * one once, drifted five fields behind, and printed garbage.)
 *
 * Everything before YaffHeader.text_offset -- header, module name, arch
 * section, dependency list, the four relocation tables, both symbol tables and
 * their lookup arrays -- is read into one buffer, because it is small (34 KiB
 * for the 1.6 MB on-device tcc, 17 KiB for toybox) and every part of it is
 * cross-referenced by every other part.  The image itself is not: it is read
 * a window at a time so that disassembling a 1.5 MB code region costs the same
 * RAM as disassembling a 9 KB one.
 */

#pragma once

#include <stdint.h>
#include <stdio.h>

#include "tccyaff.h"

typedef enum {
  YAFF_REGION_CODE = 0,
  YAFF_REGION_INIT,
  YAFF_REGION_PLT,
  YAFF_REGION_RODATA,
  YAFF_REGION_DATA,
  YAFF_REGION_BSS,
  YAFF_REGION_GOT,
  YAFF_REGION_COUNT
} YaffRegionId;

typedef struct {
  const char *name;
  uint32_t module_offset; /* address in the module's own offset space */
  uint32_t file_offset;   /* absolute offset in the file; valid when stored */
  uint32_t length;
  int stored;  /* bss occupies module offsets but no file bytes */
  int is_code; /* code, init and plt are executed; the rest is not */
} YaffRegion;

typedef struct {
  uint32_t offset;   /* module offset, thumb bit already cleared */
  uint32_t section;  /* YaffSectionCode */
  int weak;
  int thumb;         /* the low bit the writer set on a code address */
  const char *name;  /* points into YaffFile.meta */
} YaffSymbol;

typedef struct {
  uint32_t got_offset;  /* byte offset into the GOT, as the plt stub uses it */
  uint32_t symbol;      /* index into imported[] or exported[] */
  int is_exported;
  int function_pointer;
  int plt_call;
} YaffSymbolRelocation;

typedef struct {
  FILE *file;
  const char *path;
  uint32_t file_size;

  /* Everything up to text_offset, verbatim. Names and tables point into it. */
  uint8_t *meta;
  uint32_t meta_size;

  YaffHeader header; /* an aligned copy; the on-disk one is packed */
  const YaffArchSection *arch; /* NULL when the image carries no arch section */
  const char *module_name;

  YaffRegion regions[YAFF_REGION_COUNT];

  YaffSymbol *exported;
  uint32_t exported_count;
  YaffSymbol *imported;
  uint32_t imported_count;

  /* Exported code symbols sorted by address -- what a listing labels with. */
  YaffSymbol **code_symbols;
  uint32_t code_symbol_count;

  YaffSymbolRelocation *symbol_relocations;
  uint32_t symbol_relocation_count;

  const char **libraries;
  uint32_t library_count;
} YaffFile;

/* Opens and parses the metadata. Returns 0, or -1 with *why set to a static
 * string. A file that is not YAFF at all is reported as such rather than
 * guessed at, because ELF support is a separate job. */
int yaff_open(YaffFile *out, const char *path, const char **why);
void yaff_close(YaffFile *yaff);

/* Reads `length` bytes of the image at absolute file offset `offset`.
 * Returns the number of bytes read, which is short only at end of file. */
uint32_t yaff_read(YaffFile *yaff, uint32_t offset, void *buffer, uint32_t length);

/* The region a module offset falls in, or NULL when it falls outside them. */
const YaffRegion *yaff_region_of(const YaffFile *yaff, uint32_t module_offset);

/* The exported symbol starting exactly at `module_offset`, or NULL. */
const YaffSymbol *yaff_symbol_at(const YaffFile *yaff, uint32_t module_offset);

/* The exported symbol covering `module_offset`, with *delta set to the offset
 * into it, or NULL when the address is before the first symbol. */
const YaffSymbol *yaff_symbol_covering(const YaffFile *yaff, uint32_t module_offset,
                                       uint32_t *delta);

const char *yaff_module_type_name(uint8_t module_type);
const char *yaff_arch_name(uint16_t arch);
const char *yaff_fpu_name(uint8_t fpu);
const char *yaff_float_abi_name(uint8_t float_abi);
const char *yaff_section_name(uint32_t section);
