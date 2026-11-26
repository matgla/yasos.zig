// What the extension needs from tcc, without vscode: which files are yasc,
// the command line that checks one (the same as scripts/safe_mode_ratchet.py),
// and tcc's messages, include paths and predefined macros parsed.
// test/diag.js runs these under plain node.
'use strict';
const fs = require('fs');
const path = require('path');

// `**` any path, `*` and `?` within one component.
function globToRegex(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      i++;
      if (glob[i + 1] === '/') {
        i++;
        re += '(?:.*/)?';
      } else {
        re += '.*';
      }
    } else if (c === '*') {
      re += '[^/]*';
    } else if (c === '?') {
      re += '[^/]';
    } else {
      re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp('^' + re + '$');
}

// The project's yasc files: each directory the ratchet counts (with its
// flags), the extra globs from the settings, and any .c file that says
// `#pragma yasc`.
function loadProject(root, ratchetConfig, extraGlobs) {
  const dirs = [];
  const file = path.resolve(root, ratchetConfig || 'scripts/safe_mode_ratchet.json');
  try {
    const json = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const [dir, v] of Object.entries(json.dirs || {})) {
      dirs.push({ dir: dir.replace(/\/+$/, ''), flags: Array.isArray(v.flags) ? v.flags : [] });
    }
  } catch (e) {
    // no ratchet: only the globs and the pragma
  }
  dirs.sort((a, b) => b.dir.length - a.dir.length); // the deepest one wins
  const globs = (extraGlobs || []).map(globToRegex);
  return { root, dirs, globs };
}

const PRAGMA = /^[ \t]*#[ \t]*pragma[ \t]+yasc\b/m;

// {dir, flags} for a yasc file (dir relative to the root, '' for none), else
// null.  `text` is the file's contents when known (for the pragma test).
function classify(project, absFile, text) {
  const rel = path.relative(project.root, absFile).split(path.sep).join('/');
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null;
  if (!/\.[ch]$/.test(rel)) return null;
  for (const d of project.dirs) {
    if (rel.startsWith(d.dir + '/')) return { dir: d.dir, flags: d.flags };
  }
  if (project.globs.some((g) => g.test(rel))) return { dir: path.posix.dirname(rel), flags: [] };
  if (text === undefined) {
    try {
      text = fs.readFileSync(absFile, 'utf8');
    } catch (e) {
      return null;
    }
  }
  if (PRAGMA.test(text)) return { dir: path.posix.dirname(rel), flags: [] };
  return null;
}

// The include directories scripts/safe_mode_ratchet.py gives a file: its
// own directory, the counted directory and that directory's include/.
function projectIncludes(project, absFile, info) {
  const inc = [path.dirname(absFile)];
  if (info.dir) {
    const d = path.join(project.root, info.dir);
    if (!inc.includes(d)) inc.push(d);
    const di = path.join(d, 'include');
    if (fs.existsSync(di)) inc.push(di);
  }
  return inc;
}

// tcc reads the buffer from stdin (unsaved edits included); the file's text
// is preceded by `#line 1 "<file>"` so that messages name the file.
function checkArgs(project, absFile, info, extraArgs) {
  const args = ['-fsyntax-only', '-fmax-errors=0'];
  for (const d of projectIncludes(project, absFile, info)) args.push('-I' + d);
  return args.concat(info.flags, extraArgs || [], ['-']);
}

function stdinFor(absFile, text) {
  return '#line 1 "' + absFile.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"\n' + text;
}

// tcc's messages: `file:line: error|warning|note: text`, `tcc: error: text`
// (no line), each preceded by the `In file included from file:line:` chain
// when it is in a header.  Returns
//   {file, line (1-based, 0 = none), severity, message, chain: [{file, line}]}
// with paths made absolute against `cwd`.
function parseOutput(stderr, cwd) {
  const out = [];
  let chain = [];
  const abs = (f) => (f === '-' ? f : path.resolve(cwd, f));
  for (const raw of stderr.split(/\r?\n/)) {
    const line = raw.replace(/\s+$/, '');
    if (!line) continue;
    let m = /^In file included from (.+):(\d+):$/.exec(line);
    if (m) {
      chain.push({ file: abs(m[1]), line: +m[2] });
      continue;
    }
    m = /^(.+?):(\d+): (error|warning|note): (.*)$/.exec(line);
    if (m) {
      out.push({ file: abs(m[1]), line: +m[2], severity: m[3], message: m[4], chain });
      chain = [];
      continue;
    }
    m = /^(?:tcc|[^:\s]*tcc[^:\s]*): (error|warning|note): (.*)$/.exec(line);
    if (m) {
      out.push({ file: null, line: 0, severity: m[1], message: m[2], chain: [] });
      chain = [];
      continue;
    }
    // a continuation of the previous message
    if (out.length && /^\s/.test(raw)) out[out.length - 1].message += '\n' + line.trim();
  }
  return out;
}

// Where a message shows in `mainFile`: its own line, or the line of the
// outermost `#include` that leads to the header it is in.
function placeInFile(d, mainFile) {
  if (d.file === mainFile) return { line: d.line, header: null };
  for (const c of d.chain) {
    if (c.file === mainFile) return { line: c.line, header: d.file ? { file: d.file, line: d.line } : null };
  }
  return { line: d.line && d.file === null ? d.line : 0, header: d.file ? { file: d.file, line: d.line } : null };
}

// `tcc -vv`: the system include directories.
function parseIncludeDirs(vv) {
  const dirs = [];
  let inInclude = false;
  for (const line of vv.split(/\r?\n/)) {
    if (/^\S/.test(line)) inInclude = /^include:/.test(line);
    else if (inInclude && line.trim()) dirs.push(line.trim());
  }
  return dirs;
}

// `tcc -dM -E -`: object-like macros as NAME=VALUE for IntelliSense.  Not
// `__YASC__`: the headers' yasc declarations sit under it, and IntelliSense
// reads their plain C ones.  Not the function-like builtins nor __STDC*
// (IntelliSense has its own), nor what IntelliSense defines itself
// (__PRETTY_FUNCTION__, __BASE_FILE__: tcc says "-" reading stdin), nor the
// values tcc prints as a placeholder (`__FLT_MAX__ <float>`: not C, and
// IntelliSense knows them).
const OWN_PREDEFS = new Set(['__YASC__', '__PRETTY_FUNCTION__', '__FUNCTION__', '__BASE_FILE__']);
function parsePredefs(text) {
  const defs = [];
  for (const line of text.split(/\r?\n/)) {
    const m = /^#define\s+([A-Za-z_]\w*)(\s+(.*))?$/.exec(line);
    if (!m) continue;
    const name = m[1];
    if (OWN_PREDEFS.has(name) || name.startsWith('__STDC') || name.startsWith('__has_')) continue;
    if (m[3] !== undefined && /^<.*>$/.test(m[3].trim())) continue;
    defs.push(m[3] !== undefined ? `${name}=${m[3]}` : name);
  }
  return defs;
}

// The crosses a checkout has: build_rootfs.sh's, and `make cross`'s in
// libs/tinycc (after build_rootfs.sh that one is the native ARM tcc).
const COMPILERS = ['libs/tinycc/bin/armv8m-tcc', 'libs/tinycc/armv8m-tcc'];

// An ELF this machine runs: its class and machine are node's own.
function hostRunnable(file) {
  const want = { x64: [2, 62], arm64: [2, 183], ia32: [1, 3], arm: [1, 40] }[process.arch];
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const h = Buffer.alloc(20);
    if (fs.readSync(fd, h, 0, 20, 0) < 20 || h.readUInt32BE(0) !== 0x7f454c46) return false;
    return !want || (h[4] === want[0] && h[18] + 256 * h[19] === want[1]);
  } catch (e) {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

// The compiler that checks yasc files: SETTING (relative to ROOT,
// ${workspaceFolder} allowed) when given, else the newest cross of COMPILERS
// this machine runs -- a fix to tcc shows after `make cross` as after
// build_rootfs.sh.  The first candidate when none is there.
function pickCompiler(root, setting) {
  if (setting) return path.resolve(root, setting.replace(/^\$\{workspaceFolder\}/, root));
  let best = null, bestTime = -1;
  for (const c of COMPILERS) {
    const f = path.join(root, c);
    let st;
    try {
      st = fs.statSync(f);
    } catch (e) {
      continue;
    }
    if (st.isFile() && st.mtimeMs > bestTime && hostRunnable(f)) best = f, bestTime = st.mtimeMs;
  }
  return best || path.join(root, COMPILERS[0]);
}

module.exports = {
  pickCompiler,
  globToRegex,
  loadProject,
  classify,
  projectIncludes,
  checkArgs,
  stdinFor,
  parseOutput,
  placeInFile,
  parseIncludeDirs,
  parsePredefs,
};
