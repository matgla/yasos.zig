/* ccat -- cat(1) with the C coloured in, small enough for the board.
 *
 * Written for the video: the take shows a gcc.c-torture test on the board and
 * then compiles it there, and a wall of white text is a poor way to show
 * somebody a program.  `bat` would have done this and cannot come here -- it
 * is Rust on top of libgit2 and libonig, and the board has tcc and a C
 * library.  So this is the same idea at a size the board can hold: one pass
 * over each line, no tables, no allocation.
 *
 * Colours are ANSI *indices*, never RGB, so they resolve through whatever the
 * terminal's sixteen are set to.  In a take that is the project's palette
 * (generated from its visual_style.json), and on anybody else's terminal it is
 * their own scheme -- which is the behaviour a small tool should have.
 *
 * Deliberately not a parser.  It knows strings, character literals, both kinds
 * of comment, preprocessor lines, numbers and a keyword list, because that is
 * what makes a listing readable; it does not know types, scopes or macros, and
 * a construct it misreads costs a colour rather than a wrong answer.
 *
 *   ccat [-p] [-n] FILE...      -p plain (no colour), -n number the lines
 */
#include <stdio.h>
#include <string.h>

#define OFF   "\033[0m"
#define KW    "\033[35m"      /* keyword          -- the palette's violet */
#define STR   "\033[33m"      /* string, char     -- amber                */
#define CMT   "\033[32m"      /* comment          -- green                */
#define NUM   "\033[34m"      /* number           -- accent blue          */
#define PP    "\033[36m"      /* preprocessor     -- cyan                 */
#define LNO   "\033[90m"      /* the line number itself                   */

static const char *KEYWORDS[] = {
    "auto", "break", "case", "char", "const", "continue", "default", "do",
    "double", "else", "enum", "extern", "float", "for", "goto", "if",
    "inline", "int", "long", "register", "restrict", "return", "short",
    "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
    "unsigned", "void", "volatile", "while", "_Bool", "_Complex", "_Noreturn",
    0
};

static int is_word(int c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

static int is_digit(int c) { return c >= '0' && c <= '9'; }

static int keyword(const char *s, int n)
{
    int i;
    for (i = 0; KEYWORDS[i]; i++)
        if ((int)strlen(KEYWORDS[i]) == n && strncmp(KEYWORDS[i], s, n) == 0)
            return 1;
    return 0;
}

/* One line, with *in_comment* carried in and out: a block comment that opens
 * on one line and closes three lines later has to keep colouring the lines
 * between, which is the whole reason this is not a per-line function. */
static void emit(const char *line, int *in_comment, int colour)
{
    int i = 0, n = (int)strlen(line);

    if (!colour) {
        fputs(line, stdout);
        return;
    }

    /* A preprocessor line is coloured whole: `#include <stdio.h>` reads as one
     * thing, and lexing the `<stdio.h>` as a comparison is exactly the kind of
     * wrong answer a listing does not need. */
    if (!*in_comment) {
        int j = 0;
        while (j < n && (line[j] == ' ' || line[j] == '\t')) j++;
        if (j < n && line[j] == '#') {
            printf("%.*s%s%s%s", j, line, PP, line + j, OFF);
            return;
        }
    }

    while (i < n) {
        if (*in_comment) {
            int start = i;
            while (i < n && !(line[i] == '*' && i + 1 < n && line[i + 1] == '/'))
                i++;
            if (i < n) { i += 2; *in_comment = 0; }
            printf("%s%.*s%s", CMT, i - start, line + start, OFF);
            continue;
        }
        if (line[i] == '/' && i + 1 < n && line[i + 1] == '*') {
            *in_comment = 1;
            i += 2;
            printf("%s/*", CMT);
            /* the OFF is emitted by the branch above, once it closes */
            {
                int start = i;
                while (i < n && !(line[i] == '*' && i + 1 < n && line[i + 1] == '/'))
                    i++;
                if (i < n) { i += 2; *in_comment = 0; }
                printf("%.*s%s", i - start, line + start, OFF);
            }
            continue;
        }
        if (line[i] == '/' && i + 1 < n && line[i + 1] == '/') {
            printf("%s%s%s", CMT, line + i, OFF);
            return;
        }
        if (line[i] == '"' || line[i] == '\'') {
            char quote = line[i];
            int start = i++;
            while (i < n && line[i] != quote) {
                if (line[i] == '\\' && i + 1 < n) i++;
                i++;
            }
            if (i < n) i++;
            printf("%s%.*s%s", STR, i - start, line + start, OFF);
            continue;
        }
        if (is_digit(line[i]) && (i == 0 || !is_word(line[i - 1]))) {
            int start = i;
            while (i < n && (is_word(line[i]) || line[i] == '.')) i++;
            printf("%s%.*s%s", NUM, i - start, line + start, OFF);
            continue;
        }
        if (is_word(line[i])) {
            int start = i;
            while (i < n && is_word(line[i])) i++;
            if (keyword(line + start, i - start))
                printf("%s%.*s%s", KW, i - start, line + start, OFF);
            else
                printf("%.*s", i - start, line + start);
            continue;
        }
        putchar(line[i++]);
    }
}

static int show(const char *path, int colour, int numbers)
{
    char line[1024];
    int in_comment = 0, no = 0;
    FILE *fh = fopen(path, "r");

    if (!fh) {
        fprintf(stderr, "ccat: cannot open %s\n", path);
        return 1;
    }
    while (fgets(line, sizeof line, fh)) {
        if (numbers) {
            if (colour) printf("%s%5d%s  ", LNO, ++no, OFF);
            else        printf("%5d  ", ++no);
        }
        emit(line, &in_comment, colour);
    }
    fclose(fh);
    return 0;
}

int main(int argc, char **argv)
{
    int colour = 1, numbers = 0, i, bad = 0, files = 0;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0)      colour = 0;
        else if (strcmp(argv[i], "-n") == 0) numbers = 1;
        else { files++; bad |= show(argv[i], colour, numbers); }
    }
    if (!files) {
        fprintf(stderr, "usage: ccat [-p] [-n] FILE...\n");
        return 2;
    }
    return bad;
}
