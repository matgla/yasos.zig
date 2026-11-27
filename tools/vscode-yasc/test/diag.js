// The diagnostics side without VSCode: tcc's messages parsed, which files are
// yasc, and (when the cross is built) one real check of a buffer on stdin.
// Run: node test/diag.js
'use strict';
const assert = require('assert');
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const tcc = require('../tcc');
const squiggles = require('../squiggles');

const root = path.resolve(__dirname, '../../..');
let failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log('ok   ' + name);
  } catch (e) {
    failed++;
    console.log('FAIL ' + name + '\n     ' + e.message.split('\n').join('\n     '));
  }
}

test('globs', () => {
  const g = tcc.globToRegex('libs/tinycc/examples/yasc/**');
  assert(g.test('libs/tinycc/examples/yasc/02_ownership.c'));
  assert(g.test('libs/tinycc/examples/yasc/sub/x.c'));
  assert(!g.test('libs/tinycc/examples/other.c'));
  assert(tcc.globToRegex('**/*.c').test('a.c'));
  assert(tcc.globToRegex('**/*.c').test('a/b/c.c'));
  assert(!tcc.globToRegex('a/*.c').test('a/b/c.c'));
});

test('in/out erased only where they are never names', () => {
  assert.deepStrictEqual(tcc.paramWordDefines('static bool parse(inout char *line, out struct f *f);'), ['out=']);
  assert.deepStrictEqual(tcc.paramWordDefines('int f(in const char *s, out size_t *n) { return 0; }'), ['in=', 'out=']);
  // a name anywhere keeps the word: `out char *out`, `s.out`, `goto out`
  assert.deepStrictEqual(tcc.paramWordDefines('int f(out char *out) { out[0] = 0; }'), []);
  assert.deepStrictEqual(tcc.paramWordDefines('void f(out T *p) { s.out = 1; }'), []);
  assert.deepStrictEqual(tcc.paramWordDefines('void f(out T *p) { goto out; out: ; }'), []);
  // comments, strings and #include do not count
  assert.deepStrictEqual(tcc.paramWordDefines('#include "x.h"\n/* out-> */ char *s = "in)";\nvoid f(out T *p);'), ['out=']);
  assert.deepStrictEqual(tcc.paramWordDefines('int x;'), []);
});

test('messages, notes, include chains', () => {
  const err = [
    '/w/a.c:33: error: plain pointer in yasc: say owned or view for \'path\'',
    '/w/a.c:33: note: the function only borrows \'path\' (line 37): write \'*?view\'',
    'In file included from /w/a.c:2:',
    'In file included from y.h:1:',
    'x.h:2: error: expression expected before \';\'',
    '-:3: warning: \'x\' is used uninitialized',
    'tcc: error: file \'nothere.c\' not found',
  ].join('\n');
  const d = tcc.parseOutput(err, '/w');
  assert.strictEqual(d.length, 5);
  assert.deepStrictEqual([d[0].file, d[0].line, d[0].severity], ['/w/a.c', 33, 'error']);
  assert.strictEqual(d[1].severity, 'note');
  assert.deepStrictEqual(d[2].chain, [{ file: '/w/a.c', line: 2 }, { file: '/w/y.h', line: 1 }]);
  assert.deepStrictEqual(tcc.placeInFile(d[2], '/w/a.c'), { line: 2, header: { file: '/w/x.h', line: 2 } });
  assert.deepStrictEqual(tcc.placeInFile(d[0], '/w/a.c'), { line: 33, header: null });
  assert.strictEqual(d[3].file, '-');
  assert.deepStrictEqual([d[4].file, d[4].line], [null, 0]);
});

test('compiler info', () => {
  const vv = 'tcc version 0.9.28rc (ARM YasOS)\ninstall: /x\ninclude:\n  /r/usr/include\n  /x/include\nlibraries:\n  /r/usr/lib\n';
  assert.deepStrictEqual(tcc.parseIncludeDirs(vv), ['/r/usr/include', '/x/include']);
  const dm = '#define __TINYC__ 928\n#define __YASC__ 1\n#define __STDC_VERSION__ 202311L\n' +
    '#define __has_feature(x) 0\n#define __thumb__ 1\n#define __ARMEL__\n' +
    '#define __FLT_MAX__ <float>\n#define __LDBL_MIN__ <long double>\n#define __FLT_DIG__ 6\n' +
    '#define __PRETTY_FUNCTION__ __FUNCTION__\n#define __BASE_FILE__ "-"\n';
  assert.deepStrictEqual(tcc.parsePredefs(dm), ['__TINYC__=928', '__thumb__=1', '__ARMEL__', '__FLT_DIG__=6']);
});

test('the compiler: a setting, else the newest cross this machine runs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'yasc-cc-'));
  const elf = (rel, machine, when) => {
    const f = path.join(dir, rel);
    fs.mkdirSync(path.dirname(f), { recursive: true });
    const h = Buffer.alloc(64);
    h.writeUInt32BE(0x7f454c46, 0);
    h[4] = 2;
    h.writeUInt16LE(machine, 18);
    fs.writeFileSync(f, h);
    fs.utimesSync(f, when, when);
    return f;
  };
  try {
    const bin = path.join(dir, 'libs/tinycc/bin/armv8m-tcc');
    assert.strictEqual(tcc.pickCompiler(dir, ''), bin); // none built
    elf('libs/tinycc/bin/armv8m-tcc', 62, 1000);
    const cross = elf('libs/tinycc/armv8m-tcc', 62, 2000);
    if (process.arch === 'x64') {
      assert.strictEqual(tcc.pickCompiler(dir, ''), cross); // make cross is newer
      elf('libs/tinycc/armv8m-tcc', 40, 3000); // build_rootfs.sh's native ARM tcc
      assert.strictEqual(tcc.pickCompiler(dir, undefined), bin);
    }
    assert.strictEqual(tcc.pickCompiler(dir, '${workspaceFolder}/x/tcc'), path.join(dir, 'x/tcc'));
    assert.strictEqual(tcc.pickCompiler(dir, 'y/tcc'), path.join(dir, 'y/tcc'));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('which files are yasc', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'yasc-'));
  fs.mkdirSync(path.join(dir, 'scripts'));
  fs.mkdirSync(path.join(dir, 'libs/libc/include'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'other'));
  fs.writeFileSync(path.join(dir, 'scripts/safe_mode_ratchet.json'),
    JSON.stringify({ dirs: { 'libs/libc': { errors: 1, warnings: 0, flags: ['-DX=1'] }, 'apps/a': {} } }));
  fs.writeFileSync(path.join(dir, 'other/p.c'), '/* x */\n#pragma yasc\nint x;\n');
  fs.writeFileSync(path.join(dir, 'other/q.c'), 'int x;\n');
  const p = tcc.loadProject(dir, undefined, ['ex/**']);
  assert.deepStrictEqual(tcc.classify(p, path.join(dir, 'libs/libc/sub/libgen.c')), { dir: 'libs/libc', flags: ['-DX=1'] });
  assert.deepStrictEqual(tcc.classify(p, path.join(dir, 'ex/a.c'), ''), { dir: 'ex', flags: [] });
  assert.deepStrictEqual(tcc.classify(p, path.join(dir, 'other/p.c')), { dir: 'other', flags: [] });
  assert.strictEqual(tcc.classify(p, path.join(dir, 'other/q.c')), null);
  assert.strictEqual(tcc.classify(p, path.join(dir, 'libs/libc/x.zig'), ''), null);
  assert.strictEqual(tcc.classify(p, '/elsewhere/libs/libc/x.c', ''), null);
  const file = path.join(dir, 'libs/libc/sub/libgen.c');
  assert.deepStrictEqual(tcc.checkArgs(p, file, tcc.classify(p, file), ['-W']), [
    '-fsyntax-only', '-fmax-errors=0', '-I' + path.dirname(file), '-I' + path.join(dir, 'libs/libc'),
    '-I' + path.join(dir, 'libs/libc/include'), '-DX=1', '-W', '-']);
  fs.rmSync(dir, { recursive: true });
});

test('IntelliSense errors in yasc files: only where tcc agrees', () => {
  // VSCode's shape: one base class, an anonymous subclass per collection
  class Base {
    constructor(name) {
      this._name = name;
      this.data = new Map();
    }
    get name() { return this._name; }
    set(uri, d) {
      if (Array.isArray(uri)) for (const [u, x] of uri) this.set(u, x);
      else if (!d) this.data.delete(uri.toString());
      else this.data.set(uri.toString(), d);
    }
    get(uri) { return this.data.get(uri.toString()); }
    delete(uri) { this.data.delete(uri.toString()); }
    clear() { this.data.clear(); }
  }
  const make = (name) => new (class extends Base {})(name);
  const ERROR = 0;
  const WARNING = 1;
  const diag = (line, severity, source = 'C/C++') => ({ range: { start: { line } }, severity, source });
  const ours = make('tcc');
  const cpp = make('C/C++: IntelliSense');
  const other = make('C/C++: IntelliSense');
  const tccLines = new Map([['file:///w/a.c', new Set([4])]]);
  const f = squiggles.install(ours, (uri) => tccLines.get(uri.toString()) || null, ERROR);
  assert(f);
  const a = 'file:///w/a.c';
  const errs = [diag(1, ERROR), diag(4, ERROR), diag(2, WARNING), diag(3, ERROR, 'other')];
  cpp.set(a, errs);
  // line 1: tcc has no error there (`@min`, a slice); line 4 kept; warnings and other sources kept
  assert.deepStrictEqual(cpp.data.get(a).map((d) => d.range.start.line), [4, 2, 3]);
  assert.strictEqual(cpp.get(a).length, 3); // getDiagnostics sees what the editor shows
  ours.set(a, [diag(1, ERROR)]);
  assert.strictEqual(ours.data.get(a).length, 1); // other collections untouched
  cpp.set('file:///w/b.c', errs);
  assert.strictEqual(cpp.data.get('file:///w/b.c').length, 4); // not a yasc file
  tccLines.set(a, new Set([1, 4]));
  f.refresh(a);
  assert.deepStrictEqual(cpp.data.get(a).map((d) => d.range.start.line), [1, 4, 2, 3]);
  tccLines.set(a, new Set());
  f.refreshAll();
  assert.deepStrictEqual(cpp.data.get(a).map((d) => d.range.start.line), [2, 3]);
  other.set(a, errs); // a second C/C++ collection keeps its own list
  cpp.delete(a);
  assert.strictEqual(cpp.get(a), undefined);
  tccLines.set(a, new Set([1]));
  f.refresh(a);
  assert.strictEqual(cpp.get(a), undefined); // deleted stays deleted
  assert.deepStrictEqual(other.get(a).map((d) => d.range.start.line), [1, 2, 3]);
  cpp.set(a, errs);
  f.dispose();
  assert.strictEqual(cpp.data.get(a).length, 4); // restored, set no longer wrapped
  cpp.set(a, errs.slice(0, 1));
  assert.strictEqual(cpp.data.get(a).length, 1);
});

test('IntelliSense "unused" for a name used where it cannot parse', () => {
  const ERROR = 0;
  const HINT = 3;
  const text = [
    'size_t len, end;', // 0
    'int unused_one;', // 1
    '[]char s = path[0:len];', // 2: IntelliSense error, tcc fine
    'x = bad;', // 3: IntelliSense and tcc error
    'int bad;', // 4
  ].join('\n');
  const d = (line, severity, message, code) => ({ range: { start: { line } }, severity, source: 'C/C++', message, code });
  const diags = [
    d(0, HINT, 'variable "len" was set but never used', '550'),
    d(1, HINT, 'variable "unused_one" was declared but never referenced', { value: 177 }),
    d(2, ERROR, 'expected an expression', '29'),
    d(3, ERROR, 'identifier "bad" is undefined', '20'),
    d(4, HINT, 'variable "bad" was set but never used', 550),
    d(0, HINT, 'variable "end" was set but never used', '550'),
  ];
  const msgs = (r) => r.map((x) => x.message);
  // "len" appears on the hidden error's line; "bad" only on a line tcc rejects too
  assert.deepStrictEqual(msgs(squiggles.keep(diags, new Set([3]), ERROR, text)),
    [diags[1], diags[3], diags[4], diags[5]].map((x) => x.message));
  // no text: only errors are filtered
  assert.strictEqual(squiggles.keep(diags, new Set([3]), ERROR, null).length, 5);
});

test('format: the smallest line edit', () => {
  const apply = (o, e) => (e ? o.slice(0, e.start) + e.text + o.slice(e.end) : o);
  const cases = [
    ['a\nb\nc\n', 'a\nB\nc\n', { start: 2, end: 4, text: 'B\n' }],
    ['a\nb\nc', 'a\nb\nc\n', null],
    ['', 'x\n', null],
    ['x\n', '', null],
    ['a\nb\n', 'a\nb\nb\n', null],
  ];
  for (const [o, n, want] of cases) {
    const e = tcc.lineEdit(o, n);
    if (want) assert.deepStrictEqual(e, want);
    assert.strictEqual(apply(o, e), n, JSON.stringify([o, n]));
  }
  assert.strictEqual(tcc.lineEdit('same\n', 'same\n'), null);
});

test('format: the .tcc-format above a file is the opt-in', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'yasc-fmt-'));
  fs.mkdirSync(path.join(dir, 'a', 'b'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'a', '.tcc-format'), 'IndentWidth: 2\n');
  assert.strictEqual(tcc.findFormatConfig(path.join(dir, 'a', 'b', 'x.c')), path.join(dir, 'a', '.tcc-format'));
  assert.strictEqual(tcc.findFormatConfig(path.join(dir, 'y.c')), null);
  assert.deepStrictEqual(tcc.formatArgs('/w/x.c'), ['-format', '-assume-filename=/w/x.c']);
  fs.rmSync(dir, { recursive: true });
});

const exe = path.join(root, 'libs/tinycc/bin/armv8m-tcc');
if (fs.existsSync(exe)) {
  test('a real check: unsaved text on stdin names the file', () => {
    const p = tcc.loadProject(root);
    const file = path.join(root, 'libs/libc/libgen.c');
    const info = tcc.classify(p, file);
    assert(info && info.dir === 'libs/libc');
    const text = 'char *f(char *p) { return p; }\nint g(void) { int x; return x; }\n';
    const r = cp.spawnSync(exe, tcc.checkArgs(p, file, info), { cwd: root, input: tcc.stdinFor(file, text), encoding: 'utf8' });
    const d = tcc.parseOutput(r.stderr, root);
    assert(d.length >= 2, r.stderr);
    assert(d.every((x) => x.file === file), r.stderr);
    assert(d.some((x) => x.line === 1 && x.severity === 'error' && /plain pointer/.test(x.message)), r.stderr);
    assert(d.some((x) => x.line === 2 && /uninitialized/.test(x.message)), r.stderr);
  });
  // A yasc header is checked alone (its IntelliSense errors are filtered by
  // tcc's lines): the libc yasc headers must compile alone without a message,
  // or `void *owned(dlclose) dlopen(...)` keeps IntelliSense's "expected a ';'".
  test('a real check: yasc headers compile alone', () => {
    const p = tcc.loadProject(root);
    const dir = path.join(root, 'libs/libc/include/yasc');
    for (const name of ['dlfcn.h', 'stdio.h', 'stdlib.h', 'string.h', 'unistd.h']) {
      const file = path.join(dir, name);
      if (!fs.existsSync(file)) continue;
      const text = fs.readFileSync(file, 'utf8');
      const info = tcc.classify(p, file, text);
      assert(info, file);
      const r = cp.spawnSync(exe, tcc.checkArgs(p, file, info), { cwd: root, input: tcc.stdinFor(file, text), encoding: 'utf8' });
      assert.strictEqual(r.status, 0, file + ': ' + r.stderr);
      assert.deepStrictEqual(tcc.parseOutput(r.stderr, root), [], file + ': ' + r.stderr);
    }
  });
} else {
  console.log('skip a real check (no ' + exe + ')');
}

// clang-format on a buffer, for files under no .tcc-format.
if (cp.spawnSync('clang-format', ['--version']).status === 0) {
  test('a real clang-format: the repository .clang-format, the buffer on stdin', () => {
    const file = path.join(root, 'apps', 'x.c');
    const text = 'int  f( void ){return 0;}\n';
    const r = cp.spawnSync('clang-format', tcc.clangFormatArgs(file), { input: text, encoding: 'utf8' });
    assert.strictEqual(r.status, 0, r.stderr);
    assert.strictEqual(r.stdout.replace(/\n$/, ''), 'int f(void) {\n  return 0;\n}'.replace(/\n$/, ''));
  });
}

// tcc -format on a buffer, when the cross has it (`make cross` in tinycc).
const fmtExe = [path.join(root, 'libs/tinycc/bin/armv8m-tcc'), path.join(root, 'libs/tinycc/armv8m-tcc')]
  .find((f) => fs.existsSync(f) && cp.spawnSync(f, ['-format', '-h'], { encoding: 'utf8' }).status === 0);
if (fmtExe) {
  test('a real format: the buffer on stdin, the edit applied', () => {
    const text = 'int  f( void ){return 0;}\n';
    const r = cp.spawnSync(fmtExe, tcc.formatArgs(path.join(os.tmpdir(), 'x.c')), { input: text, encoding: 'utf8' });
    assert.strictEqual(r.status, 0, r.stderr);
    assert.strictEqual(r.stdout, 'int f(void) {\n  return 0;\n}\n');
    const e = tcc.lineEdit(text, r.stdout);
    assert.strictEqual(text.slice(0, e.start) + e.text + text.slice(e.end), r.stdout);
  });
} else {
  console.log('skip a real format (no tcc with -format)');
}

if (failed) {
  console.log(failed + ' failed');
  process.exit(1);
}
