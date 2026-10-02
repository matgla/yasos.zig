/*
 * pioasm.h
 *
 * A C port of the Raspberry Pi Pico SDK's PIO assembler (tools/pioasm), so it
 * can be built by tcc and run on YasOS. The SDK's version is C++ with a bison
 * lalr1.cc parser and a flex lexer; this one hand-writes both and keeps the
 * assembler and the c-sdk output byte-for-byte identical to it.
 *
 * Copyright (c) 2020 Raspberry Pi (Trading) Ltd. (the original pioasm)
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com> (the C port)
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef PIOASM_H
#define PIOASM_H

#include <stdint.h>
#include <stdio.h>

#define MAX_INSTRUCTIONS 32

typedef struct {
    int line;
    int column;
    int end_column;
} Loc;

/* ----- expressions ----- */

enum { E_INT, E_NAME, E_BINARY, E_UNARY };
enum { OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_AND, OP_OR, OP_XOR, OP_SHL, OP_SHR };
enum { OP_NEGATE, OP_REVERSE };

typedef struct Expr {
    int kind;
    Loc loc;
    int value;          /* E_INT */
    char *name;         /* E_NAME */
    int op;             /* E_BINARY, E_UNARY */
    struct Expr *left;  /* E_BINARY, and E_UNARY's operand */
    struct Expr *right; /* E_BINARY */
} Expr;

/* ----- encoding enums, values as the hardware wants them ----- */

enum { INST_JMP, INST_WAIT, INST_IN, INST_OUT, INST_PUSH_PULL, INST_MOV, INST_IRQ, INST_SET };

enum { COND_AL, COND_XZ, COND_XNZ, COND_YZ, COND_YNZ, COND_XNEY, COND_PIN, COND_OSREZ };

enum {
    IOS_PINS = 0,
    IOS_X = 1,
    IOS_Y = 2,
    IOS_NULL = 3,
    IOS_PINDIRS = 4,
    IOS_STATUS = 5, /* in */
    IOS_PC = 5,     /* out, set */
    IOS_ISR = 6,
    IOS_OSR = 7,  /* in */
    IOS_EXEC = 7, /* out */
};

enum { IRQ_SET = 0, IRQ_SET_WAIT = 1, IRQ_CLEAR = 2 };

enum {
    MOV_PINS = 0,
    MOV_X = 1,
    MOV_Y = 2,
    MOV_NULL = 3,
    MOV_PINDIRS = 3,
    MOV_EXEC = 4,
    MOV_PC = 5,
    MOV_STATUS = 5,
    MOV_ISR = 6,
    MOV_OSR = 7,
    MOV_FIFO_Y = 8,
    MOV_FIFO_INDEX = 9,
};

enum { MOV_OP_NONE = 0, MOV_OP_INVERT = 1, MOV_OP_BIT_REVERSE = 2 };

enum { MOV_STATUS_UNSPECIFIED = -1, MOV_STATUS_TX_LESSTHAN = 0, MOV_STATUS_RX_LESSTHAN = 1, MOV_STATUS_IRQ_SET = 2 };

enum { WAIT_GPIO = 0, WAIT_PIN = 1, WAIT_IRQ = 2, WAIT_JMPPIN = 3 };

enum { FIFO_TXRX = 0, FIFO_TX = 1, FIFO_RX = 2, FIFO_TXGET = 3, FIFO_TXPUT = 4, FIFO_PUTGET = 5 };

typedef struct {
    int loc;          /* MOV_* */
    Expr *fifo_index; /* MOV_FIFO_INDEX only */
} MovOperand;

enum { I_JMP, I_WAIT, I_IN, I_OUT, I_PUSH, I_PULL, I_MOV, I_IRQ, I_SET, I_WORD };

typedef struct {
    int kind;
    Loc loc;
    Expr *sideset; /* NULL when the instruction has none */
    Expr *delay;
    int cond;      /* I_JMP */
    Expr *target;  /* I_JMP */
    Expr *polarity;       /* I_WAIT */
    int wait_source;      /* I_WAIT */
    Expr *wait_param;     /* I_WAIT */
    int irq_type;         /* I_WAIT, I_IRQ: 0 plain, 1 prev, 2 rel, 3 next */
    int ios;              /* I_IN source, I_OUT / I_SET destination */
    Expr *value;          /* I_IN, I_OUT, I_SET bit count or value; I_WORD encoding; I_IRQ number */
    int if_full_or_empty; /* I_PUSH, I_PULL */
    int blocking;         /* I_PUSH, I_PULL */
    MovOperand dest, src; /* I_MOV */
    int mov_op;           /* I_MOV */
    int irq_modifiers;    /* I_IRQ */
} Instruction;

/* ----- programs ----- */

typedef struct {
    char *name;
    Loc loc;
    Expr *value;
    int is_public;
    int is_label;
    int resolve_started;
} Symbol;

typedef struct {
    Loc loc;
    Expr *pin_count; /* NULL when not specified */
    int right;
    int autop;
    Expr *threshold;
    int final_pin_count;
    int final_threshold;
} InOut;

typedef struct {
    char *lang;
    char *contents;
    Loc loc;
} CodeBlock;

typedef struct {
    char *lang;
    char *name;
    char *value;
} LangOpt;

typedef struct Program {
    char *name;
    Loc loc;

    Expr *origin;
    Loc origin_loc;
    Expr *sideset;
    Loc sideset_loc;
    int sideset_opt;
    int sideset_pindirs;
    Expr *set_count;
    Loc set_count_loc;
    InOut in;
    InOut out;

    Expr *wrap_target;
    Expr *wrap;

    int pio_version;
    unsigned clock_div_int;
    unsigned clock_div_frac;
    Loc fifo_loc;
    int fifo;
    uint8_t used_gpio_ranges; /* one bit per 16 GPIOs a `wait gpio` names */

    Symbol **symbols; /* in definition order */
    int symbol_count;
    Instruction *instructions[MAX_INSTRUCTIONS];
    int instruction_count;
    CodeBlock *code_blocks;
    int code_block_count;
    LangOpt *lang_opts;
    int lang_opt_count;

    int mov_status_type;
    Expr *mov_status_n;
    int mov_status_param;
    int mov_status_final_n;

    /* set by finalize */
    int delay_max;
    int sideset_bits_including_opt;
    int sideset_max;
    int final_set_count;

    /* set by assemble */
    unsigned encoded[MAX_INSTRUCTIONS];
    int final_wrap;
    int final_wrap_target;
    int final_origin; /* -1 when not specified */
} Program;

typedef struct {
    const char *source;
    Program *global; /* holds .define's made outside any program */
    Program **programs;
    int program_count;
    int default_pio_version;
} Assembler;

/* A symbol after resolution, as the outputs print it. */
typedef struct {
    const char *name;
    int value;
    int is_label;
} PublicSymbol;

/* parse.c */
void parse_file(Assembler *as, const char *text);

/* assemble.c */
Assembler *assembler_new(const char *source, int default_pio_version);
Program *program_new(Assembler *as, Loc loc, const char *name);
Program *current_program(Assembler *as, Loc loc, const char *requiring, int before_any_instructions, int disallow_global);
int current_pio_version(Assembler *as);
void check_version(Assembler *as, int min_version, Loc loc, const char *feature);
Symbol *get_symbol(Assembler *as, const char *name, Program *p);
void add_symbol(Assembler *as, Program *p, Symbol *s);
void add_label(Assembler *as, Program *p, Symbol *s);
void add_instruction(Assembler *as, Program *p, Instruction *inst);
void set_clock_div(Program *p, Loc loc, float div);
void assemble(Assembler *as);
PublicSymbol *public_symbols(Assembler *as, Program *p, int *count);

/* disasm.c */
void disassemble(char *buf, size_t size, unsigned inst, int sideset_bits_including_opt, int sideset_opt);

/* output.c */
int output_c_sdk(Assembler *as, FILE *out);
int output_zig(Assembler *as, FILE *out);
int output_hex(Assembler *as, FILE *out);
int is_known_output_format(const char *lang);

/* main.c */
_Noreturn void fail(Loc loc, const char *fmt, ...);
void warn(Loc loc, const char *fmt, ...);
void *xmalloc(size_t size);
char *xstrdup(const char *s);
char *xstrndup(const char *s, size_t n);

#endif
