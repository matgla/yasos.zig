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
const BANG = 'storage.modifier.errunion.yasc.c';
const IMPORT = 'keyword.control.import.yasc.c';
const MODNAME = 'entity.name.namespace.yasc.c';
const EXPORT = 'storage.modifier.export.yasc.c';

// [source lines, [[line, needle, expected scope or null], ...]]: needle's
// first word (or its first character when it does not start with a word), at
// needle's first occurrence on that line. null: no yasc scope. 'c:<scope>'
// instead checks that the C grammar's own scope is there (C highlighting goes
// on around the yasc words).
const cases = [
  ['ownership qualifiers', [
    '/* comment first */',
    'char * owned dup(const char * view s);',
    'void fill(out int * view p, drop char * owned q, int * view maybe m)',
    '{',
    '  char * owned * view argv = 0;',
    '  struct name * owned maybe next;',
    '  int f(char * view, int *view);',
    '}',
  ], [
    [1, 'owned', QUALIFIER], [1, 'view', QUALIFIER], [1, 'dup', null],
    [2, 'out', QUALIFIER], [2, 'view p', QUALIFIER], [2, 'drop', QUALIFIER],
    [2, 'owned q', QUALIFIER], [2, 'maybe', QUALIFIER],
    [4, 'owned', QUALIFIER], [4, 'view', QUALIFIER],
    [5, 'owned', QUALIFIER], [5, 'maybe', QUALIFIER],
    [6, 'view,', QUALIFIER], [6, 'view)', QUALIFIER],
    [1, 'const', 'c:storage.modifier.c'], [1, 'char', 'c:storage.type.built-in.primitive.c'],
    [0, 'comment', 'c:comment.block.c'],
  ]],
  ['the words as names', [
    'int out;',
    'struct view *v; view *w;',
    'void g(void)',
    '{',
    '  out->len = s.view + p->maybe;',
    '  if (out != 0 && drop(x) || out + 1) return out ? 1 : 0;',
    '  int output = viewer + owned_count;',
    '  /* owned view */ const char * view str = "defer owned";',
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
    'static !int parse_int(const char * view s);',
    '!char * owned make_label(const char * view num);',
    '!vec2_t vec_parse(const char * view s);',
    '!struct stack * owned stack_new(int cap);',
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
    [18, 'error_from', BUILTIN], [18, 'move', BUILTIN], [18, 'borrow', BUILTIN], [18, 'move(1)', null],
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
  ['comments and strings stay', [
    '// char * owned p; defer free(p);',
    'const char * view s = "try f() catch |e| error.X";',
  ], [[0, 'owned', null], [0, 'defer', null], [1, 'try', null], [1, 'catch', null], [1, 'error', null]]],
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
