// The C/C++ extension's IntelliSense errors in yasc files.
//
// IntelliSense parses plain C, and some yasc no macro can turn into C:
// `@min(a, b)` ('unrecognized token' at the `@`), slices (`[]const char s`,
// `p[0:n]`, after which every use of `s` is 'undefined'), `catch`, `!T`,
// `owned(dealloc)`...  EDG's `#pragma diag_suppress` cannot silence these
// (they are not discretionary), and C_Cpp.errorSquiggles is one setting for
// the whole workspace folder.  So the extension filters what the C/C++
// extension publishes: in a file tcc checks, an IntelliSense error stays only
// on a line where tcc reports an error too (tcc compiles the file; a line it
// accepts is valid yasc).  Warnings and hints stay, except an "unused"
// hint for a name used on a line whose error is hidden; other files are left
// alone.
//
// How: VSCode gives each extension its collections as subclasses of one
// DiagnosticCollection class in the extension host, so wrapping that class's
// set/delete/clear (found from one of our own collections) sees the C/C++
// extension's "C/C++: IntelliSense" collection too.  `get` is left alone:
// vscode.languages.getDiagnostics reads through it, so other extensions see
// what the editor shows.  (The C/C++ extension also reads its squiggles back
// with `get` to add a partial result: the errors hidden before stay hidden,
// and tcc marks those lines itself.)
// Plain node, no vscode: test/diag.js runs it against a fake collection.
'use strict';

const CPP_COLLECTION = /^C\/C\+\+.*IntelliSense/;
const CPP_SOURCE = 'C/C++';

// EDG's "never used" family: 177 declared but never referenced, 550 set but
// never used, 869 parameter never referenced.  A use IntelliSense cannot
// parse (`path[0:len]`) does not count for it, so in `size_t len; ...
// []char s = path[0:len];` it calls `len` unused.
const UNUSED_CODES = new Set(['177', '550', '869']);

function codeOf(d) {
  const c = d.code && typeof d.code === 'object' ? d.code.value : d.code;
  return c === undefined || c === null ? '' : String(c);
}

// IntelliSense's diagnostics that stay, given the lines (0-based) where tcc
// reports an error and the file's text (null when unknown).  Its errors stay
// on tcc's error lines only; with the text, an "unused" hint for a name that
// appears on a line whose error is hidden goes too (the use is in yasc
// IntelliSense could not read).
function keep(diags, tccErrorLines, errorSeverity, text) {
  const isCppError = (d) => d.source === CPP_SOURCE && d.severity === errorSeverity;
  const hiddenLines = new Set(diags
    .filter((d) => isCppError(d) && !tccErrorLines.has(d.range.start.line))
    .map((d) => d.range.start.line));
  let names = null;
  if (text && hiddenLines.size) {
    names = new Set();
    const lines = text.split('\n');
    for (const l of hiddenLines) for (const w of (lines[l] || '').match(/[A-Za-z_]\w*/g) || []) names.add(w);
  }
  return diags.filter((d) => {
    if (d.source !== CPP_SOURCE) return true;
    if (d.severity === errorSeverity) return !hiddenLines.has(d.range.start.line);
    if (names && UNUSED_CODES.has(codeOf(d))) {
      const m = /"([A-Za-z_]\w*)"/.exec(d.message || '');
      if (m && names.has(m[1])) return false;
    }
    return true;
  });
}

// `probe`: any DiagnosticCollection of ours.  `linesFor(uri)`: the Set of
// tcc's error lines for a file whose IntelliSense errors are filtered, null
// to leave the file alone.  `textOf(uri)` (optional): the file's text, null
// when unknown.  Returns {refresh(uri), refreshAll(), dispose()}, or null when
// the collection class is not as expected.
function install(probe, linesFor, errorSeverity, textOf) {
  let proto = Object.getPrototypeOf(probe);
  while (proto && !Object.prototype.hasOwnProperty.call(proto, 'set')) proto = Object.getPrototypeOf(proto);
  if (!proto || ['delete', 'clear'].some((m) => typeof proto[m] !== 'function')) return null;
  const orig = { set: proto.set, delete: proto.delete, clear: proto.clear };
  // collection -> Map(uri string -> {uri, diags}): what the C/C++ extension set
  const raw = new Map();
  const rawOf = (coll) => {
    let m = raw.get(coll);
    if (!m) raw.set(coll, (m = new Map()));
    return m;
  };
  const isCpp = (coll) => typeof coll.name === 'string' && CPP_COLLECTION.test(coll.name);

  const filtered = (uri, diags) => {
    let lines = null;
    let text = null;
    try {
      lines = linesFor(uri);
      if (lines && textOf) text = textOf(uri);
    } catch (e) {
      if (!lines) return diags;
    }
    return lines ? keep(diags, lines, errorSeverity, text) : diags;
  };

  proto.set = function (a, b) {
    if (!isCpp(this)) return orig.set.apply(this, arguments);
    if (Array.isArray(a)) {
      // [[uri, diags | undefined], ...] (the C/C++ extension does not use it)
      for (const [uri] of a) rawOf(this).delete(uri.toString());
      return orig.set.call(this, a.map(([uri, d]) => [uri, d ? filtered(uri, d) : d]));
    }
    const key = a.toString();
    if (!b) {
      rawOf(this).delete(key);
      return orig.set.call(this, a, b);
    }
    rawOf(this).set(key, { uri: a, diags: b.slice() });
    return orig.set.call(this, a, filtered(a, b));
  };
  proto.delete = function (uri) {
    if (isCpp(this)) rawOf(this).delete(uri.toString());
    return orig.delete.apply(this, arguments);
  };
  proto.clear = function () {
    if (isCpp(this)) raw.delete(this);
    return orig.clear.apply(this, arguments);
  };

  return {
    refresh(uri) {
      const key = uri.toString();
      for (const [coll, m] of raw) {
        const r = m.get(key);
        if (r) orig.set.call(coll, r.uri, filtered(r.uri, r.diags));
      }
    },
    refreshAll() {
      for (const [coll, m] of raw) for (const r of m.values()) orig.set.call(coll, r.uri, filtered(r.uri, r.diags));
    },
    dispose() {
      Object.assign(proto, orig);
      for (const [coll, m] of raw) for (const r of m.values()) orig.set.call(coll, r.uri, r.diags);
      raw.clear();
    },
  };
}

module.exports = { keep, install, CPP_COLLECTION, CPP_SOURCE };
