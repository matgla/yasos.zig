/*
 * mdcat -- Markdown for the terminal, small enough for the board.
 *
 *   mdcat [-p] [-c|-n] [-w COLS] [FILE...]    no FILE: stdin
 *
 *   -p   page the result through $PAGER (else more)
 *   -c   colour even when stdout is not a terminal
 *   -n   no colour (also NO_COLOR, TERM=dumb, or stdout not a terminal)
 *   -w   width; else COLUMNS, else asked from the terminal, else 80
 *
 * Headings are bold and coloured (H1 and H2 underlined with = and -),
 * paragraphs and list items reflowed to the width, **bold**, *italic*,
 * ~~strike~~, `code` and [links](url) in ANSI attributes, fenced and
 * indented code kept verbatim, block quotes behind a "| " bar, task
 * lists, and GFM pipe tables drawn as +---+ grids whose cells wrap when
 * the table is wider than the screen.  Output is ASCII plus the file's
 * own bytes (UTF-8 counts one column per character).
 *
 * `cmd | more` does not page on YasOS (the keyboard is stdin), so -p
 * renders into a file in /tmp and hands that to the pager.
 *
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* ---- output -------------------------------------------------------- */

static FILE *out;
static int color;
static int term_width = 80;

#define DIM "\033[90m"
#define OFF "\033[0m"

/* Inline attributes of one character. */
enum {
    S_BOLD = 1,
    S_ITAL = 2,
    S_CODE = 4,
    S_LINK = 8,
    S_STRIKE = 16,
    S_DIM = 32,
};

typedef struct {
    char ch;
    unsigned char st;
} Cell;

static Cell *cells;
static int ncells, capcells;

static void put(char ch, unsigned st) {
    if (ncells == capcells) {
        capcells = capcells ? capcells * 2 : 1024;
        cells = realloc(cells, sizeof(Cell) * capcells);
        if (!cells) {
            fputs("mdcat: out of memory\n", stderr);
            exit(1);
        }
    }
    cells[ncells].ch = ch;
    cells[ncells].st = (unsigned char)st;
    ++ncells;
}

static void puts_st(const char *s, unsigned st) {
    while (*s) put(*s++, st);
}

/* UTF-8 continuation bytes take no column. */
static int vis(char c) {
    return ((unsigned char)c & 0xC0) != 0x80;
}

static int range_width(int a, int b) {
    int w = 0;
    for (int k = a; k < b; ++k) w += vis(cells[k].ch);
    return w;
}

static void set_style(unsigned st, const char *base) {
    fputs("\033[0", out);
    if (base) fprintf(out, ";%s", base);
    if (st & S_BOLD) fputs(";1", out);
    if (st & S_ITAL) fputs(";3", out);
    if (st & S_STRIKE) fputs(";9", out);
    if (st & S_LINK)
        fputs(";4;34", out);
    else if (st & S_CODE)
        fputs(";33", out);
    if (st & S_DIM) fputs(";90", out);
    fputc('m', out);
}

/* cells[a..b) with their attributes over the block's base colour. */
static void emit_cells(int a, int b, const char *base) {
    int cur = base ? -1 : 0, dirty = 0;
    for (int k = a; k < b; ++k) {
        if (color && cells[k].st != cur) {
            set_style(cells[k].st, base);
            cur = cells[k].st;
            dirty = 1;
        }
        fputc(cells[k].ch, out);
    }
    if (dirty) fputs(OFF, out);
}

static void spaces(int n) {
    while (n-- > 0) fputc(' ', out);
}

static void repeat(char c, int n, const char *sgr) {
    if (color && sgr) fputs(sgr, out);
    while (n-- > 0) fputc(c, out);
    if (color && sgr) fputs(OFF, out);
}

/* ---- wrapping ------------------------------------------------------ */

typedef struct {
    int a, b;
} Rng;

typedef struct {
    Rng *r;
    int n, cap;
} Lines;

static void add_line(Lines *l, int a, int b) {
    if (l->n == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 16;
        l->r = realloc(l->r, sizeof(Rng) * l->cap);
        if (!l->r) exit(1);
    }
    l->r[l->n].a = a;
    l->r[l->n].b = b;
    ++l->n;
}

/* Break cells[a..b) into lines of at most w columns, at spaces where it
   can, at '\n' cells always. */
static void wrap(int a, int b, int w, Lines *l) {
    l->n = 0;
    if (w < 1) w = 1;
    int pos = a;
    while (pos < b) {
        int start = pos, width = 0, lastsp = -1, k = pos;
        while (k < b && cells[k].ch != '\n') {
            if (cells[k].ch == ' ') lastsp = k;
            int cw = vis(cells[k].ch);
            if (width + cw > w && width > 0) break;
            width += cw;
            ++k;
        }
        if (k >= b || cells[k].ch == '\n') {
            add_line(l, start, k);
            pos = k + 1;
        } else if (cells[k].ch == ' ') {
            add_line(l, start, k);
            pos = k + 1;
        } else if (lastsp > start) {
            add_line(l, start, lastsp);
            pos = lastsp + 1;
        } else {
            add_line(l, start, k);
            pos = k;
        }
        while (pos < b && cells[pos].ch == ' ') ++pos;
    }
}

/* ---- inline -------------------------------------------------------- */

static void inl(const char *s, int n, unsigned st);

static int run_of(const char *s, int n, int k) {
    int r = 0;
    while (k + r < n && s[k + r] == s[k]) ++r;
    return r;
}

/* A later run of exactly len delimiter chars c that can close (no space
   before it). */
static int closer_after(const char *s, int n, int k, char c, int len) {
    for (int j = k; j + len <= n; ++j) {
        if (s[j] == '\\') {
            ++j;
            continue;
        }
        if (s[j] == '`') { /* delimiters inside code spans don't count */
            int r = run_of(s, n, j), m = j + r;
            while (m < n && !(s[m] == '`' && run_of(s, n, m) == r)) ++m;
            if (m < n) j = m + r - 1;
            continue;
        }
        if (s[j] == c && j > 0 && s[j - 1] != ' ') {
            int r = run_of(s, n, j);
            if (r >= len && (c != '_' || j + r >= n || !isalnum((unsigned char)s[j + r]))) return 1;
            j += r - 1;
        }
    }
    return 0;
}

/* The ']' or ')' matching s[k], or -1. */
static int match(const char *s, int n, int k, char open, char close) {
    int depth = 0;
    for (int j = k; j < n; ++j) {
        if (s[j] == '\\') {
            ++j;
        } else if (s[j] == open) {
            ++depth;
        } else if (s[j] == close && --depth == 0) {
            return j;
        }
    }
    return -1;
}

static const struct {
    const char *name;
    char ch;
} entities[] = {
    {"amp;", '&'}, {"lt;", '<'}, {"gt;", '>'}, {"quot;", '"'}, {"nbsp;", ' '}, {"#39;", '\''}, {"apos;", '\''},
};

static void inl(const char *s, int n, unsigned st) {
    int k = 0;
    while (k < n) {
        char c = s[k];
        if (c == '\\' && k + 1 < n && ispunct((unsigned char)s[k + 1])) {
            put(s[k + 1], st);
            k += 2;
        } else if (c == '`') {
            int r = run_of(s, n, k), m = k + r;
            while (m < n && !(s[m] == '`' && run_of(s, n, m) == r)) m += run_of(s, n, m) ? run_of(s, n, m) : 1;
            if (m >= n) {
                for (int j = 0; j < r; ++j) put('`', st);
                k += r;
                continue;
            }
            int a = k + r, b = m;
            if (b - a >= 2 && s[a] == ' ' && s[b - 1] == ' ') ++a, --b;
            if (!color) put('`', st);
            for (int j = a; j < b; ++j) put(s[j], st | S_CODE);
            if (!color) put('`', st);
            k = m + r;
        } else if (c == '*' || c == '_' || c == '~') {
            int r = run_of(s, n, k);
            int len = (c == '~') ? 2 : (r >= 2 ? 2 : 1);
            unsigned bit = (c == '~') ? S_STRIKE : (len == 2 ? S_BOLD : S_ITAL);
            int prev_sp = k == 0 || s[k - 1] == ' ';
            int next_sp = k + r >= n || s[k + r] == ' ';
            int prev_an = k > 0 && isalnum((unsigned char)s[k - 1]);
            int next_an = k + r < n && isalnum((unsigned char)s[k + r]);
            if (r < len) {
                put(c, st);
                ++k;
            } else if ((st & bit) && !prev_sp && !(c == '_' && next_an)) {
                st &= ~bit;
                k += len;
            } else if (!(st & bit) && !next_sp && !(c == '_' && prev_an) && closer_after(s, n, k + r, c, len)) {
                st |= bit;
                k += len;
            } else {
                for (int j = 0; j < r; ++j) put(c, st);
                k += r;
            }
        } else if ((c == '[' || (c == '!' && k + 1 < n && s[k + 1] == '[')) &&
                   match(s, n, k + (c == '!'), '[', ']') >= 0) {
            int img = c == '!';
            int open = k + img, close = match(s, n, open, '[', ']');
            int paren = (close + 1 < n && s[close + 1] == '(') ? match(s, n, close + 1, '(', ')') : -1;
            if (paren < 0) {
                put(c, st);
                ++k;
                continue;
            }
            const char *text = s + open + 1, *url = s + close + 2;
            int tn = close - open - 1, un = paren - close - 2;
            /* drop a "title" after the URL */
            for (int j = 0; j < un; ++j)
                if (url[j] == ' ') {
                    un = j;
                    break;
                }
            if (img) {
                puts_st("[image: ", st | S_DIM);
                inl(text, tn, st | S_DIM);
                put(']', st | S_DIM);
            } else {
                inl(text, tn, st | S_LINK);
                if (un > 0 && url[0] != '#' && !(un == tn && !memcmp(url, text, un))) {
                    puts_st(" (", st | S_DIM);
                    for (int j = 0; j < un; ++j) put(url[j], st | S_DIM);
                    put(')', st | S_DIM);
                }
            }
            k = paren + 1;
        } else if (c == '<') {
            int e = k + 1;
            while (e < n && s[e] != '>' && s[e] != '<') ++e;
            if (e >= n || s[e] != '>') {
                put(c, st);
                ++k;
                continue;
            }
            const char *in = s + k + 1;
            int len = e - k - 1;
            if (memchr(in, ':', len) && !memchr(in, ' ', len)) { /* <https://...> */
                for (int j = 0; j < len; ++j) put(in[j], st | S_LINK);
            } else if (len > 0 && memchr(in, '@', len) && !memchr(in, ' ', len)) {
                for (int j = 0; j < len; ++j) put(in[j], st | S_LINK);
            } else if (len > 0 && (isalpha((unsigned char)in[0]) || in[0] == '/' || in[0] == '!')) {
                if (len >= 2 && tolower((unsigned char)in[0]) == 'b' && tolower((unsigned char)in[1]) == 'r' &&
                    (len == 2 || in[2] == ' ' || in[2] == '/'))
                    put('\n', st);
                /* other HTML tags are dropped */
            } else {
                put(c, st);
                ++k;
                continue;
            }
            k = e + 1;
        } else if (c == '&') {
            int done = 0;
            for (size_t j = 0; j < sizeof(entities) / sizeof(entities[0]); ++j) {
                int l = (int)strlen(entities[j].name);
                if (k + 1 + l <= n && !memcmp(s + k + 1, entities[j].name, l)) {
                    put(entities[j].ch, st);
                    k += 1 + l;
                    done = 1;
                    break;
                }
            }
            if (!done) put(s[k++], st);
        } else {
            put(c, st);
            ++k;
        }
    }
}

/* ---- blocks -------------------------------------------------------- */

typedef struct {
    const char *s;
    int n;
} Line;

/* Where the output goes: a list item or a quote prefixes every line it
   prints, the first line of an item with its bullet. */
typedef struct Ctx {
    struct Ctx *parent;
    char first[64], rest[64];
    int first_pending;
    int width;      /* columns left after the prefixes */
    int started;    /* a block was printed: the next needs a gap */
    int tight;      /* list item of a tight list: no gaps */
    int list_depth;
} Ctx;

static void emit_prefix(Ctx *c) {
    if (!c) return;
    emit_prefix(c->parent);
    if (c->first_pending) {
        fputs(c->first, out);
        c->first_pending = 0;
    } else {
        fputs(c->rest, out);
    }
}

static void gap(Ctx *c) {
    if (c->started && !c->tight) {
        emit_prefix(c);
        fputc('\n', out);
    }
    c->started = 1;
}

static int indent_of(Line l) {
    int i = 0;
    while (i < l.n && l.s[i] == ' ') ++i;
    return i;
}

static int blank(Line l) {
    return indent_of(l) == l.n;
}

static Line skip(Line l, int k) {
    if (k > l.n) k = l.n;
    l.s += k;
    l.n -= k;
    return l;
}

static Line trim(Line l) {
    l = skip(l, indent_of(l));
    while (l.n > 0 && l.s[l.n - 1] == ' ') --l.n;
    return l;
}

static int atx(Line l, Line *text) {
    int i = indent_of(l), lv = 0;
    if (i > 3) return 0;
    while (i + lv < l.n && l.s[i + lv] == '#') ++lv;
    if (lv < 1 || lv > 6 || (i + lv < l.n && l.s[i + lv] != ' ')) return 0;
    Line t = trim(skip(l, i + lv));
    int e = t.n;
    while (e > 0 && t.s[e - 1] == '#') --e;
    if (e == 0 || t.s[e - 1] == ' ') t.n = e; /* a closing ### run */
    *text = trim(t);
    return lv;
}

static int is_hr(Line l) {
    int i = indent_of(l), count = 0;
    if (i > 3 || i >= l.n) return 0;
    char c = l.s[i];
    if (c != '-' && c != '*' && c != '_') return 0;
    for (; i < l.n; ++i) {
        if (l.s[i] == c)
            ++count;
        else if (l.s[i] != ' ')
            return 0;
    }
    return count >= 3;
}

static int setext(Line l) {
    int i = indent_of(l);
    if (i > 3 || i >= l.n || (l.s[i] != '=' && l.s[i] != '-')) return 0;
    Line t = trim(l);
    for (int j = 0; j < t.n; ++j)
        if (t.s[j] != t.s[0]) return 0;
    return t.s[0] == '=' ? 1 : 2;
}

static int fence(Line l, char *ch) {
    int i = indent_of(l);
    if (i > 3 || i >= l.n || (l.s[i] != '`' && l.s[i] != '~')) return 0;
    int r = run_of(l.s, l.n, i);
    if (r < 3) return 0;
    *ch = l.s[i];
    return r;
}

static int quote(Line l) {
    int i = indent_of(l);
    return i <= 3 && i < l.n && l.s[i] == '>';
}

/* A list item: returns 1 (bullet) or 2 (ordered), the number, the
   marker's text and where the item's content starts. */
static int item(Line l, long *num, int *content) {
    int i = indent_of(l), j = i, kind;
    if (j < l.n && (l.s[j] == '-' || l.s[j] == '*' || l.s[j] == '+')) {
        kind = 1;
        ++j;
    } else {
        long v = 0;
        while (j < l.n && j - i < 9 && isdigit((unsigned char)l.s[j])) v = v * 10 + (l.s[j++] - '0');
        if (j == i || j >= l.n || (l.s[j] != '.' && l.s[j] != ')')) return 0;
        ++j;
        kind = 2;
        *num = v;
    }
    if (j < l.n && l.s[j] != ' ') return 0;
    if (kind == 1 && is_hr(l)) return 0;
    int sp = 0;
    while (j + sp < l.n && l.s[j + sp] == ' ') ++sp;
    if (j + sp >= l.n)
        *content = j + 1; /* empty first line */
    else
        *content = j + (sp > 4 ? 1 : sp);
    return kind;
}

static int split_row(Line l, Line *cell, int max) {
    l = trim(l);
    if (l.n && l.s[0] == '|') l = skip(l, 1);
    if (l.n && l.s[l.n - 1] == '|' && (l.n < 2 || l.s[l.n - 2] != '\\')) --l.n;
    int n = 0, start = 0, code = 0;
    for (int k = 0; k <= l.n; ++k) {
        if (k < l.n && l.s[k] == '\\') {
            ++k;
            continue;
        }
        if (k < l.n && l.s[k] == '`') code = !code;
        if (k == l.n || (l.s[k] == '|' && !code)) {
            if (n < max) {
                cell[n].s = l.s + start;
                cell[n].n = k - start;
                cell[n] = trim(cell[n]);
            }
            ++n;
            start = k + 1;
        }
    }
    return n;
}

#define MAXCOLS 32

/* The |---|:--:| row under a table's header: the alignment of each
   column ('l', 'c', 'r'), or 0 columns. */
static int table_sep(Line l, char *align) {
    if (!memchr(l.s, '|', l.n) && !memchr(l.s, '-', l.n)) return 0;
    if (!memchr(l.s, '|', l.n)) return 0;
    Line cell[MAXCOLS];
    int n = split_row(l, cell, MAXCOLS);
    if (n > MAXCOLS) return 0;
    for (int i = 0; i < n; ++i) {
        Line c = cell[i];
        if (c.n == 0) return 0;
        int left = c.s[0] == ':', right = c.s[c.n - 1] == ':';
        int dashes = 0;
        for (int k = left; k < c.n - right; ++k) {
            if (c.s[k] != '-') return 0;
            ++dashes;
        }
        if (!dashes) return 0;
        align[i] = left && right ? 'c' : right ? 'r' : 'l';
    }
    return n;
}

static int interrupts(Line l) {
    long num;
    int content;
    Line t;
    char ch;
    int kind = item(l, &num, &content);
    return atx(l, &t) || fence(l, &ch) || is_hr(l) || quote(l) || kind == 1 || (kind == 2 && num == 1);
}

static void render(Line *L, int n, Ctx *ctx);

/* The wrapped cells[a..b) under ctx, each line in base colour. */
static void flow(Ctx *ctx, int a, int b, const char *base, Lines *lines) {
    wrap(a, b, ctx->width, lines);
    for (int i = 0; i < lines->n; ++i) {
        emit_prefix(ctx);
        emit_cells(lines->r[i].a, lines->r[i].b, base);
        fputc('\n', out);
    }
}

static void heading(Ctx *ctx, int level, int a, int b) {
    static const char *const base[] = {"1;35", "1;36", "1;32", "1", "1", "1"};
    Lines lines = {0};
    flow(ctx, a, b, color ? base[level - 1] : NULL, &lines);
    if (level <= 2 && lines.n) {
        int w = 0;
        for (int i = 0; i < lines.n; ++i) {
            int lw = range_width(lines.r[i].a, lines.r[i].b);
            if (lw > w) w = lw;
        }
        emit_prefix(ctx);
        repeat(level == 1 ? '=' : '-', w, level == 1 ? "\033[35m" : "\033[36m");
        fputc('\n', out);
    }
    free(lines.r);
}

static void code_line(Ctx *ctx, Line l) {
    emit_prefix(ctx);
    spaces(4);
    if (color) fputs("\033[33m", out);
    fwrite((void *)l.s, 1, l.n, out); /* libc: fwrite(void *, ...) */
    if (color) fputs(OFF, out);
    fputc('\n', out);
}

static void table(Ctx *ctx, Line *L, int n, char *align, int ncol) {
    /* every cell rendered into cells[], remembered by offset */
    int (*span)[MAXCOLS][2] = malloc(sizeof(*span) * n);
    if (!span) return;
    int nat[MAXCOLS] = {0}, w[MAXCOLS];
    int base = ncells;
    for (int r = 0; r < n; ++r) {
        Line cell[MAXCOLS];
        int got = split_row(L[r], cell, MAXCOLS);
        for (int c = 0; c < ncol; ++c) {
            span[r][c][0] = ncells;
            if (c < got) inl(cell[c].s, cell[c].n, 0);
            span[r][c][1] = ncells;
            /* widest stretch between hard breaks */
            int lw = 0;
            for (int k = span[r][c][0]; k <= span[r][c][1]; ++k) {
                if (k == span[r][c][1] || cells[k].ch == '\n') {
                    if (lw > nat[c]) nat[c] = lw;
                    lw = 0;
                } else {
                    lw += vis(cells[k].ch);
                }
            }
        }
    }
    int avail = ctx->width - (3 * ncol + 1), sum = 0;
    for (int c = 0; c < ncol; ++c) {
        w[c] = nat[c] ? nat[c] : 1;
        sum += w[c];
    }
    while (sum > avail) { /* narrow the widest column until it fits */
        int wide = 0;
        for (int c = 1; c < ncol; ++c)
            if (w[c] > w[wide]) wide = c;
        if (w[wide] <= 3) break;
        --w[wide];
        --sum;
    }

    const char *bd = color ? DIM : "", *off = color ? OFF : "";
    Lines cl[MAXCOLS];
    memset(cl, 0, sizeof(cl));
    /* a rule between body rows once any of them takes two lines */
    int ruled = 0;
    for (int r = 1; r < n && !ruled; ++r)
        for (int c = 0; c < ncol && !ruled; ++c) {
            wrap(span[r][c][0], span[r][c][1], w[c], &cl[c]);
            ruled = cl[c].n > 1;
        }
    for (int r = -1; r <= n; ++r) {
        if (r == -1 || r == 1 || r == n || (ruled && r > 1)) { /* top, under the header, bottom */
            emit_prefix(ctx);
            fputs(bd, out);
            fputc('+', out);
            for (int c = 0; c < ncol; ++c) {
                for (int k = 0; k < w[c] + 2; ++k) fputc(r == 1 ? '=' : '-', out);
                fputc('+', out);
            }
            fputs(off, out);
            fputc('\n', out);
            if (r == -1 || r == n) continue;
        }
        int height = 1;
        for (int c = 0; c < ncol; ++c) {
            wrap(span[r][c][0], span[r][c][1], w[c], &cl[c]);
            if (cl[c].n > height) height = cl[c].n;
        }
        for (int h = 0; h < height; ++h) {
            emit_prefix(ctx);
            for (int c = 0; c < ncol; ++c) {
                fprintf(out, "%s|%s ", bd, off);
                int a = 0, b = 0;
                if (h < cl[c].n) a = cl[c].r[h].a, b = cl[c].r[h].b;
                int pad = w[c] - range_width(a, b), left = 0;
                if (pad < 0) pad = 0;
                if (align[c] == 'r') left = pad;
                if (align[c] == 'c') left = pad / 2;
                spaces(left);
                emit_cells(a, b, r == 0 && color ? "1" : NULL);
                spaces(pad - left + 1);
            }
            fprintf(out, "%s|%s\n", bd, off);
        }
    }
    for (int c = 0; c < ncol; ++c) free(cl[c].r);
    free(span);
    ncells = base;
}

/* A list starting at L[0]; returns the lines it took. */
static int list(Ctx *ctx, Line *L, int n) {
    long num = 1, first_num = 1;
    int content, kind = item(L[0], &first_num, &content);
    char bullet = "*-+"[ctx->list_depth % 3];

    /* find the items and whether the list is loose */
    int starts[256], ends[256], nitems = 0, loose = 0, i = 0;
    while (i < n && nitems < 256) {
        int k = item(L[i], &num, &content);
        if (k != kind) break;
        starts[nitems] = i;
        int j = i + 1, prev_blank = 0;
        while (j < n) {
            if (blank(L[j])) {
                prev_blank = 1;
                ++j;
                continue;
            }
            if (indent_of(L[j]) >= content) {
                if (prev_blank) loose = 1;
                prev_blank = 0;
                ++j;
                continue;
            }
            if (!prev_blank && !interrupts(L[j]) && !item(L[j], &num, &content)) { /* lazy continuation */
                ++j;
                continue;
            }
            break;
        }
        int e = j;
        while (e > i + 1 && blank(L[e - 1])) --e;
        ends[nitems++] = e;
        if (j < n && e < j && item(L[j], &num, &content) == kind) loose = 1;
        i = j;
    }

    long maxnum = first_num + nitems - 1;
    int numw = 1;
    for (long v = maxnum; v >= 10; v /= 10) ++numw;

    for (int it = 0; it < nitems; ++it) {
        Line *sub = malloc(sizeof(Line) * (ends[it] - starts[it]));
        if (!sub) break;
        item(L[starts[it]], &num, &content);
        int ns = 0;
        Line firstl = skip(L[starts[it]], content);
        if (!blank(firstl)) sub[ns++] = firstl;
        for (int j = starts[it] + 1; j < ends[it]; ++j) {
            int ind = indent_of(L[j]);
            sub[ns++] = skip(L[j], ind < content ? ind : content);
        }

        Ctx child = {0};
        child.parent = ctx;
        child.first_pending = 1;
        child.tight = !loose;
        child.list_depth = ctx->list_depth + 1;
        int mw = kind == 1 ? 2 : numw + 2;
        if (kind == 1)
            snprintf(child.first, sizeof(child.first), "%s%c%s ", color ? "\033[36m" : "", bullet, color ? OFF : "");
        else
            snprintf(child.first, sizeof(child.first), "%s%*ld.%s ", color ? "\033[36m" : "", numw, first_num + it,
                     color ? OFF : "");
        /* task list: [ ] / [x] */
        if (ns && sub[0].n >= 3 && sub[0].s[0] == '[' && sub[0].s[2] == ']' &&
            (sub[0].s[1] == ' ' || sub[0].s[1] == 'x' || sub[0].s[1] == 'X') && (sub[0].n == 3 || sub[0].s[3] == ' ')) {
            int done = sub[0].s[1] != ' ';
            size_t used = strlen(child.first);
            snprintf(child.first + used, sizeof(child.first) - used, "%s[%c]%s ",
                     color ? (done ? "\033[32m" : DIM) : "", done ? 'x' : ' ', color ? OFF : "");
            mw += 4;
            sub[0] = skip(sub[0], 4);
        }
        memset(child.rest, ' ', mw);
        child.rest[mw] = 0;
        child.width = ctx->width - mw;
        if (child.width < 10) child.width = 10;

        if (it > 0 && loose) {
            emit_prefix(ctx);
            fputc('\n', out);
        }
        if (ns)
            render(sub, ns, &child);
        else {
            emit_prefix(&child);
            fputc('\n', out);
        }
        free(sub);
    }
    return nitems ? ends[nitems - 1] : 1;
}

static void render(Line *L, int n, Ctx *ctx) {
    Lines lines = {0};
    int i = 0;
    while (i < n) {
        Line l = L[i], t;
        char ch;
        long num;
        int content, lv, r;
        if (blank(l)) {
            ++i;
            continue;
        }
        if ((r = fence(l, &ch)) > 0) {
            gap(ctx);
            int ind = indent_of(l), j = i + 1;
            for (; j < n; ++j) {
                char c2;
                if (fence(L[j], &c2) >= r && c2 == ch && trim(L[j]).n == run_of(trim(L[j]).s, trim(L[j]).n, 0))
                    break;
                int li = indent_of(L[j]);
                code_line(ctx, skip(L[j], li < ind ? li : ind));
            }
            i = j + 1;
        } else if (indent_of(l) >= 4) {
            gap(ctx);
            int j = i, e = i;
            for (; j < n && (blank(L[j]) || indent_of(L[j]) >= 4); ++j)
                if (!blank(L[j])) e = j + 1;
            for (int k = i; k < e; ++k) code_line(ctx, skip(L[k], 4));
            i = e;
        } else if ((lv = atx(l, &t)) > 0) {
            gap(ctx);
            int a = ncells;
            inl(t.s, t.n, 0);
            heading(ctx, lv, a, ncells);
            ncells = a;
            ++i;
        } else if (is_hr(l)) {
            gap(ctx);
            emit_prefix(ctx);
            repeat('-', ctx->width, DIM);
            fputc('\n', out);
            ++i;
        } else if (quote(l)) {
            gap(ctx);
            int j = i;
            Line *sub = malloc(sizeof(Line) * (n - i));
            if (!sub) return;
            int ns = 0;
            for (; j < n; ++j) {
                if (quote(L[j])) {
                    Line q = skip(L[j], indent_of(L[j]) + 1);
                    if (q.n && q.s[0] == ' ') q = skip(q, 1);
                    sub[ns++] = q;
                } else if (!blank(L[j]) && ns && !blank(sub[ns - 1]) && !interrupts(L[j])) {
                    sub[ns++] = L[j]; /* lazy continuation */
                } else {
                    break;
                }
            }
            Ctx child = {0};
            child.parent = ctx;
            snprintf(child.first, sizeof(child.first), "%s|%s ", color ? DIM : "", color ? OFF : "");
            strcpy(child.rest, child.first);
            child.width = ctx->width - 2;
            child.list_depth = ctx->list_depth;
            render(sub, ns, &child);
            free(sub);
            i = j;
        } else if (item(l, &num, &content)) {
            gap(ctx);
            i += list(ctx, L + i, n - i);
        } else {
            char align[MAXCOLS];
            int ncol;
            if (memchr(l.s, '|', l.n) && i + 1 < n && (ncol = table_sep(L[i + 1], align)) > 0) {
                Line hdr[MAXCOLS];
                if (split_row(l, hdr, MAXCOLS) == ncol) {
                    int j = i + 2;
                    while (j < n && !blank(L[j]) && memchr(L[j].s, '|', L[j].n)) ++j;
                    Line *rows = malloc(sizeof(Line) * (j - i - 1));
                    if (!rows) return;
                    rows[0] = l;
                    for (int k = i + 2; k < j; ++k) rows[k - i - 1] = L[k];
                    gap(ctx);
                    table(ctx, rows, j - i - 1, align, ncol);
                    free(rows);
                    i = j;
                    continue;
                }
            }
            /* paragraph, or a setext heading */
            gap(ctx);
            int a = ncells, j = i, level = 0;
            for (; j < n && !blank(L[j]); ++j) {
                if (j > i && (level = setext(L[j])) > 0) break;
                if (j > i && interrupts(L[j])) break;
                if (j > i && memchr(L[j].s, '|', L[j].n) && j + 1 < n && table_sep(L[j + 1], align)) break;
                Line raw = L[j], tl = trim(raw);
                int hard = (raw.n >= 2 && raw.s[raw.n - 1] == ' ' && raw.s[raw.n - 2] == ' ') ||
                           (tl.n && tl.s[tl.n - 1] == '\\');
                if (tl.n && tl.s[tl.n - 1] == '\\') --tl.n;
                if (j > i && !(ncells > a && cells[ncells - 1].ch == '\n')) put(' ', 0);
                inl(tl.s, tl.n, 0);
                if (hard) put('\n', 0);
            }
            while (ncells > a && (cells[ncells - 1].ch == '\n' || cells[ncells - 1].ch == ' ')) --ncells;
            if (level) {
                heading(ctx, level, a, ncells);
                ++j;
            } else {
                flow(ctx, a, ncells, NULL, &lines);
            }
            ncells = a;
            i = j;
        }
    }
    free(lines.r);
}

/* ---- input and the terminal --------------------------------------- */

static char *slurp(FILE *f, size_t *len) {
    size_t cap = 4096, n = 0;
    char *buf = malloc(cap);
    if (!buf) return NULL;
    for (;;) {
        if (cap - n < 1024) {
            char *p = realloc(buf, cap * 2);
            if (!p) {
                free(buf);
                return NULL;
            }
            buf = p;
            cap *= 2;
        }
        size_t got = fread(buf + n, 1, cap - n - 1, f);
        if (got == 0) break;
        n += got;
    }
    *len = n;
    return buf;
}

/* Tabs to 4-column stops, \r dropped, cut into lines. */
static Line *split_lines(const char *src, size_t len, int *count, char **store) {
    size_t tabs = 0;
    for (size_t k = 0; k < len; ++k) tabs += src[k] == '\t';
    char *buf = malloc(len + tabs * 3 + 1);
    int cap = 64, n = 0;
    Line *L = malloc(sizeof(Line) * cap);
    if (!buf || !L) return NULL;
    size_t o = 0, line_start = 0;
    for (size_t k = 0; k <= len; ++k) {
        if (k == len || src[k] == '\n') {
            if (k == len && o == line_start) break;
            if (n == cap) {
                cap *= 2;
                L = realloc(L, sizeof(Line) * cap);
                if (!L) return NULL;
            }
            L[n].s = buf + line_start;
            L[n].n = (int)(o - line_start);
            ++n;
            line_start = o;
        } else if (src[k] == '\t') {
            do buf[o++] = ' ';
            while ((o - line_start) % 4);
        } else if (src[k] != '\r') {
            buf[o++] = src[k];
        }
    }
    *count = n;
    *store = buf;
    return L;
}

static int raw_mode(struct termios *saved, int on) {
    if (on) {
        struct termios t;
        if (tcgetattr(STDIN_FILENO, saved) != 0) return 0;
        t = *saved;
        t.c_lflag &= ~(ICANON | ECHO);
        t.c_cc[VMIN] = 0;
        t.c_cc[VTIME] = 0;
        return tcsetattr(STDIN_FILENO, TCSAFLUSH, &t) == 0;
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, saved);
    return 1;
}

/* COLUMNS, else ask the terminal where column 999 is (as apps/more). */
static int detect_width(void) {
    const char *c = getenv("COLUMNS");
    if (c && atoi(c) > 10) return atoi(c);
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return 80;
    struct termios saved;
    if (!raw_mode(&saved, 1)) return 80;
    int flags = fcntl(STDIN_FILENO, F_GETFL);
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
    fputs("\0337\033[999;999H\033[6n\0338", stdout);
    fflush(stdout);
    char buf[32];
    int n = 0;
    for (int tries = 0; tries < 250 && n < (int)sizeof(buf) - 1; ++tries) {
        ssize_t r = read(STDIN_FILENO, buf + n, sizeof(buf) - 1 - n);
        if (r > 0) {
            n += (int)r;
            if (memchr(buf, 'R', n)) break;
        } else {
            struct timespec req = {0, 1000000};
            nanosleep(&req, NULL);
        }
    }
    fcntl(STDIN_FILENO, F_SETFL, flags);
    raw_mode(&saved, 0);
    buf[n] = 0;
    char *esc = memchr(buf, 0x1b, n);
    int r = 0, k = 0;
    if (esc && sscanf(esc, "\033[%d;%dR", &r, &k) == 2 && k > 10 && k <= 1000) return k;
    return 80;
}

static int cat(const char *path) {
    FILE *f = path ? fopen(path, "r") : stdin;
    if (!f) {
        fprintf(stderr, "mdcat: cannot open %s\n", path);
        return 1;
    }
    size_t len;
    char *src = slurp(f, &len);
    if (path) fclose(f);
    if (!src) {
        fputs("mdcat: out of memory\n", stderr);
        return 1;
    }
    int n;
    char *store;
    Line *L = split_lines(src, len, &n, &store);
    free(src);
    if (!L) {
        fputs("mdcat: out of memory\n", stderr);
        return 1;
    }
    Ctx top = {0};
    top.width = term_width;
    render(L, n, &top);
    free(L);
    free(store);
    return 0;
}

static void usage(void) {
    fputs("usage: mdcat [-p] [-c|-n] [-w COLS] [FILE...]\n", stderr);
    exit(2);
}

int main(int argc, char **argv) {
    int force = -1, page = 0, width = 0, i = 1;
    for (; i < argc && argv[i][0] == '-' && argv[i][1]; ++i) {
        const char *a = argv[i];
        if (!strcmp(a, "--")) {
            ++i;
            break;
        }
        for (int k = 1; a[k]; ++k) {
            if (a[k] == 'p')
                page = 1;
            else if (a[k] == 'c')
                force = 1;
            else if (a[k] == 'n')
                force = 0;
            else if (a[k] == 'w') {
                const char *v = a[k + 1] ? a + k + 1 : (i + 1 < argc ? argv[++i] : NULL);
                if (!v || (width = atoi(v)) < 10) usage();
                break;
            } else
                usage();
        }
    }

    int tty = isatty(STDOUT_FILENO);
    const char *term = getenv("TERM");
    color = force >= 0 ? force : (tty && !getenv("NO_COLOR") && !(term && !strcmp(term, "dumb")));
    term_width = width ? width : detect_width();

    char tmp[] = "/tmp/mdcatXXXXXX";
    out = stdout;
    if (page) {
        int fd = mkstemp(tmp);
        if (fd < 0 || !(out = fdopen(fd, "w"))) {
            fputs("mdcat: cannot create a file in /tmp\n", stderr);
            return 1;
        }
    }

    int rc = 0;
    if (i == argc)
        rc = cat(NULL);
    for (; i < argc; ++i) {
        rc |= cat(argv[i]);
        if (i + 1 < argc) fputc('\n', out);
    }
    if (!page) return rc;

    fclose(out);
    const char *pager = getenv("PAGER");
    if (!pager || !*pager) pager = "more";
    char *args[] = {(char *)pager, tmp, NULL};
    int pid = vfork();
    if (pid == 0) {
        execvp(pager, args);
        _exit(127);
    }
    int status = 0;
    if (pid > 0) waitpid(pid, &status, 0);
    unlink(tmp);
    if (pid < 0 || (WIFEXITED(status) && WEXITSTATUS(status) == 127)) {
        fprintf(stderr, "mdcat: cannot run %s\n", pager);
        return 1;
    }
    return rc;
}
