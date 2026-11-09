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

/* The two Python fix-ups between Zig's C backend and tcc, in C, for a build on
 * YasOS itself (no Python there):
 *
 *   zigfix fix-cbe IN.c OUT.c             scripts/kernel_tcc/tool.py fix-cbe
 *   zigfix strip-naked IN.c OUT.c [PROV]  apps/zig/strip_naked_asm.py
 *   zigfix provided OUT.txt ARCHIVE...    scripts/kernel_tcc/tool.py provided
 *
 * Each writes byte for byte what its Python original writes (the Python
 * files say what the rewrites are for); scripts/kernel_tcc/zig_device.py
 * checks that on the host. Line matching by hand: no regex library needed. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct
{
  char **v;
  int n, cap;
  /* read_lines' lines live in one block [lo, hi): not each its own allocation. */
  char *lo, *hi;
} Lines;

static void die(const char *m, const char *a)
{
  fprintf(stderr, "zigfix: %s%s\n", m, a ? a : "");
  exit(1);
}

/* Output in 64 KB writes: YasOS's stdio does not buffer a file, and a write per
 * line took fix-cbe ten minutes on a board. */
typedef struct
{
  FILE *f;
  size_t n;
  char buf[65536];
} Out;

static Out *out_open(const char *path)
{
  Out *o = malloc(sizeof *o);
  if (!o || !(o->f = fopen(path, "wb")))
    die("cannot write ", path);
  o->n = 0;
  return o;
}

static void out_flush(Out *o)
{
  if (o->n && fwrite(o->buf, 1, o->n, o->f) != o->n)
    die("write error", NULL);
  o->n = 0;
}

static void out_put(Out *o, const char *s, size_t n)
{
  while (n)
  {
    if (o->n == sizeof o->buf)
      out_flush(o);
    size_t k = sizeof o->buf - o->n;
    if (k > n)
      k = n;
    memcpy(o->buf + o->n, s, k);
    o->n += k;
    s += k;
    n -= k;
  }
}

static void out_close(Out *o, const char *path)
{
  out_flush(o);
  if (fclose(o->f))
    die("cannot write ", path);
  free(o);
}

static void push(Lines *l, char *s)
{
  if (l->n == l->cap)
  {
    l->cap = l->cap ? 2 * l->cap : 4096;
    l->v = realloc(l->v, sizeof(char *) * l->cap);
    if (!l->v)
      die("out of memory", NULL);
  }
  l->v[l->n++] = s;
}

static char *xstrdup(const char *s, size_t n)
{
  char *d = malloc(n + 1);
  if (!d)
    die("out of memory", NULL);
  memcpy(d, s, n);
  d[n] = 0;
  return d;
}

/* The file as lines, each keeping its '\n' (Python's keepends), all in one block
 * with a NUL after each: a malloc per line cost a board more than the file twice
 * over (strip-naked's 2.7 MB compiler-rt). Read twice: to count, then to copy. */
static Lines read_lines(const char *path)
{
  FILE *f = fopen(path, "rb");
  if (!f)
    die("cannot read ", path);
  static char chunk[65536];
  size_t size = 0, lines = 0, k;
  char last = '\n';
  while ((k = fread(chunk, 1, sizeof chunk, f)) > 0)
  {
    for (size_t i = 0; i < k; i++)
      lines += chunk[i] == '\n';
    size += k;
    last = chunk[k - 1];
  }
  if (ferror(f))
    die("cannot read ", path);
  if (size && last != '\n')
    lines++;
  Lines l = {0};
  l.lo = malloc(size + lines + 1);
  l.v = malloc(sizeof(char *) * (lines + 1));
  if (!l.lo || !l.v)
    die("out of memory", NULL);
  l.cap = (int)lines + 1;
  l.hi = l.lo + size + lines + 1;
  rewind(f);
  char *w = l.lo, *start = w;
  size_t got = 0;
  while ((k = fread(chunk, 1, sizeof chunk, f)) > 0)
  {
    for (size_t i = 0; i < k && got < size; i++, got++)
    {
      *w++ = chunk[i];
      if (chunk[i] == '\n')
      {
        *w++ = 0;
        l.v[l.n++] = start;
        start = w;
      }
    }
  }
  fclose(f);
  if (got != size)
    die("file changed while read: ", path);
  if (w > start)
  {
    *w++ = 0;
    l.v[l.n++] = start;
  }
  return l;
}

/* Frees a line of `l` unless it is one of read_lines' own. */
static void line_free(const Lines *l, char *s)
{
  if (!(s >= l->lo && s < l->hi))
    free(s);
}

static void write_lines(const char *path, Lines *l)
{
  Out *o = out_open(path);
  for (int i = 0; i < l->n; i++)
    out_put(o, l->v[i], strlen(l->v[i]));
  out_close(o, path);
}

static int is_word(int c)
{
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

static int is_space(int c)
{
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

static int starts(const char *s, const char *p)
{
  return strncmp(s, p, strlen(p)) == 0;
}

/* Length of the line without its '\n'. */
static size_t body_len(const char *s)
{
  size_t n = strlen(s);
  return n && s[n - 1] == '\n' ? n - 1 : n;
}

/* A growable string. */
typedef struct
{
  char *s;
  size_t n, cap;
} Str;

static void sput(Str *b, const char *s, size_t n)
{
  if (b->n + n + 1 > b->cap)
  {
    b->cap = (b->n + n + 1) * 2;
    b->s = realloc(b->s, b->cap);
    if (!b->s)
      die("out of memory", NULL);
  }
  memcpy(b->s + b->n, s, n);
  b->n += n;
  b->s[b->n] = 0;
}

static void sputs(Str *b, const char *s)
{
  sput(b, s, strlen(s));
}

/* ---- fix-cbe ------------------------------------------------------------ */

/* Lines of a file read in blocks, each keeping its '\n' as read_lines does: the
 * kernel's C is 12.7 MB, more than a board holds twice over. */
typedef struct
{
  FILE *f;
  char buf[65536];
  size_t at, end;
  int eof;
} Reader;

static int read_line(Reader *r, Str *line)
{
  line->n = 0;
  for (;;)
  {
    if (r->at == r->end)
    {
      if (r->eof)
        break;
      r->end = fread(r->buf, 1, sizeof r->buf, r->f);
      r->at = 0;
      if (r->end == 0)
      {
        if (ferror(r->f))
          die("read error", NULL);
        r->eof = 1;
        break;
      }
    }
    char *nl = memchr(r->buf + r->at, '\n', r->end - r->at);
    size_t take = nl ? (size_t)(nl - (r->buf + r->at)) + 1 : r->end - r->at;
    sput(line, r->buf + r->at, take);
    r->at += take;
    if (nl)
      return 1;
  }
  return line->n != 0;
}

/* The output, one line behind: a removed `(void)aN;` line joins the line before. */
typedef struct
{
  Out *o;
  Str prev;
  int have;
} Writer;

static void emit(Writer *w, const char *s, size_t n)
{
  if (w->have)
    out_put(w->o, w->prev.s, w->prev.n);
  w->prev.n = 0;
  sput(&w->prev, s, n);
  w->have = 1;
}

static int fix_cbe(const char *in, const char *out)
{
  Reader *r = calloc(1, sizeof *r);
  if (!r)
    die("out of memory", NULL);
  r->f = fopen(in, "rb");
  if (!r->f)
    die("cannot read ", in);
  Writer w = {0};
  w.o = out_open(out);
  Str line = {0}, t = {0};
  int in_naked = 0;
  while (read_line(r, &line))
  {
    char *s = line.s;
    size_t n = body_len(s);
    if (in_naked)
    {
      /* re.sub(r'\n \(void\)a\d+;', ''): the newline before goes with it,
       * so whatever followed on that line joins the previous one. */
      if (s[0] == '}')
        in_naked = 0;
      else if (starts(s, " (void)a") && s[8] >= '0' && s[8] <= '9')
      {
        size_t k = 8;
        while (s[k] >= '0' && s[k] <= '9')
          k++;
        if (s[k] == ';')
        {
          if (!w.have)
            die("fix-cbe: a naked function body before any line", NULL);
          w.prev.n = body_len(w.prev.s);
          w.prev.s[w.prev.n] = 0;
          sputs(&w.prev, s + k + 1);
          continue;
        }
      }
    }
    t.n = 0;
    /* ^(zig_extern .*\bzig_e_(\w+));$ */
    if (starts(s, "zig_extern ") && n && s[n - 1] == ';')
    {
      size_t e = n - 1, b = e;
      while (b > 0 && is_word(s[b - 1]))
        b--;
      if (b < e && starts(s + b, "zig_e_") && b + 6 < e && b > 0 && !is_word(s[b - 1]) && b >= 11)
      {
        sput(&t, s, n - 1);
        sputs(&t, " zig_mangled(");
        sput(&t, s + b, e - b);
        sputs(&t, ", \"");
        sput(&t, s + b + 6, e - b - 6);
        sputs(&t, "\");");
        sputs(&t, s + n);
        emit(&w, t.s, t.n);
        continue;
      }
    }
    /* ^(zig_linksection\("\.time_critical)("\) struct \w+ const ) */
    if (starts(s, "zig_linksection(\".time_critical\") struct "))
    {
      const char *p = s + strlen("zig_linksection(\".time_critical\") struct ");
      const char *q = p;
      while (is_word(*q))
        q++;
      if (q > p && starts(q, " const "))
      {
        sputs(&t, "zig_linksection(\".time_critical.data\") struct ");
        sputs(&t, p);
        emit(&w, t.s, t.n);
        continue;
      }
    }
    /* ^(static zig_never_inline) zig_naked (void zig_never_inline_) */
    if (starts(s, "static zig_never_inline zig_naked void zig_never_inline_"))
    {
      sputs(&t, "static zig_never_inline void zig_never_inline_");
      sputs(&t, s + strlen("static zig_never_inline zig_naked void zig_never_inline_"));
      emit(&w, t.s, t.n);
      continue;
    }
    /* ^(static )?zig_naked void \w+\([^)]*\) \{ ... up to the next line opening with } */
    {
      const char *p = s;
      if (starts(p, "static "))
        p += 7;
      if (starts(p, "zig_naked void "))
      {
        p += strlen("zig_naked void ");
        const char *q = p;
        while (is_word(*q))
          q++;
        if (q > p && *q == '(')
        {
          const char *c = strchr(q, ')');
          if (c && starts(c, ") {"))
            in_naked = 1;
        }
      }
    }
    emit(&w, s, line.n);
  }
  if (w.have)
    out_put(w.o, w.prev.s, w.prev.n);
  out_close(w.o, out);
  fclose(r->f);
  free(r);
  free(line.s);
  free(t.s);
  free(w.prev.s);
  return 0;
}

/* ---- strip-naked -------------------------------------------------------- */

/* A string set/map by open addressing, growing at half full (it started at 64K
 * slots: 3 MB for strip-naked's six maps on a board). */
typedef struct
{
  char **key, **val;
  int cap, n;
} Map;

static unsigned hash(const char *s)
{
  unsigned h = 2166136261u;
  while (*s)
    h = (h ^ (unsigned char)*s++) * 16777619u;
  return h;
}

static int map_slot(Map *m, const char *k)
{
  unsigned h = hash(k) & (m->cap - 1);
  while (m->key[h] && strcmp(m->key[h], k))
    h = (h + 1) & (m->cap - 1);
  return h;
}

static void map_alloc(Map *m, int cap)
{
  m->cap = cap;
  m->key = calloc(m->cap, sizeof(char *));
  m->val = calloc(m->cap, sizeof(char *));
  if (!m->key || !m->val)
    die("out of memory", NULL);
}

static void map_init(Map *m)
{
  m->n = 0;
  map_alloc(m, 64);
}

static void map_grow(Map *m)
{
  Map old = *m;
  map_alloc(m, old.cap * 2);
  for (int i = 0; i < old.cap; i++)
    if (old.key[i])
    {
      int h = map_slot(m, old.key[i]);
      m->key[h] = old.key[i];
      m->val[h] = old.val[i];
    }
  free(old.key);
  free(old.val);
}

static void map_put(Map *m, const char *k, const char *v)
{
  int h = map_slot(m, k);
  if (!m->key[h])
  {
    if (2 * (m->n + 1) > m->cap)
    {
      map_grow(m);
      h = map_slot(m, k);
    }
    m->key[h] = xstrdup(k, strlen(k));
    m->n++;
  }
  m->val[h] = v ? xstrdup(v, strlen(v)) : NULL;
}

static const char *map_get(Map *m, const char *k, int *found)
{
  int h = map_slot(m, k);
  *found = m->key[h] != NULL;
  return m->val[h];
}

/* zig_mangled(IDENT, "NAME") at p: lengths of IDENT and NAME, or 0. */
static int mangled_at(const char *p, const char **id, size_t *idn, const char **nm, size_t *nmn)
{
  if (!starts(p, "zig_mangled("))
    return 0;
  const char *a = p + 12, *b = a;
  while (is_word(*b))
    b++;
  if (b == a || !starts(b, ", \""))
    return 0;
  const char *c = b + 3, *d = c;
  while (*d && *d != '"')
    d++;
  if (d == c || !starts(d, "\")"))
    return 0;
  *id = a, *idn = b - a, *nm = c, *nmn = d - c;
  return 1;
}

/* Python's `[^"]+` at a position just after "zig_mangled(": also matches the
 * word-boundary-free \w+ the regexes use (identifiers are \w+). */
static char *dup_n(const char *s, size_t n)
{
  return xstrdup(s, n);
}

static int strip_naked(const char *in, const char *out, const char *prov_path)
{
  Lines l = read_lines(in);
  Map provided;
  map_init(&provided);
  if (prov_path)
  {
    Lines p = read_lines(prov_path);
    for (int i = 0; i < p.n; i++)
    {
      /* l.split()[-1] for non-blank lines */
      char *s = p.v[i];
      size_t n = strlen(s);
      while (n && is_space(s[n - 1]))
        n--;
      if (!n)
        continue;
      size_t b = n;
      while (b && !is_space(s[b - 1]))
        b--;
      char *w = dup_n(s + b, n - b);
      map_put(&provided, w, "");
      free(w);
    }
  }

  /* 3. Rename exports the platform provides. */
  for (int i = 0; i < l.n; i++)
  {
    char *s = l.v[i];
    if (!strstr(s, "zig_mangled("))
      continue;
    Str r = {0};
    const char *p = s;
    while (*p)
    {
      const char *id, *nm;
      size_t idn, nmn;
      if (mangled_at(p, &id, &idn, &nm, &nmn))
      {
        char *name = dup_n(nm, nmn);
        int found;
        map_get(&provided, name, &found);
        sputs(&r, "zig_mangled(");
        sput(&r, id, idn);
        sputs(&r, found ? ", \"zigrt_" : ", \"");
        sput(&r, nm, nmn);
        sputs(&r, "\")");
        free(name);
        p = nm + nmn + 2;
      }
      else
        sput(&r, p++, 1);
    }
    line_free(&l, s);
    l.v[i] = r.s;
  }

  /* 2. Second exported names as forwarding functions. */
  Map asm_name;
  map_init(&asm_name);
  for (int i = 0; i < l.n; i++)
    for (const char *p = l.v[i]; (p = strstr(p, "zig_mangled(")); p++)
    {
      const char *id, *nm;
      size_t idn, nmn;
      if (mangled_at(p, &id, &idn, &nm, &nmn))
      {
        char *k = dup_n(nm, nmn), *v = dup_n(id, idn);
        map_put(&asm_name, k, v);
        free(k), free(v);
      }
    }
  Lines kept = {0}, fwd = {0};
  for (int i = 0; i < l.n; i++)
  {
    char *s = l.v[i];
    /* ^\s*zig_extern\s+(ret.+?)\s+(zig_e_\w+)\(([^)]*)\)\s+zig_mangled_export\(\2,\s*"(exp)",\s*"(target)"\); */
    const char *p = s;
    int matched = 0;
    while (is_space(*p))
      p++;
    if (starts(p, "zig_extern") && is_space(p[10]))
    {
      const char *r0 = p + 10;
      while (is_space(*r0))
        r0++;
      /* the lazy ret: the first whitespace run (after at least one char) that a match follows */
      for (const char *w = r0 + 1; *w && !matched; w++)
      {
        if (!is_space(*w) || is_space(w[-1]))
          continue;
        const char *nmS = w;
        while (is_space(*nmS))
          nmS++;
        if (!starts(nmS, "zig_e_"))
          continue;
        const char *nmE = nmS + 6;
        while (is_word(*nmE))
          nmE++;
        if (nmE == nmS + 6 || *nmE != '(')
          continue;
        const char *pS = nmE + 1, *pE = pS;
        while (*pE && *pE != ')')
          pE++;
        if (*pE != ')')
          continue;
        const char *q = pE + 1;
        if (!is_space(*q))
          continue;
        while (is_space(*q))
          q++;
        if (!starts(q, "zig_mangled_export("))
          continue;
        q += 19;
        if (strncmp(q, nmS, nmE - nmS) || q[nmE - nmS] != ',')
          continue;
        q += nmE - nmS + 1;
        while (is_space(*q))
          q++;
        if (*q != '"')
          continue;
        const char *eS = ++q;
        while (*q && *q != '"')
          q++;
        if (*q != '"' || q == eS)
          continue;
        const char *eE = q++;
        if (*q != ',')
          continue;
        q++;
        while (is_space(*q))
          q++;
        if (*q != '"')
          continue;
        const char *tS = ++q;
        while (*q && *q != '"')
          q++;
        if (*q != '"' || q == tS || !starts(q, "\");"))
          continue;
        const char *tE = q;
        matched = 1;
        /* ret = r0 .. w minus trailing spaces (\s+ is greedy) */
        char *ret = dup_n(r0, w - r0);
        char *exp = dup_n(eS, eE - eS), *tgt = dup_n(tS, tE - tS), *params = dup_n(pS, pE - pS);
        int found;
        const char *target = map_get(&asm_name, tgt, &found);
        if (found)
        {
          Str args = {0};
          for (const char *a = params; *a; a++)
            if (*a == 'a' && (a == params || !is_word(a[-1])) && a[1] >= '0' && a[1] <= '9')
            {
              const char *z = a + 1;
              while (*z >= '0' && *z <= '9')
                z++;
              if (is_word(*z))
                continue;
              if (args.n)
                sputs(&args, ", ");
              sput(&args, a, z - a);
              a = z - 1;
            }
          Str f1 = {0}, f2 = {0};
          sputs(&f1, ret), sputs(&f1, " yz_fwd_"), sputs(&f1, exp), sputs(&f1, "("), sputs(&f1, params);
          sputs(&f1, ") __asm__(\""), sputs(&f1, exp), sputs(&f1, "\");\n");
          sputs(&f2, ret), sputs(&f2, " yz_fwd_"), sputs(&f2, exp), sputs(&f2, "("), sputs(&f2, params);
          sputs(&f2, ") { return "), sputs(&f2, target), sputs(&f2, "("), sputs(&f2, args.s ? args.s : "");
          sputs(&f2, "); }\n");
          push(&fwd, f1.s), push(&fwd, f2.s);
        }
      }
    }
    if (!matched)
      push(&kept, s);
  }

  /* 1. Named asm operands -> literal symbol references. */
  Map define_to_zig_e, first_mangled, final_name;
  map_init(&define_to_zig_e), map_init(&first_mangled), map_init(&final_name);
  Lines def_order = {0};
  for (int i = 0; i < kept.n; i++)
  {
    const char *s = kept.v[i];
    if (!starts(s, "#define "))
      continue;
    const char *a = s + 8, *b = a;
    while (is_word(*b))
      b++;
    if (b == a || *b != ' ' || !starts(b + 1, "zig_e_"))
      continue;
    const char *c = b + 1 + 6;
    while (is_word(*c))
      c++;
    if (c == b + 1 + 6)
      continue;
    char *k = dup_n(a, b - a), *v = dup_n(b + 1, c - b - 1);
    int found;
    map_get(&define_to_zig_e, k, &found);
    if (!found)
      push(&def_order, xstrdup(k, strlen(k)));
    map_put(&define_to_zig_e, k, v);
    free(k), free(v);
  }
  for (int i = 0; i < kept.n; i++)
    for (const char *p = kept.v[i]; (p = strstr(p, "zig_mangled(")); p++)
    {
      const char *id, *nm;
      size_t idn, nmn;
      if (mangled_at(p, &id, &idn, &nm, &nmn))
      {
        char *k = dup_n(id, idn);
        int found;
        map_get(&first_mangled, k, &found);
        if (!found)
        {
          char *v = dup_n(nm, nmn);
          map_put(&first_mangled, k, v);
          free(v);
        }
        free(k);
      }
    }
  for (int i = 0; i < def_order.n; i++)
  {
    int found;
    const char *ze = map_get(&define_to_zig_e, def_order.v[i], &found);
    const char *nm = map_get(&first_mangled, ze, &found);
    if (found)
      map_put(&final_name, def_order.v[i], nm);
  }

  int rewritten = 0;
  Lines asm_only = {0};
  Map asm_only_seen;
  map_init(&asm_only_seen);
  for (int i = 0; i < kept.n; i++)
  {
    char *s = kept.v[i];
    if (!strstr(s, "%["))
      continue;
    /* \[(\w+)\]"X"\(\(&(\w+)\)\) pairs, later ones overriding (a dict) */
    Lines names = {0}, idents = {0};
    for (const char *p = s; (p = strchr(p, '[')); p++)
    {
      const char *a = p + 1, *b = a;
      while (is_word(*b))
        b++;
      if (b == a || !starts(b, "]\"X\"((&"))
        continue;
      const char *c = b + 7, *d = c;
      while (is_word(*d))
        d++;
      if (d == c || !starts(d, "))"))
        continue;
      char *nm = dup_n(a, b - a), *id = dup_n(c, d - c);
      int k;
      for (k = 0; k < names.n && strcmp(names.v[k], nm); k++)
        ;
      if (k < names.n)
        free(idents.v[k]), idents.v[k] = id, free(nm);
      else
        push(&names, nm), push(&idents, id);
    }
    char *cur = xstrdup(s, strlen(s));
    for (int k = 0; k < names.n; k++)
    {
      int found;
      const char *fin = map_get(&final_name, idents.v[k], &found);
      const char *rep = found ? fin : idents.v[k];
      if (!found)
        push(&asm_only, idents.v[k]);
      Str pat = {0}, r = {0};
      sputs(&pat, "%["), sputs(&pat, names.v[k]), sputs(&pat, "]");
      const char *p = cur, *h;
      while ((h = strstr(p, pat.s)))
      {
        sput(&r, p, h - p);
        sputs(&r, rep);
        p = h + pat.n;
      }
      sputs(&r, p);
      free(cur);
      cur = r.s;
    }
    int clobber = strstr(cur, ": \"memory\"") != NULL;
    /* ::\s*\[\w+\]"X"\(\(&\w+\)\)(?:\s*:\s*"memory")? */
    Str r = {0};
    const char *p = cur;
    while (*p)
    {
      if (p[0] == ':' && p[1] == ':')
      {
        const char *q = p + 2;
        while (is_space(*q))
          q++;
        const char *a = q + 1, *b = a;
        if (*q == '[')
        {
          while (is_word(*b))
            b++;
          if (b > a && starts(b, "]\"X\"((&"))
          {
            const char *c = b + 7, *d = c;
            while (is_word(*d))
              d++;
            if (d > c && starts(d, "))"))
            {
              const char *e = d + 2, *f = e;
              while (is_space(*f))
                f++;
              if (*f == ':')
              {
                f++;
                while (is_space(*f))
                  f++;
                if (starts(f, "\"memory\""))
                  e = f + 8;
              }
              sputs(&r, clobber ? ":::\"memory\"" : "");
              p = e;
              continue;
            }
          }
        }
      }
      sput(&r, p++, 1);
    }
    free(cur);
    kept.v[i] = r.s;
    rewritten++;
  }

  Lines o = kept;
  int distinct = 0;
  if (asm_only.n)
  {
    Str t = {0};
    sputs(&t, "static void const *const yz_asm_targets[] __attribute__((used)) = { ");
    for (int i = 0; i < asm_only.n; i++)
    {
      int found;
      map_get(&asm_only_seen, asm_only.v[i], &found);
      if (found)
        continue;
      map_put(&asm_only_seen, asm_only.v[i], "");
      if (distinct++)
        sputs(&t, ", ");
      sputs(&t, "(void const *)&"), sputs(&t, asm_only.v[i]);
    }
    sputs(&t, " };\n");
    const char *h = "\n/* Static targets of the asm wrappers above. */\n";
    push(&o, xstrdup(h, strlen(h)));
    push(&o, t.s);
  }
  if (fwd.n)
  {
    const char *h = "\n/* Second exported names, as forwarding calls. */\n";
    push(&o, xstrdup(h, strlen(h)));
    for (int i = 0; i < fwd.n; i++)
      push(&o, fwd.v[i]);
  }
  write_lines(out, &o);
  int renamed = 0;
  for (int i = 0; i < o.n; i++)
    renamed += strstr(o.v[i], "zigrt_") != NULL;
  printf("rewrote %d asm wrappers, %d forwarding exports, %d renamed\n", rewritten, fwd.n / 2, renamed);
  return 0;
}

/* ---- provided ----------------------------------------------------------- */

static unsigned rd16(const unsigned char *p) { return p[0] | p[1] << 8; }
static unsigned rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24; }

/* Global/weak symbols of one ELF32 little-endian relocatable: the defined ones, or
 * (undef) the named undefined ones. */
static void elf_syms(const unsigned char *d, size_t n, Map *names, int undef)
{
  if (n < 52 || memcmp(d, "\x7f" "ELF", 4) || d[4] != 1)
    return;
  unsigned shoff = rd32(d + 0x20), shentsize = rd16(d + 0x2e), shnum = rd16(d + 0x30);
  for (unsigned i = 0; i < shnum; i++)
  {
    const unsigned char *sh = d + shoff + i * shentsize;
    if (rd32(sh + 4) != 2) /* SHT_SYMTAB */
      continue;
    unsigned off = rd32(sh + 16), size = rd32(sh + 20), link = rd32(sh + 24), entsize = rd32(sh + 36);
    if (!entsize)
      entsize = 16;
    unsigned stroff = rd32(d + shoff + link * shentsize + 16);
    for (unsigned k = 1; k < size / entsize; k++)
    {
      const unsigned char *sym = d + off + k * entsize;
      unsigned name = rd32(sym), info = sym[12], shndx = rd16(sym + 14);
      if (((info >> 4) == 1 || (info >> 4) == 2) && (undef ? shndx == 0 && name : shndx != 0))
        map_put(names, (const char *)d + stroff + name, "");
    }
  }
}

static int cmp_str(const void *a, const void *b)
{
  return strcmp(*(char *const *)a, *(char *const *)b);
}

/* provided: the symbols the archives define; needed (undef): the ones the objects and
 * archives leave undefined. */
static int symbol_list(const char *out, int narch, char **archives, int undef)
{
  Map names;
  map_init(&names);
  for (int a = 0; a < narch; a++)
  {
    FILE *f = fopen(archives[a], "rb");
    if (!f)
      die("cannot read ", archives[a]);
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *d = malloc(size + 1);
    if (!d || fread(d, 1, size, f) != (size_t)size)
      die("cannot read ", archives[a]);
    fclose(f);
    if (size < 8 || memcmp(d, "!<arch>\n", 8))
      elf_syms(d, size, &names, undef);
    else
      for (long pos = 8; pos + 60 <= size;)
      {
        char num[11];
        memcpy(num, d + pos + 48, 10);
        num[10] = 0;
        long msize = strtol(num, NULL, 10);
        const unsigned char *h = d + pos;
        int k = 0;
        while (k < 16 && h[k] == ' ')
          k++;
        if (!(k < 16 && h[k] == '/')) /* skip symbol/name tables */
          elf_syms(d + pos + 60, msize, &names, undef);
        pos += 60 + msize + (msize & 1);
      }
    free(d);
  }
  char **v = malloc(sizeof(char *) * (names.n + 1));
  int n = 0;
  for (int i = 0; i < names.cap; i++)
    if (names.key[i])
      v[n++] = names.key[i];
  qsort(v, n, sizeof(char *), cmp_str);
  FILE *f = fopen(out, "wb");
  if (!f)
    die("cannot write ", out);
  for (int i = 0; i < n; i++)
    fprintf(f, "%s\n", v[i]);
  if (fclose(f))
    die("cannot write ", out);
  return 0;
}

/* ---- prune-crt: tool.py prune_crt ------------------------------------------- */

/* The length of s less trailing whitespace. */
static size_t rlen(const char *s, size_t n)
{
  while (n && is_space((unsigned char)s[n - 1]))
    n--;
  return n;
}

/* tool.py crt_def_name: the identifier before the parameter list that ends at the
 * last ')' of h[0, n); NULL when there is none. */
static char *def_name(const char *h, size_t n)
{
  long i = (long)n - 1;
  while (i >= 0 && h[i] != ')')
    i--;
  if (i < 0)
    return NULL;
  int depth = 0;
  for (; i >= 0; i--)
  {
    depth += h[i] == ')' ? 1 : h[i] == '(' ? -1 : 0;
    if (!depth)
      break;
  }
  if (i < 0)
    i = 0; /* Python: header[:-1] -- never in the C backend's output */
  size_t e = rlen(h, (size_t)i), b = e;
  while (b && is_word((unsigned char)h[b - 1]))
    b--;
  if (b == e || (h[b] >= '0' && h[b] <= '9'))
    return NULL;
  return xstrdup(h + b, e - b);
}

/* Appends `name` to the space-separated list m[key]. */
static void map_add(Map *m, const char *key, const char *name)
{
  int found;
  const char *v = map_get(m, key, &found);
  if (!found || !v || !*v)
  {
    map_put(m, key, name);
    return;
  }
  size_t a = strlen(v), b = strlen(name);
  char *c = malloc(a + b + 2);
  if (!c)
    die("out of memory", NULL);
  memcpy(c, v, a);
  c[a] = ' ';
  memcpy(c + a + 1, name, b + 1);
  map_put(m, key, c);
  free(c);
}

typedef struct
{
  char *name;
  int a, b, next; /* next definition of the same name, or -1 */
} Def;

static int prune_crt(const char *in, const char *out, const char *needed_path)
{
  Lines L = read_lines(in);
  Def *defs = NULL;
  int nd = 0, capd = 0;
  char *in_def = calloc(L.n + 1, 1), *drop = calloc(L.n + 1, 1);
  if (!in_def || !drop)
    die("out of memory", NULL);
  for (int i = 0; i < L.n;)
  {
    const char *l = L.v[i];
    size_t n = rlen(l, strlen(l));
    if (l[0] && !strchr(" \t#}\n", l[0]) && n >= 3 && !memcmp(l + n - 3, ") {", 3))
    {
      int j = i + 1;
      while (j < L.n && strcmp(L.v[j], "}\n") && strcmp(L.v[j], "}"))
        j++;
      if (nd == capd)
      {
        capd = capd ? 2 * capd : 1024;
        defs = realloc(defs, sizeof(Def) * capd);
        if (!defs)
          die("out of memory", NULL);
      }
      defs[nd++] = (Def){def_name(l, n), i, j, -1};
      for (int k = i; k <= j && k < L.n; k++)
        in_def[k] = 1;
      i = j + 1;
    }
    else
      i++;
  }
  Map bodies, define, to_c, keep, roots;
  map_init(&bodies), map_init(&define), map_init(&to_c), map_init(&keep), map_init(&roots);
  char num[16];
  for (int d = nd - 1; d >= 0; d--)
    if (defs[d].name)
    {
      int found;
      const char *v = map_get(&bodies, defs[d].name, &found);
      defs[d].next = found ? atoi(v) : -1;
      snprintf(num, sizeof num, "%d", d);
      map_put(&bodies, defs[d].name, num);
    }
  for (int i = 0; i < L.n; i++)
  {
    const char *l = L.v[i];
    size_t n = rlen(l, strlen(l));
    if (starts(l, "#define "))
    {
      const char *a = l + 8, *b = a;
      while (is_word((unsigned char)*b))
        b++;
      if (b > a && *b == ' ' && starts(b + 1, "zig_e_"))
      {
        const char *c = b + 1, *e = c;
        while (is_word((unsigned char)*e))
          e++;
        if ((size_t)(e - l) == n)
        {
          char *k = xstrdup(c, e - c), *v = xstrdup(a, b - a);
          map_add(&define, k, v);
          free(k), free(v);
        }
      }
    }
  }
  for (int i = 0; i < L.n; i++)
  {
    const char *l = L.v[i];
    for (const char *p = strstr(l, "zig_mangled("); p; p = strstr(p + 1, "zig_mangled("))
    {
      const char *id, *nm;
      size_t idn, nmn;
      if (!mangled_at(p, &id, &idn, &nm, &nmn))
        continue;
      char *ident = xstrdup(id, idn), *asmn = xstrdup(nm, nmn);
      map_add(&to_c, asmn, ident);
      int found;
      const char *dv = map_get(&define, ident, &found);
      if (found && dv)
      {
        char *copy = xstrdup(dv, strlen(dv));
        for (char *t = strtok(copy, " "); t; t = strtok(NULL, " "))
          map_add(&to_c, asmn, t);
        free(copy);
      }
      free(ident), free(asmn);
    }
    /* `...(params) __asm__("name");` */
    size_t n = rlen(l, strlen(l));
    if (n >= 3 && !memcmp(l + n - 3, "\");", 3))
    {
      const char *q = l + n - 3, *open = q;
      while (open > l && open[-1] != '"')
        open--;
      if (open - l >= 9 && !memcmp(open - 9, "__asm__(\"", 9))
      {
        const char *k = open - 9;
        size_t pre = rlen(l, k - l);
        if (pre && l[pre - 1] == ')')
        {
          char *name = def_name(l, pre);
          if (name)
          {
            char *asmn = xstrdup(open, q - open);
            map_add(&to_c, asmn, name);
            free(asmn), free(name);
          }
        }
      }
    }
  }
  /* roots: the needed names (and their C names), and the words of top-level text
   * other than definitions, directives and declarations */
  Lines need = read_lines(needed_path);
  char **todo = NULL;
  int nt = 0, capt = 0;
#define PUSH(w)                                                           \
  do                                                                      \
  {                                                                       \
    if (nt == capt)                                                       \
    {                                                                     \
      capt = capt ? 2 * capt : 4096;                                      \
      todo = realloc(todo, sizeof(char *) * capt);                        \
      if (!todo)                                                          \
        die("out of memory", NULL);                                       \
    }                                                                     \
    todo[nt++] = xstrdup((w), strlen(w));                                 \
  } while (0)
  for (int i = 0; i < need.n; i++)
  {
    char *w = need.v[i];
    size_t n = rlen(w, strlen(w));
    size_t b = 0;
    while (b < n && is_space((unsigned char)w[b]))
      b++;
    char *name = xstrdup(w + b, n - b);
    int found;
    const char *v = map_get(&to_c, name, &found);
    if (found && v)
    {
      char *copy = xstrdup(v, strlen(v));
      for (char *t = strtok(copy, " "); t; t = strtok(NULL, " "))
        PUSH(t);
      free(copy);
    }
    PUSH(name);
    free(name);
  }
  for (int i = 0; i < L.n; i++)
  {
    const char *l = L.v[i];
    if (in_def[i] || l[0] == '#')
      continue;
    size_t n = rlen(l, strlen(l));
    if (n && l[n - 1] == ';' && rlen(l, n - 1) && l[rlen(l, n - 1) - 1] == ')')
      continue; /* a declaration */
    for (const char *p = l; *p;)
    {
      if (is_word((unsigned char)*p) && !(*p >= '0' && *p <= '9'))
      {
        const char *e = p;
        while (is_word((unsigned char)*e))
          e++;
        char *w = xstrdup(p, e - p);
        PUSH(w);
        free(w);
        p = e;
      }
      else if (is_word((unsigned char)*p))
      {
        while (is_word((unsigned char)*p))
          p++;
      }
      else
        p++;
    }
  }
  while (nt)
  {
    char *w = todo[--nt];
    int found;
    const char *v = map_get(&bodies, w, &found);
    map_get(&keep, w, &found);
    if (!v || found)
    {
      free(w);
      continue;
    }
    map_put(&keep, w, "");
    for (int d = atoi(v); d >= 0; d = defs[d].next)
      for (int k = defs[d].a; k <= defs[d].b && k < L.n; k++)
        for (const char *p = L.v[k]; *p;)
        {
          if (is_word((unsigned char)*p) && !(*p >= '0' && *p <= '9'))
          {
            const char *e = p;
            while (is_word((unsigned char)*e))
              e++;
            char *x = xstrdup(p, e - p);
            int f1, f2;
            if (map_get(&bodies, x, &f1), f1)
            {
              if (map_get(&keep, x, &f2), !f2)
                PUSH(x);
            }
            const char *cs = map_get(&to_c, x, &f1);
            if (f1 && cs)
            {
              char *copy = xstrdup(cs, strlen(cs));
              for (char *t = strtok(copy, " "); t; t = strtok(NULL, " "))
                if ((map_get(&bodies, t, &f2), f2) && (map_get(&keep, t, &f2), !f2))
                  PUSH(t);
              free(copy);
            }
            free(x);
            p = e;
          }
          else if (is_word((unsigned char)*p))
          {
            while (is_word((unsigned char)*p))
              p++;
          }
          else
            p++;
        }
    free(w);
  }
#undef PUSH
  int kept = 0;
  for (int d = 0; d < nd; d++)
  {
    int found = 0;
    if (defs[d].name)
      map_get(&keep, defs[d].name, &found);
    if (found)
      kept++;
    else
      for (int k = defs[d].a; k <= defs[d].b && k < L.n; k++)
        drop[k] = 1;
  }
  Out *o = out_open(out);
  for (int i = 0; i < L.n; i++)
    if (!drop[i])
      out_put(o, L.v[i], strlen(L.v[i]));
  out_close(o, out);
  printf("prune-crt: %d definitions, %d kept\n", nd, kept);
  return 0;
}

int main(int argc, char **argv)
{
  if (argc >= 3 && !strcmp(argv[1], "provided"))
    return symbol_list(argv[2], argc - 3, argv + 3, 0);
  if (argc >= 3 && !strcmp(argv[1], "needed"))
    return symbol_list(argv[2], argc - 3, argv + 3, 1);
  if (argc == 5 && !strcmp(argv[1], "prune-crt"))
    return prune_crt(argv[3], argv[2], argv[4]);
  if (argc == 4 && !strcmp(argv[1], "fix-cbe"))
    return fix_cbe(argv[2], argv[3]);
  if ((argc == 4 || argc == 5) && !strcmp(argv[1], "strip-naked"))
    return strip_naked(argv[2], argv[3], argc == 5 ? argv[4] : NULL);
  fprintf(stderr, "usage: zigfix fix-cbe IN.c OUT.c | strip-naked IN.c OUT.c [PROVIDED] | provided OUT.txt ARCHIVE...\n"
                  "       | needed OUT.txt FILE... | prune-crt OUT.c IN.c NEEDED.txt\n");
  return 2;
}
