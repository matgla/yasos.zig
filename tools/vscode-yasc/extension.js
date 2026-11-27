// yasc in VSCode beyond highlighting:
//  - diagnostics from tcc itself (`armv8m-tcc -fsyntax-only` on the buffer,
//    as scripts/safe_mode_ratchet.py runs it), source "tcc";
//  - a configuration provider for the C/C++ extension: yasc files get tcc's
//    include paths and macros and a forced header that erases the yasc words
//    IntelliSense cannot parse (intellisense/yasc_intellisense.h).  Other
//    files keep the C/C++ extension's own configuration;
//  - IntelliSense errors in yasc files only where tcc agrees (squiggles.js):
//    what a macro cannot erase (`@min`, slices, `catch`...) is not marked;
//  - formatting: `tcc -format` for files under a .tcc-format (Format
//    Document, and on save), clang-format for other C files (Format Document).
'use strict';
const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const tcc = require('./tcc');
const squiggles = require('./squiggles');

const PROVIDER_NAME = 'yasc (tcc)';

let collection;
let output;
const projects = new Map(); // workspace folder path -> project
const running = new Map(); // document uri -> child process
const timers = new Map(); // document uri -> debounce timer
const compilerInfo = new Map(); // compiler path -> {includes, defines}
const tccErrorLines = new Map(); // document uri -> Set of 0-based lines with a tcc error
let filter = null; // squiggles.install(): the C/C++ extension's errors in yasc files
let shimRoot = null; // where gccShimFor() writes (the extension's global storage)

function cfg(scope) {
  return vscode.workspace.getConfiguration('yasc', scope);
}

function folderOf(uri) {
  const f = vscode.workspace.getWorkspaceFolder(uri);
  return f ? f.uri.fsPath : null;
}

function project(root) {
  let p = projects.get(root);
  if (!p) {
    const c = cfg(vscode.Uri.file(root));
    p = tcc.loadProject(root, c.get('ratchetConfig'), c.get('files'));
    projects.set(root, p);
  }
  return p;
}

function compilerPath(root) {
  return tcc.pickCompiler(root, cfg(vscode.Uri.file(root)).get('compiler'));
}

// {root, project, info} for a yasc file, else null.
function lookup(uri, text) {
  if (uri.scheme !== 'file') return null;
  const root = folderOf(uri);
  if (!root) return null;
  const p = project(root);
  const info = tcc.classify(p, uri.fsPath, text);
  return info ? { root, project: p, info } : null;
}

// ---- diagnostics ------------------------------------------------------

function lineRange(doc, line, message) {
  const n = Math.min(Math.max(line - 1, 0), Math.max(doc.lineCount - 1, 0));
  const text = doc.lineCount ? doc.lineAt(n).text : '';
  // `... for 'path'`: underline that name when it is on the line
  for (const m of message.matchAll(/'([A-Za-z_]\w*)'/g)) {
    const at = new RegExp('\\b' + m[1] + '\\b').exec(text);
    if (at) return new vscode.Range(n, at.index, n, at.index + m[1].length);
  }
  const start = text.length - text.trimStart().length;
  return new vscode.Range(n, start, n, Math.max(text.length, start + 1));
}

const SEVERITY = {
  error: vscode.DiagnosticSeverity.Error,
  warning: vscode.DiagnosticSeverity.Warning,
  note: vscode.DiagnosticSeverity.Information,
};

function toDiagnostics(doc, root, stderr, code) {
  const file = doc.uri.fsPath;
  const parsed = tcc.parseOutput(stderr, root);
  const diags = [];
  let last = null;
  for (const d of parsed) {
    if (d.file === '-') d.file = file;
    const at = tcc.placeInFile(d, file);
    let message = d.message;
    if (at.header) message = `${path.relative(root, at.header.file)}:${at.header.line}: ${message}`;
    const diag = new vscode.Diagnostic(lineRange(doc, at.line, d.message), message, SEVERITY[d.severity]);
    diag.source = 'tcc';
    const related = [];
    if (at.header && fs.existsSync(at.header.file)) {
      related.push(new vscode.DiagnosticRelatedInformation(
        new vscode.Location(vscode.Uri.file(at.header.file), new vscode.Position(Math.max(at.header.line - 1, 0), 0)),
        d.message));
    }
    if (d.severity === 'note' && last) {
      // a note explains the message before it
      last.relatedInformation = (last.relatedInformation || []).concat(
        new vscode.DiagnosticRelatedInformation(new vscode.Location(doc.uri, diag.range), d.message));
    } else {
      last = diag;
    }
    if (related.length) diag.relatedInformation = related;
    diags.push(diag);
  }
  if (code !== 0 && code !== null && !parsed.some((d) => d.severity === 'error')) {
    const diag = new vscode.Diagnostic(new vscode.Range(0, 0, 0, 1),
      `tcc exited ${code}: ${stderr.trim().slice(-300) || '(no output)'}`, vscode.DiagnosticSeverity.Error);
    diag.source = 'tcc';
    diags.push(diag);
  }
  return diags;
}

// A yasc .c or .h file: a header is checked alone too, so that its
// IntelliSense errors (`owned(dealloc)`...) are filtered like a .c file's.
// VSCode may open a .h as C++.
function checkable(doc) {
  if (!/\.[ch]$/.test(doc.uri.fsPath)) return false;
  return doc.languageId === 'c' || (doc.languageId === 'cpp' && /\.h$/.test(doc.uri.fsPath));
}

function check(doc) {
  if (!checkable(doc)) return;
  const c = cfg(doc.uri);
  if (!c.get('diagnostics.enable')) return;
  const found = lookup(doc.uri, doc.getText());
  const key = doc.uri.toString();
  if (!found) {
    collection.delete(doc.uri);
    forgetErrors(doc.uri);
    return;
  }
  const exe = compilerPath(found.root);
  if (!fs.existsSync(exe)) {
    output.appendLine(`yasc: no compiler at ${exe} (./build_rootfs.sh builds it, or set yasc.compiler)`);
    return;
  }
  const prev = running.get(key);
  if (prev) prev.kill();
  const args = tcc.checkArgs(found.project, doc.uri.fsPath, found.info, c.get('extraArgs'));
  const version = doc.version;
  const child = cp.spawn(exe, args, { cwd: found.root });
  running.set(key, child);
  let stderr = '';
  child.stderr.on('data', (b) => (stderr += b));
  child.stdout.on('data', (b) => (stderr += b));
  const timer = setTimeout(() => child.kill(), (c.get('diagnostics.timeout') || 30) * 1000);
  child.on('error', (e) => {
    clearTimeout(timer);
    output.appendLine(`yasc: ${exe}: ${e.message}`);
  });
  child.on('close', (code, signal) => {
    clearTimeout(timer);
    if (running.get(key) !== child) return; // superseded
    running.delete(key);
    if (signal) return; // killed: a newer check runs, or it timed out
    if (doc.isClosed || doc.version !== version) return;
    const diags = toDiagnostics(doc, found.root, stderr, code);
    collection.set(doc.uri, diags);
    tccErrorLines.set(key, new Set(diags
      .filter((d) => d.severity === vscode.DiagnosticSeverity.Error)
      .map((d) => d.range.start.line)));
    if (filter) filter.refresh(doc.uri);
  });
  child.stdin.on('error', () => {});
  child.stdin.end(tcc.stdinFor(doc.uri.fsPath, doc.getText()));
}

function forgetErrors(uri) {
  if (tccErrorLines.delete(uri.toString()) && filter) filter.refresh(uri);
}

// For squiggles.install: tcc's error lines in an open yasc .c or .h file that
// tcc checks (empty until its first check), null for any other file.
const NO_LINES = new Set();
function errorLinesFor(uri) {
  if (uri.scheme !== 'file' || !/\.[ch]$/.test(uri.fsPath)) return null;
  const c = cfg(uri);
  if (!c.get('intellisense.hideErrors') || !c.get('diagnostics.enable')) return null;
  const key = uri.toString();
  const doc = vscode.workspace.textDocuments.find((d) => d.uri.toString() === key);
  if (!doc || !checkable(doc)) return null;
  const found = lookup(uri, doc.getText());
  if (!found || !fs.existsSync(compilerPath(found.root))) return null;
  return tccErrorLines.get(key) || NO_LINES;
}

function schedule(doc) {
  const key = doc.uri.toString();
  clearTimeout(timers.get(key));
  timers.set(key, setTimeout(() => {
    timers.delete(key);
    check(doc);
  }, cfg(doc.uri).get('diagnostics.delay') || 600));
}

// ---- C/C++ extension configuration provider ---------------------------

function infoFor(exe) {
  let info = compilerInfo.get(exe);
  if (info) return info;
  info = { includes: [], defines: [] };
  try {
    info.includes = tcc.parseIncludeDirs(cp.execFileSync(exe, ['-vv'], { encoding: 'utf8', timeout: 10000 }));
    info.defines = tcc.parsePredefs(
      cp.execFileSync(exe, ['-dM', '-E', '-'], { input: '', encoding: 'utf8', timeout: 10000 }));
  } catch (e) {
    output.appendLine(`yasc: ${exe}: ${e.message}`);
  }
  compilerInfo.set(exe, info);
  return info;
}

// FILE's text: the editor's buffer when it is open, else the file ('' when
// it cannot be read).
function textOf(file) {
  const doc = vscode.workspace.textDocuments.find((d) => d.uri.scheme === 'file' && d.uri.fsPath === file);
  if (doc) return doc.getText();
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (e) {
    return '';
  }
}

function configurationFor(found, file, extensionPath) {
  const c = cfg(vscode.Uri.file(file));
  const exe = compilerPath(found.root);
  const ci = infoFor(exe);
  const includePath = tcc.projectIncludes(found.project, file, found.info);
  const defines = ci.defines.slice();
  for (const f of found.info.flags) {
    if (f.startsWith('-I')) includePath.push(path.resolve(found.root, f.slice(2)));
    else if (f.startsWith('-D')) defines.push(f.slice(2));
  }
  defines.push(...tcc.paramWordDefines(textOf(file)));
  return {
    includePath: includePath.concat(ci.includes),
    defines,
    forcedInclude: [path.join(extensionPath, 'intellisense', 'yasc_intellisense.h')],
    compilerPath: '',
    intelliSenseMode: 'gcc-arm',
    standard: c.get('intellisense.standard') || 'gnu17',
  };
}

// The tag parser's settings (workspace symbols, go to definition in another
// file) for a workspace folder with yasc files, else null.  Without one the
// C/C++ extension waits for the provider to time out, then falls back to the
// default browse path plus the host compiler's headers (/usr/include, the
// wrong libc for the target), and resolving every #include of the folder
// through that keeps its server busy for minutes while IntelliSense requests
// wait on it.  The folder itself (C_Cpp.files.exclude still applies) and
// tcc's system headers, with gccShimFor() as the compiler, so no host headers.
function browseConfigurationFor(root) {
  if (cfg(vscode.Uri.file(root)).get('intellisense.enable') === false) return null;
  const p = project(root);
  if (!p.dirs.length && !p.globs.length) return null;
  const ci = infoFor(compilerPath(root));
  const inside = (d) => !path.relative(root, d).startsWith('..');
  return {
    browsePath: [root].concat(ci.includes.filter((d) => !inside(d))),
    compilerPath: gccShimFor(root, ci),
    compilerArgs: [],
    standard: cfg(vscode.Uri.file(root)).get('intellisense.standard') || 'gnu17',
  };
}

// The compiler the workspace configuration names: a script that gives the
// C/C++ extension tcc's system headers and macros (tcc.gccShim).  An empty
// compilerPath makes it query the host's compiler instead, and its symbol
// database then holds /usr/include: go to definition lands in the host's
// time.h rather than the libc tcc checks with.  '' when it cannot be written.
function gccShimFor(root, ci) {
  if (!shimRoot || !ci.includes.length) return '';
  const id = crypto.createHash('sha1').update(root).digest('hex').slice(0, 12);
  const file = path.join(shimRoot, id, 'arm-none-eabi-gcc');
  const text = tcc.gccShim(ci.includes, ci.defines);
  try {
    let old = null;
    try {
      old = fs.readFileSync(file, 'utf8');
    } catch (e) {
      // not written yet
    }
    if (old !== text) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file + '.new', text, { mode: 0o755 });
      fs.renameSync(file + '.new', file);
    }
    return file;
  } catch (e) {
    output.appendLine(`yasc: cannot write ${file}: ${e.message}`);
    return '';
  }
}

function firstBrowseConfiguration() {
  for (const f of vscode.workspace.workspaceFolders || []) {
    const c = browseConfigurationFor(f.uri.fsPath);
    if (c) return c;
  }
  return null;
}

async function registerProvider(context) {
  const ext = vscode.extensions.getExtension('ms-vscode.cpptools');
  if (!ext) return null;
  if (!ext.isActive) await ext.activate();
  const exp = ext.exports;
  if (!exp || typeof exp.getApi !== 'function') return null;
  const api = exp.getApi(6);
  const provider = {
    name: PROVIDER_NAME,
    extensionId: context.extension.id,
    canProvideConfiguration: async (uri) =>
      cfg(uri).get('intellisense.enable') !== false && !!lookup(uri),
    provideConfigurations: async (uris) => {
      const items = [];
      for (const uri of uris) {
        const found = lookup(uri);
        if (found) items.push({ uri, configuration: configurationFor(found, uri.fsPath, context.extensionPath) });
      }
      return items;
    },
    canProvideBrowseConfiguration: async () => !!firstBrowseConfiguration(),
    provideBrowseConfiguration: async () => firstBrowseConfiguration(),
    canProvideBrowseConfigurationsPerFolder: async () => true,
    provideFolderBrowseConfiguration: async (uri) => {
      const root = folderOf(uri) || uri.fsPath;
      return browseConfigurationFor(root);
    },
    dispose: () => {},
  };
  api.registerCustomConfigurationProvider(provider);
  api.notifyReady(provider);
  return { api, provider };
}

// ---- formatting ---------------------------------------------------------

let noFormatWarned = false;
const clangFound = new Map(); // clang-format path -> runs here

function clangRuns(exe) {
  if (!clangFound.has(exe)) {
    const r = cp.spawnSync(exe, ['--version'], { encoding: 'utf8', timeout: 5000 });
    clangFound.set(exe, r.status === 0);
    if (r.status !== 0) output.appendLine(`yasc: no ${exe} to format C files without a .tcc-format`);
  }
  return clangFound.get(exe);
}

// How DOC is formatted: {exe, args, cwd, tcc} -- tcc -format under a
// .tcc-format, else clang-format (yasc.format.clangFormat, '' for none) --
// or null.
const YASC_SYNTAX = /\*\?|\*@\(|\[\?|\?(?:owned|view)\b|^\s*#\s*pragma\s+yasc\b/m;

function formatterFor(doc) {
  if (!checkable(doc) || doc.uri.scheme !== 'file') return null;
  const c = cfg(doc.uri);
  if (!c.get('format.enable')) return null;
  const file = doc.uri.fsPath;
  const root = folderOf(doc.uri) || path.dirname(file);
  if (tcc.findFormatConfig(file)) {
    const exe = compilerPath(root);
    if (!fs.existsSync(exe)) {
      output.appendLine(`yasc: no compiler at ${exe} to format with (./build_rootfs.sh builds it, or set yasc.compiler)`);
      return null;
    }
    return { exe, args: tcc.formatArgs(file), cwd: root, tcc: true };
  }
  const clang = c.get('format.clangFormat');
  if (!clang || !clangRuns(clang)) return null;
  // clang-format reads `*?owned` as a conditional and knows no `*@(a, b)`:
  // on yasc it writes `*? owned`, which tcc rejects
  if (YASC_SYNTAX.test(doc.getText())) {
    output.appendLine(`yasc: ${file} is yasc and has no .tcc-format above it: not formatted (clang-format would break its pointer words)`);
    return null;
  }
  return { exe: clang, args: tcc.clangFormatArgs(file), cwd: path.dirname(file), tcc: false };
}

// The edits that format DOC ([] when it is formatted already or tcc cannot
// format it: tcc says why, in the output channel).
function formatEdits(doc, found) {
  const text = doc.getText();
  const version = doc.version;
  return new Promise((resolve) => {
    const child = cp.spawn(found.exe, found.args, { cwd: found.cwd });
    let out = '', err = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (b) => (out += b));
    child.stderr.on('data', (b) => (err += b));
    const timer = setTimeout(() => child.kill(), 10000);
    child.on('error', (e) => {
      clearTimeout(timer);
      output.appendLine(`yasc: ${found.exe}: ${e.message}`);
      resolve([]);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        if (found.tcc && /invalid option/.test(err)) {
          if (!noFormatWarned) {
            noFormatWarned = true;
            vscode.window.showWarningMessage(`yasc: ${found.exe} has no -format yet: rebuild it (make cross)`);
          }
        } else if (err) {
          output.appendLine(err.replace(/\s+$/, ''));
        }
        resolve([]);
        return;
      }
      if (doc.isClosed || doc.version !== version) return resolve([]);
      const e = tcc.lineEdit(text, out);
      resolve(e ? [vscode.TextEdit.replace(new vscode.Range(doc.positionAt(e.start), doc.positionAt(e.end)), e.text)] : []);
    });
    child.stdin.on('error', () => {});
    child.stdin.end(text);
  });
}

async function formatNow(editor) {
  const doc = editor.document;
  const found = formatterFor(doc);
  if (!found) {
    vscode.window.showInformationMessage('yasc: nothing formats this file (no .tcc-format above it, no clang-format)');
    return;
  }
  const edits = await formatEdits(doc, found);
  if (!edits.length) return;
  const we = new vscode.WorkspaceEdit();
  we.set(doc.uri, edits);
  await vscode.workspace.applyEdit(we);
}

function registerFormatting(context) {
  const selector = [
    { language: 'c', scheme: 'file' },
    { language: 'cpp', scheme: 'file', pattern: '**/*.h' },
  ];
  context.subscriptions.push(
    vscode.languages.registerDocumentFormattingEditProvider(selector, {
      provideDocumentFormattingEdits(doc) {
        const found = formatterFor(doc);
        return found ? formatEdits(doc, found) : [];
      },
    }),
    // On save without making tcc VSCode's default formatter: other C files
    // keep theirs.  When it is the default and editor.formatOnSave is on,
    // VSCode asks the provider above itself.
    vscode.workspace.onWillSaveTextDocument((e) => {
      const doc = e.document;
      if (e.reason === vscode.TextDocumentSaveReason.AfterDelay) return;
      if (!cfg(doc.uri).get('format.onSave')) return;
      const editor = vscode.workspace.getConfiguration('editor', doc.uri);
      if (editor.get('formatOnSave') && editor.get('defaultFormatter') === context.extension.id) return;
      const found = formatterFor(doc);
      if (found && found.tcc) e.waitUntil(formatEdits(doc, found));
    }),
    vscode.commands.registerCommand('yasc.formatFile', () => {
      const ed = vscode.window.activeTextEditor;
      if (ed) return formatNow(ed);
    }),
  );
}

// ---- activation -------------------------------------------------------

async function activate(context) {
  collection = vscode.languages.createDiagnosticCollection('tcc');
  output = vscode.window.createOutputChannel('yasc');
  context.subscriptions.push(collection, output);
  if (context.globalStorageUri) shimRoot = path.join(context.globalStorageUri.fsPath, 'gcc-shim');
  filter = squiggles.install(collection, errorLinesFor, vscode.DiagnosticSeverity.Error, (uri) => {
    const key = uri.toString();
    const doc = vscode.workspace.textDocuments.find((d) => d.uri.toString() === key);
    return doc ? doc.getText() : null;
  });
  if (filter) context.subscriptions.push(filter);
  else output.appendLine('yasc: cannot filter IntelliSense errors (unexpected DiagnosticCollection)');
  registerFormatting(context);

  let cpptools = null;
  try {
    cpptools = await registerProvider(context);
  } catch (e) {
    output.appendLine(`yasc: C/C++ configuration provider not registered: ${e.message}`);
  }
  if (cpptools) context.subscriptions.push({ dispose: () => cpptools.api.dispose() });

  // What the C/C++ extension was last given.  A rebuilt compiler (sessions
  // rebuild the cross every few minutes) almost never changes it, and telling
  // the extension anyway restarts its include scan of the whole workspace:
  // go to definition then waits behind a scan that never finishes.
  const fingerprint = () => JSON.stringify((vscode.workspace.workspaceFolders || []).map((f) => {
    const root = f.uri.fsPath;
    const p = project(root);
    return [root, p.dirs, p.globs.map((g) => g.source), infoFor(compilerPath(root)), browseConfigurationFor(root)];
  }));
  let given = cpptools ? fingerprint() : null;

  // FORCE: a settings change, which can change what fingerprint() leaves out.
  const reset = (force) => {
    projects.clear();
    compilerInfo.clear();
    if (filter) filter.refreshAll();
    if (cpptools) {
      const now = fingerprint();
      if (force || now !== given) {
        given = now;
        cpptools.api.didChangeCustomConfiguration(cpptools.provider);
        cpptools.api.didChangeCustomBrowseConfiguration(cpptools.provider);
      }
    }
    vscode.workspace.textDocuments.forEach(check);
  };

  // Only the compiler and ratchet file each folder uses: the same names in
  // other checkouts inside the folder (.cache worktrees rebuilt by other
  // sessions) must not reset IntelliSense, which re-reads every file's
  // configuration.
  const watched = (uri) => (vscode.workspace.workspaceFolders || []).some((f) => {
    const root = f.uri.fsPath;
    const ratchet = path.resolve(root, cfg(f.uri).get('ratchetConfig') || 'scripts/safe_mode_ratchet.json');
    return uri.fsPath === compilerPath(root) || uri.fsPath === ratchet;
  });
  // A link writes the compiler in several steps: wait until it is done, so
  // a half-written file is not run for its include paths.
  let settle = null;
  const onWatched = (uri) => {
    if (!watched(uri)) return;
    clearTimeout(settle);
    settle = setTimeout(() => reset(false), 3000);
  };
  const watcher = vscode.workspace.createFileSystemWatcher('**/{safe_mode_ratchet.json,armv8m-tcc}');
  watcher.onDidChange(onWatched);
  watcher.onDidCreate(onWatched);
  watcher.onDidDelete(onWatched);
  context.subscriptions.push(
    watcher,
    { dispose: () => clearTimeout(settle) },
    vscode.workspace.onDidOpenTextDocument(check),
    vscode.workspace.onDidSaveTextDocument(check),
    vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.contentChanges.length && cfg(e.document.uri).get('diagnostics.onType')) schedule(e.document);
    }),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      collection.delete(doc.uri);
      tccErrorLines.delete(doc.uri.toString());
      const child = running.get(doc.uri.toString());
      if (child) child.kill();
    }),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('yasc')) reset(true);
    }),
    vscode.commands.registerCommand('yasc.checkFile', () => {
      const ed = vscode.window.activeTextEditor;
      if (ed) check(ed.document);
    }),
  );
  vscode.workspace.textDocuments.forEach(check);

  if (cpptools) maybeOfferProvider(context);
}

// The C/C++ extension asks a provider only when it is named in
// C_Cpp.default.configurationProvider; offer to set it once per workspace.
async function maybeOfferProvider(context) {
  const c = vscode.workspace.getConfiguration('C_Cpp');
  const current = c.get('default.configurationProvider');
  if (current === context.extension.id || context.workspaceState.get('yasc.providerOffered')) return;
  if (current) return; // another provider is in use: leave it
  const hasYasc = vscode.workspace.workspaceFolders &&
    vscode.workspace.workspaceFolders.some((f) => project(f.uri.fsPath).dirs.length);
  if (!hasYasc) return;
  await context.workspaceState.update('yasc.providerOffered', true);
  const pick = await vscode.window.showInformationMessage(
    'yasc: let the C/C++ extension take IntelliSense settings for yasc files from tcc? ' +
    '(sets C_Cpp.default.configurationProvider for this workspace)', 'Set', 'Not now');
  if (pick === 'Set') {
    await c.update('default.configurationProvider', context.extension.id, vscode.ConfigurationTarget.Workspace);
  }
}

function deactivate() {
  for (const child of running.values()) child.kill();
  if (filter) filter.dispose();
  filter = null;
}

module.exports = { activate, deactivate };
