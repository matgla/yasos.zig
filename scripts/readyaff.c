/*
 * readyaff - dump the header and architecture section of a YAFF module.
 *
 *   gcc -I libs/tinycc -o readyaff scripts/readyaff.c
 *   ./readyaff rootfs/usr/bin/hello
 *
 * The layout comes from the compiler's own tccyaff.h rather than a copy kept
 * here: this tool exists to check what the writer produced, so a private
 * duplicate of the struct is the one thing it must not have. (It used to keep
 * one, drifted five fields behind, and printed garbage for the module name.)
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "tccyaff.h"

const char *get_module_type_str(uint8_t module_type) {
  switch (module_type) {
  case YAFF_MODULE_TYPE_EXECUTABLE:
    return "exec";
  case YAFF_MODULE_TYPE_SHARED_LIBRARY:
    return "shared library";
  }
  return "unknown";
}

const char *get_arch_str(uint16_t arch) {
  switch (arch) {
  case YAFF_ARCH_ARMV6_M:
    return "armv6-m";
  case YAFF_ARCH_ARMV7_M:
    return "armv7-m";
  case YAFF_ARCH_ARMV7E_M:
    return "armv7e-m";
  case YAFF_ARCH_ARMV8_M:
    return "armv8-m";
  }
  return "unknown";
}

const char *get_fpu_str(uint8_t fpu) {
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
  }
  return "unknown";
}

const char *get_float_abi_str(uint8_t abi) {
  switch (abi) {
  case YAFF_FLOAT_ABI_SOFT:
    return "soft";
  case YAFF_FLOAT_ABI_SOFTFP:
    return "softfp";
  case YAFF_FLOAT_ABI_HARD:
    return "hard";
  }
  return "unknown";
}

void print_features(uint32_t features) {
  static const struct {
    uint32_t bit;
    const char *name;
  } known[] = {
      {YAFF_ARCH_FEATURE_FPU_SP, "fpu-sp"},
      {YAFF_ARCH_FEATURE_FPU_DP, "fpu-dp"},
      {YAFF_ARCH_FEATURE_DCP, "dcp"},
  };
  if (features == 0) {
    printf("none");
    return;
  }
  uint32_t rest = features;
  int first = 1;
  for (unsigned i = 0; i < sizeof(known) / sizeof(known[0]); ++i) {
    if (features & known[i].bit) {
      printf("%s%s", first ? "" : "+", known[i].name);
      first = 0;
      rest &= ~known[i].bit;
    }
  }
  /* A bit this build does not know about is exactly what a dump should show:
   * the image needs something newer than this tool. */
  if (rest)
    printf("%sunknown(0x%x)", first ? "" : "+", rest);
}

void print_arch_section(const YaffArchSection *arch) {
  printf("  Architecture section:\n");
  printf("    size:            %d\n", arch->size);
  printf("    arch:            %s\n", get_arch_str(arch->arch));
  printf("    fpu:             %s\n", get_fpu_str(arch->fpu));
  printf("    float abi:       %s\n", get_float_abi_str(arch->float_abi));
  printf("    requires:        ");
  print_features(arch->required_features);
  printf("\n");
}

void print_header(const YaffHeader *header, const char *name) {
  printf("YAFF Header:\n");
  printf("  Magic:         %4s\n", header->magic);
  printf("  Format:        v%d (this tool reads v%d)\n", header->yaff_version,
         YAFF_VERSION);
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
  if (read(fd, &header, sizeof(YaffHeader)) != (ssize_t)sizeof(YaffHeader)) {
    printf("Not a YAFF file (too short): %s\n", argv[1]);
    close(fd);
    return -1;
  }
  if (memcmp(header.magic, "YAFF", 4) != 0) {
    printf("Not a YAFF file (bad magic): %s\n", argv[1]);
    close(fd);
    return -1;
  }

  char name[64];
  /* The name runs from the end of the header to the architecture section (or,
   * in a pre-v2 image with no such section, to the imported-library table). */
  uint32_t name_end = header.arch_section_offset
                          ? header.arch_section_offset
                          : header.imported_libraries_offset;
  uint32_t name_length = name_end - sizeof(YaffHeader);
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

  if (header.arch_section_offset) {
    YaffArchSection arch;
    if (lseek(fd, header.arch_section_offset, SEEK_SET) >= 0 &&
        read(fd, &arch, sizeof(arch)) == (ssize_t)sizeof(arch)) {
      print_arch_section(&arch);
    }
  } else {
    printf("  Architecture section: none\n");
  }

  close(fd);
}
