// Tokenizes yasc snippets with VSCode's own TextMate engine, its built-in C
// grammar and this extension's injections, and checks the scope of each
// yasc word. Run: node test/run.js  (VSCODE_APP = VSCode's resources/app,
// default /usr/share/code/resources/app).
'use strict';
const fs = require('fs');
const path = require('path');

const app = process.env.VSCODE_APP || '/usr/share/code/resources/app';
const tm = require(path.join(app, 'node_modules/vscode-textmate'));
const onig = require(path.join(app, 'node_modules/vscode-oniguruma'));

const here = path.join(__dirname, '..');
const grammars = {
  'source.c': path.join(app, 'extensions/cpp/syntaxes/c.tmLanguage.json'),
  'source.c.yasc': path.join(here, 'syntaxes/yasc.tmLanguage.json'),
};
const pkg = JSON.parse(fs.readFileSync(path.join(here, 'package.json'), 'utf8'));
const injections = pkg.contributes.grammars.filter((g) => g.injectTo).map((g) => g.scopeName);

const QUALIFIER = 'storage.modifier.yasc.c';
const DEFER = 'keyword.control.defer.yasc.c';
const TRY = 'keyword.control.try.yasc.c';
const CATCH = 'keyword.control.catch.yasc.c';
const CAPTURE = 'variable.parameter.capture.yasc.c';
const ERROR = 'storage.type.error.yasc.c';
const ERRSET = 'entity.name.type.error.yasc.c';
const ERRNAME = 'constant.other.error.yasc.c';
const BUILTIN = 'support.function.yasc.c';
const MOVE = 'keyword.operator.expression.move.yasc.c';
const BORROW = 'keyword.operator.expression.borrow.yasc.c';
const BANG = 'storage.modifier.errunion.yasc.c';
const IMPORT = 'keyword.control.import.yasc.c';
const MODNAME = 'entity.name.namespace.yasc.c';
const EXPORT = 'storage.modifier.export.yasc.c';
const UNSAFE = 'keyword.control.unsafe.yasc.c';
const WHEN = 'storage.modifier.when.yasc.c';
const REG = 'storage.modifier.register.yasc.c';
const ATBUILTIN = 'support.function.builtin.yasc.c';
const SLICE = 'storage.modifier.slice.yasc.c';
const SLICEOP = 'keyword.operator.slice.yasc.c';
const UNREACHABLE = 'keyword.control.unreachable.yasc.c';
const UNDEFINED = 'constant.language.undefined.yasc.c';
const CAST = 'keyword.operator.cast.yasc.c';
const UNSAFECAST = 'keyword.operator.cast.unsafe.yasc.c';
const PERM = 'storage.modifier.cast.yasc.c';
const CASTOPEN = 'punctuation.definition.cast.begin.yasc.c';
const CASTCLOSE = 'punctuation.definition.cast.end.yasc.c';

// [source lines, [[line, needle, expected scope or null], ...]]: needle's
// first word (or its first character when it does not start with a word), at
// needle's first occurrence on that line. null: no yasc scope. 'c:<scope>'
// instead checks that the C grammar's own scope is there (C highlighting goes
// on around the yasc words).
const cases = [
  ['in / inout / out before a parameter', [
    'void step(inout struct node *view n, in const char *view s, out int *view r);',
    'void g(void)',
    '{',
    '  FILE *in = fopen(p, "r"); in = 0; if (in && inout) return;',
    '}',
    'int on_key(unused inout struct ctx *view c, int unused) __attribute__((unused));',
    '{ unused(user, group); x = unused(1); }',
    '  unused(buf, size);',
    'static const char *parse_name(const char *s, out char *out, size_t cap) { out[n] = 0; }',
    'int close(int drop ?owned(close) fd); struct out x; struct drop *d;',
    '               out struct passwd *?borrows(pwd) *result) {',
    '#define out foo',
  ], [
    [0, 'inout', QUALIFIER], [0, 'in const', QUALIFIER], [0, 'out int', QUALIFIER], [0, 'node', null],
    [3, 'in =', null], [3, 'in = 0', null], [3, 'in &&', null], [3, 'inout)', null],
    [5, 'unused inout', QUALIFIER], [5, 'unused)', null], [5, 'unused))', null],
    [6, 'unused(user', DEFER], [6, 'unused(1', null], [7, 'unused(buf', DEFER],
    [8, 'out char', QUALIFIER], [8, 'out,', null], [8, 'out[', null],
    [9, 'drop', QUALIFIER], [9, 'out x', null], [9, 'drop *d', null],
    [10, 'out', QUALIFIER], [11, 'out foo', null],
  ]],
  ['ownership qualifiers', [
    '/* comment first */',
    'char *owned dup(const char *view s);',
    'void fill(out int *view p, drop char *owned q, int *?view m)',
    '{',
    '  char *owned *view argv = 0;',
    '  struct name *?owned next;',
    '  int f(char *view, int *view);',
    '}',
  ], [
    [1, 'owned', QUALIFIER], [1, 'view', QUALIFIER], [1, 'dup', null],
    [2, 'out', QUALIFIER], [2, 'view p', QUALIFIER], [2, 'drop', QUALIFIER],
    [2, 'owned q', QUALIFIER], [2, '?', QUALIFIER],
    [4, 'owned', QUALIFIER], [4, 'view', QUALIFIER],
    [5, 'owned', QUALIFIER], [5, '?', QUALIFIER],
    [6, 'view,', QUALIFIER], [6, 'view)', QUALIFIER],
    [1, 'const', 'c:storage.modifier.c'], [1, 'char', 'c:storage.type.built-in.primitive.c'],
    [0, 'comment', 'c:comment.block.c'],
  ]],
  ['move / borrow are operators, not calls', [
    'void f(DIR *owned dir)',
    '{',
    '  memset(borrow(dir), 0, sizeof(*dir));',
    '  return g(move(dir), p->move(1), q.borrow (2));',
    '}',
  ], [
    [2, 'borrow', BORROW], [2, 'memset', 'c:entity.name.function.c'], [2, 'sizeof', 'c:keyword.operator.sizeof.c'],
    [3, 'move(dir)', MOVE], [3, 'move(1)', null], [3, 'borrow', null],
  ]],
  ['the words as names', [
    'int out;',
    'struct view *v; view *w;',
    'void g(void)',
    '{',
    '  out->len = s.view + p->maybe;',
    '  if (out != 0 && drop(x) || out + 1) return out ? 1 : 0;',
    '  int output = viewer + owned_count;',
    '  /* owned view */ const char *view str = "defer owned";',
    '  goto out;',
    '  x = a * view + b;',
    '}',
  ], [
    [0, 'out', null], [1, 'view *v', null], [1, 'view *w', null],
    [4, 'out', null], [4, 'view', null], [4, 'maybe', null],
    [5, 'out', null], [5, 'drop', null], [5, 'out ?', null],
    [6, 'output', null], [6, 'viewer', null], [6, 'owned_count', null],
    [7, 'owned', null], [7, 'view str', QUALIFIER], [7, 'defer', null],
    [8, 'out', null], [9, 'view', null],
  ]],
  ['defer, errdefer', [
    'void f(void)',
    '{',
    '  defer free(q);',
    '  defer { note("x"); }',
    '  errdefer mem_free(buf);',
    '  defer',
    '  if (p) return;',
    '}',
  ], [
    [2, 'defer', DEFER], [3, 'defer', DEFER], [4, 'errdefer', DEFER], [5, 'defer', DEFER],
    [6, 'if', 'c:keyword.control.c'], [3, '"x"', 'c:string.quoted.double.c'],
  ]],
  ['errors', [
    'error ParseError { Empty, BadDigit = 7, TooBig };',
    'error FsError',
    '{',
    '  FileNotFound = ENOENT, /* errno */ BadPath',
    '};',
    'static !int parse_int(const char *view s);',
    '!char *owned make_label(const char *view num);',
    '!vec2_t vec_parse(const char *view s);',
    '!struct stack *owned stack_new(int cap);',
    'static !int add(error ParseError pe, error any)',
    '{',
    '  if (!ok) return error.Empty;',
    '  int v = try parse_int(a) + try parse_int(b);',
    '  int a = parse_int("42") catch -1;',
    '  int b = parse_int(s) catch |e| {',
    '    printf("%s", error_name(e));',
    '  };',
    '  f() catch |err| { report(err); };',
    '  x = error_from(errno); n->next = move(head); f(borrow(p), s.move(1));',
    '  if (!vec_ok(v) && n != 0) return !x;',
    '  int error = 0; error = report.error; try = catch;',
    '  return v',
    '    catch 0;',
    '}',
  ], [
    [0, 'error', ERROR], [0, 'ParseError', ERRSET], [0, 'Empty', ERRNAME],
    [0, 'BadDigit', ERRNAME], [0, 'TooBig', ERRNAME], [0, '7', 'c:constant.numeric.decimal.c'],
    [1, 'error', ERROR], [1, 'FsError', ERRSET],
    [5, '!', BANG], [5, 'int', 'c:storage.type.built-in.primitive.c'],
    [6, '!', BANG], [7, '!', BANG], [8, '!', BANG],
    [9, '!', BANG], [9, 'error', ERROR], [9, 'ParseError', ERRSET], [9, 'error any', ERROR],
    [11, '!', null], [11, 'error', ERROR], [11, 'Empty', ERRNAME],
    [12, 'try', TRY], [12, 'try parse_int(b)', TRY],
    [13, 'catch', CATCH], [14, 'catch', CATCH], [14, 'e|', CAPTURE],
    [15, 'error_name', BUILTIN],
    [17, 'catch', CATCH], [17, 'err|', CAPTURE],
    [18, 'error_from', BUILTIN], [18, 'move', MOVE], [18, 'borrow', BORROW], [18, 'move(1)', null],
    [19, '!', null], [19, '!=', null], [19, '!x', null],
    [20, 'error', null], [20, 'error =', null], [20, 'error;', null],
    [20, 'try', null], [20, 'catch', null],
    [22, 'catch', CATCH],
  ]],
  ['modules', [
    'module lib.vec;',
    'import lib.shapes;',
    'export typedef struct vec2 { int x, y; } vec2_t;',
    'export vec2_t vec_add(vec2_t a, vec2_t b);',
    'int module = import + export;',
  ], [
    [0, 'module', IMPORT], [0, 'lib.vec', MODNAME], [1, 'import', IMPORT], [1, 'lib.shapes', MODNAME],
    [2, 'export', EXPORT], [2, 'typedef', 'c:keyword.other.typedef.c'], [3, 'export', EXPORT],
    [4, 'module', null], [4, 'import', null], [4, 'export', null],
  ]],
  ['owned(dealloc), borrows(x), takes(p), handles', [
    'FILE *?owned(fclose) fopen(const char *view path, const char *view mode);',
    'void *?@(owned, takes(p)) realloc(void *?owned p, size_t n);',
    'char *borrows(s) find(char *view s, int c);',
    'const char *borrows(static) err_name(int e);',
    'struct cache { char *owned buf; char *borrows(buf) key; };',
    'struct tokenizer borrows(text) { const char *borrows(text) pos; };',
    'void g(void)',
    '{',
    '  int ?owned(close) fd = open(path, O_RDONLY);',
    '  regex_t owned(regfree) re;',
    '}',
    'void use(int view fd, pid_t view p);',
    '!char *borrows(s) first_word(const char *view s);',
    'long strtol(const char *view s, out char *borrows(s) *?view end, int base);',
    'void name(int e, out const char *borrows(static) *view msg);',
  ], [
    [0, 'owned', QUALIFIER], [0, 'fclose', null], [0, '?', QUALIFIER], [0, 'view path', QUALIFIER],
    [1, 'owned', QUALIFIER], [1, 'takes', QUALIFIER], [1, 'realloc', null], [1, '@', QUALIFIER], [1, '?', QUALIFIER],
    [2, 'borrows', QUALIFIER], [3, 'borrows', QUALIFIER],
    [4, 'borrows', QUALIFIER], [5, 'borrows', QUALIFIER], [5, 'borrows(text) pos', QUALIFIER],
    [8, 'owned', QUALIFIER], [8, 'close', null], [8, '?', QUALIFIER],
    [9, 'owned', QUALIFIER], [11, 'view fd', QUALIFIER], [11, 'view p', QUALIFIER],
    [12, '!', BANG], [12, 'borrows', QUALIFIER],
    // borrows(...) on the pointer an out parameter points to
    [13, 'out', QUALIFIER], [13, 'borrows', QUALIFIER], [13, 's) *', null],
    [13, '?view', QUALIFIER], [13, 'view end', QUALIFIER], [13, 'end,', null],
    [14, 'out', QUALIFIER], [14, 'borrows', QUALIFIER], [14, 'view msg', QUALIFIER], [14, 'msg', null],
  ]],
  ['parameter array brackets; readonly is a name', [
    'int main(int argc, const char *view *view argv);',
    'int count(char *view a[owned], int b[?4], char *view c[view restrict]);',
    'const char *?view name(const char *view s);',
    'int readonly = 3; char *uid = 0, *readonly[] = {0};',
    'n = ARRAY_LEN(readonly); y = x * readonly; char * readonly p;',
  ], [
    [0, 'view *', QUALIFIER], [0, 'view argv', QUALIFIER], [0, 'argv', null],
    [1, 'owned]', QUALIFIER], [1, '?', QUALIFIER], [1, 'view c', QUALIFIER],
    [1, 'view restrict', QUALIFIER], [1, '4', null],
    [2, '?view', QUALIFIER], [2, 'view name', QUALIFIER], [2, 'view s', QUALIFIER],
    [3, 'readonly =', null], [3, 'readonly[]', null],
    [4, 'readonly)', null], [4, 'readonly;', null], [4, 'readonly p', null],
  ]],
  ['the list words as names', [
    'int f(void) { return owned(x) + borrows(y) + takes(z); }',
    'int view = 3; int view, x; x = owned(3); y = s.owned(1) * view;',
    'struct view v; int maybe; enum takes t; a = borrows (b);',
  ], [
    [0, 'owned', null], [0, 'borrows', null], [0, 'takes', null],
    [1, 'view =', null], [1, 'view,', null], [1, 'owned(3)', null], [1, 'owned(1)', null],
    [1, 'view;', null],
    [2, 'view v', null], [2, 'maybe', null], [2, 'takes', null], [2, 'borrows', null],
  ]],
  ['unsafe', [
    'void f(void)',
    '{',
    '  unsafe { p = (char *view)raw; }',
    '  const char *view name = unsafe(counter_name(borrow(c)));',
    '  unsafe {',
    '  }',
    '  int unsafe = 0; x = s.unsafe(1); unsafe = 2;',
    '}',
  ], [
    [2, 'unsafe', UNSAFE], [3, 'unsafe', UNSAFE], [4, 'unsafe', UNSAFE],
    [6, 'unsafe =', null], [6, 'unsafe(1)', null], [6, 'unsafe = 2', null],
  ]],
  ['tagged unions', [
    'struct value {',
    '  int k;',
    '  union(k) { long i when(V_INT); char *view s when(V_STR, V_SYM); } u;',
    '  int buf[4] when(V_BUF);',
    '};',
    'void f(void) { GUARD(when(is_imm32(src2)); and(x)); return when(x); int when; }',
    '#define when(expr) ok = !!(expr)',
  ], [
    [2, 'union', 'c:storage.type.union.c'], [2, 'when(V_INT)', WHEN], [2, 'V_INT', null],
    [2, 'when(V_STR', WHEN], [3, 'when', WHEN],
    [5, 'when(is', null], [5, 'when(x)', null], [5, 'when;', null], [6, 'when', null],
  ]],
  ['unreachable', [
    '  unreachable;',
    '  default: unreachable;',
    '  int v = get(x) catch unreachable;',
    '  if (x) unreachable;',
    '  else unreachable;',
    '  use(get(x) catch unreachable);',
    '  int unreachable;',
    '  unreachable();',
    '  x = unreachable;',
    '  s.unreachable; p->unreachable;',
    'int f(int unreachable) {',
  ], [
    [0, 'unreachable', UNREACHABLE], [1, 'unreachable', UNREACHABLE], [2, 'unreachable', UNREACHABLE],
    [3, 'unreachable', UNREACHABLE], [4, 'unreachable', UNREACHABLE], [5, 'unreachable', UNREACHABLE],
    [2, 'catch', CATCH], [5, 'catch', CATCH],
    [6, 'unreachable', null], [7, 'unreachable', null], [8, 'unreachable', null], [9, 'unreachable', null],
    [9, 'unreachable;', null], [10, 'unreachable', null],
  ]],
  ['= undefined', [
    '  struct stat st = undefined;',
    '  int k = undefined; sscanf(s, "%d", &k);',
    '  int a = undefined, b = 1;',
    '  int k=undefined;',
    '  int undefined;',
    '  if (x == undefined) {',
    '  x += undefined;',
    '  undefined;',
    '  s.undefined = 1; f(undefined);',
    '  if (y != undefined || y <= undefined) {',
  ], [
    [0, 'undefined', UNDEFINED], [1, 'undefined', UNDEFINED], [2, 'undefined', UNDEFINED],
    [3, 'undefined', UNDEFINED],
    [4, 'undefined', null], [5, 'undefined', null], [6, 'undefined', null],
    [7, 'undefined', null], [8, 'undefined =', null], [8, 'undefined)', null],
    [9, 'undefined ||', null], [9, 'undefined)', null],
  ]],
  ['cast<...> / unsafe_cast<...>', [
    'uint16_t port = cast<int(uint16_t)>(n); float f = cast< float (double) >(d);',
    'auto de = cast<ptr(struct dirent *), align>(dir->buf + pos);',
    'char *view hit = unsafe_cast<qual(char *)>(s); x = cast<align(4)>(p);',
    'if (cast < as && trunc > 1) return cast(int, x); s.cast = p->unsafe_cast;',
    'y = cast<trunc(uint8_t)>(f(a, int(b)) > 0);',
  ], [
    [0, 'cast<int', CAST], [0, '<int', CASTOPEN], [0, 'int(uint16_t)', PERM],
    [0, 'uint16_t)', 'c:storage.type.built-in.c'], [0, '>(n)', CASTCLOSE],
    [0, 'cast< float', CAST], [0, 'float (double)', PERM], [0, 'double', 'c:storage.type.built-in.primitive.c'],
    [0, ' >(d)', null], [0, '>(d)', CASTCLOSE], [0, 'float f', null],
    [1, 'cast', CAST], [1, 'ptr', PERM], [1, 'align', PERM], [1, 'dirent', null], [1, '>(dir', CASTCLOSE],
    [1, '->buf', null],
    [2, 'unsafe_cast', UNSAFECAST], [2, 'qual', PERM], [2, 'align(4)', PERM], [2, '>(s)', CASTCLOSE],
    [3, 'cast <', null], [3, '< as', null], [3, 'as &&', null], [3, 'trunc >', null], [3, '> 1', null],
    [3, 'cast(int', null], [3, 'int, x', null], [3, 'cast =', null], [3, 'unsafe_cast;', null],
    [4, 'trunc', PERM], [4, 'int(b)', null], [4, '> 0', null],
  ]],
  ['register fields', [
    'struct uart_regs {',
    '  volatile uint32_t data wo;',
    '  volatile uint32_t status w1c;',
    '  volatile reg_t id ro;',
    '  uint32_t irq:1 w1c, err : 2 ro;',
    '  uint32_t * p ro, fifo[4] wo;',
    '};',
    'int ro; unsigned int wo; struct s w1c; const my_t ro; my_t wo;',
    'void f(void) { return ro; goto wo; x = w1c; f(ro, wo); }',
  ], [
    [1, 'wo', REG], [2, 'w1c', REG], [3, 'ro', REG], [4, 'w1c', REG], [4, 'ro', REG],
    [5, 'ro', REG], [5, 'wo', REG],
    [7, 'ro', null], [7, 'wo', null], [7, 'w1c', null], [7, 'ro; my', null], [7, 'wo;', null],
    [8, 'ro', null], [8, 'wo', null], [8, 'w1c', null], [8, 'ro,', null],
  ]],
  ['C23 and GNU words', [
    'constexpr int z = 1; int * p = nullptr; typeof(x) y; __typeof__(y) w; __auto_type q = 1;',
    'int a = alignof(int); s.constexpr = x->nullptr;',
    'auto v = borrow(p); const auto n = 3; auto int k; s.auto = x->auto;',
  ], [
    [0, 'constexpr', 'storage.modifier.constexpr.yasc.c'], [0, 'nullptr', 'constant.language.nullptr.yasc.c'],
    [0, 'typeof', 'keyword.operator.typeof.yasc.c'], [0, '__typeof__', 'keyword.operator.typeof.yasc.c'],
    [0, '__auto_type', 'storage.type.auto.yasc.c'], [1, 'alignof', 'keyword.operator.typeof.yasc.c'],
    [1, 'constexpr', null], [1, 'nullptr', null],
    [2, 'auto', 'storage.type.auto.yasc.c'], [2, 'auto n', 'storage.type.auto.yasc.c'],
    [2, 'auto int', 'storage.type.auto.yasc.c'], [2, 'auto =', null], [2, 'auto;', null],
  ]],
  ['@min and @max', [
    'size_t n = @min(buflen, PATH_MAX);',
    'int v = @max(lo, @min(x, hi)), minimum = min(a, b);',
    'f(@ min(a)); /* @min(a, b) */ s = "@max(a, b)";',
  ], [
    [0, '@min', ATBUILTIN], [0, 'min(', ATBUILTIN], [0, 'buflen', null],
    [1, '@max', ATBUILTIN], [1, '@min', ATBUILTIN], [1, 'minimum', null], [1, 'min(a', null],
    [2, 'min(a))', null], [2, '@min(a, b) */', null], [2, '@max', null],
  ]],
  ['slices', [
    '[:0]char s = path[0:len:0];',
    'static []const char names = list[1:];',
    'size_t count([]char *view argv, [ : 0 ]const char p, [][]int rows);',
    't = s[:n]; x = a[c ? 1 : 2]; [[gnu::unused]] int z;',
    'int a[] __attribute__((unused)); char *argv[]; v = m[i][j];',
    'struct line { [:0]char text; };',
    "case '[': end = ']'; break; case L'[': case L'\\\\': case L']':",
  ], [
    [0, '[:0]', SLICE], [0, ':0]char', SLICE], [0, 'char', 'c:storage.type.built-in.primitive.c'],
    [0, ':len', SLICEOP], [0, ':0];', SLICEOP], [0, 'path', null], [0, 'len', null],
    [1, '[]', SLICE], [1, 'static', 'c:storage.modifier.c'], [1, ':]', SLICEOP],
    [2, '[]char', SLICE], [2, '[ :', SLICE], [2, '[][]', SLICE], [2, '][]int', SLICE],
    [3, ':n', SLICEOP], [3, ': 2', null], [3, '::unused', null],
    [4, '[]', null], [4, '[];', null], [4, '[j]', null],
    [5, '[:0]', SLICE], [6, ': end', null], [6, ": case L'\\\\", null], [6, ": case L']", null],
  ]],
  ['comments and strings stay', [
    '// char *owned p; defer free(p);',
    'const char *view s = "try f() catch |e| error.X";',
    '/* [:0]char s = p[0:n:0]; */ const char *t = "[]char s[1:]";',
  ], [[0, 'owned', null], [0, 'defer', null], [1, 'try', null], [1, 'catch', null], [1, 'error', null],
    [2, '[:0]', null], [2, ':n', null], [2, '[]char', null], [2, ':]', null]]],
];

async function main() {
  const wasm = fs.readFileSync(path.join(app, 'node_modules/vscode-oniguruma/release/onig.wasm'));
  await onig.loadWASM(wasm.buffer);
  const registry = new tm.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (s) => new onig.OnigScanner(s),
      createOnigString: (s) => new onig.OnigString(s),
    }),
    loadGrammar: async (scope) => {
      const file = grammars[scope];
      return file ? tm.parseRawGrammar(fs.readFileSync(file, 'utf8'), file) : null;
    },
    getInjections: (scope) => (scope === 'source.c' ? injections : undefined),
  });
  const grammar = await registry.loadGrammar('source.c');

  let failures = 0;
  // A lookaround nested in a variable-length lookbehind makes Oniguruma report
  // an empty match at 0 on any line, which silently disables the whole
  // injection: no rule may match an empty string.
  const yasc = JSON.parse(fs.readFileSync(grammars['source.c.yasc'], 'utf8'));
  const walk = (o) => Object.entries(o).forEach(([k, v]) => {
    if (k === 'match' && typeof v === 'string') {
      const m = new onig.OnigScanner([v]).findNextMatchSync(new onig.OnigString('x = 1;'), 0);
      if (m && m.captureIndices[0].length === 0) {
        failures++;
        console.log(`FAIL empty match: ${v}`);
      }
    } else if (v && typeof v === 'object') {
      walk(v);
    }
  });
  walk(yasc);
  for (const [name, lines, checks] of cases) {
    let state = tm.INITIAL;
    const tokens = lines.map((line) => {
      const r = grammar.tokenizeLine(line, state);
      state = r.ruleStack;
      return r.tokens;
    });
    for (const [ln, needle, want] of checks) {
      const col = lines[ln].indexOf(needle);
      if (col < 0) throw new Error(`${name}: '${needle}' not on line ${ln}`);
      const tok = tokens[ln].find((t) => t.startIndex <= col && col < t.endIndex);
      const scopes = tok.scopes;
      const yasc = scopes.find((s) => s.endsWith('.yasc.c')) || null;
      const ok = want !== null && want.startsWith('c:') ? scopes.includes(want.slice(2)) : yasc === want;
      if (!ok) {
        failures++;
        console.log(`FAIL ${name}: line ${ln} '${needle}': ${scopes.join(' ')} (want ${want})`);
      }
    }
  }
  console.log(failures ? `${failures} check(s) failed` : 'all checks passed');
  process.exit(failures ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(2); });
