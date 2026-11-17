/*
 * more.c
 *
 * A small pager for YasOS: man pages, logs, source.  The whole file is held
 * in memory, so it can page backwards and search.
 *
 *   more FILE...        page through each FILE
 *   cmd | more          no keyboard to read: copies stdin to stdout
 *
 * Keys: space/f/PgDn next page, Enter/j/Down next line, b/PgUp previous
 * page, k/Up previous line, g/G first/last line, /text search forward,
 * n next match, N previous match (matches shown in reverse video, u
 * stops marking them), h help, q quit (next file, if any).
 *
 * The keyboard is stdin (YasOS has no /dev/tty), so a file is always named
 * on the command line.  Output that isn't a terminal is copied straight
 * through.  The size comes from LINES/COLUMNS, else from asking the
 * terminal (ESC[6n, see libs/yasos_curses detect_terminal_size()), else
 * 24x80.
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
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int rows = 24, cols = 80;
static struct termios saved_termios;
static int raw_on;

static char *text;      /* the file, NUL-terminated */
static size_t text_len;
static size_t *line_at; /* offset of each line */
static int line_count;
static char last_search[128];
static int highlight = 1; /* mark matches of last_search; u turns it off */

static void out(const char *s, size_t n) {
    while (n > 0) {
        ssize_t w = write(STDOUT_FILENO, s, n);
        if (w <= 0) return;
        s += w;
        n -= (size_t)w;
    }
}

static void outs(const char *s) {
    out(s, strlen(s));
}

static void raw_mode(int on) {
    if (on && !raw_on) {
        struct termios t;
        if (tcgetattr(STDIN_FILENO, &saved_termios) != 0) return;
        t = saved_termios;
        t.c_lflag &= ~(ICANON | ECHO);
        t.c_cc[VMIN] = 1;
        t.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &t);
        raw_on = 1;
    } else if (!on && raw_on) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_termios);
        raw_on = 0;
    }
}

static int read_key(void) {
    unsigned char c;
    if (read(STDIN_FILENO, &c, 1) != 1) return 'q';
    if (c != 0x1b) return c;
    /* ESC [ A/B (arrows), ESC [ 5~ / 6~ (PgUp/PgDn); a lone ESC quits. */
    unsigned char seq[3];
    if (read(STDIN_FILENO, &seq[0], 1) != 1 || seq[0] != '[') return 'q';
    if (read(STDIN_FILENO, &seq[1], 1) != 1) return 'q';
    switch (seq[1]) {
    case 'A': return 'k';
    case 'B': return 'j';
    case 'H': return 'g';
    case 'F': return 'G';
    case '5':
    case '6':
        if (read(STDIN_FILENO, &seq[2], 1) != 1) return 'q';
        return seq[1] == '5' ? 'b' : ' ';
    }
    return 0;
}

/* Ask the terminal for its size: move to 999;999, read back the position. */
static void detect_size(void) {
    const char *l = getenv("LINES"), *c = getenv("COLUMNS");
    if (l && c && atoi(l) > 1 && atoi(c) > 1) {
        rows = atoi(l);
        cols = atoi(c);
        return;
    }
    int flags = fcntl(STDIN_FILENO, F_GETFL);
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
    outs("\0337\033[999;999H\033[6n\0338");
    char buf[32];
    int n = 0;
    for (int tries = 0; tries < 250 && n < (int)sizeof(buf) - 1; ++tries) {
        ssize_t r = read(STDIN_FILENO, buf + n, sizeof(buf) - 1 - n);
        if (r > 0) {
            n += (int)r;
            if (memchr(buf, 'R', n)) break;
        } else {
            struct timespec req = {0, 1000000}; /* 1 ms */
            nanosleep(&req, NULL);
        }
    }
    fcntl(STDIN_FILENO, F_SETFL, flags);
    buf[n] = 0;
    char *esc = memchr(buf, 0x1b, n);
    int r = 0, k = 0;
    if (esc && sscanf(esc, "\033[%d;%dR", &r, &k) == 2 && r >= 2 && r <= 1000 && k >= 2 && k <= 1000) {
        rows = r;
        cols = k;
    }
}

static int load(FILE *f) {
    size_t cap = 4096;
    text_len = 0;
    text = malloc(cap);
    if (!text) return -1;
    for (;;) {
        if (cap - text_len < 2048) {
            char *p = realloc(text, cap * 2);
            if (!p) return -1;
            text = p;
            cap *= 2;
        }
        size_t got = fread(text + text_len, 1, cap - text_len - 1, f);
        if (got == 0) break;
        text_len += got;
    }
    text[text_len] = 0;

    int cap_lines = 256;
    line_at = malloc(sizeof(size_t) * cap_lines);
    if (!line_at) return -1;
    line_count = 0;
    size_t pos = 0;
    while (pos < text_len) {
        if (line_count == cap_lines) {
            size_t *p = realloc(line_at, sizeof(size_t) * cap_lines * 2);
            if (!p) return -1;
            line_at = p;
            cap_lines *= 2;
        }
        line_at[line_count++] = pos;
        char *nl = memchr(text + pos, '\n', text_len - pos);
        pos = nl ? (size_t)(nl - text) + 1 : text_len;
    }
    return 0;
}

static size_t line_len(int i) {
    size_t start = line_at[i];
    size_t end = (i + 1 < line_count) ? line_at[i + 1] : text_len;
    while (end > start && (text[end - 1] == '\n' || text[end - 1] == '\r')) --end;
    return end - start;
}

/* Screen rows a line takes when the terminal wraps it (tabs to 8). */
static int line_rows(int i) {
    size_t n = line_len(i);
    const char *s = text + line_at[i];
    int width = 0;
    for (size_t k = 0; k < n; ++k) width = (s[k] == '\t') ? (width / 8 + 1) * 8 : width + 1;
    return width <= cols ? 1 : (width + cols - 1) / cols;
}

/* Where pat starts in s[0..n), case-insensitively; n when it does not. */
static size_t find_ci(const char *s, size_t n, const char *pat, size_t m) {
    for (size_t k = 0; m && k + m <= n; ++k) {
        size_t j = 0;
        while (j < m && tolower((unsigned char)s[k + j]) == tolower((unsigned char)pat[j])) ++j;
        if (j == m) return k;
    }
    return n;
}

static void show_line(int i) {
    size_t n = line_len(i);
    const char *s = text + line_at[i];
    /* Strip overstrike (x\bx bold, _\bx underline) left by nroff. */
    static char *clean;
    static size_t clean_cap;
    if (n + 1 > clean_cap) {
        char *p = realloc(clean, n + 1);
        if (!p) {
            out(s, n);
            outs("\r\n");
            return;
        }
        clean = p;
        clean_cap = n + 1;
    }
    size_t used = 0;
    for (size_t k = 0; k < n; ++k) {
        if (k + 1 < n && s[k + 1] == '\b') {
            ++k;
            continue;
        }
        clean[used++] = s[k];
    }
    /* Every match of the last search in reverse video: the escapes take no
       columns, so line_rows() still counts right. */
    size_t m = highlight ? strlen(last_search) : 0;
    size_t pos = 0;
    while (pos < used) {
        size_t hit = find_ci(clean + pos, used - pos, last_search, m);
        out(clean + pos, hit);
        if (pos + hit >= used) break;
        outs("\033[7m");
        out(clean + pos + hit, m);
        outs("\033[0m");
        pos += hit + m;
    }
    outs("\r\n");
}

/* Draw from line top; returns the first line not shown. */
static int draw_page(int top) {
    outs("\033[H\033[2J");
    int used = 0, i = top;
    while (i < line_count) {
        int r = line_rows(i);
        if (used + r > rows - 1 && used > 0) break;
        show_line(i);
        used += r;
        ++i;
    }
    return i;
}

static void prompt(const char *name, int next) {
    char buf[160];
    int pct = line_count ? (int)((long)next * 100 / line_count) : 100;
    snprintf(buf, sizeof(buf), "\033[7m%s %s(%d%%) h:help q:quit\033[0m", name,
             next >= line_count ? "(END) " : "", pct);
    outs("\r\033[K");
    outs(buf);
}

/* The first line of the page that ends just before line end. */
static int page_before(int end) {
    int used = 0, i = end;
    while (i > 0 && used + line_rows(i - 1) <= rows - 1) {
        used += line_rows(i - 1);
        --i;
    }
    return i;
}

static int contains(int i, const char *pat) {
    size_t n = line_len(i), m = strlen(pat);
    return m && find_ci(text + line_at[i], n, pat, m) < n;
}

static int search(int from, int dir) {
    for (int i = from; i >= 0 && i < line_count; i += dir)
        if (contains(i, last_search)) return i;
    return -1;
}

static void read_pattern(void) {
    char buf[sizeof(last_search)];
    int n = 0;
    outs("\r\033[K/");
    for (;;) {
        int c = read_key();
        if (c == '\r' || c == '\n') break;
        if (c == 'q' && n == 0) return;
        if ((c == 0x7f || c == '\b') && n > 0) {
            --n;
            outs("\b \b");
            continue;
        }
        if (c >= ' ' && c < 0x7f && n < (int)sizeof(buf) - 1) {
            buf[n++] = (char)c;
            char e = (char)c;
            out(&e, 1);
        }
    }
    if (n > 0) {
        buf[n] = 0;
        memcpy(last_search, buf, n + 1);
        highlight = 1;
    }
}

static const char help_text[] =
    "\033[H\033[2J"
    "more: keys\r\n\r\n"
    "  space f PgDn    next page\r\n"
    "  Enter j Down    next line\r\n"
    "  b PgUp          previous page\r\n"
    "  k Up            previous line\r\n"
    "  g G             first / last line\r\n"
    "  /text           search forward (case-insensitive)\r\n"
    "  n N             next / previous match (matches in reverse video)\r\n"
    "  u               stop marking the matches (n/N mark them again)\r\n"
    "  q               quit (next file)\r\n\r\n"
    "any key to go back";

/* Returns 1 to quit everything, 0 to go on to the next file. */
static int page(const char *name) {
    int top = 0;
    for (;;) {
        int next = draw_page(top);
        prompt(name, next);
        int c = read_key();
        switch (c) {
        case 'q':
        case 'Q':
            outs("\r\033[K");
            return c == 'Q';
        case ' ':
        case 'f':
            if (next < line_count) top = next;
            else return 0;
            break;
        case '\r':
        case '\n':
        case 'j':
            if (next < line_count) ++top;
            else return 0;
            break;
        case 'b':
            top = page_before(top);
            break;
        case 'k':
            if (top > 0) --top;
            break;
        case 'g':
            top = 0;
            break;
        case 'G':
            top = page_before(line_count);
            break;
        case 'u':
            highlight = 0;
            break;
        case '/':
            read_pattern();
            /* fall through */
        case 'n': {
            highlight = 1;
            int hit = last_search[0] ? search(top + 1, 1) : -1;
            if (hit >= 0) top = hit;
            break;
        }
        case 'N': {
            highlight = 1;
            int hit = last_search[0] ? search(top - 1, -1) : -1;
            if (hit >= 0) top = hit;
            break;
        }
        case 'h':
        case '?':
            outs(help_text);
            read_key();
            break;
        }
    }
}

static int copy(FILE *f) {
    char buf[1024];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out(buf, n);
    return 0;
}

int main(int argc, char **argv) {
    int interactive = isatty(STDOUT_FILENO) && isatty(STDIN_FILENO);
    if (argc < 2) return copy(stdin);
    if (interactive) {
        raw_mode(1);
        detect_size();
    }
    int rc = 0;
    for (int a = 1; a < argc; ++a) {
        FILE *f = fopen(argv[a], "rb");
        if (!f) {
            raw_mode(0);
            fprintf(stderr, "more: cannot open %s\n", argv[a]);
            rc = 1;
            if (interactive) raw_mode(1);
            continue;
        }
        if (!interactive) {
            copy(f);
            fclose(f);
            continue;
        }
        if (load(f) != 0) {
            raw_mode(0);
            fprintf(stderr, "more: out of memory for %s\n", argv[a]);
            fclose(f);
            return 1;
        }
        fclose(f);
        int quit = page(argv[a]);
        free(text);
        free(line_at);
        if (quit) break;
    }
    if (interactive) {
        raw_mode(0);
        outs("\r\n");
    }
    return rc;
}
