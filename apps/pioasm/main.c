/*
 * main.c
 *
 * pioasm's command line, as the SDK's: pioasm [-o format] [-p param]
 * [-v version] <input> [<output>].
 *
 * Copyright (c) 2020 Raspberry Pi (Trading) Ltd. (the original pioasm)
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com> (the C port)
 *
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "pioasm.h"

#include <errno.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

static const char *source_name = "-";

void *xmalloc(size_t size) {
    void *p = malloc(size ? size : 1);
    if (!p) {
        fprintf(stderr, "pioasm: out of memory\n");
        exit(1);
    }
    return p;
}

char *xstrndup(const char *s, size_t n) {
    char *d = xmalloc(n + 1);
    memcpy(d, s, n);
    d[n] = 0;
    return d;
}

char *xstrdup(const char *s) {
    return xstrndup(s, strlen(s));
}

static void report(Loc loc, const char *fmt, va_list ap) {
    fprintf(stderr, "%s:%d.%d", source_name, loc.line, loc.column);
    if (loc.end_column > loc.column + 1) fprintf(stderr, "-%d", loc.end_column - 1);
    fprintf(stderr, ": ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
}

_Noreturn void fail(Loc loc, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    report(loc, fmt, ap);
    va_end(ap);
    exit(1);
}

void warn(Loc loc, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    report(loc, fmt, ap);
    va_end(ap);
}

static char *read_all(const char *path) {
    FILE *f = strcmp(path, "-") ? fopen(path, "rb") : stdin;
    size_t cap = 4096, len = 0, n;
    char *buf;
    if (!f) {
        fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
        exit(1);
    }
    buf = xmalloc(cap);
    while ((n = fread(buf + len, 1, cap - len - 1, f)) > 0) {
        len += n;
        if (len + 1 == cap) {
            cap *= 2;
            buf = realloc(buf, cap);
            if (!buf) {
                fprintf(stderr, "pioasm: out of memory\n");
                exit(1);
            }
        }
    }
    buf[len] = 0;
    if (f != stdin) fclose(f);
    return buf;
}

static void usage(void) {
    fprintf(stderr, "usage: pioasm <options> <input> (<output>)\n\n");
    fprintf(stderr, "Assemble file of PIO program(s) for use in applications.\n");
    fprintf(stderr, "   <input>             the input filename\n");
    fprintf(stderr, "   <output>            the output filename; if not specified, the output is written to stdout\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "options:\n");
    fprintf(stderr, "  -o <output_format>   select output_format (default 'c-sdk'); available options are:\n");
    fprintf(stderr, "                           c-sdk\n");
    fprintf(stderr, "                               C header suitable for use with the Raspberry Pi Pico SDK\n");
    fprintf(stderr, "                           zig\n");
    fprintf(stderr, "                               Zig declarations, for use without translate-c\n");
    fprintf(stderr, "                           hex\n");
    fprintf(stderr, "                               Raw hex output (only valid for single program inputs)\n");
    fprintf(stderr, "  -p <output_param>    add a parameter to be passed to the output format generator\n");
    fprintf(stderr, "  -v <version>         specify the default PIO version (0 or 1)\n");
    fprintf(stderr, "  -?, --help           print this help and exit\n");
}

int main(int argc, char *argv[]) {
    const char *format = "c-sdk";
    const char *input = NULL;
    const char *output = "-";
    int version = 0;
    int i = 1;
    int res = 0;
    Assembler *as;
    FILE *out;

    for (; i < argc && argv[i][0] == '-' && argv[i][1]; i++) {
        if (!strcmp(argv[i], "-o") || !strcmp(argv[i], "-p") || !strcmp(argv[i], "-v")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "error: %s requires a value\n", argv[i]);
                res = 1;
                break;
            }
            if (argv[i][1] == 'o') {
                format = argv[++i];
            } else if (argv[i][1] == 'v') {
                i++;
                if (!strcmp(argv[i], "0"))
                    version = 0;
                else if (!strcmp(argv[i], "1"))
                    version = 1;
                else {
                    fprintf(stderr, "error: unsupported PIO version '%s'\n", argv[i]);
                    res = 1;
                    break;
                }
            } else {
                i++; /* no format of ours takes parameters */
            }
        } else if (!strcmp(argv[i], "-?") || !strcmp(argv[i], "--help")) {
            usage();
            return 1;
        } else {
            fprintf(stderr, "error: unknown option %s\n", argv[i]);
            res = 1;
            break;
        }
    }
    if (!res) {
        if (i < argc) {
            input = argv[i++];
        } else {
            fprintf(stderr, "error: expected input filename\n");
            res = 1;
        }
    }
    if (!res && i < argc) output = argv[i++];
    if (!res && i < argc) {
        fprintf(stderr, "unexpected command line argument %s\n", argv[i]);
        res = 1;
    }
    if (!res && strcmp(format, "c-sdk") && strcmp(format, "zig") && strcmp(format, "hex")) {
        fprintf(stderr, "error: unknown output format '%s'\n", format);
        res = 1;
    }
    if (res) {
        fprintf(stderr, "\n");
        usage();
        return res;
    }

    source_name = input;
    as = assembler_new(input, version);
    parse_file(as, read_all(input));
    assemble(as);
    if (!as->program_count) {
        printf("warning: input contained no programs\n");
        fflush(stdout);
    }
    if (!strcmp(format, "hex") && !as->program_count) return 1;

    out = strcmp(output, "-") ? fopen(output, "w") : stdout;
    if (!out) {
        fprintf(stderr, "Can't open output file '%s'\n", output);
        return 1;
    }
    if (!strcmp(format, "c-sdk"))
        res = output_c_sdk(as, out);
    else if (!strcmp(format, "zig"))
        res = output_zig(as, out);
    else
        res = output_hex(as, out);
    if (out != stdout) fclose(out);
    return res;
}
