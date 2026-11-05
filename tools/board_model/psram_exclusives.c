/*
 * Copyright (c) 2026 Mateusz Stadnik
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * QEMU TCG plugin: stop on an exclusive access to memory the board has as PSRAM.
 *
 * An exclusive store to PSRAM never succeeds on the RP2350, so an atomic there
 * spins for ever (source/kernel/sync/placement.zig). QEMU's exclusives always work,
 * and the placement assertion covers only what calls it, so such an atomic passes
 * every test here and hangs the board. This sees all of them, whatever compiled
 * them and whoever allocated the memory.
 *
 *   -plugin libpsram_exclusives.so,range=0x6c000000:0x80000000[,range=...][,log=FILE]
 *
 * On the first one it writes the PC and the address, to FILE when given as well as
 * to the plugin log, and ends QEMU with status 99.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

#define MAX_RANGES 8

static struct
{
  uint64_t start, end;
} ranges[MAX_RANGES];
static int range_count;
static const char *log_path;

static int in_range(uint64_t address)
{
  for (int i = 0; i < range_count; i++)
    if (address >= ranges[i].start && address < ranges[i].end)
      return 1;
  return 0;
}

static void on_exclusive(unsigned int vcpu, qemu_plugin_meminfo_t info, uint64_t address, void *pc)
{
  (void)vcpu;
  (void)info;
  if (!in_range(address))
    return;
  char line[128];
  snprintf(line, sizeof line, "EXCLUSIVE IN PSRAM pc=0x%" PRIx64 " address=0x%" PRIx64 "\n", (uint64_t)(uintptr_t)pc,
           address);
  qemu_plugin_outs(line);
  if (log_path)
  {
    FILE *log = fopen(log_path, "a");
    if (log)
    {
      fputs(line, log);
      fclose(log);
    }
  }
  exit(99);
}

/* From the encoding: this QEMU may be built without a disassembler, and then
 * qemu_plugin_insn_disas has no mnemonic to look at. Thumb-2, ARMv8-M:
 *   E85n         ldrex
 *   E84n         strex
 *   E8Dn, op     ldrexb 4, ldrexh 5, ldaexb C, ldaexh D, ldaex E
 *   E8Cn, op     strexb 4, strexh 5, stlexb C, stlexh D, stlex E
 * with op in bits 7:4 of the second halfword. Other ops there are not exclusive:
 * tbb, tbh, lda, stl. */
static int is_exclusive(const struct qemu_plugin_insn *insn)
{
  uint8_t bytes[4];
  if (qemu_plugin_insn_size(insn) != 4 || qemu_plugin_insn_data(insn, bytes, sizeof bytes) != sizeof bytes)
    return 0;
  uint16_t first = (uint16_t)(bytes[0] | bytes[1] << 8);
  uint16_t second = (uint16_t)(bytes[2] | bytes[3] << 8);
  uint16_t group = first & 0xFFF0;
  if (group == 0xE850 || group == 0xE840)
    return 1;
  if (group != 0xE8D0 && group != 0xE8C0)
    return 0;
  unsigned op = (second >> 4) & 0xF;
  return op == 0x4 || op == 0x5 || op == 0xC || op == 0xD || op == 0xE;
}

static void on_translation(struct qemu_plugin_tb *tb, void *userdata)
{
  (void)userdata;
  size_t count = qemu_plugin_tb_n_insns(tb);
  for (size_t i = 0; i < count; i++)
  {
    struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
    if (is_exclusive(insn))
      qemu_plugin_register_vcpu_mem_cb(insn, on_exclusive, QEMU_PLUGIN_CB_NO_REGS, QEMU_PLUGIN_MEM_RW,
                                       (void *)(uintptr_t)qemu_plugin_insn_vaddr(insn));
  }
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info, int argc, char **argv)
{
  (void)info;
  for (int i = 0; i < argc; i++)
  {
    uint64_t start, end;
    if (sscanf(argv[i], "range=%" SCNx64 ":%" SCNx64, &start, &end) == 2 && range_count < MAX_RANGES)
    {
      ranges[range_count].start = start;
      ranges[range_count].end = end;
      range_count++;
    }
    else if (!strncmp(argv[i], "log=", 4))
    {
      log_path = argv[i] + 4;
    }
    else
    {
      fprintf(stderr, "psram_exclusives: bad argument '%s'\n", argv[i]);
      return -1;
    }
  }
  qemu_plugin_register_vcpu_tb_trans_cb(id, on_translation, NULL);
  return 0;
}
