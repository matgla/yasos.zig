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

#include "yaff.h"

#include <stdlib.h>
#include <string.h>
/* SEEK_SET and friends live in unistd.h in the board's libc, not in stdio.h. */
#include <unistd.h>

/* The tables are read field by field rather than by casting the file bytes to
 * the packed structs.  The layouts are bitfields inside packed structs, and
 * bitfield allocation is implementation defined -- this has to agree with what
 * the *writer* emitted, not with whatever the compiler building this tool
 * happens to do, and the tool is built by two different compilers (gcc for the
 * host differential test, tcc for the board).  Reading the words explicitly is
 * the only spelling that cannot drift. */
static uint32_t read32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint16_t read16(const uint8_t *p) {
  return (uint16_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8));
}

static uint32_t align_up(uint32_t value, uint32_t alignment) {
  if (alignment < 2) {
    return value;
  }
  return (value + alignment - 1) & ~(alignment - 1);
}

const char *yaff_module_type_name(uint8_t module_type) {
  switch (module_type) {
  case YAFF_MODULE_TYPE_EXECUTABLE:
    return "executable";
  case YAFF_MODULE_TYPE_SHARED_LIBRARY:
    return "shared library";
  default:
    return "unknown";
  }
}

const char *yaff_arch_name(uint16_t arch) {
  switch (arch) {
  case YAFF_ARCH_ARMV6_M:
    return "armv6-m";
  case YAFF_ARCH_ARMV7_M:
    return "armv7-m";
  case YAFF_ARCH_ARMV7E_M:
    return "armv7e-m";
  case YAFF_ARCH_ARMV8_M:
    return "armv8-m";
  default:
    return "unknown";
  }
}

const char *yaff_fpu_name(uint8_t fpu) {
  switch (fpu) {
  case YAFF_FPU_NONE:
    return "none";
  case YAFF_FPU_FPV4_SP_D16:
    return "fpv4-sp-d16";
  case YAFF_FPU_FPV5_SP_D16:
    return "fpv5-sp-d16";
  case YAFF_FPU_FPV5_D16:
    return "fpv5-d16";
  case YAFF_FPU_RP2350:
    return "rp2350";
  case YAFF_FPU_VFP:
    return "vfp";
  case YAFF_FPU_VFPV3:
    return "vfpv3";
  case YAFF_FPU_VFPV4:
    return "vfpv4";
  case YAFF_FPU_NEON:
    return "neon";
  case YAFF_FPU_NEON_VFPV4:
    return "neon-vfpv4";
  case YAFF_FPU_NEON_FP_ARMV8:
    return "neon-fp-armv8";
  default:
    return "unknown";
  }
}

const char *yaff_float_abi_name(uint8_t float_abi) {
  switch (float_abi) {
  case YAFF_FLOAT_ABI_SOFT:
    return "soft";
  case YAFF_FLOAT_ABI_SOFTFP:
    return "softfp";
  case YAFF_FLOAT_ABI_HARD:
    return "hard";
  default:
    return "unknown";
  }
}

const char *yaff_section_name(uint32_t section) {
  switch (section) {
  case YAFF_SECTION_CODE:
    return "CODE";
  case YAFF_SECTION_DATA:
    return "DATA";
  case YAFF_SECTION_INIT:
    return "INIT";
  case YAFF_SECTION_BSS:
    return "BSS";
  case YAFF_SECTION_RODATA:
    return "RODATA";
  default:
    return "UNK";
  }
}

/* Module offset space, walked exactly as the loader's
 * get_section_address_for_offset() walks it: code | init | plt | data | bss |
 * got, with the shared XIP rodata as a prefix *inside* the data region.  bss is
 * the one region with no bytes in the file, so from bss on the module offset
 * and the file offset drift apart by bss_length -- both are tracked. */
static void build_regions(YaffFile *yaff) {
  const YaffHeader *h = &yaff->header;
  uint32_t rodata = h->const_rodata_length;
  uint32_t code = 0;
  uint32_t init = code + h->code_length;
  uint32_t plt = init + h->init_length;
  uint32_t data = plt + h->plt_length;
  uint32_t bss = data + h->data_length;
  uint32_t got = bss + h->bss_length;
  YaffRegion *r = yaff->regions;

  if (rodata > h->data_length) {
    rodata = h->data_length; /* refuse to walk off the end of a bad header */
  }

  r[YAFF_REGION_CODE] = (YaffRegion){"code", code, h->text_offset + code, h->code_length, 1, 1};
  r[YAFF_REGION_INIT] = (YaffRegion){"init", init, h->text_offset + init, h->init_length, 1, 1};
  r[YAFF_REGION_PLT] = (YaffRegion){"plt", plt, h->text_offset + plt, h->plt_length, 1, 1};
  r[YAFF_REGION_RODATA] = (YaffRegion){"rodata", data, h->text_offset + data, rodata, 1, 0};
  r[YAFF_REGION_DATA] =
      (YaffRegion){"data", data + rodata, h->text_offset + data + rodata, h->data_length - rodata, 1, 0};
  r[YAFF_REGION_BSS] = (YaffRegion){"bss", bss, 0, h->bss_length, 0, 0};
  r[YAFF_REGION_GOT] = (YaffRegion){"got", got, h->text_offset + bss, h->got_length, 1, 0};
}

const YaffRegion *yaff_region_of(const YaffFile *yaff, uint32_t module_offset) {
  for (int i = 0; i < YAFF_REGION_COUNT; ++i) {
    const YaffRegion *r = &yaff->regions[i];
    if (r->length && module_offset >= r->module_offset && module_offset < r->module_offset + r->length) {
      return r;
    }
  }
  return NULL;
}

/* A symbol's offset is the module offset for everything the writer classified
 * as CODE (text starts the module, so its section-relative offset already is
 * the module one), but DATA symbols are relative to the data region -- see the
 * st_value adjustment in tccyaff.c, which folds rodata, data and bss into one
 * data-relative number. */
static uint32_t symbol_module_offset(const YaffFile *yaff, uint32_t section, uint32_t offset) {
  if (section == YAFF_SECTION_DATA) {
    return yaff->regions[YAFF_REGION_RODATA].module_offset + offset;
  }
  return offset;
}

static int parse_symbol_table(YaffFile *yaff, uint32_t table_offset, uint32_t lookup_offset, uint32_t count,
                              YaffSymbol **out, const char **why) {
  YaffSymbol *symbols = NULL;
  uint32_t i = 0;

  *out = NULL;
  if (count == 0) {
    return 0;
  }
  if (lookup_offset + 2u * count > yaff->meta_size) {
    *why = "symbol lookup table runs past the module metadata";
    return -1;
  }
  symbols = calloc(count, sizeof(YaffSymbol));
  if (!symbols) {
    *why = "out of memory reading the symbol table";
    return -1;
  }
  for (i = 0; i < count; ++i) {
    uint32_t entry = table_offset + read16(yaff->meta + lookup_offset + 2u * i);
    uint32_t word = 0;
    uint32_t section = 0;
    uint32_t offset = 0;
    const char *name = NULL;
    if (entry + 5 > yaff->meta_size) {
      free(symbols);
      *why = "symbol entry runs past the module metadata";
      return -1;
    }
    word = read32(yaff->meta + entry);
    section = word & 0x3u;
    offset = word >> 3;
    name = (const char *)(yaff->meta + entry + 4);
    if (!memchr(name, 0, yaff->meta_size - (entry + 4))) {
      free(symbols);
      *why = "unterminated symbol name";
      return -1;
    }
    symbols[i].section = section;
    symbols[i].weak = (int)((word >> 2) & 0x1u);
    symbols[i].thumb = (section != YAFF_SECTION_DATA) && (offset & 1u);
    symbols[i].offset = symbol_module_offset(yaff, section, offset & ~1u);
    symbols[i].name = name;
  }
  *out = symbols;
  return 0;
}

static int compare_symbols(const void *lhs, const void *rhs) {
  const YaffSymbol *a = *(const YaffSymbol *const *)lhs;
  const YaffSymbol *b = *(const YaffSymbol *const *)rhs;
  if (a->offset != b->offset) {
    return a->offset < b->offset ? -1 : 1;
  }
  /* A named symbol beats the empty one the writer emits for index 0, so a
   * listing never labels an address with "". */
  return (int)(a->name[0] == 0) - (int)(b->name[0] == 0);
}

/* Exported symbols that name an executable address, sorted -- the labels a
 * disassembly listing hangs its function headers on. */
static int build_code_symbols(YaffFile *yaff, const char **why) {
  uint32_t i = 0;
  uint32_t count = 0;

  if (yaff->exported_count == 0) {
    return 0;
  }
  yaff->code_symbols = calloc(yaff->exported_count, sizeof(YaffSymbol *));
  if (!yaff->code_symbols) {
    *why = "out of memory sorting the symbol table";
    return -1;
  }
  for (i = 0; i < yaff->exported_count; ++i) {
    const YaffRegion *region = yaff_region_of(yaff, yaff->exported[i].offset);
    if (yaff->exported[i].name[0] == 0) {
      continue;
    }
    if (region && region->is_code) {
      yaff->code_symbols[count++] = &yaff->exported[i];
    }
  }
  yaff->code_symbol_count = count;
  if (count) {
    qsort(yaff->code_symbols, count, sizeof(YaffSymbol *), compare_symbols);
  }
  return 0;
}

const YaffSymbol *yaff_symbol_at(const YaffFile *yaff, uint32_t module_offset) {
  uint32_t delta = 0;
  const YaffSymbol *symbol = yaff_symbol_covering(yaff, module_offset, &delta);
  return (symbol && delta == 0) ? symbol : NULL;
}

const YaffSymbol *yaff_symbol_covering(const YaffFile *yaff, uint32_t module_offset, uint32_t *delta) {
  uint32_t low = 0;
  uint32_t high = yaff->code_symbol_count;
  const YaffSymbol *found = NULL;

  while (low < high) {
    uint32_t middle = low + (high - low) / 2;
    if (yaff->code_symbols[middle]->offset <= module_offset) {
      found = yaff->code_symbols[middle];
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  if (found && delta) {
    *delta = module_offset - found->offset;
  }
  return found;
}

static int parse_libraries(YaffFile *yaff, const char **why) {
  uint32_t position = yaff->header.imported_libraries_offset;
  uint32_t i = 0;

  if (yaff->header.external_libraries_amount == 0) {
    return 0;
  }
  yaff->libraries = calloc(yaff->header.external_libraries_amount, sizeof(const char *));
  if (!yaff->libraries) {
    *why = "out of memory reading the dependency list";
    return -1;
  }
  for (i = 0; i < yaff->header.external_libraries_amount; ++i) {
    const char *name = (const char *)(yaff->meta + position);
    uint32_t length = 0;
    if (position >= yaff->meta_size || !memchr(name, 0, yaff->meta_size - position)) {
      *why = "dependency list runs past the module metadata";
      return -1;
    }
    length = (uint32_t)strlen(name) + 1;
    yaff->libraries[i] = name;
    position += align_up(length, yaff->header.alignment);
  }
  yaff->library_count = yaff->header.external_libraries_amount;
  return 0;
}

/* Only the symbol table relocations are kept: they are the ones that name a
 * thing (a plt stub, a GOT slot) that shows up in a disassembly listing.  The
 * local/data/copy tables are printed straight from the file by main.c. */
static int parse_symbol_relocations(YaffFile *yaff, const char **why) {
  uint32_t count = yaff->header.symbol_table_relocations_amount;
  uint32_t base = yaff->header.relocations_offset;
  uint32_t i = 0;

  if (count == 0) {
    return 0;
  }
  if (base + 8u * count > yaff->meta_size) {
    *why = "relocation table runs past the module metadata";
    return -1;
  }
  yaff->symbol_relocations = calloc(count, sizeof(YaffSymbolRelocation));
  if (!yaff->symbol_relocations) {
    *why = "out of memory reading the relocation table";
    return -1;
  }
  for (i = 0; i < count; ++i) {
    uint32_t first = read32(yaff->meta + base + 8u * i);
    uint32_t second = read32(yaff->meta + base + 8u * i + 4);
    YaffSymbolRelocation *rel = &yaff->symbol_relocations[i];
    rel->is_exported = (int)(first & 1u);
    rel->function_pointer = (int)(second & 1u);
    rel->plt_call = (int)((second >> 1) & 1u);
    rel->symbol = second >> 2;
    /* `index` counts GOT slots for a data relocation and function descriptors
     * -- two slots, the entry point and the callee's GOT base -- for a plt
     * call, which is what the stub's literal holds. */
    rel->got_offset = (first >> 1) * (rel->plt_call ? 8u : 4u);
  }
  yaff->symbol_relocation_count = count;
  return 0;
}

int yaff_open(YaffFile *out, const char *path, const char **why) {
  uint8_t raw_header[sizeof(YaffHeader)];
  YaffFile *yaff = out;
  long size = 0;

  memset(yaff, 0, sizeof(*yaff));
  yaff->path = path;
  yaff->file = fopen(path, "rb");
  if (!yaff->file) {
    *why = "cannot open file";
    return -1;
  }
  if (fseek(yaff->file, 0, SEEK_END) != 0 || (size = ftell(yaff->file)) < 0) {
    *why = "cannot size file";
    goto fail;
  }
  yaff->file_size = (uint32_t)size;
  if (fseek(yaff->file, 0, SEEK_SET) != 0) {
    *why = "cannot rewind file";
    goto fail;
  }
  if (yaff->file_size < sizeof(YaffHeader) ||
      fread(raw_header, 1, sizeof(raw_header), yaff->file) != sizeof(raw_header)) {
    *why = "file is too short to hold a YAFF header";
    goto fail;
  }
  if (memcmp(raw_header, "YAFF", 4) != 0) {
    *why = "not a YAFF module (ELF is not supported yet)";
    goto fail;
  }
  /* The header is packed and both hosts this runs on are little endian, so a
   * straight copy into the aligned struct is exact.  The rest of the file is
   * read field by field, where that is not true. */
  memcpy(&yaff->header, raw_header, sizeof(yaff->header));
  if (yaff->header.yaff_version != YAFF_VERSION) {
    *why = "unsupported YAFF version";
    goto fail;
  }
  yaff->meta_size = yaff->header.text_offset;
  if (yaff->meta_size < sizeof(YaffHeader) || yaff->meta_size > yaff->file_size) {
    *why = "text_offset does not point inside the file";
    goto fail;
  }
  yaff->meta = malloc(yaff->meta_size);
  if (!yaff->meta) {
    *why = "out of memory reading the module metadata";
    goto fail;
  }
  if (fseek(yaff->file, 0, SEEK_SET) != 0 || fread(yaff->meta, 1, yaff->meta_size, yaff->file) != yaff->meta_size) {
    *why = "short read of the module metadata";
    goto fail;
  }

  yaff->module_name = (const char *)(yaff->meta + sizeof(YaffHeader));
  if (!memchr(yaff->module_name, 0, yaff->meta_size - sizeof(YaffHeader))) {
    *why = "unterminated module name";
    goto fail;
  }
  if (yaff->header.arch_section_offset != 0 &&
      yaff->header.arch_section_offset + sizeof(YaffArchSection) <= yaff->meta_size) {
    const YaffArchSection *arch = (const YaffArchSection *)(yaff->meta + yaff->header.arch_section_offset);
    if (read16((const uint8_t *)arch) >= sizeof(YaffArchSection)) {
      yaff->arch = arch;
    }
  }

  build_regions(yaff);
  if (parse_libraries(yaff, why) != 0) {
    goto fail;
  }
  if (parse_symbol_relocations(yaff, why) != 0) {
    goto fail;
  }
  if (parse_symbol_table(yaff, yaff->header.imported_symbols_offset, yaff->header.imported_symbols_lookup_offset,
                         yaff->header.imported_symbols_amount, &yaff->imported, why) != 0) {
    goto fail;
  }
  yaff->imported_count = yaff->header.imported_symbols_amount;
  if (parse_symbol_table(yaff, yaff->header.exported_symbols_offset, yaff->header.exported_symbols_lookup_offset,
                         yaff->header.exported_symbols_amount, &yaff->exported, why) != 0) {
    goto fail;
  }
  yaff->exported_count = yaff->header.exported_symbols_amount;
  if (build_code_symbols(yaff, why) != 0) {
    goto fail;
  }
  return 0;

fail:
  yaff_close(yaff);
  return -1;
}

void yaff_close(YaffFile *yaff) {
  if (yaff->file) {
    fclose(yaff->file);
  }
  free(yaff->meta);
  free(yaff->exported);
  free(yaff->imported);
  free(yaff->code_symbols);
  free(yaff->symbol_relocations);
  free(yaff->libraries);
  memset(yaff, 0, sizeof(*yaff));
}

uint32_t yaff_read(YaffFile *yaff, uint32_t offset, void *buffer, uint32_t length) {
  if (offset >= yaff->file_size) {
    return 0;
  }
  if (length > yaff->file_size - offset) {
    length = yaff->file_size - offset;
  }
  if (fseek(yaff->file, (long)offset, SEEK_SET) != 0) {
    return 0;
  }
  return (uint32_t)fread(buffer, 1, length, yaff->file);
}
