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

/* A Thumb-2 disassembler for what an armv8-m module actually contains.
 *
 * The syntax is arm-none-eabi-objdump's, deliberately: that is what makes the
 * differential test in tests/ cheap (disassemble the whole rootfs both ways and
 * diff), and the test is the specification.  Where this decoder is *not* a copy
 * of objdump is in what it is told: it disassembles a YAFF module, so it knows
 * which bytes are code, which pc-relative words are literal pools, and what the
 * functions are called.
 */

#pragma once

#include <stdint.h>

/* An IT block colours the instructions that follow it, so decoding is not
 * position independent -- a listing has to be walked from the start of a
 * region, which is what the caller does. */
typedef struct {
  /* ITSTATE exactly as the architecture keeps it: firstcond in the top nibble,
   * the then/else mask in the bottom one, shifted left by one per instruction
   * the block covers. Zero means "not in an IT block". */
  uint8_t state;
} ThumbItState;

typedef enum {
  THUMB_TARGET_NONE = 0,
  THUMB_TARGET_BRANCH,  /* a code address */
  THUMB_TARGET_LITERAL, /* a data word the instruction loads */
} ThumbTargetKind;

typedef struct {
  uint32_t size; /* 2 or 4; 0 when there were not enough bytes left */
  char text[96]; /* "mnemonic\toperands", objdump's spelling */
  char comment[64]; /* what objdump would put after "@", without it */
  ThumbTargetKind target_kind;
  uint32_t target;      /* branch destination, or literal address */
  uint32_t target_size; /* bytes of literal data (4 or 8) */
  int undefined;        /* nothing decoded it; text is ".word" */
} ThumbInsn;

void thumb_it_reset(ThumbItState *it);

/* Decodes one instruction at `address` from `bytes` (`available` bytes of it).
 * `address` is in whatever space the caller counts in -- for a YAFF listing
 * that is the module offset, so the branch targets come out as the same
 * numbers the symbol table uses. */
void thumb_decode(ThumbItState *it, uint32_t address, const uint8_t *bytes, uint32_t available, ThumbInsn *out);

/* Formats `count` bytes as objdump prints an encoding: "b580" for a 16-bit
 * instruction, "f240 0300" for a 32-bit one. */
void thumb_format_encoding(const uint8_t *bytes, uint32_t count, char *out, uint32_t size);
