// yasc in VSCode beyond highlighting:
//  - diagnostics from tcc itself (`armv8m-tcc -fsyntax-only` on the buffer,
//    as scripts/safe_mode_ratchet.py runs it), source "tcc";
//  - a configuration provider for the C/C++ extension: yasc files get tcc's
//    include paths and macros and a forced header that erases the yasc words
//    IntelliSense cannot parse (intellisense/yasc_intellisense.h).  Other
//    files keep the C/C++ extension's own configuration;
//  - IntelliSense errors in yasc files only where tcc agrees (squiggles.js):
//    what a macro cannot erase (`@min`, slices, `catch`...) is not marked.
'use strict';
const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
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
  const c = cfg(vscode.Uri.file(root)).get('compiler') || 'libs/tinycc/bin/armv8m-tcc';
  return path.resolve(root, c.replace(/^\$\{workspaceFolder\}/, root));
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

function check(doc) {
  if (doc.languageId !== 'c' || !/\.c$/.test(doc.uri.fsPath)) return;
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

// For squiggles.install: tcc's error lines in an open yasc .c file that tcc
// checks (empty until its first check), null for any other file.
const NO_LINES = new Set();
function errorLinesFor(uri) {
  if (uri.scheme !== 'file' || !/\.c$/.test(uri.fsPath)) return null;
  const c = cfg(uri);
  if (!c.get('intellisense.hideErrors') || !c.get('diagnostics.enable')) return null;
  const key = uri.toString();
  const doc = vscode.workspace.textDocuments.find((d) => d.uri.toString() === key);
  if (!doc || doc.languageId !== 'c') return null;
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
  return {
    includePath: includePath.concat(ci.includes),
    defines,
    forcedInclude: [path.join(extensionPath, 'intellisense', 'yasc_intellisense.h')],
    compilerPath: '',
    intelliSenseMode: 'gcc-arm',
    standard: c.get('intellisense.standard') || 'gnu17',
  };
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
    canProvideBrowseConfiguration: async () => false,
    provideBrowseConfiguration: async () => null,
    canProvideBrowseConfigurationsPerFolder: async () => false,
    provideFolderBrowseConfiguration: async () => null,
    dispose: () => {},
  };
  api.registerCustomConfigurationProvider(provider);
  api.notifyReady(provider);
  return { api, provider };
}

// ---- activation -------------------------------------------------------

async function activate(context) {
  collection = vscode.languages.createDiagnosticCollection('tcc');
  output = vscode.window.createOutputChannel('yasc');
  context.subscriptions.push(collection, output);
  filter = squiggles.install(collection, errorLinesFor, vscode.DiagnosticSeverity.Error, (uri) => {
    const key = uri.toString();
    const doc = vscode.workspace.textDocuments.find((d) => d.uri.toString() === key);
    return doc ? doc.getText() : null;
  });
  if (filter) context.subscriptions.push(filter);
  else output.appendLine('yasc: cannot filter IntelliSense errors (unexpected DiagnosticCollection)');

  let cpptools = null;
  try {
    cpptools = await registerProvider(context);
  } catch (e) {
    output.appendLine(`yasc: C/C++ configuration provider not registered: ${e.message}`);
  }
  if (cpptools) context.subscriptions.push({ dispose: () => cpptools.api.dispose() });

  const reset = () => {
    projects.clear();
    compilerInfo.clear();
    if (filter) filter.refreshAll();
    if (cpptools) cpptools.api.didChangeCustomConfiguration(cpptools.provider);
    vscode.workspace.textDocuments.forEach(check);
  };

  const watcher = vscode.workspace.createFileSystemWatcher('**/{safe_mode_ratchet.json,armv8m-tcc}');
  watcher.onDidChange(reset);
  watcher.onDidCreate(reset);
  watcher.onDidDelete(reset);
  context.subscriptions.push(
    watcher,
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
      if (e.affectsConfiguration('yasc')) reset();
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
