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

#include "thumb.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* objdump's names, not the architecture's: r10, r11 and r12 print as sl, fp
 * and ip.  Matching this is the whole point -- the differential test diffs
 * against objdump line for line. */
static const char *const register_names[16] = {"r0", "r1", "r2",  "r3", "r4", "r5", "r6", "r7",
                                               "r8", "r9", "sl",  "fp", "ip", "sp", "lr", "pc"};
static const char *const condition_names[16] = {"eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc",
                                                "hi", "ls", "ge", "lt", "gt", "le", "al", ""};
static const char *const shift_names[4] = {"lsl", "lsr", "asr", "ror"};

#define R(n) register_names[(n) & 0xF]

static void put(ThumbInsn *insn, const char *format, ...) {
  va_list arguments;
  size_t used = strlen(insn->text);
  va_start(arguments, format);
  vsnprintf(insn->text + used, sizeof(insn->text) - used, format, arguments);
  va_end(arguments);
}

static void note(ThumbInsn *insn, const char *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  vsnprintf(insn->comment, sizeof(insn->comment), format, arguments);
  va_end(arguments);
}

/* objdump repeats an immediate in hex once it stops being readable in decimal.
 * The cut-off is empirical: it is where binutils starts doing it. */
static void note_immediate(ThumbInsn *insn, int32_t value) {
  if (value > 32 || value < -32) {
    note(insn, "0x%x", (unsigned int)value);
  }
}

static void branch_to(ThumbInsn *insn, uint32_t target) {
  insn->target_kind = THUMB_TARGET_BRANCH;
  insn->target = target;
}

static void literal_at(ThumbInsn *insn, uint32_t address, uint32_t size) {
  insn->target_kind = THUMB_TARGET_LITERAL;
  insn->target = address;
  insn->target_size = size;
}

static int32_t sign_extend(uint32_t value, unsigned bits) {
  uint32_t sign = 1u << (bits - 1);
  return (int32_t)((value ^ sign) - sign);
}

static void register_list(char *buffer, size_t size, uint32_t list) {
  size_t used = 1;
  int first = 1;
  int i = 0;
  buffer[0] = '{';
  buffer[1] = 0;
  for (i = 0; i < 16; ++i) {
    if (!(list & (1u << i))) {
      continue;
    }
    used += (size_t)snprintf(buffer + used, size - used, "%s%s", first ? "" : ", ", R(i));
    first = 0;
  }
  snprintf(buffer + used, size - used, "}");
}

/* ThumbExpandImm: the 12-bit modified immediate of the 32-bit data processing
 * encodings, which is either a byte replicated into some of the four lanes or
 * an 8-bit value with its top bit forced on and rotated right. */
static uint32_t expand_immediate(uint32_t i, uint32_t imm3, uint32_t imm8) {
  uint32_t value = (i << 11) | (imm3 << 8) | imm8;
  uint32_t rotation = 0;
  uint32_t unrotated = 0;
  if ((value & 0xC00) == 0) {
    switch ((value >> 8) & 0x3) {
    case 0:
      return imm8;
    case 1:
      return (imm8 << 16) | imm8;
    case 2:
      return (imm8 << 24) | (imm8 << 8);
    default:
      return (imm8 << 24) | (imm8 << 16) | (imm8 << 8) | imm8;
    }
  }
  unrotated = 0x80u | (imm8 & 0x7Fu);
  rotation = value >> 7;
  return (unrotated >> rotation) | (unrotated << (32 - rotation));
}

void thumb_it_reset(ThumbItState *it) { it->state = 0; }

/* The condition an instruction inherits from the IT block it sits in, or NULL
 * when it is not inside one. */
static const char *it_condition(const ThumbItState *it) {
  if ((it->state & 0xF) == 0) {
    return NULL;
  }
  return condition_names[(it->state >> 4) & 0xF];
}

/* ITSTATE advances by one instruction: the architecture's
 * ITSTATE[7:5]:(ITSTATE[4:0] << 1), which empties the mask on the last one. */
static void it_advance(ThumbItState *it) {
  /* The architecture's ITAdvance: ITSTATE<4:0> shifts left, and bits 7:5 stay
   * put.  The condition's low bit is *inside* the shifted field -- that is what
   * flips the condition on an "else" slot -- so preserving the whole top nibble
   * (the obvious spelling) turns "ite ne" into ne/cs instead of ne/eq. */
  if ((it->state & 0x7) == 0) {
    it->state = 0;
    return;
  }
  it->state = (uint8_t)((it->state & 0xE0) | ((it->state << 1) & 0x1F));
}

/* Two of the three suffixes a 16-bit mnemonic can carry.  Outside an IT block
 * the 16-bit data-processing instructions always set flags, so they print with
 * "s"; inside one they do not, and print with the block's condition instead. */
static const char *flag_suffix(const ThumbItState *it) {
  const char *condition = it_condition(it);
  return condition ? condition : "s";
}

static const char *plain_suffix(const ThumbItState *it) {
  const char *condition = it_condition(it);
  return condition ? condition : "";
}

void thumb_format_encoding(const uint8_t *bytes, uint32_t count, char *out, uint32_t size) {
  if (count >= 4) {
    snprintf(out, size, "%02x%02x %02x%02x", bytes[1], bytes[0], bytes[3], bytes[2]);
  } else if (count >= 2) {
    snprintf(out, size, "%02x%02x", bytes[1], bytes[0]);
  } else {
    snprintf(out, size, "%02x", bytes[0]);
  }
}

/* ---------------------------------------------------------------------- */
/* 16-bit encodings                                                        */
/* ---------------------------------------------------------------------- */

/* Returns 1 when the instruction opened an IT block, which is the one case
 * where the caller must not then advance ITSTATE. */
static int decode16(ThumbItState *it, uint32_t address, uint16_t hw, ThumbInsn *out) {
  char list[96];

  switch (hw >> 12) {
  case 0x0:
  case 0x1: {
    unsigned op = (hw >> 11) & 0x3;
    if (op != 3) { /* shift by immediate */
      unsigned imm5 = (hw >> 6) & 0x1F;
      unsigned rm = (hw >> 3) & 0x7;
      unsigned rd = hw & 0x7;
      if (op == 0 && imm5 == 0) {
        put(out, "mov%s\t%s, %s", flag_suffix(it), R(rd), R(rm));
      } else {
        unsigned amount = (op != 0 && imm5 == 0) ? 32 : imm5;
        put(out, "%s%s\t%s, %s, #%u", shift_names[op], flag_suffix(it), R(rd), R(rm), amount);
      }
    } else { /* add/sub, register or 3-bit immediate */
      unsigned kind = (hw >> 9) & 0x3;
      unsigned operand = (hw >> 6) & 0x7;
      unsigned rn = (hw >> 3) & 0x7;
      unsigned rd = hw & 0x7;
      const char *name = (kind & 1) ? "sub" : "add";
      if (kind < 2) {
        put(out, "%s%s\t%s, %s, %s", name, flag_suffix(it), R(rd), R(rn), R(operand));
      } else {
        put(out, "%s%s\t%s, %s, #%u", name, flag_suffix(it), R(rd), R(rn), operand);
      }
    }
    break;
  }
  case 0x2:
  case 0x3: {
    unsigned op = (hw >> 11) & 0x3;
    unsigned rd = (hw >> 8) & 0x7;
    unsigned immediate = hw & 0xFF;
    static const char *const names[4] = {"mov", "cmp", "add", "sub"};
    put(out, "%s%s\t%s, #%u", names[op], op == 1 ? plain_suffix(it) : flag_suffix(it), R(rd), immediate);
    note_immediate(out, (int32_t)immediate);
    break;
  }
  case 0x4: {
    if ((hw & 0xFC00) == 0x4000) { /* data processing, low registers */
      static const char *const names[16] = {"and", "eor", "lsl", "lsr", "asr", "adc", "sbc", "ror",
                                            "tst", "rsb", "cmp", "cmn", "orr", "mul", "bic", "mvn"};
      unsigned op = (hw >> 6) & 0xF;
      unsigned rm = (hw >> 3) & 0x7;
      unsigned rd = hw & 0x7;
      if (op == 8 || op == 10 || op == 11) { /* tst, cmp, cmn never carry an s */
        put(out, "%s%s\t%s, %s", names[op], plain_suffix(it), R(rd), R(rm));
      } else if (op == 9) { /* RSB #0 in the architecture, which objdump spells neg */
        put(out, "neg%s\t%s, %s", flag_suffix(it), R(rd), R(rm));
      } else {
        put(out, "%s%s\t%s, %s", names[op], flag_suffix(it), R(rd), R(rm));
      }
    } else if ((hw & 0xFC00) == 0x4400) { /* high registers, and the branches */
      unsigned op = (hw >> 8) & 0x3;
      unsigned rm = (hw >> 3) & 0xF;
      unsigned rd = (unsigned)(((hw >> 4) & 0x8) | (hw & 0x7));
      switch (op) {
      case 0:
        put(out, "add%s\t%s, %s", plain_suffix(it), R(rd), R(rm));
        break;
      case 1:
        put(out, "cmp%s\t%s, %s", plain_suffix(it), R(rd), R(rm));
        break;
      case 2:
        if (hw == 0x46C0) {
          put(out, "nop%s", plain_suffix(it));
          note(out, "(mov r8, r8)");
        } else {
          put(out, "mov%s\t%s, %s", plain_suffix(it), R(rd), R(rm));
        }
        break;
      default:
        /* Bit 0 selects the security-extension form; it is not a don't-care. */
        put(out, "%s%s%s\t%s", (hw & 0x0080) ? "blx" : "bx", (hw & 0x0004) ? "ns" : "", plain_suffix(it), R(rm));
        break;
      }
    } else { /* ldr from the literal pool */
      unsigned rt = (hw >> 8) & 0x7;
      unsigned offset = (unsigned)(hw & 0xFF) * 4;
      uint32_t target = ((address + 4) & ~3u) + offset;
      put(out, "ldr%s\t%s, [pc, #%u]", plain_suffix(it), R(rt), offset);
      note(out, "(0x%x)", target);
      literal_at(out, target, 4);
    }
    break;
  }
  case 0x5: {
    static const char *const names[8] = {"str", "strh", "strb", "ldrsb", "ldr", "ldrh", "ldrb", "ldrsh"};
    unsigned op = (hw >> 9) & 0x7;
    put(out, "%s%s\t%s, [%s, %s]", names[op], plain_suffix(it), R(hw & 7), R((hw >> 3) & 7), R((hw >> 6) & 7));
    break;
  }
  case 0x6:
  case 0x7: {
    unsigned load = (hw >> 11) & 1;
    unsigned byte = (hw >> 12) & 1;
    unsigned offset = (unsigned)((hw >> 6) & 0x1F) * (byte ? 1u : 4u);
    put(out, "%s%s%s\t%s, [%s, #%u]", load ? "ldr" : "str", byte ? "b" : "", plain_suffix(it), R(hw & 7),
        R((hw >> 3) & 7), offset);
    note_immediate(out, (int32_t)offset);
    break;
  }
  case 0x8: {
    unsigned offset = (unsigned)((hw >> 6) & 0x1F) * 2;
    put(out, "%s%s\t%s, [%s, #%u]", ((hw >> 11) & 1) ? "ldrh" : "strh", plain_suffix(it), R(hw & 7),
        R((hw >> 3) & 7), offset);
    note_immediate(out, (int32_t)offset);
    break;
  }
  case 0x9: {
    unsigned offset = (unsigned)(hw & 0xFF) * 4;
    put(out, "%s%s\t%s, [sp, #%u]", ((hw >> 11) & 1) ? "ldr" : "str", plain_suffix(it), R((hw >> 8) & 7), offset);
    note_immediate(out, (int32_t)offset);
    break;
  }
  case 0xA: {
    unsigned rd = (hw >> 8) & 0x7;
    unsigned offset = (unsigned)(hw & 0xFF) * 4;
    if (hw & 0x0800) {
      put(out, "add%s\t%s, sp, #%u", plain_suffix(it), R(rd), offset);
      note_immediate(out, (int32_t)offset);
    } else {
      uint32_t target = ((address + 4) & ~3u) + offset;
      put(out, "add%s\t%s, pc, #%u", plain_suffix(it), R(rd), offset);
      note(out, "(adr %s, 0x%x)", R(rd), target);
      /* An address, but of no stated length: the listing may annotate it and
       * must not conclude it knows how many bytes there are. */
      literal_at(out, target, 0);
    }
    break;
  }
  case 0xB: {
    if ((hw & 0xFF00) == 0xB000) {
      unsigned offset = (unsigned)(hw & 0x7F) * 4;
      put(out, "%s%s\tsp, #%u", (hw & 0x0080) ? "sub" : "add", plain_suffix(it), offset);
      note_immediate(out, (int32_t)offset);
    } else if ((hw & 0xF500) == 0xB100) {
      unsigned offset = (unsigned)((((hw >> 9) & 1) << 6) | (((hw >> 3) & 0x1F) << 1));
      uint32_t target = address + 4 + offset;
      put(out, "cb%sz\t%s, 0x%x", (hw & 0x0800) ? "n" : "", R(hw & 7), target);
      branch_to(out, target);
    } else if ((hw & 0xFF00) == 0xB200) {
      static const char *const names[4] = {"sxth", "sxtb", "uxth", "uxtb"};
      put(out, "%s%s\t%s, %s", names[(hw >> 6) & 3], plain_suffix(it), R(hw & 7), R((hw >> 3) & 7));
    } else if ((hw & 0xFE00) == 0xB400) {
      register_list(list, sizeof(list), (uint32_t)(hw & 0xFF) | ((hw & 0x0100) ? 0x4000u : 0u));
      put(out, "push%s\t%s", plain_suffix(it), list);
    } else if ((hw & 0xFE00) == 0xBC00) {
      register_list(list, sizeof(list), (uint32_t)(hw & 0xFF) | ((hw & 0x0100) ? 0x8000u : 0u));
      put(out, "pop%s\t%s", plain_suffix(it), list);
    } else if ((hw & 0xFF00) == 0xBA00) {
      static const char *const names[4] = {"rev", "rev16", NULL, "revsh"};
      const char *name = names[(hw >> 6) & 3];
      if (!name) {
        out->undefined = 1;
      } else {
        put(out, "%s%s\t%s, %s", name, plain_suffix(it), R(hw & 7), R((hw >> 3) & 7));
      }
    } else if ((hw & 0xFFE8) == 0xB660) {
      put(out, "cps%s\t%s", (hw & 0x0010) ? "id" : "ie", (hw & 0x0002) ? "i" : "f");
    } else if ((hw & 0xFF00) == 0xBE00) {
      put(out, "bkpt\t0x%04x", (unsigned)(hw & 0xFF));
    } else if ((hw & 0xFF00) == 0xBF00) {
      unsigned mask = hw & 0xF;
      unsigned condition = (hw >> 4) & 0xF;
      if (mask == 0) {
        static const char *const hints[5] = {"nop", "yield", "wfe", "wfi", "sev"};
        if (condition < 5) {
          put(out, "%s%s", hints[condition], plain_suffix(it));
        } else {
          /* Unallocated hints execute as a nop, and objdump prints which one. */
          put(out, "nop%s\t{%u}", plain_suffix(it), condition);
        }
      } else {
        /* "it", then one letter per instruction the block still covers: t when
         * that slot takes the base condition, e when it takes the inverse. */
        char name[8];
        unsigned length = 0;
        unsigned lowest = 0;
        unsigned bit = 0;
        name[length++] = 'i';
        name[length++] = 't';
        while (!((mask >> lowest) & 1)) {
          ++lowest;
        }
        for (bit = 3; bit > lowest; --bit) {
          name[length++] = (((mask >> bit) & 1) == (condition & 1)) ? 't' : 'e';
        }
        name[length] = 0;
        put(out, "%s\t%s", name, condition_names[condition]);
        it->state = (uint8_t)((condition << 4) | mask);
        return 1;
      }
    } else {
      out->undefined = 1;
    }
    break;
  }
  case 0xC: {
    unsigned load = (hw >> 11) & 1;
    unsigned rn = (hw >> 8) & 0x7;
    unsigned registers = hw & 0xFF;
    /* A load whose base is in the list leaves the base alone -- the popped
     * value wins -- and objdump drops the writeback marker to say so. */
    int writeback = !(load && (registers & (1u << rn)));
    register_list(list, sizeof(list), registers);
    put(out, "%s%s\t%s%s, %s", load ? "ldmia" : "stmia", plain_suffix(it), R(rn), writeback ? "!" : "", list);
    break;
  }
  case 0xD: {
    unsigned condition = (hw >> 8) & 0xF;
    if (condition == 0xE) {
      put(out, "udf\t#%u", (unsigned)(hw & 0xFF));
      note_immediate(out, (int32_t)(hw & 0xFF));
    } else if (condition == 0xF) {
      put(out, "svc\t%u", (unsigned)(hw & 0xFF));
    } else {
      uint32_t target = (uint32_t)((int32_t)address + 4 + sign_extend((uint32_t)(hw & 0xFF) << 1, 9));
      put(out, "b%s.n\t0x%x", condition_names[condition], target);
      branch_to(out, target);
    }
    break;
  }
  default: { /* 0xE000..0xE7FF, the unconditional narrow branch */
    uint32_t target = (uint32_t)((int32_t)address + 4 + sign_extend((uint32_t)(hw & 0x7FF) << 1, 12));
    put(out, "b%s.n\t0x%x", plain_suffix(it), target);
    branch_to(out, target);
    break;
  }
  }
  return 0;
}

/* ---------------------------------------------------------------------- */
/* 32-bit encodings                                                        */
/* ---------------------------------------------------------------------- */

/* The data-processing operations shared by the shifted-register and the
 * modified-immediate encodings.  `wide` records which of them objdump spells
 * with a .w: exactly the ones that also have a 16-bit encoding, so that the
 * suffix says "this is the wide form of something you have seen narrow". */
/* pkh is deliberately absent: it has its own operand form in the shifted
 * register space and no encoding at all in the immediate one, so leaving it in
 * this table made a word of data decode as "pkh r0, r8, #0". */
static const char *const dp_names[16] = {"and", "bic", "orr", "orn", "eor", NULL, NULL, NULL,
                                         "add", NULL,  "adc", "sbc", NULL,  "sub", "rsb", NULL};
static const char dp_wide[16] = {1, 1, 1, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0};

/* The four data-processing operations that keep only the flags.  teq has no
 * 16-bit encoding, so it alone is not spelled with a .w. */
static const char *compare_name(unsigned op) {
  switch (op) {
  case 0:
    return "tst";
  case 4:
    return "teq";
  case 8:
    return "cmn";
  case 13:
    return "cmp";
  default:
    return NULL;
  }
}

static int compare_is_wide(unsigned op) { return op != 4; }

static void note_immediate_unsigned(ThumbInsn *insn, uint32_t value) {
  if (value > 32) {
    note(insn, "0x%x", value);
  }
}

static void append_shift(ThumbInsn *out, unsigned type, unsigned amount) {
  if (type == 3 && amount == 0) {
    put(out, ", rrx");
    return;
  }
  if (amount == 0) {
    if (type == 0) {
      return; /* lsl #0 is not a shift at all */
    }
    amount = 32; /* lsr #0 and asr #0 encode a shift of 32 */
  }
  put(out, ", %s #%u", shift_names[type], amount);
}

/* "[rn, #imm]", "[rn, #imm]!" or "[rn], #imm", chosen by the index/writeback
 * bits.  The sign is printed rather than folded into the number so that the
 * negative-zero objdump emits for U=0,imm=0 survives. */
static void append_indexed(ThumbInsn *out, unsigned rn, unsigned index, unsigned add, unsigned writeback,
                           unsigned immediate) {
  const char *sign = add ? "" : "-";
  if (index) {
    if (immediate == 0 && add) {
      put(out, "[%s]%s", R(rn), writeback ? "!" : "");
    } else {
      put(out, "[%s, #%s%u]%s", R(rn), sign, immediate, writeback ? "!" : "");
    }
  } else {
    put(out, "[%s], #%s%u", R(rn), sign, immediate);
  }
  note_immediate(out, add ? (int32_t)immediate : -(int32_t)immediate);
}

/* The address of a load/store pair.  A zero displacement disappears, and takes
 * the writeback marker with it -- objdump prints "strd r0, r1, [r2, #0]!" as
 * "strd r0, r1, [r2]" -- but a *negative* zero keeps both.  The core loads do
 * not do any of this, which is why they have their own printer. */
static void append_pair_address(ThumbInsn *out, unsigned rn, unsigned index, unsigned add, unsigned writeback,
                                unsigned immediate) {
  if (!index) {
    put(out, "[%s], #%s%u", R(rn), add ? "" : "-", immediate);
    if (immediate) {
      note_immediate(out, add ? (int32_t)immediate : -(int32_t)immediate);
    }
    return;
  }
  if (immediate) {
    put(out, "[%s, #%s%u]%s", R(rn), add ? "" : "-", immediate, writeback ? "!" : "");
    note_immediate(out, add ? (int32_t)immediate : -(int32_t)immediate);
  } else if (!add) {
    put(out, "[%s, #-0]%s", R(rn), writeback ? "!" : "");
  } else {
    put(out, "[%s]", R(rn));
  }
}

/* The coprocessor form is the same idea with one difference: its negative zero
 * drops the writeback marker as well. */
static void append_coprocessor_address(ThumbInsn *out, unsigned rn, unsigned add, unsigned writeback,
                                       unsigned immediate) {
  if (immediate) {
    put(out, "[%s, #%s%u]%s", R(rn), add ? "" : "-", immediate, writeback ? "!" : "");
    note_immediate(out, add ? (int32_t)immediate : -(int32_t)immediate);
  } else if (!add) {
    put(out, "[%s, #-0]", R(rn));
  } else {
    put(out, "[%s]", R(rn));
  }
}

static void decode32_load_store_multiple(ThumbItState *it, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned op = (hw1 >> 7) & 0x3;
  unsigned writeback = (hw1 >> 5) & 1;
  unsigned load = (hw1 >> 4) & 1;
  unsigned rn = hw1 & 0xF;
  char list[128];
  const char *name = NULL;

  if (op == 1) {
    name = load ? "ldmia.w" : "stmia.w";
  } else if (op == 2) {
    name = load ? "ldmdb" : "stmdb";
  } else {
    out->undefined = 1;
    return;
  }
  register_list(list, sizeof(list), hw2);
  put(out, "%s%s\t%s%s, %s", name, plain_suffix(it), R(rn), writeback ? "!" : "", list);
}

static void decode32_load_store_dual(ThumbItState *it, uint32_t address, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned rn = hw1 & 0xF;
  unsigned rt = (hw2 >> 12) & 0xF;
  unsigned rt2 = (hw2 >> 8) & 0xF;
  unsigned immediate = (unsigned)(hw2 & 0xFF) * 4;

  if ((hw1 & 0xFFE0) == 0xE840) { /* the word-sized exclusives */
    if ((hw1 & 0x0010) && (hw2 & 0x0F00) != 0x0F00) {
      out->undefined = 1; /* ldrex names no second register: the field is SBO */
      return;
    }
    if (hw1 & 0x0010) {
      put(out, "ldrex%s\t%s, ", plain_suffix(it), R(rt));
    } else {
      put(out, "strex%s\t%s, %s, ", plain_suffix(it), R(rt2), R(rt));
    }
    if (immediate == 0) {
      put(out, "[%s]", R(rn));
    } else {
      put(out, "[%s, #%u]", R(rn), immediate);
      note_immediate(out, (int32_t)immediate);
    }
    return;
  }
  if ((hw1 & 0xFFE0) == 0xE8C0) { /* byte/halfword exclusives, and table branch */
    unsigned op = (hw2 >> 4) & 0xF;
    unsigned load = (hw1 >> 4) & 1;
    /* Every encoding here has a should-be-one field where a table branch keeps
     * its Rt: without checking it, a word of data decodes as an exclusive. */
    if (load && (op == 0 || op == 1) && (hw2 & 0xF000) == 0xF000 && ((hw2 >> 8) & 0xF) == 0) {
      if (op == 0) {
        put(out, "tbb%s\t[%s, %s]", plain_suffix(it), R(rn), R(hw2 & 0xF));
      } else {
        put(out, "tbh%s\t[%s, %s, lsl #1]", plain_suffix(it), R(rn), R(hw2 & 0xF));
      }
      return;
    }
    if ((op == 4 || op == 5) && (hw2 & 0x0F00) == 0x0F00) {
      const char *width = (op == 5) ? "h" : "b";
      if (load) {
        put(out, "ldrex%s%s\t%s, [%s]", width, plain_suffix(it), R(rt), R(rn));
      } else {
        put(out, "strex%s%s\t%s, %s, [%s]", width, plain_suffix(it), R(hw2 & 0xF), R(rt), R(rn));
      }
      return;
    }
    out->undefined = 1;
    return;
  }
  /* Everything else in the class is the load/store pair. */
  {
    unsigned index = (hw1 >> 8) & 1;
    unsigned add = (hw1 >> 7) & 1;
    unsigned writeback = (hw1 >> 5) & 1;
    unsigned load = (hw1 >> 4) & 1;
    put(out, "%s%s\t%s, %s, ", load ? "ldrd" : "strd", plain_suffix(it), R(rt), R(rt2));
    if (rn == 15 && load) {
      uint32_t target = ((address + 4) & ~3u) + (add ? immediate : (uint32_t)-(int32_t)immediate);
      put(out, "[pc, #%s%u]", add ? "" : "-", immediate);
      note(out, "(0x%x)", target);
      literal_at(out, target, 8);
      return;
    }
    append_pair_address(out, rn, index, add, writeback, immediate);
  }
}

static void decode32_data_shifted(ThumbItState *it, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned op = (hw1 >> 5) & 0xF;
  unsigned setflags = (hw1 >> 4) & 1;
  unsigned rn = hw1 & 0xF;
  unsigned rd = (hw2 >> 8) & 0xF;
  unsigned rm = hw2 & 0xF;
  unsigned type = (hw2 >> 4) & 0x3;
  unsigned amount = (unsigned)(((hw2 >> 12) & 0x7) << 2) | ((hw2 >> 6) & 0x3);
  const char *condition = plain_suffix(it);

  if (setflags && rd == 15) { /* the compare forms, which discard the result */
    const char *name = compare_name(op);
    if (name) {
      put(out, "%s%s%s\t%s, %s", name, condition, compare_is_wide(op) ? ".w" : "", R(rn), R(rm));
      append_shift(out, type, amount);
      return;
    }
  }
  if (rn == 15 && (op == 2 || op == 3)) { /* mov/mvn register, with a shift */
    put(out, "%s%s%s.w\t%s, %s", op == 2 ? "mov" : "mvn", setflags ? "s" : "", condition, R(rd), R(rm));
    append_shift(out, type, amount);
    return;
  }
  if (!dp_names[op]) {
    out->undefined = 1;
    return;
  }
  put(out, "%s%s%s%s\t%s, %s, %s", dp_names[op], setflags ? "s" : "", condition, dp_wide[op] ? ".w" : "", R(rd),
      R(rn), R(rm));
  append_shift(out, type, amount);
}

static void decode32_data_immediate(ThumbItState *it, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned op = (hw1 >> 5) & 0xF;
  unsigned setflags = (hw1 >> 4) & 1;
  unsigned rn = hw1 & 0xF;
  unsigned rd = (hw2 >> 8) & 0xF;
  uint32_t value = expand_immediate((hw1 >> 10) & 1, (hw2 >> 12) & 0x7, hw2 & 0xFF);
  const char *condition = plain_suffix(it);

  if (setflags && rd == 15) {
    const char *name = compare_name(op);
    if (name) {
      put(out, "%s%s%s\t%s, #%u", name, condition, compare_is_wide(op) ? ".w" : "", R(rn), value);
      note_immediate_unsigned(out, value);
      return;
    }
  }
  if (rn == 15 && (op == 2 || op == 3)) {
    put(out, "%s%s%s.w\t%s, #%u", op == 2 ? "mov" : "mvn", setflags ? "s" : "", condition, R(rd), value);
    note_immediate_unsigned(out, value);
    return;
  }
  if (!dp_names[op]) {
    out->undefined = 1;
    return;
  }
  put(out, "%s%s%s%s\t%s, %s, #%u", dp_names[op], setflags ? "s" : "", condition, dp_wide[op] ? ".w" : "", R(rd),
      R(rn), value);
  note_immediate_unsigned(out, value);
}

static void decode32_plain_immediate(ThumbItState *it, uint32_t address, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned rn = hw1 & 0xF;
  unsigned rd = (hw2 >> 8) & 0xF;
  uint32_t immediate12 = (uint32_t)(((hw1 >> 10) & 1) << 11) | (uint32_t)(((hw2 >> 12) & 0x7) << 8) | (hw2 & 0xFF);
  unsigned lsb = (unsigned)(((hw2 >> 12) & 0x7) << 2) | ((hw2 >> 6) & 0x3);
  const char *condition = plain_suffix(it);

  /* Only the four "wide immediate" forms use the i bit as an immediate bit; in
   * the saturate and bitfield encodings it is a should-be-zero, and honouring
   * that is what keeps a word of data from decoding as an sbfx. */
  if ((hw1 & 0x0400) && (hw1 & 0x0300) == 0x0300) {
    out->undefined = 1;
    return;
  }
  switch (hw1 & 0xFBF0) {
  case 0xF200:
  case 0xF2A0: {
    int subtract = (hw1 & 0x00A0) == 0x00A0;
    if (rn == 15) { /* adr, which the assembler spells as an add or sub of pc */
      uint32_t target = ((address + 4) & ~3u) + (subtract ? (uint32_t)-(int32_t)immediate12 : immediate12);
      put(out, "%s%s\t%s, pc, #%u", subtract ? "subw" : "addw", condition, R(rd), immediate12);
      note(out, "(adr %s, 0x%x)", R(rd), target);
      literal_at(out, target, 0);
      return;
    }
    put(out, "%s%s\t%s, %s, #%u", subtract ? "subw" : "addw", condition, R(rd), R(rn), immediate12);
    note_immediate_unsigned(out, immediate12);
    return;
  }
  case 0xF240:
  case 0xF2C0: {
    uint32_t value = ((uint32_t)(hw1 & 0xF) << 12) | immediate12;
    put(out, "%s%s\t%s, #%u", (hw1 & 0x0080) ? "movt" : "movw", condition, R(rd), value);
    note_immediate_unsigned(out, value);
    return;
  }
  case 0xF340:
  case 0xF3C0:
    put(out, "%s%s\t%s, %s, #%u, #%u", (hw1 & 0x0080) ? "ubfx" : "sbfx", condition, R(rd), R(rn), lsb,
        (unsigned)(hw2 & 0x1F) + 1);
    return;
  case 0xF360: {
    unsigned msb = hw2 & 0x1F;
    if (msb < lsb) {
      out->undefined = 1;
      return;
    }
    if (rn == 15) {
      put(out, "bfc%s\t%s, #%u, #%u", condition, R(rd), lsb, msb - lsb + 1);
    } else {
      put(out, "bfi%s\t%s, %s, #%u, #%u", condition, R(rd), R(rn), lsb, msb - lsb + 1);
    }
    return;
  }
  case 0xF300:
  case 0xF380: {
    unsigned saturate = (unsigned)(hw2 & 0x1F) + ((hw1 & 0x0080) ? 0u : 1u);
    unsigned type = (hw2 >> 4) & 0x2;
    put(out, "%s%s\t%s, #%u, %s", (hw1 & 0x0080) ? "usat" : "ssat", condition, R(rd), saturate, R(rn));
    append_shift(out, type ? 2 : 0, lsb);
    return;
  }
  default:
    out->undefined = 1;
    return;
  }
}

/* The registers mrs and msr reach, in the numbering the architecture gives
 * them.  Anything unallocated prints as its number rather than as a guess. */
static const char *special_register_name(char *buffer, size_t size, unsigned number) {
  static const char *const names[21] = {"CPSR", "IAPSR", "EAPSR", "PSR",    "",     "IPSR",   "EPSR",
                                        "IEPSR", "MSP",  "PSP",   "MSPLIM", "PSPLIM", "",     "",
                                        "",      "",     "PRIMASK", "BASEPRI", "BASEPRI_MAX", "FAULTMASK",
                                        "CONTROL"};
  if (number < 21 && names[number][0]) {
    snprintf(buffer, size, "%s", names[number]);
  } else {
    snprintf(buffer, size, "<%u>", number);
  }
  return buffer;
}

static void decode32_branch(ThumbItState *it, uint32_t address, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned form = (unsigned)((hw2 >> 12) & 0x5);
  unsigned sign = (hw1 >> 10) & 1;
  unsigned j1 = (hw2 >> 13) & 1;
  unsigned j2 = (hw2 >> 11) & 1;
  uint32_t imm11 = hw2 & 0x7FF;

  if (form == 0) { /* conditional branch, or one of the system instructions */
    unsigned condition = (hw1 >> 6) & 0xF;
    if (condition < 0xE) {
      uint32_t raw = (uint32_t)(sign << 20) | (uint32_t)(j2 << 19) | (uint32_t)(j1 << 18) |
                     ((uint32_t)(hw1 & 0x3F) << 12) | (imm11 << 1);
      uint32_t target = (uint32_t)((int32_t)address + 4 + sign_extend(raw, 21));
      put(out, "b%s.w\t0x%x", condition_names[condition], target);
      branch_to(out, target);
      return;
    }
    /* Barriers, status register moves and hints all live in this corner. */
    if ((hw1 & 0xFFF0) == 0xF3B0 && (hw2 & 0xFF00) == 0x8F00) {
      static const char *const barriers[16] = {NULL, NULL,  "clrex", NULL, "dsb", "dmb", "isb", NULL,
                                               NULL, NULL,  NULL,    NULL, NULL,  NULL,  NULL, NULL};
      const char *name = barriers[(hw2 >> 4) & 0xF];
      unsigned option = hw2 & 0xF;
      if (!name) {
        out->undefined = 1;
        return;
      }
      if ((hw2 & 0xF0) == 0x20) {
        put(out, "clrex");
        return;
      }
      if (option == 0xF) {
        put(out, "%s\tsy", name);
      } else {
        put(out, "%s\t#%u", name, option);
      }
      return;
    }
    if ((hw1 & 0xFFF0) == 0xF3A0 && (hw2 & 0xF700) == 0x8000) {
      static const char *const hints[8] = {"nop.w", "yield.w", "wfe.w", "wfi.w", "sev.w", NULL, NULL, NULL};
      const char *name = hints[hw2 & 0x7];
      if (!name || (hw2 & 0xFF) > 4) {
        out->undefined = 1;
        return;
      }
      put(out, "%s", name);
      return;
    }
    if ((hw1 & 0xFFE0) == 0xF3E0 && (hw2 & 0xF000) == 0x8000) {
      char name[16];
      put(out, "mrs%s\t%s, %s", plain_suffix(it), R((hw2 >> 8) & 0xF),
          special_register_name(name, sizeof(name), hw2 & 0xFF));
      return;
    }
    if ((hw1 & 0xFFF0) == 0xF380 && (hw2 & 0xF300) == 0x8000) {
      char name[16];
      put(out, "msr%s\t%s, %s", plain_suffix(it), special_register_name(name, sizeof(name), hw2 & 0xFF),
          R(hw1 & 0xF));
      return;
    }
    out->undefined = 1;
    return;
  }
  if (form == 4) { /* blx to an ARM target, which no M-profile part has */
    out->undefined = 1;
    return;
  }
  {
    unsigned i1 = (~(j1 ^ sign)) & 1;
    unsigned i2 = (~(j2 ^ sign)) & 1;
    uint32_t raw = (uint32_t)(sign << 24) | (uint32_t)(i1 << 23) | (uint32_t)(i2 << 22) |
                   ((uint32_t)(hw1 & 0x3FF) << 12) | (imm11 << 1);
    uint32_t target = (uint32_t)((int32_t)address + 4 + sign_extend(raw, 25));
    if (form == 1) {
      put(out, "b%s.w\t0x%x", plain_suffix(it), target);
    } else {
      put(out, "bl%s\t0x%x", plain_suffix(it), target);
    }
    branch_to(out, target);
  }
}

static void decode32_load_store_single(ThumbItState *it, uint32_t address, uint16_t hw1, uint16_t hw2,
                                       ThumbInsn *out) {
  unsigned sign = (hw1 >> 8) & 1;
  unsigned wide_immediate = (hw1 >> 7) & 1;
  unsigned size = (hw1 >> 5) & 0x3;
  unsigned load = (hw1 >> 4) & 1;
  unsigned rn = hw1 & 0xF;
  unsigned rt = (hw2 >> 12) & 0xF;
  const char *name = NULL;
  const char *condition = plain_suffix(it);

  if (size == 3 || (sign && !load) || (sign && size == 2)) {
    out->undefined = 1; /* there is no signed word load, and no size 3 */
    return;
  }
  if (load) {
    if (sign) {
      name = (size == 0) ? "ldrsb" : "ldrsh";
    } else {
      name = (size == 0) ? "ldrb" : (size == 1) ? "ldrh" : "ldr";
    }
  } else {
    name = (size == 0) ? "strb" : (size == 1) ? "strh" : "str";
  }
  /* A load into pc is a preload hint rather than a load -- but only in the
   * forms that have one: the wide immediate, the register form and the single
   * negative-offset imm8.  A writeback form with Rt=15 is just an unpredictable
   * load, and objdump prints it as one. */
  if (load && rt == 15 && size == 0 &&
      (wide_immediate || !(hw2 & 0x0800) || (hw2 & 0x0F00) == 0x0C00)) {
    put(out, "%s%s\t", sign ? "pli" : "pld", condition);
  } else {
    put(out, "%s%s.w\t%s, ", name, condition, R(rt));
  }

  if (rn == 15) { /* pc relative: the literal pool */
    unsigned immediate = hw2 & 0xFFF;
    uint32_t target = ((address + 4) & ~3u) + (wide_immediate ? immediate : (uint32_t)-(int32_t)immediate);
    put(out, "[pc, #%s%u]", wide_immediate ? "" : "-", immediate);
    note(out, "(0x%x)", target);
    literal_at(out, target, (size == 2) ? 4 : (size == 1 ? 2 : 1));
    return;
  }
  if (wide_immediate) {
    unsigned immediate = hw2 & 0xFFF;
    if (immediate == 0) {
      put(out, "[%s]", R(rn));
    } else {
      put(out, "[%s, #%u]", R(rn), immediate);
      note_immediate(out, (int32_t)immediate);
    }
    return;
  }
  if (hw2 & 0x0800) {
    append_indexed(out, rn, (hw2 >> 10) & 1, (hw2 >> 9) & 1, (hw2 >> 8) & 1, hw2 & 0xFF);
    return;
  }
  if ((hw2 & 0x0FC0) == 0) {
    unsigned shift = (hw2 >> 4) & 0x3;
    if (shift) {
      put(out, "[%s, %s, lsl #%u]", R(rn), R(hw2 & 0xF), shift);
    } else {
      put(out, "[%s, %s]", R(rn), R(hw2 & 0xF));
    }
    return;
  }
  out->undefined = 1;
}

static void decode32_data_register(ThumbItState *it, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned op1 = (hw1 >> 4) & 0xF;
  unsigned rn = hw1 & 0xF;
  unsigned rd = (hw2 >> 8) & 0xF;
  unsigned op2 = (hw2 >> 4) & 0xF;
  unsigned rm = hw2 & 0xF;
  const char *condition = plain_suffix(it);

  if ((hw2 & 0xF000) != 0xF000) {
    out->undefined = 1;
    return;
  }
  if (op2 == 0 && op1 < 8) { /* shift by a register */
    put(out, "%s%s%s.w\t%s, %s, %s", shift_names[(op1 >> 1) & 0x3], (op1 & 1) ? "s" : "", condition, R(rd), R(rn),
        R(rm));
    return;
  }
  if ((op2 & 0xC) == 0x8 && op1 < 8) { /* the extends, with an optional rotate */
    static const char *const names[8] = {"sxth", "uxth", "sxtb16", "uxtb16", "sxtb", "uxtb", NULL, NULL};
    const char *name = names[op1];
    unsigned rotate = (unsigned)(op2 & 0x3) * 8;
    if (!name) {
      out->undefined = 1;
      return;
    }
    if (rn == 15) {
      put(out, "%s%s.w\t%s, %s", name, condition, R(rd), R(rm));
    } else { /* the accumulating form, sxtab and friends */
      put(out, "%sa%s%s\t%s, %s, %s", (name[0] == 's') ? "sxt" : "uxt", name + 3, condition, R(rd), R(rn), R(rm));
    }
    if (rotate) {
      put(out, ", ror #%u", rotate);
    }
    return;
  }
  if (op1 == 9 && (op2 & 0xC) == 0x8) { /* the byte reversals */
    static const char *const names[4] = {"rev.w", "rev16.w", "rbit", "revsh.w"};
    put(out, "%s%s\t%s, %s", names[op2 & 0x3], condition, R(rd), R(rm));
    return;
  }
  if (op1 == 11 && (op2 & 0xC) == 0x8) {
    put(out, "clz%s\t%s, %s", condition, R(rd), R(rm));
    return;
  }
  out->undefined = 1;
}

static void decode32_multiply(ThumbItState *it, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned op1 = (hw1 >> 4) & 0x7;
  unsigned rn = hw1 & 0xF;
  unsigned ra = (hw2 >> 12) & 0xF;
  unsigned rd = (hw2 >> 8) & 0xF;
  unsigned op2 = (hw2 >> 4) & 0x3;
  unsigned rm = hw2 & 0xF;
  const char *condition = plain_suffix(it);

  if (op1 == 0 && op2 == 0) {
    if (ra == 15) {
      put(out, "mul%s.w\t%s, %s, %s", condition, R(rd), R(rn), R(rm));
    } else {
      put(out, "mla%s\t%s, %s, %s, %s", condition, R(rd), R(rn), R(rm), R(ra));
    }
    return;
  }
  if (op1 == 0 && op2 == 1) {
    put(out, "mls%s\t%s, %s, %s, %s", condition, R(rd), R(rn), R(rm), R(ra));
    return;
  }
  out->undefined = 1;
}

static void decode32_long_multiply(ThumbItState *it, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned op1 = (hw1 >> 4) & 0x7;
  unsigned rn = hw1 & 0xF;
  unsigned rdlo = (hw2 >> 12) & 0xF;
  unsigned rdhi = (hw2 >> 8) & 0xF;
  unsigned op2 = (hw2 >> 4) & 0xF;
  unsigned rm = hw2 & 0xF;
  const char *condition = plain_suffix(it);
  const char *name = NULL;

  if (op2 == 0xF && (op1 == 1 || op1 == 3)) {
    put(out, "%s%s\t%s, %s, %s", (op1 == 1) ? "sdiv" : "udiv", condition, R(rdhi), R(rn), R(rm));
    return;
  }
  if (op2 == 0) {
    switch (op1) {
    case 0:
      name = "smull";
      break;
    case 2:
      name = "umull";
      break;
    case 4:
      name = "smlal";
      break;
    case 6:
      name = "umlal";
      break;
    default:
      break;
    }
  } else if (op1 == 6 && op2 == 6) {
    name = "umaal";
  }
  if (!name) {
    out->undefined = 1;
    return;
  }
  put(out, "%s%s\t%s, %s, %s, %s", name, condition, R(rdlo), R(rdhi), R(rn), R(rm));
}

/* ---------------------------------------------------------------------- */
/* the floating point coprocessors                                         */
/* ---------------------------------------------------------------------- */

/* Coprocessors 10 and 11 are the FPU: 10 addresses the single-precision
 * registers, 11 the double-precision ones.  Every instruction below would
 * otherwise decode as a generic cdp/mcr/ldc, which is what the listing showed
 * before this existed -- correct, and unreadable. */

static const char *vfp_register(char *buffer, size_t size, int is_double, unsigned number) {
  snprintf(buffer, size, "%c%u", is_double ? 'd' : 's', number);
  return buffer;
}

/* The 8-bit immediate of VMOV (immediate), which encodes a sign, a three-bit
 * exponent and a four-bit mantissa. */
static double vfp_expand_immediate(unsigned imm8) {
  int exponent = (int)((imm8 >> 4) & 0x7);
  double value = 1.0 + (double)(imm8 & 0xF) / 16.0;
  int shift = 0;
  /* The exponent is biased so that 0b100 is 2^0, and it is stored inverted in
   * its top bit. */
  exponent = ((imm8 & 0x40) ? 0 : -1) * 4 + (exponent & 0x3);
  for (shift = 0; shift < exponent; ++shift) {
    value *= 2.0;
  }
  for (shift = 0; shift > exponent; --shift) {
    value /= 2.0;
  }
  return (imm8 & 0x80) ? -value : value;
}

static void vfp_register_list(char *buffer, size_t size, int is_double, unsigned first, unsigned count) {
  if (count <= 1) {
    snprintf(buffer, size, "{%c%u}", is_double ? 'd' : 's', first);
  } else {
    snprintf(buffer, size, "{%c%u-%c%u}", is_double ? 'd' : 's', first, is_double ? 'd' : 's', first + count - 1);
  }
}

static int decode32_vfp(ThumbItState *it, uint32_t address, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  unsigned coprocessor = (hw2 >> 8) & 0xF;
  int is_double = (coprocessor == 11);
  const char *type = is_double ? "f64" : "f32";
  const char *condition = plain_suffix(it);
  char first[8];
  char second[8];
  char third[8];

  if ((hw1 & 0x0FE0) == 0x0C40) { /* two core registers to or from the FPU */
    unsigned load = (hw1 >> 4) & 1;
    unsigned rt2 = hw1 & 0xF;
    unsigned rt = (hw2 >> 12) & 0xF;
    unsigned m = (hw2 >> 5) & 1;
    unsigned vm = hw2 & 0xF;
    if (is_double) {
      unsigned dm = (m << 4) | vm;
      if (load) {
        put(out, "vmov%s\t%s, %s, %s", condition, R(rt), R(rt2), vfp_register(first, sizeof(first), 1, dm));
      } else {
        put(out, "vmov%s\t%s, %s, %s", condition, vfp_register(first, sizeof(first), 1, dm), R(rt), R(rt2));
      }
    } else {
      unsigned sm = (vm << 1) | m;
      if (load) {
        put(out, "vmov%s\t%s, %s, %s, %s", condition, R(rt), R(rt2), vfp_register(first, sizeof(first), 0, sm),
            vfp_register(second, sizeof(second), 0, sm + 1));
      } else {
        put(out, "vmov%s\t%s, %s, %s, %s", condition, vfp_register(first, sizeof(first), 0, sm),
            vfp_register(second, sizeof(second), 0, sm + 1), R(rt), R(rt2));
      }
    }
    return 1;
  }

  if ((hw1 & 0x0E00) == 0x0C00) { /* the load/store forms */
    unsigned index = (hw1 >> 8) & 1;
    unsigned add = (hw1 >> 7) & 1;
    unsigned d = (hw1 >> 6) & 1;
    unsigned writeback = (hw1 >> 5) & 1;
    unsigned load = (hw1 >> 4) & 1;
    unsigned rn = hw1 & 0xF;
    unsigned vd = (hw2 >> 12) & 0xF;
    unsigned immediate = (unsigned)(hw2 & 0xFF) * 4;
    unsigned number = is_double ? ((d << 4) | vd) : ((vd << 1) | d);

    if (index && !writeback) { /* vldr / vstr */
      put(out, "%s%s\t%s, ", load ? "vldr" : "vstr", condition, vfp_register(first, sizeof(first), is_double, number));
      if (rn == 15) {
        uint32_t target = ((address + 4) & ~3u) + (add ? immediate : (uint32_t)-(int32_t)immediate);
        put(out, "[pc, #%s%u]", add ? "" : "-", immediate);
        note(out, "(0x%x)", target);
        literal_at(out, target, is_double ? 8 : 4);
        return 1;
      }
      if (immediate == 0) {
        put(out, "[%s]", R(rn));
      } else {
        put(out, "[%s, #%s%u]", R(rn), add ? "" : "-", immediate);
        note_immediate(out, add ? (int32_t)immediate : -(int32_t)immediate);
      }
      return 1;
    }
    { /* the block forms, of which push and pop are the named special cases */
      unsigned count = (unsigned)(hw2 & 0xFF);
      char list[32];
      if (is_double) {
        count /= 2;
      }
      vfp_register_list(list, sizeof(list), is_double, number, count);
      if (rn == 13 && writeback && !index && add && load) {
        put(out, "vpop%s\t%s", condition, list);
      } else if (rn == 13 && writeback && index && !add && !load) {
        put(out, "vpush%s\t%s", condition, list);
      } else {
        put(out, "%s%s%s\t%s%s, %s", load ? "vldm" : "vstm", index ? "db" : "ia", condition, R(rn),
            writeback ? "!" : "", list);
      }
      return 1;
    }
  }

  if ((hw1 & 0x0F00) != 0x0E00) {
    return 0;
  }

  if (hw2 & 0x10) { /* one core register to or from the FPU */
    unsigned opc1 = (hw1 >> 5) & 0x7;
    unsigned load = (hw1 >> 4) & 1;
    unsigned vn = hw1 & 0xF;
    unsigned rt = (hw2 >> 12) & 0xF;
    unsigned n = (hw2 >> 7) & 1;
    if (opc1 == 0) {
      unsigned sn = (vn << 1) | n;
      if (load) {
        put(out, "vmov%s\t%s, %s", condition, R(rt), vfp_register(first, sizeof(first), 0, sn));
      } else {
        put(out, "vmov%s\t%s, %s", condition, vfp_register(first, sizeof(first), 0, sn), R(rt));
      }
      return 1;
    }
    if (opc1 == 7) {
      static const char *const specials[16] = {"fpsid", "fpscr", NULL,    NULL, NULL,   "mvfr2", "mvfr1", "mvfr0",
                                               "fpexc", "fpinst", "fpinst2", NULL, NULL, NULL,    NULL,   NULL};
      const char *name = specials[vn];
      char fallback[8];
      if (!name) {
        snprintf(fallback, sizeof(fallback), "<%u>", vn);
        name = fallback;
      }
      if (load) {
        /* A read into r15 lands in the flags, not in a register. */
        put(out, "vmrs%s\t%s, %s", condition, (rt == 15) ? "APSR_nzcv" : R(rt), name);
      } else {
        put(out, "vmsr%s\t%s, %s", condition, name, R(rt));
      }
      return 1;
    }
    return 0;
  }

  { /* data processing */
    unsigned o1 = (hw1 >> 7) & 1;
    unsigned d = (hw1 >> 6) & 1;
    unsigned o2 = (hw1 >> 4) & 0x3;
    unsigned vn = hw1 & 0xF;
    unsigned vd = (hw2 >> 12) & 0xF;
    unsigned n = (hw2 >> 7) & 1;
    unsigned opc3 = (hw2 >> 6) & 0x3;
    unsigned m = (hw2 >> 5) & 1;
    unsigned vm = hw2 & 0xF;
    unsigned dd = is_double ? ((d << 4) | vd) : ((vd << 1) | d);
    unsigned dn = is_double ? ((n << 4) | vn) : ((vn << 1) | n);
    unsigned dm = is_double ? ((m << 4) | vm) : ((vm << 1) | m);
    const char *name = NULL;

    if (!(o1 && o2 == 3)) { /* the three-operand arithmetic */
      static const char *const names[2][4][2] = {
          {{"vmla", "vmls"}, {"vnmls", "vnmla"}, {"vmul", "vnmul"}, {"vadd", "vsub"}},
          {{"vdiv", NULL}, {"vfnms", "vfnma"}, {"vfma", "vfms"}, {NULL, NULL}},
      };
      name = names[o1][o2][opc3 & 1];
      if (!name) {
        return 0;
      }
      put(out, "%s.%s%s\t%s, %s, %s", name, type, condition, vfp_register(first, sizeof(first), is_double, dd),
          vfp_register(second, sizeof(second), is_double, dn), vfp_register(third, sizeof(third), is_double, dm));
      return 1;
    }

    if ((opc3 & 1) == 0) { /* vmov immediate */
      unsigned imm8 = (unsigned)((vn << 4) | vm);
      put(out, "vmov.%s%s\t%s, #%g", type, condition, vfp_register(first, sizeof(first), is_double, dd),
          vfp_expand_immediate(imm8));
      return 1;
    }
    switch (vn) {
    case 0:
      name = (opc3 == 1) ? "vmov" : "vabs";
      break;
    case 1:
      name = (opc3 == 1) ? "vneg" : "vsqrt";
      break;
    case 4:
    case 5:
      put(out, "vcmp%s.%s%s\t%s, ", (opc3 & 2) ? "e" : "", type, condition,
          vfp_register(first, sizeof(first), is_double, dd));
      if (vn == 5) {
        put(out, "#0.0");
      } else {
        put(out, "%s", vfp_register(second, sizeof(second), is_double, dm));
      }
      return 1;
    case 7: /* the precision conversions, which change register bank */
      put(out, "vcvt.%s.%s%s\t%s, %s", is_double ? "f32" : "f64", type, condition,
          vfp_register(first, sizeof(first), !is_double, is_double ? ((vd << 1) | d) : ((d << 4) | vd)),
          vfp_register(second, sizeof(second), is_double, dm));
      return 1;
    case 8: /* integer to floating point */
      put(out, "vcvt.%s.%s%s\t%s, %s", type, (opc3 & 2) ? "s32" : "u32", condition,
          vfp_register(first, sizeof(first), is_double, dd), vfp_register(second, sizeof(second), 0, (vm << 1) | m));
      return 1;
    case 12:
    case 13: /* floating point to integer, with and without rounding */
      put(out, "vcvt%s.%s.%s%s\t%s, %s", (opc3 & 2) ? "" : "r", (vn == 13) ? "s32" : "u32", type, condition,
          vfp_register(first, sizeof(first), 0, (vd << 1) | d), vfp_register(second, sizeof(second), is_double, dm));
      return 1;
    default:
      return 0;
    }
    put(out, "%s.%s%s\t%s, %s", name, type, condition, vfp_register(first, sizeof(first), is_double, dd),
        vfp_register(second, sizeof(second), is_double, dm));
    return 1;
  }
}

/* The generic coprocessor space.  On this part it is not generic at all: it is
 * where the RP2350's double-precision coprocessor lives (cp4), which is why an
 * FP-heavy module disassembles into mcrr/mrrc/cdp rather than into anything
 * that looks like arithmetic. */
static void decode32_coprocessor(ThumbItState *it, uint32_t address, uint16_t hw1, uint16_t hw2,
                                 ThumbInsn *out) {
  unsigned second = (hw1 & 0x1000) ? 1 : 0; /* the ldc2/stc2/cdp2/mcr2 forms */
  unsigned coprocessor = (hw2 >> 8) & 0xF;
  const char *condition = second ? "" : plain_suffix(it);
  char suffix[4];

  snprintf(suffix, sizeof(suffix), "%s", second ? "2" : "");

  if ((coprocessor == 10 || coprocessor == 11) && decode32_vfp(it, address, hw1, hw2, out)) {
    return;
  }

  if ((hw1 & 0x0FE0) == 0x0C40) { /* two core registers to and from a coprocessor */
    put(out, "%s%s%s\t%u, %u, %s, %s, cr%u", (hw1 & 0x0010) ? "mrrc" : "mcrr", suffix, condition, coprocessor,
        (unsigned)((hw2 >> 4) & 0xF), R((hw2 >> 12) & 0xF), R(hw1 & 0xF), (unsigned)(hw2 & 0xF));
    return;
  }
  if ((hw1 & 0x0E00) == 0x0C00) { /* load/store coprocessor */
    unsigned index = (hw1 >> 8) & 1;
    unsigned add = (hw1 >> 7) & 1;
    unsigned longer = (hw1 >> 6) & 1;
    unsigned writeback = (hw1 >> 5) & 1;
    unsigned load = (hw1 >> 4) & 1;
    unsigned immediate = (unsigned)(hw2 & 0xFF) * 4;
    put(out, "%s%s%s%s\t%u, cr%u, ", load ? "ldc" : "stc", suffix, longer ? "l" : "", condition, coprocessor,
        (unsigned)((hw2 >> 12) & 0xF));
    if (index) {
      append_coprocessor_address(out, hw1 & 0xF, add, writeback, immediate);
      return;
    }
    if (!writeback) {
      /* Unindexed: the imm8 is an option field the coprocessor reads, not a
       * displacement, so it is printed even when it is zero -- and it still
       * carries the sign of the U bit. */
      if (hw2 & 0xFF) {
        put(out, "[%s], {%u}", R(hw1 & 0xF), (unsigned)(hw2 & 0xFF));
      } else {
        put(out, "[%s], {%s0}", R(hw1 & 0xF), add ? "" : "-");
      }
    } else if (immediate) {
      put(out, "[%s], #%s%u", R(hw1 & 0xF), add ? "" : "-", immediate);
      note_immediate(out, add ? (int32_t)immediate : -(int32_t)immediate);
    } else if (!add) {
      put(out, "[%s], #-0", R(hw1 & 0xF));
    } else {
      put(out, "[%s]", R(hw1 & 0xF));
    }
    return;
  }
  if ((hw1 & 0x0F00) == 0x0E00) {
    if ((hw2 & 0x10) == 0) { /* coprocessor data operation */
      put(out, "cdp%s%s\t%u, %u, cr%u, cr%u, cr%u, {%u}", suffix, condition, coprocessor,
          (unsigned)((hw1 >> 4) & 0xF), (unsigned)((hw2 >> 12) & 0xF), (unsigned)(hw1 & 0xF), (unsigned)(hw2 & 0xF),
          (unsigned)((hw2 >> 5) & 0x7));
      return;
    }
    { /* one core register to or from a coprocessor */
      unsigned load = (hw1 >> 4) & 1;
      unsigned rt = (hw2 >> 12) & 0xF;
      char destination[16];
      /* mrc into pc does not write a register, it writes the flags. */
      if (load && rt == 15 && !second) {
        snprintf(destination, sizeof(destination), "APSR_nzcv");
      } else {
        snprintf(destination, sizeof(destination), "%s", R(rt));
      }
      put(out, "%s%s%s\t%u, %u, %s, cr%u, cr%u, {%u}", load ? "mrc" : "mcr", suffix, condition, coprocessor,
          (unsigned)((hw1 >> 5) & 0x7), destination, (unsigned)(hw1 & 0xF), (unsigned)(hw2 & 0xF),
          (unsigned)((hw2 >> 5) & 0x7));
      return;
    }
  }
  out->undefined = 1;
}

static void decode32(ThumbItState *it, uint32_t address, uint16_t hw1, uint16_t hw2, ThumbInsn *out) {
  switch ((hw1 >> 11) & 0x3) {
  case 1:
    if (hw1 >= 0xEC00) {
      decode32_coprocessor(it, address, hw1, hw2, out);
    } else if ((hw1 & 0xFE40) == 0xE800) {
      decode32_load_store_multiple(it, hw1, hw2, out);
    } else if ((hw1 & 0xFE40) == 0xE840) {
      decode32_load_store_dual(it, address, hw1, hw2, out);
    } else {
      decode32_data_shifted(it, hw1, hw2, out);
    }
    break;
  case 2:
    if (hw2 & 0x8000) {
      decode32_branch(it, address, hw1, hw2, out);
    } else if (hw1 & 0x0200) {
      decode32_plain_immediate(it, address, hw1, hw2, out);
    } else {
      decode32_data_immediate(it, hw1, hw2, out);
    }
    break;
  default:
    if (hw1 >= 0xFC00) {
      decode32_coprocessor(it, address, hw1, hw2, out);
    } else if ((hw1 & 0xFE00) == 0xF800) {
      decode32_load_store_single(it, address, hw1, hw2, out);
    } else if ((hw1 & 0xFF00) == 0xFA00 || (hw1 & 0xFF00) == 0xFB00) {
      if ((hw1 & 0xFF00) == 0xFA00) {
        decode32_data_register(it, hw1, hw2, out);
      } else if (hw1 & 0x0080) {
        decode32_long_multiply(it, hw1, hw2, out);
      } else {
        decode32_multiply(it, hw1, hw2, out);
      }
    } else {
      out->undefined = 1;
    }
    break;
  }
}

void thumb_decode(ThumbItState *it, uint32_t address, const uint8_t *bytes, uint32_t available, ThumbInsn *out) {
  uint16_t hw1 = 0;
  int opened_block = 0;

  memset(out, 0, sizeof(*out));
  if (available < 2) {
    out->size = 0;
    return;
  }
  hw1 = (uint16_t)((uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8));
  if ((hw1 & 0xE000) == 0xE000 && (hw1 & 0x1800) != 0) { /* a 32-bit encoding */
    uint16_t hw2 = 0;
    if (available < 4) {
      out->size = 0;
      return;
    }
    hw2 = (uint16_t)((uint32_t)bytes[2] | ((uint32_t)bytes[3] << 8));
    out->size = 4;
    decode32(it, address, hw1, hw2, out);
    if (out->undefined) {
      out->text[0] = 0;
      out->comment[0] = 0;
      out->target_kind = THUMB_TARGET_NONE;
      put(out, ".word\t0x%04x%04x", hw2, hw1);
    }
  } else {
    out->size = 2;
    opened_block = decode16(it, address, hw1, out);
    if (out->undefined) {
      out->text[0] = 0;
      out->comment[0] = 0;
      out->target_kind = THUMB_TARGET_NONE;
      put(out, ".short\t0x%04x", hw1);
    }
  }
  if (!opened_block) {
    it_advance(it);
  }
}
