/*
 * disasm.c
 *
 * The one-line disassembly the c-sdk output prints beside each instruction;
 * a port of pio_disassembler.cpp, column widths and all.
 *
 * Copyright (c) 2020 Raspberry Pi (Trading) Ltd. (the original pioasm)
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com> (the C port)
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "pioasm.h"

#include <stdio.h>
#include <string.h>

typedef struct {
    char *buf;
    size_t size;
    size_t len;
} Out;

static void put(Out *o, const char *s) {
    size_t n = strlen(s);
    if (o->len + n >= o->size) n = o->size - o->len - 1;
    memcpy(o->buf + o->len, s, n);
    o->len += n;
    o->buf[o->len] = 0;
}

/* std::left << std::setw(width) << s */
static void put_padded(Out *o, const char *s, size_t width) {
    put(o, s);
    for (size_t n = strlen(s); n < width; n++)
        put(o, " ");
}

void disassemble(char *buf, size_t size, unsigned inst, int sideset_bits_including_opt, int sideset_opt) {
    static const char *const conditions[8] = {"", "!x, ", "x--, ", "!y, ", "y--, ", "x != y, ", "pin, ", "!osre, "};
    static const char *const in_sources[8] = {"pins", "x", "y", "null", "", "status", "isr", "osr"};
    static const char *const out_dests[8] = {"pins", "x", "y", "null", "pindirs", "pc", "isr", "exec"};
    static const char *const mov_dests[8] = {"pins", "x", "y", "pindirs", "exec", "pc", "isr", "osr"};
    static const char *const set_dests[8] = {"pins", "x", "y", "", "pindirs", "", "", ""};
    unsigned major = (inst >> 13u) & 0x7u;
    unsigned arg1 = (inst >> 5u) & 0x7u;
    unsigned arg2 = (inst & 0x1fu) | ((inst & 0x10000u) >> 11);
    char guts[64];
    const char *op = NULL;
    int invalid = 0;
    Out o = {buf, size, 0};
    unsigned delay;

    buf[0] = 0;
    guts[0] = 0;
    switch (major) {
    case 0: /* jmp */
        op = "jmp";
        snprintf(guts, sizeof(guts), "%s%u", conditions[arg1], arg2);
        break;
    case 1: { /* wait */
        char src[32];
        switch (arg1 & 3u) {
        case 0:
            snprintf(src, sizeof(src), "gpio, %u", arg2);
            break;
        case 1:
            snprintf(src, sizeof(src), "pin, %u", arg2);
            break;
        case 2:
            snprintf(src, sizeof(src), "irq%s, %u%s", (arg2 & 0x08) ? ((arg2 & 0x10) ? " next" : " prev") : "",
                     arg2 & 7u, (arg2 & 0x18) == 0x10 ? " rel" : "");
            break;
        default:
            if (arg2 & 0x1cu)
                invalid = 1;
            else if (arg2)
                snprintf(src, sizeof(src), "jmppin + %u", arg2 & 3u);
            else
                snprintf(src, sizeof(src), "jmppin");
            break;
        }
        if (!invalid) {
            op = "wait";
            snprintf(guts, sizeof(guts), "%s%s", (arg1 & 4u) ? "1 " : "0 ", src);
        }
        break;
    }
    case 2: /* in */
        if (!in_sources[arg1][0]) {
            invalid = 1;
        } else {
            op = "in";
            snprintf(guts, sizeof(guts), "%s, %u", in_sources[arg1], arg2 ? arg2 : 32);
        }
        break;
    case 3: /* out */
        op = "out";
        snprintf(guts, sizeof(guts), "%s, %u", out_dests[arg1], arg2 ? arg2 : 32);
        break;
    case 4: /* push, pull, and the fifo movs */
        if (arg2) {
            if ((arg1 & 3u) || !(arg2 & 0x10u)) {
                invalid = 1;
            } else {
                char index[16];
                if (arg2 & 8u)
                    snprintf(index, sizeof(index), "%u", arg2 & 3u);
                else
                    snprintf(index, sizeof(index), "y");
                op = "mov";
                if (arg1 & 4u)
                    snprintf(guts, sizeof(guts), "osr, rxfifo[%s]", index);
                else
                    snprintf(guts, sizeof(guts), "rxfifo[%s], isr", index);
            }
        } else {
            const char *cond = "";
            if (arg1 & 4u) {
                op = "pull";
                if (arg1 & 2u) cond = "ifempty ";
            } else {
                op = "push";
                if (arg1 & 2u) cond = "iffull ";
            }
            snprintf(guts, sizeof(guts), "%s%s", cond, (arg1 & 1u) ? "block" : "noblock");
        }
        break;
    case 5: { /* mov */
        const char *dest = mov_dests[arg1];
        const char *source = in_sources[arg2 & 7u];
        unsigned operation = arg2 >> 3u;
        if (!source[0] || !dest[0] || operation == 3) invalid = 1;
        if (!strcmp(dest, source) && !operation && (arg1 == 1 || arg2 == 2)) {
            op = "nop";
        } else {
            op = "mov";
            snprintf(guts, sizeof(guts), "%s, %s%s", dest, operation == 1 ? "~" : operation == 2 ? "::" : "", source);
        }
        break;
    }
    case 6: /* irq */
        if (arg1 & 0x4u) {
            invalid = 1;
        } else {
            const char *mod = (arg1 & 0x2u) ? "clear " : (arg1 & 0x1u) ? "wait " : "nowait ";
            const char *prefix = "";
            const char *suffix = "";
            switch (arg2 & 0x18u) {
            case 0x10: suffix = " rel"; break;
            case 0x08: prefix = "prev "; break;
            case 0x18: prefix = "next "; break;
            }
            op = "irq";
            snprintf(guts, sizeof(guts), "%s%s%u%s", prefix, mod, arg2 & 7u, suffix);
        }
        break;
    case 7: /* set */
        if (!set_dests[arg1][0]) {
            invalid = 1;
        } else {
            op = "set";
            snprintf(guts, sizeof(guts), "%s, %u", set_dests[arg1], arg2);
        }
        break;
    }
    if (invalid) {
        put(&o, "reserved");
        return;
    }
    put_padded(&o, op, 7);
    put_padded(&o, guts, 16);

    delay = (inst >> 8u) & 0x1fu;
    if (sideset_bits_including_opt && (!sideset_opt || (delay & 0x10u))) {
        char side[32];
        snprintf(side, sizeof(side), "side %u",
                 (delay & (sideset_opt ? 0xfu : 0x1fu)) >> (5u - (unsigned)sideset_bits_including_opt));
        put_padded(&o, side, 7);
    } else {
        put_padded(&o, "", 7);
    }
    delay &= ((1u << (5 - sideset_bits_including_opt)) - 1u);
    if (delay) {
        char d[16];
        snprintf(d, sizeof(d), "[%u]", delay);
        put_padded(&o, d, 4);
    } else {
        put_padded(&o, "", 4);
    }
    while (o.len && buf[o.len - 1] == ' ')
        buf[--o.len] = 0;
}
