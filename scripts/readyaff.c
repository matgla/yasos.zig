#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct __attribute__((packed)) YaffHeader {
  uint8_t magic[4];
  uint8_t module_type;
  uint16_t arch;
  uint8_t yaff_version;
  uint32_t code_length;
  uint32_t init_length;
  uint32_t data_length;
  uint32_t bss_length;
  uint32_t entry;
  uint16_t external_libraries_amount;
  uint8_t alignment;
  uint8_t text_and_data_separation;
  uint16_t version_major;
  uint16_t version_minor;
  uint16_t symbol_table_relocations_amount;
  uint16_t local_relocations_amount;
  uint16_t data_relocations_amount;
  uint16_t _reserved2;
  uint16_t exported_symbols_amount;
  uint16_t imported_symbols_amount;
  uint32_t got_length;
  uint32_t got_plt_length;
  uint32_t plt_length;
  // TODO: remove or move to the arch section
  uint16_t arch_section_offset;
  uint16_t imported_libraries_offset;
  uint16_t relocations_offset;
  uint16_t imported_symbols_offset;
  uint16_t exported_symbols_offset;
  uint16_t text_offset;
} YaffHeader;

typedef enum YaffSectionCode {
  YAFF_SECTION_CODE = 0,
  YAFF_SECTION_DATA = 1,
  YAFF_SECTION_INIT = 2,
  YAFF_SECTION_UNKNOWN = 3,
} YaffSectionCode;

typedef struct __attribute__((packed)) YaffSymbolTableRelocationEntry {
  uint32_t is_exported_symbol : 1;
  uint32_t index : 31;
  uint32_t symbol_index;
} YaffSymbolTableRelocationEntry;

typedef struct __attribute__((packed)) YaffDataRelocationEntry {
  uint32_t to;
  uint32_t section : 2;
  uint32_t from : 30;
} YaffDataRelocationEntry;

typedef struct __attribute__((packed)) YaffLocalRelocationEntry {
  uint32_t section : 2;
  uint32_t index : 30;
  uint32_t target_offset;
} YaffLocalRelocationEntry;

typedef struct __attribute__((packed)) YaffSymbolEntry {
  uint32_t section : 2;
  uint32_t offset : 30;
  char name[0];
} YaffSymbolEntry;

typedef enum YaffModuleType {
  YAFF_MODULE_TYPE_EXECUTABLE = 1,
  YAFF_MODULE_TYPE_SHARED_LIBRARY = 2,
} YaffModuleType;

const char *get_module_type_str(uint8_t module_type) {
  switch (module_type) {
  case YAFF_MODULE_TYPE_EXECUTABLE:
    return "exec";
  case YAFF_MODULE_TYPE_SHARED_LIBRARY:
    return "shared library";
  }
  return "unknown";
}

typedef enum YaffArch {
  YAFF_ARCH_ARMV6M = 1,
} YaffArch;

const char *get_arch_str(uint16_t arch) {
  switch (arch) {
  case YAFF_ARCH_ARMV6M:
    return "armv6m";
  }
  return "unknown";
}

void print_header(const YaffHeader *header, const char *name) {
  printf("YAFF Header:\n");
  printf("  Magic:         %4s\n", header->magic);
  printf("  Type:          %s\n", get_module_type_str(header->module_type));
  printf("  Arch:          %s\n", get_arch_str(header->arch));
  printf("  Alignemnt:     %d\n", header->alignment);
  printf("  Name:          %s\n", name);
  printf("  Version:       %d.%d\n", header->version_major,
         header->version_minor);
  printf("  Sections:\n");
  printf("   .text len:    %x\n", header->code_length);
  printf("   .init len:    %x\n", header->init_length);
  printf("   .plt len:     %x\n", header->plt_length);
  printf("   .data len:    %x\n", header->data_length);
  printf("   .bss len:     %x\n", header->bss_length);
  printf("   .got len:     %x\n", header->got_length);
  printf("  Entry:         %x\n", header->entry);
  printf("  Number of imported libraries:    %d\n",
         header->external_libraries_amount);
  printf("  Text and data separation:        %d\n",
         header->text_and_data_separation);
  printf("  Symbol table relocations amount: %d\n",
         header->symbol_table_relocations_amount);
  printf("  Local relocations amount:        %d\n",
         header->local_relocations_amount);
  printf("  Data relocations amount:         %d\n",
         header->data_relocations_amount);
  printf("  Exported symbols amount:         %d\n",
         header->exported_symbols_amount);
  printf("  Imported symbols amount:         %d\n",
         header->imported_symbols_amount);

  printf("  Offsets:\n");
  printf("    .text:               %x\n", header->text_offset);
  printf("    .arch_section:       %x\n", header->arch_section_offset);
  printf("    .imported_libraries: %x\n", header->imported_libraries_offset);
  printf("    .relocations:        %x\n", header->relocations_offset);
  printf("    .imported_symbols:   %x\n", header->imported_symbols_offset);
  printf("    .exported_symbols:   %x\n", header->exported_symbols_offset);
}

int main(int argc, char *argv[]) {
  if (argc < 2) {
    printf("Usage: readyaff <file>\n");
    exit(-1);
  }

  int fd = open(argv[1], O_RDONLY);
  if (fd < 0) {
    printf("Cannot open file: %s\n", argv[1]);
    return -1;
  }

  YaffHeader header;
  read(fd, &header, sizeof(YaffHeader));
  char name[64];
  uint32_t name_length = header.imported_libraries_offset - sizeof(YaffHeader);
  if (name_length > sizeof(name)) {
    read(fd, name, sizeof(name));
    for (uint32_t i = 0; i < name_length - sizeof(name); ++i) {
      char c;
      read(fd, &c, 1);
    }
    name[sizeof(name) - 1] = '\0';
  } else {
    read(fd, name, name_length);
  }

  print_header(&header, name);

  close(fd);
}