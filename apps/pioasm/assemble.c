/*
 * assemble.c
 *
 * Program bookkeeping, expression resolution and instruction encoding; a port
 * of pio_assembler.cpp and the parts of pio_types.h that do work.
 *
 * Copyright (c) 2020 Raspberry Pi (Trading) Ltd. (the original pioasm)
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com> (the C port)
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "pioasm.h"

#include <stdlib.h>
#include <string.h>

Assembler *assembler_new(const char *source, int default_pio_version) {
    Assembler *as = xmalloc(sizeof(*as));
    Loc none = {1, 1, 1};
    as->source = source;
    as->programs = NULL;
    as->program_count = 0;
    as->default_pio_version = default_pio_version;
    as->global = NULL;
    as->global = program_new(as, none, "");
    as->global->pio_version = default_pio_version;
    return as;
}

Program *program_new(Assembler *as, Loc loc, const char *name) {
    Program *p = xmalloc(sizeof(*p));
    memset(p, 0, sizeof(*p));
    p->name = xstrdup(name);
    p->loc = loc;
    p->sideset_opt = 1;
    p->clock_div_int = 1;
    p->fifo = FIFO_TXRX;
    p->in.final_pin_count = -1;
    p->out.final_pin_count = -1;
    p->mov_status_type = MOV_STATUS_UNSPECIFIED;
    p->final_set_count = -1;
    p->final_origin = -1;
    /* a new program starts at the version `.pio_version` set outside any program */
    p->pio_version = as->global ? as->global->pio_version : as->default_pio_version;
    return p;
}

Program *current_program(Assembler *as, Loc loc, const char *requiring, int before_any_instructions, int disallow_global) {
    Program *p;
    if (as->program_count == 0) {
        if (disallow_global) fail(loc, "%s is invalid outside of a program", requiring);
        return as->global;
    }
    p = as->programs[as->program_count - 1];
    if (before_any_instructions && p->instruction_count)
        fail(loc, "%s must precede any program instructions", requiring);
    return p;
}

int current_pio_version(Assembler *as) {
    if (as->program_count) return as->programs[as->program_count - 1]->pio_version;
    return as->global->pio_version;
}

void check_version(Assembler *as, int min_version, Loc loc, const char *feature) {
    if (current_pio_version(as) < min_version)
        fail(loc, "PIO version %d is required for '%s'", min_version, feature);
}

static Symbol *find_symbol(Program *p, const char *name) {
    for (int i = 0; i < p->symbol_count; i++)
        if (!strcmp(p->symbols[i]->name, name)) return p->symbols[i];
    return NULL;
}

/* p may be NULL for global symbols only */
Symbol *get_symbol(Assembler *as, const char *name, Program *p) {
    Symbol *s = find_symbol(as->global, name);
    if (s) return s;
    return p ? find_symbol(p, name) : NULL;
}

void add_symbol(Assembler *as, Program *p, Symbol *s) {
    Symbol *existing = get_symbol(as, s->name, p);
    if (existing) {
        if (s->is_label != existing->is_label)
            fail(s->loc, "'%s' was already defined as a %s at line %d", s->name, existing->is_label ? "label" : "value",
                 existing->loc.line);
        else if (s->is_label)
            fail(s->loc, "label '%s' was already defined at line %d", s->name, existing->loc.line);
        else
            fail(s->loc, "'%s' was already defined at line %d", s->name, existing->loc.line);
    }
    p->symbols = realloc(p->symbols, sizeof(*p->symbols) * (p->symbol_count + 1));
    if (!p->symbols) fail(s->loc, "out of memory");
    p->symbols[p->symbol_count++] = s;
}

static Expr *int_expr(Loc loc, int v) {
    Expr *e = xmalloc(sizeof(*e));
    memset(e, 0, sizeof(*e));
    e->kind = E_INT;
    e->loc = loc;
    e->value = v;
    return e;
}

void add_label(Assembler *as, Program *p, Symbol *s) {
    s->value = int_expr(s->loc, p->instruction_count);
    add_symbol(as, p, s);
}

static int mov_uses_fifo(const MovOperand *m) {
    return m->loc == MOV_FIFO_INDEX || m->loc == MOV_FIFO_Y;
}

void add_instruction(Assembler *as, Program *p, Instruction *inst) {
    (void)as;
    if (p->instruction_count >= MAX_INSTRUCTIONS)
        fail(inst->loc, "program instruction limit of %d instruction(s) exceeded", MAX_INSTRUCTIONS);
    if (!p->sideset_opt && !inst->sideset)
        fail(inst->loc,
             "instruction requires 'side' to specify side set value for the instruction because non optional sideset "
             "was specified for the program at line %d",
             p->sideset_loc.line);
    if (inst->kind == I_PUSH) {
        if (p->fifo != FIFO_RX && p->fifo != FIFO_TXRX)
            fail(inst->loc, "FIFO must be configured for 'txrx' or 'rx' to use this instruction");
    } else if (inst->kind == I_MOV) {
        if (mov_uses_fifo(&inst->dest)) {
            if (inst->src.loc != MOV_ISR) fail(inst->loc, "mov rxfifo[] source must be isr");
            if (p->fifo != FIFO_TXPUT && p->fifo != FIFO_PUTGET)
                fail(inst->loc, "FIFO must be configured for 'txput' or 'putget' to use this instruction");
        } else if (mov_uses_fifo(&inst->src)) {
            if (inst->dest.loc != MOV_OSR) fail(inst->loc, "mov ,txfifo[] target must be osr");
            if (p->fifo != FIFO_TXGET && p->fifo != FIFO_PUTGET)
                fail(inst->loc, "FIFO must be configured for 'txget' or 'putget' to use this instruction");
        }
    }
    p->instructions[p->instruction_count++] = inst;
}

void set_clock_div(Program *p, Loc loc, float div) {
    if (div < 1.0f || div >= 65536.0f) fail(loc, "clock divider must be between 1 and 65535");
    p->clock_div_int = (uint16_t)div;
    if (p->clock_div_int == 0) {
        p->clock_div_frac = 0;
    } else {
        /* sic: the SDK subtracts the (still zero) fraction, not the integer part */
        p->clock_div_frac = (uint8_t)(uint32_t)((div - (float)p->clock_div_frac) * (1u << 8u));
    }
}

/* ----- resolution ----- */

static int resolve_in(Assembler *as, Program *p, Expr *e, Loc scope);

static int resolve(Assembler *as, Program *p, Expr *e) {
    return resolve_in(as, p, e, e->loc);
}

static int resolve_in(Assembler *as, Program *p, Expr *e, Loc scope) {
    switch (e->kind) {
    case E_INT:
        return e->value;
    case E_NAME: {
        Symbol *s = get_symbol(as, e->name, p);
        int rc;
        if (!s) fail(e->loc, "undefined symbol '%s'", e->name);
        if (s->resolve_started)
            fail(scope, "circular dependency in definition of '%s'; detected at line %d)", e->name, e->loc.line);
        s->resolve_started++;
        rc = resolve_in(as, p, s->value, scope);
        s->resolve_started--;
        return rc;
    }
    case E_UNARY: {
        int value = resolve_in(as, p, e->left, scope);
        if (e->op == OP_NEGATE) return (int)(0u - (unsigned)value);
        {
            unsigned v = (unsigned)value, result = 0;
            for (unsigned i = 0; i < 32; i++) {
                result = (result << 1u) | (v & 1u);
                v >>= 1u;
            }
            return (int)result;
        }
    }
    case E_BINARY: {
        int l = resolve_in(as, p, e->left, scope);
        int r = resolve_in(as, p, e->right, scope);
        switch (e->op) {
        case OP_ADD: return (int)((unsigned)l + (unsigned)r);
        case OP_SUB: return (int)((unsigned)l - (unsigned)r);
        case OP_MUL: return (int)((unsigned)l * (unsigned)r);
        case OP_DIV:
            if (r == 0) fail(e->loc, "division by zero");
            return l / r;
        case OP_AND: return l & r;
        case OP_OR: return l | r;
        case OP_XOR: return l ^ r;
        /* the counts wrap as x86 does, which is what the SDK's build runs on */
        case OP_SHL: return (int)((unsigned)l << ((unsigned)r & 31u));
        case OP_SHR: return l >> ((unsigned)r & 31u);
        }
    }
    }
    fail(e->loc, "internal error");
}

static void finalize(Assembler *as, Program *p) {
    if (p->mov_status_type != MOV_STATUS_UNSPECIFIED) {
        unsigned n = (unsigned)resolve(as, p, p->mov_status_n);
        if (p->mov_status_type == MOV_STATUS_IRQ_SET) {
            if (n > 7) fail(p->mov_status_n->loc, "irq number should be >= 0 and <= 7");
            p->mov_status_final_n = p->mov_status_param * 8 + (int)n;
        } else {
            if (n > 31) fail(p->mov_status_n->loc, "fido depth should be >= 0 and <= 31");
            p->mov_status_final_n = (int)n;
        }
    }
    if (p->in.pin_count) {
        p->in.final_pin_count = resolve(as, p, p->in.pin_count);
        if (!p->pio_version && p->in.final_pin_count != 32)
            fail(p->in.pin_count->loc, "in pin count must be 32 for PIO version 0");
        if (p->in.final_pin_count < 1 || p->in.final_pin_count > 32)
            fail(p->in.pin_count->loc, "in pin count should be >= 1 and <= 32");
        p->in.final_threshold = resolve(as, p, p->in.threshold);
        if (p->in.final_threshold < 1 || p->in.final_threshold > 32)
            fail(p->in.threshold->loc, "threshold should be >= 1 and <= 32");
    }
    if (p->out.pin_count) {
        p->out.final_pin_count = resolve(as, p, p->out.pin_count);
        if (p->out.final_pin_count < 0 || p->out.final_pin_count > 32)
            fail(p->out.pin_count->loc, "out pin count should be >= 0 and <= 32");
        p->out.final_threshold = resolve(as, p, p->out.threshold);
        if (p->out.final_threshold < 1 || p->out.final_threshold > 32)
            fail(p->out.threshold->loc, "threshold should be >= 1 and <= 32");
    }
    if (p->set_count) {
        p->final_set_count = resolve(as, p, p->set_count);
        if (p->final_set_count < 0 || p->final_set_count > 5)
            fail(p->set_count_loc, "set pin count should be >= 0 and <= 5");
    }
    if (p->sideset) {
        int bits = resolve(as, p, p->sideset);
        if (bits < 0) fail(p->sideset->loc, "number of side set bits must be positive");
        p->sideset_max = (int)((1u << bits) - 1);
        if (p->sideset_opt) bits++;
        p->sideset_bits_including_opt = bits;
        if (bits > 5) {
            if (p->sideset_opt) fail(p->sideset->loc, "maximum number of side set bits with optional is 4");
            fail(p->sideset->loc, "maximum number of side set bits is 5");
        }
        p->delay_max = (int)((1u << (5 - bits)) - 1);
    } else {
        p->sideset_max = 0;
        p->delay_max = 31;
    }
    if (p->fifo != FIFO_RX && p->fifo != FIFO_TX && p->fifo != FIFO_TXRX) {
        if (p->in.pin_count && p->in.autop)
            fail(p->in.loc, "autopush is incompatible with your selected FIFO configuration specified at line %d",
                 p->fifo_loc.line);
    }
}

/* ----- encoding ----- */

typedef struct {
    unsigned type, arg1, arg2;
} Raw;

static unsigned push_get_index(Assembler *as, Program *p, const MovOperand *m) {
    unsigned v;
    if (m->loc == MOV_FIFO_Y) return 0;
    v = (unsigned)resolve(as, p, m->fifo_index);
    if (v > 7) fail(m->fifo_index->loc, "FIFO index myst be between 0 and 7");
    return v | 8;
}

static Raw raw_encode(Assembler *as, Program *p, Instruction *in) {
    Raw r = {0, 0, 0};
    switch (in->kind) {
    case I_JMP: {
        int dest = resolve(as, p, in->target);
        if (dest < 0) fail(in->target->loc, "jmp target address must be positive");
        if (dest >= p->instruction_count)
            fail(in->target->loc, "jmp target address %d is beyond the end of the program", dest);
        r.type = INST_JMP;
        r.arg1 = (unsigned)in->cond;
        r.arg2 = (unsigned)dest;
        return r;
    }
    case I_WAIT: {
        unsigned pol = (unsigned)resolve(as, p, in->polarity);
        unsigned arg2;
        if (pol > 1) fail(in->polarity->loc, "'wait' polarity must be 0 or 1");
        arg2 = (unsigned)resolve(as, p, in->wait_param);
        switch (in->wait_source) {
        case WAIT_IRQ:
            if (arg2 > 7) fail(in->wait_param->loc, "irq number must be must be >= 0 and <= 7");
            break;
        case WAIT_GPIO: {
            unsigned bitmap;
            if (!p->pio_version) {
                if (arg2 > 31) fail(in->wait_param->loc, "absolute GPIO number must be must be >= 0 and <= 31");
            } else {
                if (arg2 > 47) fail(in->wait_param->loc, "absolute GPIO number must be must be >= 0 and <= 47");
            }
            bitmap = 1u << (arg2 >> 4);
            if (bitmap == 4 && (p->used_gpio_ranges & 1))
                fail(in->wait_param->loc, "absolute GPIO number must be must be >= 0 and <= 31 as a GPIO number <16 "
                                          "has already been used");
            if (bitmap == 1 && (p->used_gpio_ranges & 4))
                fail(in->wait_param->loc, "absolute GPIO number must be must be >= 16 and <= 47 as a GPIO number >32 "
                                          "has already been used");
            p->used_gpio_ranges |= (uint8_t)bitmap;
            break;
        }
        case WAIT_PIN:
            if (arg2 > 31) fail(in->wait_param->loc, "pin number must be must be >= 0 and <= 31");
            break;
        case WAIT_JMPPIN:
            if (arg2 > 3) fail(in->wait_param->loc, "jmppin offset must be must be >= 0 and <= 3");
            break;
        }
        r.type = INST_WAIT;
        r.arg1 = (pol << 2u) | (unsigned)in->wait_source;
        r.arg2 = arg2 | ((unsigned)in->irq_type << 3);
        return r;
    }
    case I_IN:
    case I_OUT: {
        int v = resolve(as, p, in->value);
        if (v < 1 || v > 32)
            fail(in->value->loc, "'%s' bit count must be >= 1 and <= 32", in->kind == I_IN ? "in" : "out");
        r.type = in->kind == I_IN ? INST_IN : INST_OUT;
        r.arg1 = (unsigned)in->ios;
        r.arg2 = (unsigned)v & 0x1fu;
        return r;
    }
    case I_SET: {
        int v = resolve(as, p, in->value);
        if (v < 0 || v > 31) fail(in->value->loc, "'set' bit count must be >= 0 and <= 31");
        r.type = INST_SET;
        r.arg1 = (unsigned)in->ios;
        r.arg2 = (unsigned)v;
        return r;
    }
    case I_PUSH:
        r.type = INST_PUSH_PULL;
        r.arg1 = (in->blocking ? 1u : 0u) | (in->if_full_or_empty ? 0x2u : 0u);
        return r;
    case I_PULL:
        r.type = INST_PUSH_PULL;
        r.arg1 = (in->blocking ? 1u : 0u) | (in->if_full_or_empty ? 0x2u : 0u) | 0x4u;
        return r;
    case I_MOV:
        if (!mov_uses_fifo(&in->dest) && !mov_uses_fifo(&in->src)) {
            r.type = INST_MOV;
            r.arg1 = (unsigned)in->dest.loc;
            r.arg2 = (unsigned)in->src.loc | ((unsigned)in->mov_op << 3u);
        } else if (mov_uses_fifo(&in->dest)) {
            r.type = INST_PUSH_PULL;
            r.arg1 = 0;
            r.arg2 = 0x10 | push_get_index(as, p, &in->dest);
        } else {
            r.type = INST_PUSH_PULL;
            r.arg1 = 0x4;
            r.arg2 = 0x10 | push_get_index(as, p, &in->src);
        }
        return r;
    case I_IRQ: {
        unsigned arg2 = (unsigned)resolve(as, p, in->value);
        if (arg2 > 7) fail(in->value->loc, "irq number must be must be >= 0 and <= 7");
        r.type = INST_IRQ;
        r.arg1 = (unsigned)in->irq_modifiers;
        r.arg2 = arg2 | ((unsigned)in->irq_type << 3);
        return r;
    }
    }
    fail(in->loc, "internal error");
}

static unsigned encode(Assembler *as, Program *p, Instruction *in) {
    Raw raw;
    int delay, sideset = 0;
    if (in->kind == I_WORD) {
        unsigned value = (unsigned)resolve(as, p, in->value);
        if (value > 0xffffu) fail(in->loc, ".word value must be a positive 16 bit value");
        return value;
    }
    raw = raw_encode(as, p, in);
    delay = resolve(as, p, in->delay);
    if (delay < 0) fail(in->delay->loc, "instruction delay must be positive");
    if (delay > p->delay_max) {
        if (p->delay_max == 31) fail(in->delay->loc, "instruction delay must be <= 31");
        fail(in->delay->loc, "the instruction delay limit is %d because of the side set specified at line %d",
             p->delay_max, p->sideset_loc.line);
    }
    if (in->sideset) {
        sideset = resolve(as, p, in->sideset);
        if (sideset < 0) fail(in->sideset->loc, "side set value must be >=0");
        if (sideset > p->sideset_max)
            fail(in->sideset->loc, "the maximum side set value is %d based on the configuration specified at line %d",
                 p->sideset_max, p->sideset_loc.line);
        sideset <<= (5u - (unsigned)p->sideset_bits_including_opt);
        if (p->sideset_opt) sideset |= 0x10;
    }
    /* the 6th bit of arg2 is kept above the 16 bits of the instruction */
    return (raw.type << 13u) | (((unsigned)delay | (unsigned)sideset) << 8u) | (raw.arg1 << 5u) | (raw.arg2 & 0x1fu) |
           ((raw.arg2 >> 5) << 16);
}

PublicSymbol *public_symbols(Assembler *as, Program *p, int *count) {
    PublicSymbol *rc = xmalloc(sizeof(*rc) * (size_t)(p->symbol_count + 1));
    int n = 0;
    for (int i = 0; i < p->symbol_count; i++) {
        Symbol *s = p->symbols[i];
        if (!s->is_public) continue;
        rc[n].name = s->name;
        rc[n].value = resolve(as, p, s->value);
        rc[n].is_label = s->is_label;
        n++;
    }
    *count = n;
    return rc;
}

void assemble(Assembler *as) {
    for (int i = 0; i < as->program_count; i++) {
        Program *p = as->programs[i];
        finalize(as, p);
        for (int j = 0; j < p->instruction_count; j++)
            p->encoded[j] = encode(as, p, p->instructions[j]);
        for (int j = 0; j < p->code_block_count; j++) {
            if (!is_known_output_format(p->code_blocks[j].lang))
                warn(p->code_blocks[j].loc, "warning, unknown code block output type '%s'", p->code_blocks[j].lang);
        }
        if (p->wrap)
            p->final_wrap = resolve(as, p, p->wrap);
        else
            p->final_wrap = p->instruction_count - 1 > 0 ? p->instruction_count - 1 : 0;
        if (p->wrap_target) {
            p->final_wrap_target = resolve(as, p, p->wrap_target);
            if (p->final_wrap_target >= p->instruction_count)
                fail(p->wrap_target->loc, ".wrap_target cannot be placed after the last program instruction");
        } else {
            p->final_wrap_target = 0;
        }
        if (p->origin) p->final_origin = resolve(as, p, p->origin);
    }
}
