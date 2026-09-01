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

/* yaffdump -- read, and disassemble, a YAFF module on the machine that runs it.
 *
 * The board already compiles its own programs; this is the other half of that
 * loop.  Everything the listing knows comes out of the module itself: which
 * bytes are executable, which pc-relative words are literal pools rather than
 * instructions, what the functions are called and which plt stub belongs to
 * which imported symbol -- so it says more than `objdump -D -b binary` on a
 * host can, which sees a flat blob with no symbols at all.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "thumb.h"
#include "yaff.h"

typedef struct {
  int header;
  int regions;
  int libraries;
  int symbols;
  int relocations;
  int disassemble;
  int mark_pools;
  const char *only_region;
} Options;

/* ---------------------------------------------------------------------- */
/* labels                                                                  */
/* ---------------------------------------------------------------------- */

typedef struct {
  uint32_t address;
  const char *name;
  char *owned; /* non-NULL when the name was built here and must be freed */
} Label;

typedef struct {
  Label *items;
  uint32_t count;
  uint32_t capacity;
} Labels;

static int add_label(Labels *labels, uint32_t address, const char *name, char *owned) {
  if (labels->count == labels->capacity) {
    uint32_t capacity = labels->capacity ? labels->capacity * 2 : 64;
    Label *grown = realloc(labels->items, capacity * sizeof(Label));
    if (!grown) {
      return -1;
    }
    labels->items = grown;
    labels->capacity = capacity;
  }
  labels->items[labels->count].address = address;
  labels->items[labels->count].name = name;
  labels->items[labels->count].owned = owned;
  labels->count++;
  return 0;
}

static int compare_labels(const void *lhs, const void *rhs) {
  const Label *a = lhs;
  const Label *b = rhs;
  if (a->address != b->address) {
    return a->address < b->address ? -1 : 1;
  }
  return 0;
}

static const Label *find_label(const Labels *labels, uint32_t address) {
  uint32_t low = 0;
  uint32_t high = labels->count;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2;
    if (labels->items[middle].address == address) {
      return &labels->items[middle];
    }
    if (labels->items[middle].address < address) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return NULL;
}

/* The name of the thing an address falls inside, and how far into it. */
static const Label *find_enclosing_label(const Labels *labels, uint32_t address, uint32_t *delta) {
  uint32_t low = 0;
  uint32_t high = labels->count;
  const Label *found = NULL;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2;
    if (labels->items[middle].address <= address) {
      found = &labels->items[middle];
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  if (found) {
    *delta = address - found->address;
  }
  return found;
}

/* Every plt stub loads a GOT byte offset from a literal four words in, adds the
 * GOT base and calls through the descriptor it finds.  That literal is what
 * names the stub: the symbol table relocations record the same offset against
 * the imported symbol the linker bound it to.  Reading it out of the stub
 * rather than assuming a stub size means a change to the stub shape shows up
 * as a missing label, not as a wrong one. */
static void label_plt_stubs(YaffFile *yaff, Labels *labels) {
  const YaffRegion *plt = &yaff->regions[YAFF_REGION_PLT];
  uint8_t *bytes = NULL;
  uint32_t offset = 0;

  if (plt->length < 8 || yaff->symbol_relocation_count == 0) {
    return;
  }
  bytes = malloc(plt->length);
  if (!bytes) {
    return;
  }
  if (yaff_read(yaff, plt->file_offset, bytes, plt->length) != plt->length) {
    free(bytes);
    return;
  }
  for (offset = 0; offset + 4 <= plt->length; offset += 2) {
    uint32_t first = (uint32_t)bytes[offset] | ((uint32_t)bytes[offset + 1] << 8);
    uint32_t second = (uint32_t)bytes[offset + 2] | ((uint32_t)bytes[offset + 3] << 8);
    uint32_t literal = 0;
    uint32_t got_offset = 0;
    uint32_t i = 0;
    if (first != 0xF8DF || (second & 0xF000) != 0xC000) {
      continue; /* not "ldr.w ip, [pc, #imm]", so not the head of a stub */
    }
    literal = ((offset + 4) & ~3u) + (second & 0xFFF);
    if (literal + 4 > plt->length) {
      continue;
    }
    got_offset = (uint32_t)bytes[literal] | ((uint32_t)bytes[literal + 1] << 8) |
                 ((uint32_t)bytes[literal + 2] << 16) | ((uint32_t)bytes[literal + 3] << 24);
    for (i = 0; i < yaff->symbol_relocation_count; ++i) {
      const YaffSymbolRelocation *relocation = &yaff->symbol_relocations[i];
      const YaffSymbol *symbol = NULL;
      char *name = NULL;
      if (!relocation->plt_call || relocation->got_offset != got_offset) {
        continue;
      }
      if (relocation->is_exported) {
        symbol = (relocation->symbol < yaff->exported_count) ? &yaff->exported[relocation->symbol] : NULL;
      } else {
        symbol = (relocation->symbol < yaff->imported_count) ? &yaff->imported[relocation->symbol] : NULL;
      }
      if (!symbol) {
        break;
      }
      name = malloc(strlen(symbol->name) + 5);
      if (!name) {
        break;
      }
      sprintf(name, "%s@plt", symbol->name);
      add_label(labels, plt->module_offset + offset, name, name);
      break;
    }
  }
  free(bytes);
}

static int build_labels(YaffFile *yaff, Labels *labels) {
  uint32_t i = 0;
  for (i = 0; i < yaff->code_symbol_count; ++i) {
    if (add_label(labels, yaff->code_symbols[i]->offset, yaff->code_symbols[i]->name, NULL) != 0) {
      return -1;
    }
  }
  label_plt_stubs(yaff, labels);
  if (labels->count) {
    qsort(labels->items, labels->count, sizeof(Label), compare_labels);
  }
  return 0;
}

static void free_labels(Labels *labels) {
  uint32_t i = 0;
  for (i = 0; i < labels->count; ++i) {
    free(labels->items[i].owned);
  }
  free(labels->items);
  labels->items = NULL;
  labels->count = 0;
  labels->capacity = 0;
}

/* ---------------------------------------------------------------------- */
/* the literal pool                                                        */
/* ---------------------------------------------------------------------- */

/* Addresses that some pc-relative load reached, which are therefore data even
 * though they sit in the middle of the code.  YAFF carries no $d mapping
 * symbols, so this is the only thing that keeps a listing in sync across a
 * pool -- and it is why the board's output is cleaner than a host objdump of
 * the same bytes, which decodes pools as instructions and desyncs. */
#define POOL_LIMIT 4096

typedef struct {
  uint32_t address[POOL_LIMIT];
  uint32_t first; /* entries below this have been walked past */
  uint32_t count;
  uint32_t dropped;
} Pool;

/* Everything the listing has already walked past is dead: forget it, so that a
 * 1.5 MB region needs no more table than the deepest pool it ever has in
 * flight (a few dozen entries). */
static void pool_forget_before(Pool *pool, uint32_t address) {
  while (pool->first < pool->count && pool->address[pool->first] < address) {
    pool->first++;
  }
  if (pool->first == pool->count) {
    pool->first = 0;
    pool->count = 0;
  }
}

static void pool_add(Pool *pool, uint32_t address) {
  uint32_t low = pool->first;
  uint32_t high = pool->count;
  uint32_t i = 0;
  address &= ~3u;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2;
    if (pool->address[middle] == address) {
      return;
    }
    if (pool->address[middle] < address) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  if (pool->count == POOL_LIMIT) {
    if (pool->first == 0) {
      pool->dropped++;
      return;
    }
    /* Slide the live entries down and try again. */
    for (i = pool->first; i < pool->count; ++i) {
      pool->address[i - pool->first] = pool->address[i];
    }
    low -= pool->first;
    pool->count -= pool->first;
    pool->first = 0;
  }
  for (i = pool->count; i > low; --i) {
    pool->address[i] = pool->address[i - 1];
  }
  pool->address[low] = address;
  pool->count++;
}

static int pool_holds(const Pool *pool, uint32_t address) {
  uint32_t low = pool->first;
  uint32_t high = pool->count;
  while (low < high) {
    uint32_t middle = low + (high - low) / 2;
    if (pool->address[middle] == address) {
      return 1;
    }
    if (pool->address[middle] < address) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return 0;
}

/* ---------------------------------------------------------------------- */
/* the code window                                                         */
/* ---------------------------------------------------------------------- */

/* A 1.5 MB code region is disassembled through the same 4 KB of RAM as a 9 KB
 * one: the listing only ever looks forward, so a sliding window is enough. */
#define WINDOW_SIZE 4096

typedef struct {
  YaffFile *yaff;
  uint32_t file_base;   /* file offset of the region's first byte */
  uint32_t region_base; /* module offset of the same byte */
  uint32_t region_length;
  uint8_t bytes[WINDOW_SIZE];
  uint32_t start; /* module offset of bytes[0] */
  uint32_t length;
} Window;

static const uint8_t *window_at(Window *window, uint32_t module_offset, uint32_t *available) {
  uint32_t region_end = window->region_base + window->region_length;
  uint32_t have = 0;

  if (module_offset >= window->start && module_offset < window->start + window->length) {
    have = window->start + window->length - module_offset;
  }
  /* Refill when the window holds less than the widest instruction and the
   * region has not itself run out.  Refilling only when the address falls
   * outside the window is the obvious spelling and is wrong: a 32-bit encoding
   * straddling the window edge then reads as "no bytes left", and the listing
   * stops there -- which cut the 1.5 MB tcc listing off after 14k lines. */
  if (have == 0 || (have < 4 && module_offset + have < region_end)) {
    uint32_t wanted = region_end - module_offset;
    if (wanted > WINDOW_SIZE) {
      wanted = WINDOW_SIZE;
    }
    window->start = module_offset;
    window->length =
        yaff_read(window->yaff, window->file_base + (module_offset - window->region_base), window->bytes, wanted);
    have = window->length;
  }
  if (have == 0) {
    *available = 0;
    return NULL;
  }
  *available = have;
  return window->bytes + (module_offset - window->start);
}

/* ---------------------------------------------------------------------- */
/* listing                                                                 */
/* ---------------------------------------------------------------------- */

static void print_label(const Labels *labels, uint32_t address) {
  const Label *label = find_label(labels, address);
  if (label) {
    printf("\n%08x <%s>:\n", address, label->name);
  }
}

/* objdump's "<name+0x8>" tail, which is what turns a listing of numbers into
 * something readable -- and here it can be printed for a plt stub too. */
static void print_reference(const Labels *labels, uint32_t address) {
  uint32_t delta = 0;
  const Label *label = find_enclosing_label(labels, address, &delta);
  if (!label) {
    return;
  }
  if (delta == 0) {
    printf(" <%s>", label->name);
  } else {
    printf(" <%s+0x%x>", label->name, delta);
  }
}

static void print_word(Window *window, uint32_t address, const char *why) {
  uint32_t available = 0;
  const uint8_t *bytes = window_at(window, address, &available);
  uint32_t value = 0;
  if (!bytes || available < 4) {
    return;
  }
  value = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
  printf("%8x:\t%02x%02x %02x%02x \t.word\t0x%08x", address, bytes[1], bytes[0], bytes[3], bytes[2], value);
  if (why) {
    printf("\t@ %s", why);
  }
  printf("\n");
}

static void disassemble_region(YaffFile *yaff, const YaffRegion *region, const Labels *labels, const Options *options) {
  Window window;
  Pool pool;
  ThumbItState it;
  ThumbInsn insn;
  uint32_t address = region->module_offset;
  uint32_t end = region->module_offset + region->length;

  memset(&window, 0, sizeof(window));
  memset(&pool, 0, sizeof(pool));
  window.yaff = yaff;
  window.file_base = region->file_offset;
  window.region_base = region->module_offset;
  window.region_length = region->length;
  thumb_it_reset(&it);

  printf("\nDisassembly of region %s (module 0x%x, %u bytes):\n", region->name, region->module_offset,
         region->length);

  while (address < end) {
    uint32_t available = 0;
    const uint8_t *bytes = NULL;
    char encoding[16];

    print_label(labels, address);
    pool_forget_before(&pool, address);
    if (options->mark_pools && pool_holds(&pool, address)) {
      print_word(&window, address, "literal pool");
      thumb_it_reset(&it); /* data ends whatever IT block was open */
      address += 4;
      continue;
    }
    bytes = window_at(&window, address, &available);
    if (!bytes || available < 2) {
      break;
    }
    thumb_decode(&it, address, bytes, available, &insn);
    if (insn.size == 0) {
      /* A 32-bit encoding that the region is too short to hold.  It is still
       * two bytes of the module, so say what they are rather than stopping and
       * leaving the tail of the region unaccounted for. */
      printf("%8x:\t%02x%02x      \t.short\t0x%02x%02x\n", address, bytes[1], bytes[0], bytes[1], bytes[0]);
      address += 2;
      continue;
    }
    thumb_format_encoding(bytes, insn.size, encoding, sizeof(encoding));
    printf("%8x:\t%-10s\t%s", address, encoding, insn.text);
    if (insn.target_kind == THUMB_TARGET_BRANCH) {
      print_reference(labels, insn.target);
    }
    if (insn.comment[0]) {
      printf("\t@ %s", insn.comment);
    }
    printf("\n");
    if (insn.target_kind == THUMB_TARGET_LITERAL && insn.target_size >= 4 && insn.target > address &&
        insn.target < end) {
      pool_add(&pool, insn.target);
      if (insn.target_size == 8) {
        pool_add(&pool, insn.target + 4);
      }
    }
    address += insn.size;
  }
  if (pool.dropped) {
    fprintf(stderr, "yaffdump: %u literal pool entries did not fit and were disassembled as code\n", pool.dropped);
  }
}

/* ---------------------------------------------------------------------- */
/* the metadata reports                                                    */
/* ---------------------------------------------------------------------- */

static void print_header(const YaffFile *yaff) {
  const YaffHeader *h = &yaff->header;
  printf("%s: YAFF v%u %s, %s\n", yaff->path, h->yaff_version, yaff_module_type_name(h->module_type),
         yaff_arch_name(h->arch));
  printf("  module name       %s\n", yaff->module_name[0] ? yaff->module_name : "(none)");
  printf("  version           %u.%u\n", h->version_major, h->version_minor);
  printf("  entry             0x%x%s\n", h->entry & ~1u, (h->entry & 1u) ? " (thumb)" : "");
  printf("  alignment         %u\n", h->alignment);
  printf("  text at           0x%x\n", h->text_offset);
  if (h->stack_size == 0xFFFFFFFFu) {
    printf("  stack / heap      OS default\n");
  } else {
    printf("  stack / heap      %u / %u bytes\n", h->stack_size, h->heap_size);
  }
  if (yaff->arch) {
    printf("  fpu               %s\n", yaff_fpu_name(yaff->arch->fpu));
    printf("  float abi         %s\n", yaff_float_abi_name(yaff->arch->float_abi));
    printf("  required features 0x%x%s%s%s\n", yaff->arch->required_features,
           (yaff->arch->required_features & YAFF_ARCH_FEATURE_FPU_SP) ? " fpu-sp" : "",
           (yaff->arch->required_features & YAFF_ARCH_FEATURE_FPU_DP) ? " fpu-dp" : "",
           (yaff->arch->required_features & YAFF_ARCH_FEATURE_DCP) ? " dcp" : "");
  } else {
    printf("  arch section      (none)\n");
  }
}

/* The region walk doubles as a check on the file: the regions have to end
 * exactly where the file does, or something is truncated. */
static void print_regions(const YaffFile *yaff) {
  uint32_t last = 0;
  int i = 0;
  printf("\n  %-8s %10s %10s %10s\n", "region", "module", "file", "bytes");
  for (i = 0; i < YAFF_REGION_COUNT; ++i) {
    const YaffRegion *region = &yaff->regions[i];
    char module[16];
    char file[16];
    if (!region->length) {
      continue;
    }
    sprintf(module, "0x%x", region->module_offset);
    if (region->stored) {
      sprintf(file, "0x%x", region->file_offset);
      if (region->file_offset + region->length > last) {
        last = region->file_offset + region->length;
      }
    } else {
      sprintf(file, "-");
    }
    printf("  %-8s %10s %10s %10u\n", region->name, module, file, region->length);
  }
  if (last == yaff->file_size) {
    printf("\n  regions account for every byte of the file\n");
  } else {
    printf("\n  WARNING: regions end at 0x%x but the file is 0x%x bytes\n", last, yaff->file_size);
  }
}

static void print_libraries(const YaffFile *yaff) {
  uint32_t i = 0;
  printf("\nDEPENDENCIES (%u):\n", yaff->library_count);
  for (i = 0; i < yaff->library_count; ++i) {
    printf("  %s\n", yaff->libraries[i]);
  }
}

static void print_symbol_table(const char *title, const YaffSymbol *symbols, uint32_t count) {
  uint32_t i = 0;
  printf("\n%s (%u):\n", title, count);
  for (i = 0; i < count; ++i) {
    printf("%08x %c %-6s %s\n", symbols[i].offset, symbols[i].weak ? 'w' : 'g',
           yaff_section_name(symbols[i].section), symbols[i].name[0] ? symbols[i].name : "(unnamed)");
  }
}

static void print_relocations(const YaffFile *yaff) {
  uint32_t i = 0;
  printf("\nSYMBOL TABLE RELOCATIONS (%u):\n", yaff->symbol_relocation_count);
  for (i = 0; i < yaff->symbol_relocation_count; ++i) {
    const YaffSymbolRelocation *relocation = &yaff->symbol_relocations[i];
    const YaffSymbol *table = relocation->is_exported ? yaff->exported : yaff->imported;
    uint32_t table_count = relocation->is_exported ? yaff->exported_count : yaff->imported_count;
    const char *name = (relocation->symbol < table_count) ? table[relocation->symbol].name : "(out of range)";
    printf("  got+0x%-6x %-9s %s%s\n", relocation->got_offset, relocation->plt_call ? "plt-call" : "got-slot",
           name, relocation->function_pointer ? " (function pointer)" : "");
  }
  printf("\n  local %u, data %u, copy %u relocations\n", yaff->header.local_relocations_amount,
         yaff->header.data_relocations_amount, yaff->header.copy_relocations_amount);
}

static void usage(const char *program) {
  fprintf(stderr,
          "Usage: %s [OPTIONS] FILE\n"
          "\n"
          "  -f  module header (the default, with -h)\n"
          "  -h  region table\n"
          "  -l  imported libraries\n"
          "  -t  symbol tables\n"
          "  -r  relocation tables\n"
          "  -d  disassemble the executable regions\n"
          "  -j NAME  disassemble only this region\n"
          "  -x  everything but the disassembly\n"
          "  -a  everything\n"
          "  --no-pool  disassemble literal pools as code, as a host objdump of\n"
          "             the raw bytes has to\n",
          program);
}

int main(int argc, char *argv[]) {
  Options options;
  YaffFile yaff;
  Labels labels;
  const char *why = NULL;
  const char *path = NULL;
  int i = 0;
  int status = 0;

  memset(&options, 0, sizeof(options));
  memset(&labels, 0, sizeof(labels));
  options.mark_pools = 1;

  for (i = 1; i < argc; ++i) {
    const char *argument = argv[i];
    if (strcmp(argument, "--no-pool") == 0) {
      options.mark_pools = 0;
    } else if (strcmp(argument, "-j") == 0 && i + 1 < argc) {
      options.only_region = argv[++i];
      options.disassemble = 1;
    } else if (strcmp(argument, "--help") == 0) {
      usage(argv[0]);
      return 0;
    } else if (argument[0] == '-' && argument[1] != 0) {
      const char *flag = argument + 1;
      while (*flag) {
        switch (*flag) {
        case 'f':
          options.header = 1;
          break;
        case 'h':
          options.regions = 1;
          break;
        case 'l':
          options.libraries = 1;
          break;
        case 't':
          options.symbols = 1;
          break;
        case 'r':
          options.relocations = 1;
          break;
        case 'd':
          options.disassemble = 1;
          break;
        case 'x':
          options.header = options.regions = options.libraries = options.symbols = options.relocations = 1;
          break;
        case 'a':
          options.header = options.regions = options.libraries = options.symbols = options.relocations = 1;
          options.disassemble = 1;
          break;
        default:
          fprintf(stderr, "%s: unknown option -%c\n", argv[0], *flag);
          usage(argv[0]);
          return 1;
        }
        ++flag;
      }
    } else if (!path) {
      path = argument;
    } else {
      fprintf(stderr, "%s: only one file at a time\n", argv[0]);
      return 1;
    }
  }
  if (!path) {
    usage(argv[0]);
    return 1;
  }
  if (!options.header && !options.regions && !options.libraries && !options.symbols && !options.relocations &&
      !options.disassemble) {
    options.header = 1;
    options.regions = 1;
  }

  if (yaff_open(&yaff, path, &why) != 0) {
    fprintf(stderr, "%s: %s: %s\n", argv[0], path, why);
    return 1;
  }
  if (options.header) {
    print_header(&yaff);
  }
  if (options.regions) {
    print_regions(&yaff);
  }
  if (options.libraries) {
    print_libraries(&yaff);
  }
  if (options.symbols) {
    print_symbol_table("IMPORTED SYMBOLS", yaff.imported, yaff.imported_count);
    print_symbol_table("EXPORTED SYMBOLS", yaff.exported, yaff.exported_count);
  }
  if (options.relocations) {
    print_relocations(&yaff);
  }
  if (options.disassemble) {
    if (build_labels(&yaff, &labels) != 0) {
      fprintf(stderr, "%s: out of memory building the label table\n", argv[0]);
      status = 1;
    } else {
      for (i = 0; i < YAFF_REGION_COUNT; ++i) {
        const YaffRegion *region = &yaff.regions[i];
        if (!region->is_code || !region->length) {
          continue;
        }
        if (options.only_region && strcmp(options.only_region, region->name) != 0) {
          continue;
        }
        disassemble_region(&yaff, region, &labels, &options);
      }
    }
    free_labels(&labels);
  }
  yaff_close(&yaff);
  return status;
}
