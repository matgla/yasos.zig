/*
 * Copyright (c) 2026 Mateusz Stadnik
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

/* define_filter OUT.h IN.h ZIG...
 *
 * IN.h is `gcc -E -dD` output: the C code with every macro already expanded,
 * plus a #define line per macro.  translate-c turns each #define into a Zig
 * declaration, and the pico-sdk register headers define ~32k of them per
 * header -- every one parsed, lowered and scanned by every compile that
 * imports the module (the device Zig compiler could not hold the lowering).
 * The Zig code reads a few hundred.  OUT.h keeps every line that is not a
 * #define or #undef, and the #define/#undef lines of the macros named in the
 * ZIG files (any identifier-shaped word, comments and strings included) or in
 * the body of a macro kept, transitively.  The C declarations need none of the
 * macros: -E expanded them. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(const char *m, const char *a)
{
  fprintf(stderr, "define_filter: %s%s\n", m, a ? a : "");
  exit(1);
}

static char *slurp(const char *path, size_t *len)
{
  FILE *f = fopen(path, "rb");
  if (!f)
    die("cannot read ", path);
  size_t cap = 1 << 16, n = 0;
  char *b = malloc(cap + 1);
  for (;;)
  {
    if (!b)
      die("out of memory", NULL);
    size_t k = fread(b + n, 1, cap - n, f);
    n += k;
    if (n < cap)
      break;
    cap *= 2;
    b = realloc(b, cap + 1);
  }
  if (ferror(f))
    die("cannot read ", path);
  fclose(f);
  b[n] = 0;
  *len = n;
  return b;
}

/* A set of words (pointer + length into buffers that outlive it). */
typedef struct
{
  const char **s;
  size_t *n;
  size_t cap, count;
} Set;

static size_t hash(const char *s, size_t n)
{
  size_t h = 1469598103934665603ull;
  for (size_t i = 0; i < n; i++)
    h = (h ^ (unsigned char)s[i]) * 1099511628211ull;
  return h;
}

static void set_grow(Set *t);

/* Adds the word; returns 1 if it was not there. */
static int set_add(Set *t, const char *s, size_t n)
{
  if ((t->count + 1) * 2 > t->cap)
    set_grow(t);
  size_t i = hash(s, n) & (t->cap - 1);
  while (t->s[i])
  {
    if (t->n[i] == n && memcmp(t->s[i], s, n) == 0)
      return 0;
    i = (i + 1) & (t->cap - 1);
  }
  t->s[i] = s;
  t->n[i] = n;
  t->count++;
  return 1;
}

static int set_has(const Set *t, const char *s, size_t n)
{
  if (!t->cap)
    return 0;
  size_t i = hash(s, n) & (t->cap - 1);
  while (t->s[i])
  {
    if (t->n[i] == n && memcmp(t->s[i], s, n) == 0)
      return 1;
    i = (i + 1) & (t->cap - 1);
  }
  return 0;
}

static void set_grow(Set *t)
{
  Set old = *t;
  t->cap = old.cap ? old.cap * 2 : 1024;
  t->s = calloc(t->cap, sizeof *t->s);
  t->n = calloc(t->cap, sizeof *t->n);
  if (!t->s || !t->n)
    die("out of memory", NULL);
  t->count = 0;
  for (size_t i = 0; i < old.cap; i++)
    if (old.s[i])
      set_add(t, old.s[i], old.n[i]);
  free(old.s);
  free(old.n);
}

static int is_start(int c)
{
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

static int is_word(int c)
{
  return is_start(c) || (c >= '0' && c <= '9');
}

/* Every identifier-shaped word of s[0..n) into the set; with a stack, the ones
 * that were not there yet are also pushed on it, for the closure. */
static void words(Set *t, const char *s, size_t n, const char ***stack, size_t *sn, size_t *scap,
                  size_t **slen)
{
  for (size_t i = 0; i < n;)
  {
    if (!is_start((unsigned char)s[i]) || (i && is_word((unsigned char)s[i - 1])))
    {
      i++;
      continue;
    }
    size_t j = i;
    while (j < n && is_word((unsigned char)s[j]))
      j++;
    if (set_add(t, s + i, j - i) && stack)
    {
      if (*sn == *scap)
      {
        *scap = *scap ? *scap * 2 : 1024;
        *stack = realloc(*stack, *scap * sizeof **stack);
        *slen = realloc(*slen, *scap * sizeof **slen);
        if (!*stack || !*slen)
          die("out of memory", NULL);
      }
      (*stack)[*sn] = s + i;
      (*slen)[(*sn)++] = j - i;
    }
    i = j;
  }
}

typedef struct
{
  const char *line; /* the whole line, without its newline */
  size_t len;
  const char *name; /* the macro's name, for #define and #undef lines */
  size_t name_len;
  const char *body; /* a #define's replacement list (parameters included) */
  size_t body_len;
} Line;

/* "#define NAME..." or "#undef NAME": the name and what follows it. */
static int directive(const char *s, size_t n, const char *word, const char **name, size_t *name_len,
                     const char **rest)
{
  size_t i = 0;
  while (i < n && (s[i] == ' ' || s[i] == '\t'))
    i++;
  if (i == n || s[i] != '#')
    return 0;
  i++;
  while (i < n && (s[i] == ' ' || s[i] == '\t'))
    i++;
  size_t wl = strlen(word);
  if (n - i < wl || memcmp(s + i, word, wl) != 0 || (i + wl < n && is_word((unsigned char)s[i + wl])))
    return 0;
  i += wl;
  while (i < n && (s[i] == ' ' || s[i] == '\t'))
    i++;
  size_t b = i;
  while (i < n && is_word((unsigned char)s[i]))
    i++;
  if (i == b)
    return 0;
  *name = s + b;
  *name_len = i - b;
  *rest = s + i;
  return 1;
}

int main(int argc, char **argv)
{
  if (argc < 3)
    die("usage: define_filter OUT.h IN.h ZIG...", NULL);

  /* The names the Zig code may read. */
  Set used = {0};
  const char **stack = NULL;
  size_t *slen = NULL, sn = 0, scap = 0;
  for (int a = 3; a < argc; a++)
  {
    size_t n;
    char *z = slurp(argv[a], &n);
    words(&used, z, n, NULL, NULL, NULL, NULL);
    /* z stays allocated: the set points into it */
  }

  size_t in_len;
  char *in = slurp(argv[2], &in_len);
  size_t nlines = 0, lcap = 1 << 14;
  Line *lines = malloc(lcap * sizeof *lines);
  if (!lines)
    die("out of memory", NULL);
  for (size_t i = 0; i < in_len;)
  {
    size_t j = i;
    while (j < in_len && in[j] != '\n')
      j++;
    if (nlines == lcap)
    {
      lcap *= 2;
      lines = realloc(lines, lcap * sizeof *lines);
      if (!lines)
        die("out of memory", NULL);
    }
    Line *l = &lines[nlines++];
    memset(l, 0, sizeof *l);
    l->line = in + i;
    l->len = j - i;
    const char *rest;
    if (directive(l->line, l->len, "define", &l->name, &l->name_len, &rest))
    {
      l->body = rest;
      l->body_len = (size_t)(in + j - rest);
    }
    else if (!directive(l->line, l->len, "undef", &l->name, &l->name_len, &rest))
      l->name = NULL;
    i = j < in_len ? j + 1 : j;
  }

  /* The closure: a kept macro's body names more macros to keep. */
  Set keep = {0};
  for (size_t i = 0; i < nlines; i++)
    if (lines[i].body && set_has(&used, lines[i].name, lines[i].name_len))
      words(&keep, lines[i].name, lines[i].name_len, &stack, &sn, &scap, &slen);
  while (sn)
  {
    const char *s = stack[--sn];
    size_t n = slen[sn];
    for (size_t i = 0; i < nlines; i++)
      if (lines[i].body && lines[i].name_len == n && memcmp(lines[i].name, s, n) == 0)
        words(&keep, lines[i].body, lines[i].body_len, &stack, &sn, &scap, &slen);
  }

  FILE *out = fopen(argv[1], "wb");
  if (!out)
    die("cannot write ", argv[1]);
  for (size_t i = 0; i < nlines; i++)
  {
    const Line *l = &lines[i];
    if (l->name && !set_has(&keep, l->name, l->name_len))
      continue;
    if (fwrite(l->line, 1, l->len, out) != l->len || fputc('\n', out) == EOF)
      die("cannot write ", argv[1]);
  }
  if (fclose(out))
    die("cannot write ", argv[1]);
  return 0;
}
