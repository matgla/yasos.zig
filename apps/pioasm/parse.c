/*
 * parse.c
 *
 * The lexer and parser: a hand-written stand-in for the SDK's lexer.ll (flex)
 * and parser.yy (bison). Where the flex rules tie or overlap, the comments say
 * which rule won there, because matching those choices is what keeps the
 * output identical.
 *
 * Copyright (c) 2020 Raspberry Pi (Trading) Ltd. (the original pioasm)
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com> (the C port)
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "pioasm.h"

#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

enum {
    T_END,
    T_NEWLINE,
    T_COMMA,
    T_COLON,
    T_LPAREN,
    T_RPAREN,
    T_LBRACKET,
    T_RBRACKET,
    T_PLUS,
    T_MINUS,
    T_MULTIPLY,
    T_DIVIDE,
    T_OR,
    T_AND,
    T_XOR,
    T_SHL,
    T_SHR,
    T_POST_DECREMENT,
    T_NOT_EQUAL,
    T_NOT,
    T_REVERSE,
    T_ASSIGN,
    T_LESSTHAN,

    /* directives */
    T_PROGRAM,
    T_WRAP_TARGET,
    T_WRAP,
    T_DEFINE,
    T_SIDE_SET,
    T_WORD,
    T_ORIGIN,
    T_LANG_OPT,
    T_PIO_VERSION,
    T_CLOCK_DIV,
    T_FIFO,
    T_MOV_STATUS,
    T_DOT_SET,
    T_DOT_OUT,
    T_DOT_IN,
    T_UNKNOWN_DIRECTIVE,

    /* keywords */
    T_JMP,
    T_WAIT,
    T_IN,
    T_OUT,
    T_PUSH,
    T_PULL,
    T_MOV,
    T_IRQ,
    T_SET,
    T_NOP,
    T_PIN,
    T_GPIO,
    T_OSRE,
    T_JMPPIN,
    T_PREV,
    T_NEXT,
    T_PINS,
    T_NULL,
    T_PINDIRS,
    T_BLOCK,
    T_NOBLOCK,
    T_IFEMPTY,
    T_IFFULL,
    T_NOWAIT,
    T_CLEAR,
    T_REL,
    T_X,
    T_Y,
    T_EXEC,
    T_PC,
    T_ISR,
    T_OSR,
    T_OPTIONAL,
    T_SIDE,
    T_STATUS,
    T_PUBLIC,
    T_RP2040,
    T_RP2350,
    T_RXFIFO,
    T_TXFIFO,
    T_TXRX,
    T_TX,
    T_RX,
    T_TXPUT,
    T_TXGET,
    T_PUTGET,
    T_LEFT,
    T_RIGHT,
    T_AUTO,
    T_MANUAL,

    /* with a value */
    T_ID,
    T_STRING,
    T_NON_WS,
    T_CODE_BLOCK_START,
    T_CODE_BLOCK_CONTENTS,
    T_INT,
    T_FLOAT,
};

typedef struct {
    const char *name;
    int token;
} Keyword;

static const Keyword directives[] = {
    {"program", T_PROGRAM},         {"wrap_target", T_WRAP_TARGET}, {"wrap", T_WRAP},
    {"word", T_WORD},               {"define", T_DEFINE},           {"side_set", T_SIDE_SET},
    {"origin", T_ORIGIN},           {"lang_opt", T_LANG_OPT},       {"pio_version", T_PIO_VERSION},
    {"clock_div", T_CLOCK_DIV},     {"fifo", T_FIFO},               {"mov_status", T_MOV_STATUS},
    {"set", T_DOT_SET},             {"out", T_DOT_OUT},             {"in", T_DOT_IN},
};

/* ONE and ZERO are integers, handled apart */
static const Keyword keywords[] = {
    {"jmp", T_JMP},         {"wait", T_WAIT},       {"in", T_IN},           {"out", T_OUT},
    {"push", T_PUSH},       {"pull", T_PULL},       {"mov", T_MOV},         {"irq", T_IRQ},
    {"set", T_SET},         {"nop", T_NOP},         {"public", T_PUBLIC},   {"optional", T_OPTIONAL},
    {"opt", T_OPTIONAL},    {"side", T_SIDE},       {"sideset", T_SIDE},    {"side_set", T_SIDE},
    {"pin", T_PIN},         {"gpio", T_GPIO},       {"osre", T_OSRE},       {"pins", T_PINS},
    {"null", T_NULL},       {"pindirs", T_PINDIRS}, {"x", T_X},             {"y", T_Y},
    {"pc", T_PC},           {"exec", T_EXEC},       {"isr", T_ISR},         {"osr", T_OSR},
    {"status", T_STATUS},   {"block", T_BLOCK},     {"noblock", T_NOBLOCK}, {"iffull", T_IFFULL},
    {"ifempty", T_IFEMPTY}, {"rel", T_REL},         {"clear", T_CLEAR},     {"nowait", T_NOWAIT},
    {"jmppin", T_JMPPIN},   {"next", T_NEXT},       {"prev", T_PREV},       {"txrx", T_TXRX},
    {"tx", T_TX},           {"rx", T_RX},           {"txput", T_TXPUT},     {"txget", T_TXGET},
    {"putget", T_PUTGET},   {"rp2040", T_RP2040},   {"rp2350", T_RP2350},   {"rxfifo", T_RXFIFO},
    {"txfifo", T_TXFIFO},   {"left", T_LEFT},       {"right", T_RIGHT},     {"auto", T_AUTO},
    {"manual", T_MANUAL},
};

typedef struct {
    int type;
    Loc loc;
    char *text; /* identifiers, strings, code block language and contents */
    int ival;
    float fval;
} Token;

typedef struct {
    Assembler *as;
    const char *src;
    size_t pos;
    int line;
    const char *line_start;
    int lang_opt; /* inside a .lang_opt line: flex's lang_opt start condition */
    Token tok;
} Parser;

static int is_blank(char c) {
    return c == ' ' || c == '\t' || c == '\r';
}

static int is_id_start(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static int is_digit(char c) {
    return c >= '0' && c <= '9';
}

static int is_id_char(char c) {
    return is_id_start(c) || is_digit(c);
}

static int is_hex_digit(char c) {
    return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

static int lower(char c) {
    return c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c;
}

static int keyword_eq(const char *s, size_t n, const char *keyword) {
    size_t i;
    for (i = 0; i < n; i++)
        if (!keyword[i] || lower(s[i]) != keyword[i]) return 0;
    return keyword[i] == 0;
}

static int lookup(const Keyword *table, size_t count, const char *s, size_t n) {
    for (size_t i = 0; i < count; i++)
        if (keyword_eq(s, n, table[i].name)) return table[i].token;
    return -1;
}

static Loc loc_at(Parser *ps, size_t start, size_t end) {
    Loc l;
    l.line = ps->line;
    l.column = (int)(ps->src + start - ps->line_start) + 1;
    l.end_column = (int)(ps->src + end - ps->line_start) + 1;
    return l;
}

static int convert_int(Parser *ps, size_t start, size_t end, int skip, int base, const char *what) {
    char *text = xstrndup(ps->src + start, end - start);
    long n;
    errno = 0;
    n = strtol(text + skip, NULL, base);
    if (!(INT_MIN <= n && n <= INT_MAX && errno != ERANGE)) fail(loc_at(ps, start, end), "%s is out of range: %s", what, text);
    free(text);
    return (int)n;
}

/* The number rules: {int}, {float}, {hex}, {binary}; the longest match wins,
 * and on a tie the earlier rule. Returns the token and sets *end. */
static int lex_number(Parser *ps, size_t start, size_t *end, int *ival, float *fval) {
    const char *s = ps->src;
    size_t p = start, int_end, float_end = 0, hex_end = 0, bin_end = 0;
    while (is_digit(s[p]))
        p++;
    int_end = p;
    if (s[p] == '.' && is_digit(s[p + 1])) {
        p++;
        while (is_digit(s[p]))
            p++;
        float_end = p;
    }
    if (s[start] == '0' && lower(s[start + 1]) == 'x' && is_hex_digit(s[start + 2])) {
        p = start + 2;
        while (is_hex_digit(s[p]))
            p++;
        hex_end = p;
    }
    if (s[start] == '0' && lower(s[start + 1]) == 'b' && (s[start + 2] == '0' || s[start + 2] == '1')) {
        p = start + 2;
        while (s[p] == '0' || s[p] == '1')
            p++;
        bin_end = p;
    }
    if (float_end > int_end && float_end >= hex_end && float_end >= bin_end) {
        char *text = xstrndup(s + start, float_end - start);
        *fval = strtof(text, NULL);
        free(text);
        *end = float_end;
        return T_FLOAT;
    }
    if (hex_end > int_end && hex_end >= bin_end) {
        *end = hex_end;
        *ival = convert_int(ps, start, hex_end, 2, 16, "hex");
        return T_INT;
    }
    if (bin_end > int_end) {
        *end = bin_end;
        *ival = convert_int(ps, start, bin_end, 2, 2, "binary");
        return T_INT;
    }
    *end = int_end;
    *ival = convert_int(ps, start, int_end, 0, 10, "integer");
    return T_INT;
}

static void newline(Parser *ps, size_t after) {
    ps->line++;
    ps->line_start = ps->src + after;
}

/* `% lang {`: {output_fmt} is [^%\n]+ and greedy, so the block opens at the
 * LAST '{' before the end of the line or the next '%'. */
static int lex_code_block(Parser *ps, size_t start, Token *t) {
    const char *s = ps->src;
    size_t p = start + 1, open = 0, first, last;
    while (s[p] && s[p] != '\n' && s[p] != '%') {
        if (s[p] == '{' && p > start + 1) open = p;
        p++;
    }
    if (!open) return 0;
    first = start + 1;
    last = open;
    while (first < last && is_blank(s[first]) && s[first] != '\r')
        first++;
    while (last > first && (s[last - 1] == ' ' || s[last - 1] == '\t'))
        last--;
    t->type = T_CODE_BLOCK_START;
    t->text = xstrndup(s + first, last - first);
    t->loc = loc_at(ps, start, open + 1);
    ps->pos = open + 1;
    return 1;
}

/* The code_block start condition, run to its end in one go. Per line: a line
 * of only blanks ties {blank}+ with .* and {blank}+ (earlier) wins, so it is
 * dropped; a line that is "%}" plus blanks ends the block (that rule precedes
 * .*); anything else, leading blanks included, is .* and kept whole. */
static char *lex_code_block_contents(Parser *ps, Loc start) {
    const char *s = ps->src;
    size_t p = ps->pos, cap = 256, len = 0;
    char *out = xmalloc(cap);
    out[0] = 0;
    for (;;) {
        size_t line_end = p, q;
        int only_blanks = 1;
        if (!s[p]) fail(start, "syntax error, unexpected end of file, expecting %%}");
        while (s[line_end] && s[line_end] != '\n')
            line_end++;
        for (q = p; q < line_end; q++)
            if (!is_blank(s[q])) only_blanks = 0;
        if (s[p] == '%' && s[p + 1] == '}') {
            int rest_blank = 1;
            for (q = p + 2; q < line_end; q++)
                if (!is_blank(s[q])) rest_blank = 0;
            if (rest_blank) {
                ps->pos = line_end;
                return out;
            }
        }
        if (!only_blanks) {
            size_t n = line_end - p;
            while (len + n + 2 > cap) {
                cap *= 2;
                out = realloc(out, cap);
                if (!out) fail(start, "out of memory");
            }
            memcpy(out + len, s + p, n);
            len += n;
            out[len++] = '\n';
            out[len] = 0;
        }
        p = line_end;
        while (s[p] == '\n') {
            p++;
            newline(ps, p);
        }
    }
}

static void next(Parser *ps);

static void lex_lang_opt(Parser *ps, Token *t) {
    const char *s = ps->src;
    size_t start;
    for (;;) {
        while (is_blank(s[ps->pos]))
            ps->pos++;
        start = ps->pos;
        if (!s[start]) {
            t->type = T_END;
            t->loc = loc_at(ps, start, start);
            return;
        }
        if (s[start] == '\n') {
            size_t p = start;
            t->type = T_NEWLINE;
            t->loc = loc_at(ps, start, start);
            while (s[p] == '\n') {
                p++;
                newline(ps, p);
            }
            ps->pos = p;
            ps->lang_opt = 0;
            return;
        }
        break;
    }
    if (s[start] == '"') {
        /* \"[^\n]*\": greedy, to the last quote on the line */
        size_t p = start + 1, close = 0;
        while (s[p] && s[p] != '\n') {
            if (s[p] == '"') close = p;
            p++;
        }
        if (close) {
            t->type = T_STRING;
            t->text = xstrndup(s + start, close + 1 - start);
            t->loc = loc_at(ps, start, close + 1);
            ps->pos = close + 1;
            return;
        }
        fail(loc_at(ps, start, start + 1), "invalid character: \"");
    }
    if (s[start] == '=') {
        t->type = T_ASSIGN;
        t->loc = loc_at(ps, start, start + 1);
        ps->pos = start + 1;
        return;
    }
    {
        /* NON_WS is [^ \t\n\"=]+. The lang_opt rules have {int}, {hex} and
         * {binary} but no {float}; a number is never longer than the NON_WS
         * over the same text, so it wins only by tying it (being earlier). */
        size_t p = start;
        while (s[p] && s[p] != ' ' && s[p] != '\t' && s[p] != '\n' && s[p] != '"' && s[p] != '=')
            p++;
        if (is_digit(s[start])) {
            size_t end;
            int ival;
            float fval;
            int type = lex_number(ps, start, &end, &ival, &fval);
            if (type == T_FLOAT) {
                /* no {float} here: {int} is the digits before the point */
                end = start;
                while (is_digit(s[end]))
                    end++;
                ival = convert_int(ps, start, end, 0, 10, "integer");
            }
            if (end == p) {
                t->type = T_INT;
                t->ival = ival;
                t->loc = loc_at(ps, start, end);
                ps->pos = end;
                return;
            }
        }
        t->type = T_NON_WS;
        t->text = xstrndup(s + start, p - start);
        t->loc = loc_at(ps, start, p);
        ps->pos = p;
    }
}

static void lex(Parser *ps, Token *t) {
    const char *s = ps->src;
    size_t start;
    t->text = NULL;
    if (ps->lang_opt) {
        lex_lang_opt(ps, t);
        return;
    }
    for (;;) {
        while (is_blank(s[ps->pos]))
            ps->pos++;
        start = ps->pos;
        if (s[start] == ';' || (s[start] == '/' && s[start + 1] == '/')) {
            while (s[ps->pos] && s[ps->pos] != '\n')
                ps->pos++;
            continue;
        }
        if (s[start] == '/' && s[start + 1] == '*') {
            /* newlines inside a C comment are not NEWLINE tokens */
            size_t p = start + 2;
            for (;;) {
                if (!s[p]) {
                    ps->pos = p;
                    break;
                }
                if (s[p] == '*' && s[p + 1] == '/') {
                    ps->pos = p + 2;
                    break;
                }
                if (s[p] == '\n') newline(ps, p + 1);
                p++;
            }
            continue;
        }
        break;
    }
    t->loc = loc_at(ps, start, start + 1);
    if (!s[start]) {
        t->type = T_END;
        return;
    }
    if (s[start] == '\n') {
        size_t p = start;
        t->type = T_NEWLINE;
        t->loc = loc_at(ps, start, start);
        while (s[p] == '\n') {
            p++;
            newline(ps, p);
        }
        ps->pos = p;
        return;
    }
    if (s[start] == '%') {
        if (lex_code_block(ps, start, t)) return;
        fail(t->loc, "invalid character: %%");
    }
    {
        static const struct {
            const char *text;
            int token;
        } puncts[] = {
            {"::", T_REVERSE}, {"--", T_POST_DECREMENT}, {"\xe2\x88\x92\xe2\x88\x92", T_POST_DECREMENT},
            {"!=", T_NOT_EQUAL}, {"<<", T_SHL}, {">>", T_SHR},
            {",", T_COMMA},    {":", T_COLON},    {"[", T_LBRACKET}, {"]", T_RBRACKET}, {"(", T_LPAREN},
            {")", T_RPAREN},   {"+", T_PLUS},     {"-", T_MINUS},    {"*", T_MULTIPLY}, {"/", T_DIVIDE},
            {"|", T_OR},       {"&", T_AND},      {"^", T_XOR},      {"!", T_NOT},      {"~", T_NOT},
            {"<", T_LESSTHAN},
        };
        for (size_t i = 0; i < sizeof(puncts) / sizeof(puncts[0]); i++) {
            size_t n = strlen(puncts[i].text);
            if (!strncmp(s + start, puncts[i].text, n)) {
                t->type = puncts[i].token;
                t->loc = loc_at(ps, start, start + n);
                ps->pos = start + n;
                return;
            }
        }
    }
    if (s[start] == '.' && is_id_start(s[start + 1])) {
        size_t p = start + 1;
        int token;
        while (is_id_char(s[p]))
            p++;
        token = lookup(directives, sizeof(directives) / sizeof(directives[0]), s + start + 1, p - start - 1);
        t->loc = loc_at(ps, start, p);
        ps->pos = p;
        if (token < 0) {
            t->type = T_UNKNOWN_DIRECTIVE;
            t->text = xstrndup(s + start, p - start);
            return;
        }
        t->type = token;
        if (token == T_LANG_OPT) ps->lang_opt = 1;
        return;
    }
    if (is_digit(s[start]) || (s[start] == '.' && is_digit(s[start + 1]))) {
        size_t end;
        t->type = lex_number(ps, start, &end, &t->ival, &t->fval);
        t->loc = loc_at(ps, start, end);
        ps->pos = end;
        return;
    }
    if (is_id_start(s[start])) {
        size_t p = start;
        int token;
        while (is_id_char(s[p]))
            p++;
        t->loc = loc_at(ps, start, p);
        ps->pos = p;
        if (keyword_eq(s + start, p - start, "one") || keyword_eq(s + start, p - start, "zero")) {
            t->type = T_INT;
            t->ival = lower(s[start]) == 'o';
            return;
        }
        token = lookup(keywords, sizeof(keywords) / sizeof(keywords[0]), s + start, p - start);
        if (token >= 0) {
            t->type = token;
            return;
        }
        t->type = T_ID;
        t->text = xstrndup(s + start, p - start);
        return;
    }
    fail(t->loc, "invalid character: %c", s[start]);
}

static void next(Parser *ps) {
    lex(ps, &ps->tok);
}

static int accept(Parser *ps, int type) {
    if (ps->tok.type != type) return 0;
    next(ps);
    return 1;
}

static _Noreturn void unexpected(Parser *ps) {
    fail(ps->tok.loc, "syntax error, unexpected token");
}

static void expect(Parser *ps, int type) {
    if (!accept(ps, type)) unexpected(ps);
}

/* ----- expressions ----- */

static Expr *new_expr(int kind, Loc loc) {
    Expr *e = xmalloc(sizeof(*e));
    memset(e, 0, sizeof(*e));
    e->kind = kind;
    e->loc = loc;
    return e;
}

static Expr *int_expr(Loc loc, int v) {
    Expr *e = new_expr(E_INT, loc);
    e->value = v;
    return e;
}

static Expr *parse_expression(Parser *ps, int min_prec);

/* value: INT | ID | '(' expression ')' */
static int starts_value(Parser *ps) {
    return ps->tok.type == T_INT || ps->tok.type == T_ID || ps->tok.type == T_LPAREN;
}

static Expr *parse_value(Parser *ps) {
    Token t = ps->tok;
    Expr *e;
    switch (t.type) {
    case T_INT:
        next(ps);
        return int_expr(t.loc, t.ival);
    case T_ID:
        next(ps);
        e = new_expr(E_NAME, t.loc);
        e->name = t.text;
        return e;
    case T_LPAREN:
        next(ps);
        e = parse_expression(ps, 1);
        expect(ps, T_RPAREN);
        return e;
    }
    unexpected(ps);
}

/* %left REVERSE / SHL SHR / PLUS MINUS / MULTIPLY DIVIDE / AND OR XOR: later
 * lines bind tighter, so & | ^ bind tightest of all. */
static int binary_prec(int token, int *op) {
    switch (token) {
    case T_SHL: *op = OP_SHL; return 1;
    case T_SHR: *op = OP_SHR; return 1;
    case T_PLUS: *op = OP_ADD; return 2;
    case T_MINUS: *op = OP_SUB; return 2;
    case T_MULTIPLY: *op = OP_MUL; return 3;
    case T_DIVIDE: *op = OP_DIV; return 3;
    case T_AND: *op = OP_AND; return 4;
    case T_OR: *op = OP_OR; return 4;
    case T_XOR: *op = OP_XOR; return 4;
    }
    return 0;
}

static Expr *parse_unary(Parser *ps) {
    Loc loc = ps->tok.loc;
    Expr *e;
    /* a prefix rule takes its precedence from its operator: `- a + b` is
     * (-a) + b, `- a * b` is -(a * b), and `:: a + b` is ::(a + b) */
    if (accept(ps, T_MINUS)) {
        e = new_expr(E_UNARY, loc);
        e->op = OP_NEGATE;
        e->left = parse_expression(ps, 3);
        return e;
    }
    if (accept(ps, T_REVERSE)) {
        e = new_expr(E_UNARY, loc);
        e->op = OP_REVERSE;
        e->left = parse_expression(ps, 1);
        return e;
    }
    return parse_value(ps);
}

static Expr *parse_expression(Parser *ps, int min_prec) {
    Expr *left = parse_unary(ps);
    for (;;) {
        int op, prec = binary_prec(ps->tok.type, &op);
        Expr *e;
        if (!prec || prec < min_prec) return left;
        e = new_expr(E_BINARY, left->loc);
        next(ps);
        e->op = op;
        e->left = left;
        e->right = parse_expression(ps, prec + 1);
        left = e;
    }
}

/* ----- lines ----- */

static Symbol *parse_symbol_def(Parser *ps) {
    Symbol *s = xmalloc(sizeof(*s));
    memset(s, 0, sizeof(*s));
    s->loc = ps->tok.loc;
    if (accept(ps, T_PUBLIC) || accept(ps, T_MULTIPLY)) s->is_public = 1;
    if (ps->tok.type != T_ID) unexpected(ps);
    s->name = ps->tok.text;
    next(ps);
    return s;
}

static void optional_comma(Parser *ps) {
    accept(ps, T_COMMA);
}

static Instruction *new_instruction(int kind, Loc loc) {
    Instruction *in = xmalloc(sizeof(*in));
    memset(in, 0, sizeof(*in));
    in->kind = kind;
    in->loc = loc;
    return in;
}

static int parse_irq_modifiers(Parser *ps) {
    if (accept(ps, T_CLEAR)) return IRQ_CLEAR;
    if (accept(ps, T_WAIT)) return IRQ_SET_WAIT;
    if (accept(ps, T_NOWAIT) || accept(ps, T_SET)) return IRQ_SET;
    return IRQ_SET;
}

/* `irq prev ...` / `irq next ...` refuse `rel` */
static void refuse_rel(Parser *ps, const char *which) {
    if (ps->tok.type == T_REL) fail(ps->tok.loc, "'rel' is not supported for 'irq %s'", which);
}

static void parse_wait_source(Parser *ps, Instruction *in) {
    Loc loc = ps->tok.loc;
    Assembler *as = ps->as;
    if (accept(ps, T_IRQ)) {
        in->wait_source = WAIT_IRQ;
        if (ps->tok.type == T_PREV || ps->tok.type == T_NEXT) {
            int is_next = ps->tok.type == T_NEXT;
            next(ps);
            check_version(as, 1, loc, is_next ? "irq next" : "irq prev");
            optional_comma(ps);
            in->wait_param = parse_value(ps);
            refuse_rel(ps, is_next ? "next" : "prev");
            in->irq_type = is_next ? 3 : 1;
            return;
        }
        optional_comma(ps);
        in->wait_param = parse_value(ps);
        in->irq_type = accept(ps, T_REL) ? 2 : 0;
        return;
    }
    if (accept(ps, T_GPIO)) {
        in->wait_source = WAIT_GPIO;
        optional_comma(ps);
        in->wait_param = parse_value(ps);
        return;
    }
    if (accept(ps, T_PIN)) {
        in->wait_source = WAIT_PIN;
        optional_comma(ps);
        in->wait_param = parse_value(ps);
        return;
    }
    if (accept(ps, T_JMPPIN)) {
        check_version(as, 1, loc, "wait jmppin");
        in->wait_source = WAIT_JMPPIN;
        if (accept(ps, T_PLUS))
            in->wait_param = parse_value(ps);
        else
            in->wait_param = int_expr(loc, 0);
        return;
    }
    fail(loc, "%s", current_pio_version(as) >= 1 ? "expected irq, gpio, pin or jmp_pin" : "expected irq, gpio or pin");
}

static MovOperand parse_rxfifo(Parser *ps, Loc loc) {
    MovOperand m = {MOV_FIFO_Y, NULL};
    check_version(ps->as, 1, loc, "mov rxfifo[], ");
    expect(ps, T_LBRACKET);
    if (!accept(ps, T_Y)) {
        m.loc = MOV_FIFO_INDEX;
        m.fifo_index = parse_value(ps);
    }
    expect(ps, T_RBRACKET);
    return m;
}

static MovOperand parse_mov_target(Parser *ps) {
    MovOperand m = {0, NULL};
    Loc loc = ps->tok.loc;
    switch (ps->tok.type) {
    case T_PINS: m.loc = MOV_PINS; break;
    case T_X: m.loc = MOV_X; break;
    case T_Y: m.loc = MOV_Y; break;
    case T_EXEC: m.loc = MOV_EXEC; break;
    case T_PC: m.loc = MOV_PC; break;
    case T_ISR: m.loc = MOV_ISR; break;
    case T_OSR: m.loc = MOV_OSR; break;
    case T_PINDIRS:
        check_version(ps->as, 1, loc, "mov pindirs");
        m.loc = MOV_PINDIRS;
        break;
    case T_RXFIFO:
        next(ps);
        return parse_rxfifo(ps, loc);
    default: unexpected(ps);
    }
    next(ps);
    return m;
}

static MovOperand parse_mov_source(Parser *ps) {
    MovOperand m = {0, NULL};
    Loc loc = ps->tok.loc;
    switch (ps->tok.type) {
    case T_PINS: m.loc = MOV_PINS; break;
    case T_X: m.loc = MOV_X; break;
    case T_Y: m.loc = MOV_Y; break;
    case T_NULL: m.loc = MOV_NULL; break;
    case T_STATUS: m.loc = MOV_STATUS; break;
    case T_ISR: m.loc = MOV_ISR; break;
    case T_OSR: m.loc = MOV_OSR; break;
    case T_RXFIFO:
        next(ps);
        return parse_rxfifo(ps, loc);
    default: unexpected(ps);
    }
    next(ps);
    return m;
}

static int parse_in_source(Parser *ps) {
    int v;
    switch (ps->tok.type) {
    case T_PINS: v = IOS_PINS; break;
    case T_X: v = IOS_X; break;
    case T_Y: v = IOS_Y; break;
    case T_NULL: v = IOS_NULL; break;
    case T_ISR: v = IOS_ISR; break;
    case T_OSR: v = IOS_OSR; break;
    case T_STATUS: v = IOS_STATUS; break;
    default: unexpected(ps);
    }
    next(ps);
    return v;
}

static int parse_out_target(Parser *ps) {
    int v;
    switch (ps->tok.type) {
    case T_PINS: v = IOS_PINS; break;
    case T_X: v = IOS_X; break;
    case T_Y: v = IOS_Y; break;
    case T_NULL: v = IOS_NULL; break;
    case T_PINDIRS: v = IOS_PINDIRS; break;
    case T_ISR: v = IOS_ISR; break;
    case T_PC: v = IOS_PC; break;
    case T_EXEC: v = IOS_EXEC; break;
    default: unexpected(ps);
    }
    next(ps);
    return v;
}

static int parse_set_target(Parser *ps) {
    int v;
    switch (ps->tok.type) {
    case T_PINS: v = IOS_PINS; break;
    case T_X: v = IOS_X; break;
    case T_Y: v = IOS_Y; break;
    case T_PINDIRS: v = IOS_PINDIRS; break;
    default: unexpected(ps);
    }
    next(ps);
    return v;
}

static int is_instruction_start(int type) {
    switch (type) {
    case T_NOP:
    case T_JMP:
    case T_WAIT:
    case T_IN:
    case T_OUT:
    case T_PUSH:
    case T_PULL:
    case T_MOV:
    case T_IRQ:
    case T_SET:
        return 1;
    }
    return 0;
}

static Instruction *parse_base_instruction(Parser *ps) {
    Loc loc = ps->tok.loc;
    Assembler *as = ps->as;
    Instruction *in;
    int type = ps->tok.type;
    next(ps);
    switch (type) {
    case T_NOP:
        in = new_instruction(I_MOV, loc);
        in->dest.loc = MOV_Y;
        in->src.loc = MOV_Y;
        return in;
    case T_JMP:
        in = new_instruction(I_JMP, loc);
        in->cond = COND_AL;
        if (accept(ps, T_NOT)) {
            if (accept(ps, T_X))
                in->cond = COND_XZ;
            else if (accept(ps, T_Y))
                in->cond = COND_YZ;
            else if (accept(ps, T_OSRE))
                in->cond = COND_OSREZ;
            else
                unexpected(ps);
        } else if (accept(ps, T_X)) {
            if (accept(ps, T_POST_DECREMENT))
                in->cond = COND_XNZ;
            else if (accept(ps, T_NOT_EQUAL) && accept(ps, T_Y))
                in->cond = COND_XNEY;
            else
                unexpected(ps);
        } else if (accept(ps, T_Y)) {
            expect(ps, T_POST_DECREMENT);
            in->cond = COND_YNZ;
        } else if (accept(ps, T_PIN)) {
            in->cond = COND_PIN;
        }
        optional_comma(ps);
        in->target = parse_expression(ps, 1);
        return in;
    case T_WAIT:
        in = new_instruction(I_WAIT, loc);
        if (starts_value(ps))
            in->polarity = parse_value(ps);
        else
            in->polarity = int_expr(loc, 1);
        parse_wait_source(ps, in);
        return in;
    case T_IN:
        in = new_instruction(I_IN, loc);
        in->ios = parse_in_source(ps);
        optional_comma(ps);
        in->value = parse_value(ps);
        return in;
    case T_OUT:
        in = new_instruction(I_OUT, loc);
        in->ios = parse_out_target(ps);
        optional_comma(ps);
        in->value = parse_value(ps);
        return in;
    case T_PUSH:
    case T_PULL:
        in = new_instruction(type == T_PUSH ? I_PUSH : I_PULL, loc);
        in->if_full_or_empty = accept(ps, type == T_PUSH ? T_IFFULL : T_IFEMPTY);
        in->blocking = 1;
        if (accept(ps, T_NOBLOCK))
            in->blocking = 0;
        else
            accept(ps, T_BLOCK);
        return in;
    case T_MOV:
        in = new_instruction(I_MOV, loc);
        in->dest = parse_mov_target(ps);
        optional_comma(ps);
        if (accept(ps, T_NOT))
            in->mov_op = MOV_OP_INVERT;
        else if (accept(ps, T_REVERSE))
            in->mov_op = MOV_OP_BIT_REVERSE;
        else
            in->mov_op = MOV_OP_NONE;
        in->src = parse_mov_source(ps);
        return in;
    case T_IRQ:
        in = new_instruction(I_IRQ, loc);
        if (ps->tok.type == T_PREV || ps->tok.type == T_NEXT) {
            int is_next = ps->tok.type == T_NEXT;
            next(ps);
            in->irq_modifiers = parse_irq_modifiers(ps);
            in->value = parse_value(ps);
            check_version(as, 1, loc, is_next ? "irq next" : "irq prev");
            refuse_rel(ps, is_next ? "next" : "prev");
            in->irq_type = is_next ? 3 : 1;
            return in;
        }
        in->irq_modifiers = parse_irq_modifiers(ps);
        in->value = parse_value(ps);
        in->irq_type = accept(ps, T_REL) ? 2 : 0;
        return in;
    case T_SET:
        in = new_instruction(I_SET, loc);
        in->ios = parse_set_target(ps);
        optional_comma(ps);
        in->value = parse_value(ps);
        return in;
    }
    unexpected(ps);
}

/* instruction: base_instruction, then `side value` and `[delay]` in either
 * order; a missing delay is 0, a missing side set stays absent */
static Instruction *parse_instruction(Parser *ps) {
    Instruction *in = parse_base_instruction(ps);
    for (int i = 0; i < 2; i++) {
        if (!in->sideset && accept(ps, T_SIDE)) {
            in->sideset = parse_value(ps);
        } else if (!in->delay && ps->tok.type == T_LBRACKET) {
            next(ps);
            in->delay = parse_expression(ps, 1);
            expect(ps, T_RBRACKET);
        }
    }
    if (!in->delay) in->delay = int_expr(in->loc, 0);
    return in;
}

static int parse_direction(Parser *ps) {
    if (accept(ps, T_LEFT)) return 0;
    accept(ps, T_RIGHT);
    return 1;
}

static int parse_autop(Parser *ps) {
    if (accept(ps, T_AUTO)) return 1;
    accept(ps, T_MANUAL);
    return 0;
}

static void parse_in_out(Parser *ps, InOut *io, Loc loc) {
    io->loc = loc;
    io->pin_count = parse_value(ps);
    io->right = parse_direction(ps);
    io->autop = parse_autop(ps);
    io->threshold = starts_value(ps) ? parse_value(ps) : int_expr(loc, 32);
}

static void parse_directive(Parser *ps) {
    Assembler *as = ps->as;
    Token t = ps->tok;
    Loc loc = t.loc;
    Program *p;
    next(ps);
    switch (t.type) {
    case T_DEFINE: {
        Symbol *s;
        s = parse_symbol_def(ps);
        s->is_label = 0;
        s->value = parse_expression(ps, 1);
        add_symbol(as, current_program(as, loc, ".define", 0, 0), s);
        return;
    }
    case T_ORIGIN: {
        Expr *v = parse_value(ps);
        p = current_program(as, loc, ".origin", 1, 1);
        p->origin = v;
        p->origin_loc = loc;
        return;
    }
    case T_PIO_VERSION: {
        int version;
        if (ps->tok.type == T_INT)
            version = ps->tok.ival;
        else if (ps->tok.type == T_RP2040)
            version = 0;
        else if (ps->tok.type == T_RP2350)
            version = 1;
        else
            unexpected(ps);
        next(ps);
        p = current_program(as, loc, ".pio_version", 1, 0);
        if (version < 0 || version > 1) fail(loc, "only PIO versions 0 (rp2040) and 1 (rp2350) are supported");
        p->pio_version = version;
        return;
    }
    case T_SIDE_SET: {
        Expr *v = parse_value(ps);
        int optional = accept(ps, T_OPTIONAL);
        int pindirs = accept(ps, T_PINDIRS);
        p = current_program(as, loc, ".side_set", 1, 1);
        p->sideset = v;
        p->sideset_loc = loc;
        p->sideset_opt = optional;
        p->sideset_pindirs = pindirs;
        return;
    }
    case T_DOT_IN:
    case T_DOT_OUT: {
        InOut io;
        memset(&io, 0, sizeof(io));
        parse_in_out(ps, &io, loc);
        p = current_program(as, loc, t.type == T_DOT_IN ? ".in" : ".out", 1, 1);
        if (t.type == T_DOT_IN) {
            io.final_pin_count = p->in.final_pin_count;
            p->in = io;
        } else {
            io.final_pin_count = p->out.final_pin_count;
            p->out = io;
        }
        return;
    }
    case T_DOT_SET: {
        Expr *v = parse_value(ps);
        p = current_program(as, loc, ".set", 1, 1);
        p->set_count = v;
        p->set_count_loc = loc;
        return;
    }
    case T_WRAP_TARGET:
        p = current_program(as, loc, ".wrap_target", 0, 1);
        if (p->wrap_target) fail(loc, ".wrap_target was already specified at line %d", p->wrap_target->loc.line);
        p->wrap_target = int_expr(loc, p->instruction_count);
        return;
    case T_WRAP:
        p = current_program(as, loc, ".wrap", 0, 1);
        if (p->wrap) fail(loc, ".wrap was already specified at line %d", p->wrap->loc.line);
        if (!p->instruction_count) fail(loc, ".wrap cannot be placed before the first program instruction");
        p->wrap = int_expr(loc, p->instruction_count - 1);
        return;
    case T_WORD: {
        Instruction *in = new_instruction(I_WORD, loc);
        in->value = parse_value(ps);
        add_instruction(as, current_program(as, loc, "instruction", 0, 1), in);
        return;
    }
    case T_LANG_OPT: {
        char *lang, *name, *value;
        if (ps->tok.type != T_NON_WS) goto bad_lang_opt;
        lang = ps->tok.text;
        next(ps);
        if (ps->tok.type != T_NON_WS) goto bad_lang_opt;
        name = ps->tok.text;
        next(ps);
        if (!accept(ps, T_ASSIGN)) goto bad_lang_opt;
        if (ps->tok.type == T_INT) {
            char buf[16];
            snprintf(buf, sizeof(buf), "%d", ps->tok.ival);
            value = xstrdup(buf);
        } else if (ps->tok.type == T_STRING || ps->tok.type == T_NON_WS) {
            value = ps->tok.text;
        } else {
            goto bad_lang_opt;
        }
        next(ps);
        p = current_program(as, loc, ".lang_opt", 0, 1);
        p->lang_opts = realloc(p->lang_opts, sizeof(*p->lang_opts) * (size_t)(p->lang_opt_count + 1));
        if (!p->lang_opts) fail(loc, "out of memory");
        p->lang_opts[p->lang_opt_count].lang = lang;
        p->lang_opts[p->lang_opt_count].name = name;
        p->lang_opts[p->lang_opt_count].value = value;
        p->lang_opt_count++;
        return;
    bad_lang_opt:
        fail(loc, "expected format is .lang_opt language option_name = option_value");
    }
    case T_CLOCK_DIV: {
        float div;
        if (ps->tok.type == T_INT)
            div = (float)ps->tok.ival;
        else if (ps->tok.type == T_FLOAT)
            div = ps->tok.fval;
        else
            unexpected(ps);
        next(ps);
        set_clock_div(current_program(as, loc, ".clock_div", 0, 1), loc, div);
        return;
    }
    case T_FIFO: {
        int config;
        Loc cl = ps->tok.loc;
        switch (ps->tok.type) {
        case T_TXRX: config = FIFO_TXRX; break;
        case T_TX: config = FIFO_TX; break;
        case T_RX: config = FIFO_RX; break;
        case T_TXPUT:
            check_version(as, 1, cl, "txput");
            config = FIFO_TXPUT;
            break;
        case T_TXGET:
            check_version(as, 1, cl, "rxput");
            config = FIFO_TXGET;
            break;
        case T_PUTGET:
            check_version(as, 1, cl, "putget");
            config = FIFO_PUTGET;
            break;
        default:
            fail(loc, "%s", current_pio_version(as) >= 1 ? "expected txrx, tx, rx, txput, rxget or putget"
                                                          : "expected txrx, tx or rx");
        }
        next(ps);
        p = current_program(as, loc, ".fifo", 1, 1);
        p->fifo_loc = loc;
        p->fifo = config;
        return;
    }
    case T_MOV_STATUS: {
        int type, param = 0;
        Expr *n;
        if (accept(ps, T_TXFIFO)) {
            type = MOV_STATUS_TX_LESSTHAN;
            expect(ps, T_LESSTHAN);
        } else if (accept(ps, T_RXFIFO)) {
            type = MOV_STATUS_RX_LESSTHAN;
            expect(ps, T_LESSTHAN);
        } else if (accept(ps, T_IRQ)) {
            type = MOV_STATUS_IRQ_SET;
            if (accept(ps, T_NEXT))
                param = 2;
            else if (accept(ps, T_PREV))
                param = 1;
            expect(ps, T_SET);
        } else {
            fail(loc, "expected 'txfifo < N', 'rxfifo < N' or 'irq set N'");
        }
        n = parse_value(ps);
        p = current_program(as, loc, ".mov_status", 1, 1);
        p->mov_status_type = type;
        p->mov_status_n = n;
        p->mov_status_param = param;
        return;
    }
    case T_UNKNOWN_DIRECTIVE:
        fail(loc, "unknown directive %s", t.text);
    }
    unexpected(ps);
}

static void parse_code_block(Parser *ps) {
    Token t = ps->tok;
    char *contents = lex_code_block_contents(ps, t.loc);
    Program *p;
    CodeBlock *cb;
    next(ps);
    p = current_program(ps->as, t.loc, "code block", 0, 0);
    p->code_blocks = realloc(p->code_blocks, sizeof(*p->code_blocks) * (size_t)(p->code_block_count + 1));
    if (!p->code_blocks) fail(t.loc, "out of memory");
    cb = &p->code_blocks[p->code_block_count++];
    cb->lang = t.text[0] ? t.text : xstrdup("c-sdk");
    cb->contents = contents;
    cb->loc = t.loc;
}

static void parse_line(Parser *ps) {
    Assembler *as = ps->as;
    int type = ps->tok.type;
    if (type == T_NEWLINE || type == T_END) return;
    if (type == T_PROGRAM) {
        Loc loc = ps->tok.loc;
        Program *p;
        next(ps);
        if (ps->tok.type != T_ID) unexpected(ps);
        for (int i = 0; i < as->program_count; i++)
            if (!strcmp(as->programs[i]->name, ps->tok.text)) fail(loc, "program %s already exists", ps->tok.text);
        p = program_new(as, loc, ps->tok.text);
        as->programs = realloc(as->programs, sizeof(*as->programs) * (size_t)(as->program_count + 1));
        if (!as->programs) fail(loc, "out of memory");
        as->programs[as->program_count++] = p;
        next(ps);
        return;
    }
    if (type == T_CODE_BLOCK_START) {
        parse_code_block(ps);
        return;
    }
    if (type >= T_WRAP_TARGET && type <= T_UNKNOWN_DIRECTIVE) {
        parse_directive(ps);
        return;
    }
    if (type == T_ID || type == T_PUBLIC || type == T_MULTIPLY) {
        Symbol *s = parse_symbol_def(ps);
        expect(ps, T_COLON);
        s->is_label = 1;
        if (is_instruction_start(ps->tok.type)) {
            Loc loc = ps->tok.loc;
            Instruction *in = parse_instruction(ps);
            Program *p = current_program(as, loc, "instruction", 0, 1);
            add_label(as, p, s);
            add_instruction(as, p, in);
        } else {
            add_label(as, current_program(as, s->loc, "label", 0, 1), s);
        }
        return;
    }
    if (is_instruction_start(type)) {
        Loc loc = ps->tok.loc;
        Instruction *in = parse_instruction(ps);
        add_instruction(as, current_program(as, loc, "instruction", 0, 1), in);
        return;
    }
    unexpected(ps);
}

void parse_file(Assembler *as, const char *text) {
    Parser ps;
    memset(&ps, 0, sizeof(ps));
    ps.as = as;
    ps.src = text;
    ps.line = 1;
    ps.line_start = text;
    next(&ps);
    for (;;) {
        parse_line(&ps);
        if (ps.tok.type == T_END) return;
        expect(&ps, T_NEWLINE);
    }
}
