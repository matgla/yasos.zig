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

/* Unit tests for the Thumb-2 decoder.
 *
 * The exhaustive check is diff_objdump.py, which runs the decoder over every
 * module in the rootfs; these cover the cases that a corpus cannot be relied
 * on to contain, and the ones that were wrong once and must not be wrong
 * again.  They need no cross toolchain, so they run anywhere. */

#include "acutest.h"

#include "../thumb.h"

#include <string.h>

/* Encodings are written the way objdump prints them -- "f240 0300" -- because
 * that is how they are read out of a listing when a case is being added. */
static uint32_t bytes_of(const char *encoding, uint8_t *out) {
  uint32_t count = 0;
  while (*encoding) {
    unsigned value = 0;
    int digits = 0;
    while (*encoding == ' ') {
      ++encoding;
    }
    while (digits < 4 && *encoding) {
      char c = *encoding++;
      value = (value << 4) | (unsigned)((c <= '9') ? (c - '0') : (c - 'a' + 10));
      ++digits;
    }
    out[count++] = (uint8_t)(value & 0xFF);
    out[count++] = (uint8_t)(value >> 8);
  }
  return count;
}

static void check_at(uint32_t address, const char *encoding, const char *expected) {
  uint8_t bytes[8];
  uint32_t length = bytes_of(encoding, bytes);
  ThumbItState it;
  ThumbInsn insn;
  thumb_it_reset(&it);
  thumb_decode(&it, address, bytes, length, &insn);
  TEST_CHECK_(strcmp(insn.text, expected) == 0, "%s -> \"%s\", expected \"%s\"", encoding, insn.text, expected);
}

static void check(const char *encoding, const char *expected) { check_at(0, encoding, expected); }

void test_narrow_data_processing(void) {
  check("2600", "movs\tr6, #0");
  check("0000", "movs\tr0, r0");
  check("008a", "lsls\tr2, r1, #2");
  check("17e0", "asrs\tr0, r4, #31");
  check("1c61", "adds\tr1, r4, #1");
  check("18a9", "adds\tr1, r5, r2");
  check("4348", "muls\tr0, r1");
  check("431e", "orrs\tr6, r3");
  check("4240", "negs\tr0, r0");
  check("2b00", "cmp\tr3, #0");
  check("45b0", "cmp\tr8, r6");
  check("464a", "mov\tr2, r9");
  check("46c0", "nop"); /* the canonical thumb nop, which is a mov r8, r8 */
}

void test_narrow_memory_and_stack(void) {
  check("681e", "ldr\tr6, [r3, #0]");
  check("780a", "ldrb\tr2, [r1, #0]");
  check("5c0a", "ldrb\tr2, [r1, r0]");
  check("8e48", "ldrh\tr0, [r1, #50]");
  check("b430", "push\t{r4, r5}");
  check("bd70", "pop\t{r4, r5, r6, pc}");
  check("b083", "sub\tsp, #12");
  check("a901", "add\tr1, sp, #4");
  check("c278", "stmia\tr2!, {r3, r4, r5, r6}");
  /* A load whose base is in the list writes no base back, and objdump says so
   * by dropping the marker. */
  check("cc95", "ldmia\tr4, {r0, r2, r4, r7}");
}

void test_narrow_branches(void) {
  check_at(0x40, "e7f5", "b.n\t0x2e");
  check_at(0x2e, "d011", "beq.n\t0x54");
  check_at(0x2d12, "b12c", "cbz\tr4, 0x2d20");
  check_at(0x2d2c, "b939", "cbnz\tr1, 0x2d3e");
  check("4770", "bx\tlr");
  check("47d0", "blx\tsl");
  /* The security-extension forms differ from bx/blx in bit 2 only. */
  check("4704", "bxns\tr0");
  check("4724", "bxns\tr4");
  check("beef", "bkpt\t0x00ef");
  check("df38", "svc\t56");
}

void test_wide_data_processing(void) {
  check("f108 0801", "add.w\tr8, r8, #1");
  check("f04f 0800", "mov.w\tr8, #0");
  check("f06f 0000", "mvn.w\tr0, #0");
  check("f082 4100", "eor.w\tr1, r2, #2147483648");
  check("f1ba 0f00", "cmp.w\tsl, #0");
  check("f1c0 0200", "rsb\tr2, r0, #0"); /* rsb has no narrow form, so no .w */
  check("ea40 0201", "orr.w\tr2, r0, r1");
  check("ea42 72c1", "orr.w\tr2, r2, r1, lsl #31");
  check("ea4f 2806", "mov.w\tr8, r6, lsl #8");
  check("eb00 1b01", "add.w\tfp, r0, r1, lsl #4");
  check("f240 72ff", "movw\tr2, #2047");
  check("f200 31ff", "addw\tr1, r0, #1023");
  check("f3c3 0216", "ubfx\tr2, r3, #0, #23");
  check("f361 00c4", "bfi\tr0, r1, #3, #2");
  check("fab1 f281", "clz\tr2, r1");
  check("fb00 3201", "mla\tr2, r0, r1, r3");
  check("fb00 f102", "mul.w\tr1, r0, r2");
  check("fb91 f0f2", "sdiv\tr0, r1, r2");
  check("fba2 4506", "umull\tr4, r5, r2, r6");
}

void test_wide_memory(void) {
  check("f8d9 33a8", "ldr.w\tr3, [r9, #936]");
  check("f8dd 9000", "ldr.w\tr9, [sp]"); /* a wide form drops a zero offset */
  check("f857 a028", "ldr.w\tsl, [r7, r8, lsl #2]");
  check("e9c0 2302", "strd\tr2, r3, [r0, #8]");
  check("e9c2 4500", "strd\tr4, r5, [r2]");
  check("e92d 45f0", "stmdb\tsp!, {r4, r5, r6, r7, r8, sl, lr}");
  check("e8bd 05f0", "ldmia.w\tsp!, {r4, r5, r6, r7, r8, sl}");
  check("f851 0f00", "ldr.w\tr0, [r1]!"); /* but a core load keeps its marker */
  check("f851 0b00", "ldr.w\tr0, [r1], #0");
  check("e9e2 0100", "strd\tr0, r1, [r2]"); /* while a pair drops it */
}

void test_wide_branches(void) {
  check_at(0x62, "f004 fa25", "bl\t0x44b0");
  check_at(0x2, "f000 b800", "b.w\t0x6");
  check_at(0xc6, "f000 8003", "beq.w\t0xd0");
  check_at(0x2b4, "f2c0 8020", "blt.w\t0x2f8");
  check("f3ef 8014", "mrs\tr0, CONTROL");
  check("f380 8814", "msr\tCONTROL, r0");
}

void test_coprocessor_and_floating_point(void) {
  /* The RP2350's double-precision coprocessor, which lives on cp4. */
  check("ec45 4410", "mcrr\t4, 1, r4, r5, cr0");
  check("ee00 0401", "cdp\t4, 0, cr0, cr0, cr1, {0}");
  check("ee10 f430", "mrc\t4, 0, APSR_nzcv, cr0, cr0, {1}");
  /* The FPU, which would otherwise decode as more of the same. */
  check("ee00 0a10", "vmov\ts0, r0");
  check("ee10 0a10", "vmov\tr0, s0");
  check("ec43 2b10", "vmov\td0, r2, r3");
  check("eef1 fa10", "vmrs\tAPSR_nzcv, fpscr");
  check("ee30 0a01", "vadd.f32\ts0, s0, s2");
  check("ee80 0b01", "vdiv.f64\td0, d0, d1");
  check("eeb1 0bc0", "vsqrt.f64\td0, d0");
  check("eeb4 0ac0", "vcmpe.f32\ts0, s0");
  check("ed90 0a00", "vldr\ts0, [r0]");
  check("ed2d 8b10", "vpush\t{d8-d15}");
}

/* An IT block colours the instructions after it, and the condition of each
 * slot comes out of a shift that includes the condition's own low bit -- get
 * that wrong and "ite ne" reads as ne/cs instead of ne/eq. */
void test_it_block(void) {
  static const uint8_t block[] = {0x14, 0xbf, 0x01, 0x20, 0x00, 0x20, 0x0a, 0x78};
  static const char *const expected[] = {"ite\tne", "movne\tr0, #1", "moveq\tr0, #0", "ldrb\tr2, [r1, #0]"};
  ThumbItState it;
  ThumbInsn insn;
  uint32_t offset = 0;
  unsigned index = 0;
  thumb_it_reset(&it);
  for (index = 0; index < 4; ++index) {
    thumb_decode(&it, offset, block + offset, (uint32_t)sizeof(block) - offset, &insn);
    TEST_CHECK_(strcmp(insn.text, expected[index]) == 0, "slot %u -> \"%s\", expected \"%s\"", index, insn.text,
                expected[index]);
    offset += insn.size;
  }
}

/* What the listing needs on top of the text: where a branch goes, and which
 * words are data rather than instructions. */
void test_reported_targets(void) {
  uint8_t bytes[8];
  ThumbItState it;
  ThumbInsn insn;

  thumb_it_reset(&it);
  bytes_of("4a06", bytes);
  thumb_decode(&it, 0x14d0, bytes, 2, &insn);
  TEST_CHECK(insn.target_kind == THUMB_TARGET_LITERAL);
  TEST_CHECK(insn.target == 0x14ec);
  TEST_CHECK(insn.target_size == 4);

  thumb_it_reset(&it);
  bytes_of("f004 fa25", bytes);
  thumb_decode(&it, 0x62, bytes, 4, &insn);
  TEST_CHECK(insn.target_kind == THUMB_TARGET_BRANCH);
  TEST_CHECK(insn.target == 0x44b0);
}

/* Encodings that no armv8-m part has must be refused rather than guessed at:
 * they are what a literal pool looks like to a disassembler. */
void test_refuses_what_is_not_an_instruction(void) {
  check("ffff b570", ".word\t0xb570ffff");
  check("e850 0000", ".word\t0x0000e850"); /* ldrex, but with its SBO field clear */
  check("f0c8 0000", ".word\t0x0000f0c8"); /* pkh has no immediate encoding */
  check("f740 0000", ".word\t0x0000f740"); /* sbfx with the i bit set */
}

void test_truncated_input(void) {
  uint8_t bytes[4];
  ThumbItState it;
  ThumbInsn insn;
  thumb_it_reset(&it);
  bytes_of("f004 fa25", bytes);
  thumb_decode(&it, 0, bytes, 2, &insn);
  TEST_CHECK(insn.size == 0); /* a 32-bit encoding with only a halfword left */
  thumb_decode(&it, 0, bytes, 0, &insn);
  TEST_CHECK(insn.size == 0);
}

TEST_LIST = {
    {"narrow data processing", test_narrow_data_processing},
    {"narrow memory and stack", test_narrow_memory_and_stack},
    {"narrow branches", test_narrow_branches},
    {"wide data processing", test_wide_data_processing},
    {"wide memory", test_wide_memory},
    {"wide branches", test_wide_branches},
    {"coprocessor and floating point", test_coprocessor_and_floating_point},
    {"it block", test_it_block},
    {"reported targets", test_reported_targets},
    {"refuses what is not an instruction", test_refuses_what_is_not_an_instruction},
    {"truncated input", test_truncated_input},
    {NULL, NULL},
};
