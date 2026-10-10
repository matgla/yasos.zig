#!/usr/bin/env python3
"""asm_compare — godbolt-style function comparison of two ELFs.

Disassembles both ELFs (GNU objdump, source-interleaved when DWARF line
info is present), matches functions across them, and emits one
self-contained HTML file with a two-column browser:

  - exact-name matches, fuzzy shape matches (for renamed/reshaped code),
    inlining hints for functions that vanished on one side
  - per-function instruction diff coloring (same/changed/added/removed)
  - sidebar with search, status filter and sorting by size delta

Usage:
    scripts/asm_compare.py ELF_A ELF_B [--label-a tcc] [--label-b llvm]
                          [-o OUTDIR] [--only REGEX]

Then open OUTDIR/index.html (works from file://, no server needed).
"""

import argparse
import difflib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter, defaultdict

# ---------------------------------------------------------------- disassembly

FUNC_HDR_RE = re.compile(r"^([0-9a-fA-F]{4,16})\s+<(.+)>:\s*$")
INSN_RE = re.compile(r"^\s*([0-9a-fA-F]{4,16}):\s*(\S.*)$")
LINE_RE = re.compile(r"^(\S*[/\\]\S*):(\d+)\s*$")
DECOR_RE = re.compile(r"^\S+\(\):$")
MAPPING_SYM_RE = re.compile(r"^\$[tda]")
COND_CODES = (
    "eq ne cs hs cc lo mi pl vs vc hi ls ge lt gt le al".split()
)
FLAG_S_BASES = {
    "mov", "add", "sub", "adc", "sbc", "rsb", "mul", "and", "orr", "eor",
    "bic", "lsl", "asr", "ror", "neg", "lsrs",
}

SRC, INSN = 0, 1  # row kinds


class Func:
    __slots__ = ("name", "aliases", "addr", "size", "rows", "insns",
                 "shapes", "counter", "stem")

    def __init__(self, name, addr):
        self.name = name
        self.aliases = []
        self.addr = addr
        self.size = 0
        self.rows = []          # [SRC, fileidx, line, text] / [INSN, addr, text]
        self.insns = []         # instruction texts, parallel to rows subset
        self.shapes = []        # normalized mnemonic+operand-shape per insn
        self.counter = Counter()
        self.stem = re.sub(r"__\d+$", "", name)


def find_objdump(override):
    candidates = []
    if override:
        candidates.append(override)
    if os.environ.get("ASM_COMPARE_OBJDUMP"):
        candidates.append(os.environ["ASM_COMPARE_OBJDUMP"])
    candidates += ["arm-none-eabi-objdump", "objdump", "llvm-objdump"]
    for cand in candidates:
        path = shutil.which(cand)
        if not path:
            continue
        try:
            rc = subprocess.run([path, "--version"], capture_output=True).returncode
        except OSError:
            continue
        if rc == 0:
            return path
    sys.exit("no usable objdump found (tried: %s)" % ", ".join(candidates))


def run_objdump(objdump, path):
    cmd = [objdump, "-d", "-l", "-S", "--no-show-raw-insn", path]
    proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if proc.returncode != 0:
        sys.exit("%s failed on %s:\n%s" % (objdump, path, proc.stderr[:2000]))
    return proc.stdout


def nm_sizes(path):
    sizes = {}
    for nm in ("arm-none-eabi-nm", "nm"):
        nmpath = shutil.which(nm)
        if not nmpath:
            continue
        proc = subprocess.run(
            [nmpath, "-S", "--defined-only", path],
            capture_output=True, text=True, errors="replace")
        if proc.returncode != 0:
            continue
        for line in proc.stdout.splitlines():
            parts = line.split()
            if len(parts) == 4 and parts[2] in ("t", "T"):
                try:
                    sizes[parts[3]] = int(parts[1], 16)
                except ValueError:
                    pass
        break
    return sizes


def shape_of(text):
    """Normalized mnemonic + operand-kind fingerprint of one instruction."""
    text = text.split("@")[0].strip()
    parts = text.split(None, 1)
    if not parts:
        return "?:"
    m = parts[0].lower()
    m = re.sub(r"\.(n|w)$", "", m)
    for cc in COND_CODES:
        if m.endswith(cc) and len(m) > len(cc):
            m = m[: -len(cc)]
            break
    if m.endswith("s") and m[:-1] in FLAG_S_BASES:
        m = m[:-1]
    kinds = []
    rest = parts[1] if len(parts) > 1 else ""
    for tok in rest.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if "<" in tok or ">" in tok:
            kinds.append("l")
        elif "[" in tok or "]" in tok:
            kinds.append("m")
        elif tok.startswith("#"):
            kinds.append("i")
        elif re.fullmatch(r"[a-z][a-z0-9]*", tok):
            kinds.append("r")
        else:
            kinds.append("x")
    return m + ":" + "".join(kinds)


def parse_disassembly(raw, files, files_idx, sizes):
    """Parse objdump -d -l -S output into functions."""
    funcs = {}
    order = []
    cur = None
    cur_line = None          # (fileidx, line)
    pending_src = []         # source text lines for cur_line, not yet emitted
    pending_emitted = True

    def flush_src():
        nonlocal pending_emitted
        if cur is None or pending_emitted or cur_line is None:
            return
        cur.rows.append([SRC, cur_line[0], cur_line[1],
                         "\n".join(pending_src)])
        pending_emitted = True

    boiler = ("file format", "Disassembly of section")
    for line in raw.splitlines():
        if not line.strip() or any(b in line for b in boiler):
            continue
        m = FUNC_HDR_RE.match(line)
        if m:
            flush_src()
            name = m.group(2)
            addr = int(m.group(1), 16)
            if MAPPING_SYM_RE.match(name):
                cur = None
                continue
            if addr in funcs:  # symbol alias: same range printed again
                funcs[addr].aliases.append(name)
                cur = None
                continue
            cur = Func(name, addr)
            cur.size = sizes.get(name, 0)
            funcs[addr] = cur
            order.append(addr)
            cur_line = None
            pending_src = []
            pending_emitted = True
            continue
        m = INSN_RE.match(line)
        if m and cur is not None:
            flush_src()
            text = m.group(2).rstrip()
            cur.rows.append([INSN, int(m.group(1), 16), text])
            cur.insns.append(text)
            shp = shape_of(text)
            cur.shapes.append(shp)
            cur.counter[shp] += 1
            continue
        m = LINE_RE.match(line)
        if m and cur is not None:
            flush_src()
            path, lineno = m.group(1), int(m.group(2))
            if path not in files_idx:
                files_idx[path] = len(files)
                files.append(path)
            cur_line = (files_idx[path], lineno)
            pending_src = []
            pending_emitted = False
            continue
        if cur is not None and not DECOR_RE.match(line):
            # source text belonging to cur_line (from -S)
            if not pending_emitted and cur_line is not None:
                pending_src.append(line)
            elif line.strip() and not line.startswith("..."):
                # trailing annotation lines between blocks: ignore
                pass

    # extent-based size fallback when nm had none
    for i, addr in enumerate(order):
        f = funcs[addr]
        if f.size or not f.rows:
            continue
        last = max(r[1] for r in f.rows if r[0] == INSN) if any(
            r[0] == INSN for r in f.rows) else addr
        nxt = order[i + 1] if i + 1 < len(order) else None
        est = (nxt - addr) if (nxt and nxt > addr) else (last - addr + 4)
        f.size = max(4, est)

    return [funcs[a] for a in order]


# ------------------------------------------------------------------ matching

def jaccard(inter, total_a, total_b):
    union = total_a + total_b - inter
    return inter / union if union else 0.0


def build_index(funcs):
    index = defaultdict(list)   # shape -> [(fid, count)]
    totals = []
    for fid, f in enumerate(funcs):
        for shp, cnt in f.counter.items():
            index[shp].append((fid, cnt))
        totals.append(sum(f.counter.values()))
    return index, totals


def top_candidates(f, other_index, other_totals, topk=8):
    """Cheap multiset-Jaccard prefilter via an inverted index."""
    acc = Counter()
    total_a = sum(f.counter.values())
    for shp, acnt in f.counter.items():
        for fid, bcnt in other_index.get(shp, ()):
            acc[fid] += min(acnt, bcnt)
    scored = []
    for fid, inter in acc.items():
        j = jaccard(inter, total_a, other_totals[fid])
        if j > 0.2:
            scored.append((j, fid))
    scored.sort(reverse=True)
    return scored[:topk]


def seq_ratio(sa, sb, jac):
    if not sa or not sb:
        return 0.0
    if len(sa) > 700 or len(sb) > 700:
        lr = min(len(sa), len(sb)) / max(len(sa), len(sb))
        return jac * (0.6 + 0.4 * lr)
    return difflib.SequenceMatcher(None, sa, sb, autojunk=False).ratio()


def match_functions(a_funcs, b_funcs, args):
    t0 = time.time()
    pairs = {}   # (aidx, bidx) -> {"type":..., "score":...}
    a_by_name = defaultdict(list)
    b_by_name = defaultdict(list)
    for i, f in enumerate(a_funcs):
        a_by_name[f.name].append(i)
    for j, f in enumerate(b_funcs):
        b_by_name[f.name].append(j)

    matched_a, matched_b = set(), set()

    def pair(aid, bid, mtype, score):
        pairs[(aid, bid)] = {"type": mtype, "score": round(score, 3)}
        matched_a.add(aid)
        matched_b.add(bid)

    # stage 1: exact names (if a name is ambiguous, pick closest by length)
    for name, aids in a_by_name.items():
        bids = b_by_name.get(name)
        if not bids:
            continue
        for aid in aids:
            if len(bids) == 1:
                bid = bids[0]
            else:
                n = len(a_funcs[aid].insns)
                bid = min(bids, key=lambda j: abs(len(b_funcs[j].insns) - n))
            pair(aid, bid, "exact", 1.0)

    # stage 2: symbol stems (handles __<n> discriminator renumbering)
    for aid, f in enumerate(a_funcs):
        if aid in matched_a:
            continue
        cands = [j for j, g in enumerate(b_funcs)
                 if g.stem == f.stem and j not in matched_b]
        if len(cands) == 1:
            g = b_funcs[cands[0]]
            jac = jaccard(sum((f.counter & g.counter).values()),
                          sum(f.counter.values()), sum(g.counter.values()))
            pair(aid, cands[0], "stem", seq_ratio(f.shapes, g.shapes, jac))

    # stage 3: fuzzy shape matching over the remainder
    rem_a = [i for i in range(len(a_funcs)) if i not in matched_a]
    rem_b = [j for j in range(len(b_funcs)) if j not in matched_b]
    b_index, b_totals = build_index([b_funcs[j] for j in rem_b])
    for aid in rem_a:
        f = a_funcs[aid]
        best = (0.0, None)
        for jac, k in top_candidates(f, b_index, b_totals):
            g = b_funcs[rem_b[k]]
            r = seq_ratio(f.shapes, g.shapes, jac)
            if r > best[0]:
                best = (r, rem_b[k])
        if best[1] is None:
            continue
        if best[0] >= args.similar_threshold:
            pair(aid, best[1], "similar", best[0])
        elif best[0] >= args.weak_threshold:
            pair(aid, best[1], "weak", best[0])

    # stage 4: inlining/merge hints for the still-unmatched
    hints_a = {}
    hints_b = {}
    all_b_index, all_b_totals = build_index(b_funcs)
    all_a_index, all_a_totals = build_index(a_funcs)
    for aid in range(len(a_funcs)):
        if aid in matched_a:
            continue
        f = a_funcs[aid]
        if len(f.insns) < 6:
            continue
        total = sum(f.counter.values())
        best = (0.0, None)
        for jac, bid in top_candidates(f, all_b_index, all_b_totals, topk=5):
            g = b_funcs[bid]
            if len(g.insns) < 1.25 * max(1, len(f.insns)):
                continue
            inter = sum((f.counter & g.counter).values())
            cont = inter / total if total else 0.0
            if cont > best[0]:
                best = (cont, bid)
        if best[0] >= 0.72 and best[1] is not None:
            hints_a[aid] = {"into": b_funcs[best[1]].name, "frac": round(best[0], 2)}
    for bid in range(len(b_funcs)):
        if bid in matched_b:
            continue
        g = b_funcs[bid]
        if len(g.insns) < 6:
            continue
        total = sum(g.counter.values())
        best = (0.0, None)
        for jac, aid in top_candidates(g, all_a_index, all_a_totals, topk=5):
            f = a_funcs[aid]
            if len(f.insns) < 1.25 * max(1, len(g.insns)):
                continue
            inter = sum((g.counter & f.counter).values())
            cont = inter / total if total else 0.0
            if cont > best[0]:
                best = (cont, aid)
        if best[0] >= 0.72 and best[1] is not None:
            hints_b[bid] = {"into": a_funcs[best[1]].name, "frac": round(best[0], 2)}

    sys.stderr.write("matched %d pairs, %d+%d unmatched "
                     "(%.1fs)\n" % (len(pairs), len(a_funcs) - len(matched_a),
                                    len(b_funcs) - len(matched_b),
                                    time.time() - t0))
    return pairs, matched_a, matched_b, hints_a, hints_b


def diff_rows(f, g, cap=4000):
    """Per-instruction diff tags: 0 same, 1 changed, 2 A-only, 3 B-only."""
    if not f or not g:
        return None, None
    if len(f.insns) + len(g.insns) > cap:
        return None, None
    sm = difflib.SequenceMatcher(None, f.insns, g.insns, autojunk=False)
    da = [0] * len(f.insns)
    db = [0] * len(g.insns)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        val = 1 if tag == "replace" else (2 if tag == "delete" else 3)
        for i in range(i1, i2):
            da[i] = max(da[i], 1 if tag == "replace" else 2)
        for j in range(j1, j2):
            db[j] = max(db[j], 1 if tag == "replace" else 3)
    return da, db


# -------------------------------------------------------------------- output

PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>asm compare</title>
<style>
:root {
  --bg: #14161a; --panel: #1b1e24; --panel2: #20242c; --line: #2c313c;
  --fg: #d4d8e0; --dim: #7f8794; --accent: #4f9cf0;
  --green: #37b46b; --yellow: #d6a72c; --orange: #d97e2f; --red: #e05555;
  --purple: #9d7cd8; --srcline: #5c8f52;
}
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body {
  background: var(--bg); color: var(--fg);
  font: 13px/1.45 "Segoe UI", system-ui, sans-serif;
  display: grid; grid-template-rows: auto 1fr; height: 100vh; overflow: hidden;
}
header {
  display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
  padding: 8px 14px; background: var(--panel); border-bottom: 1px solid var(--line);
}
header h1 { font-size: 14px; margin: 0; font-weight: 600; }
header h1 .vs { color: var(--accent); }
.chip { padding: 2px 9px; border-radius: 10px; background: var(--panel2);
  border: 1px solid var(--line); color: var(--dim); font-size: 12px; white-space: nowrap; }
.chip b { color: var(--fg); }
input, select {
  background: var(--panel2); color: var(--fg); border: 1px solid var(--line);
  border-radius: 4px; padding: 4px 8px; font: inherit;
}
input:focus, select:focus { outline: 1px solid var(--accent); }
#search { width: 220px; }
main { display: grid; grid-template-columns: 360px 1fr; min-height: 0; }
#side {
  border-right: 1px solid var(--line); background: var(--panel);
  overflow-y: auto; min-height: 0;
}
.frow {
  display: grid; grid-template-columns: 10px 1fr auto; gap: 8px;
  padding: 4px 10px; cursor: pointer; align-items: center;
  border-bottom: 1px solid #ffffff08;
}
.frow:hover { background: var(--panel2); }
.frow.sel { background: #2b3a52; }
.dot { width: 8px; height: 8px; border-radius: 50%; }
.fname {
  font-family: ui-monospace, Consolas, monospace; font-size: 11.5px;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.fmeta { color: var(--dim); font-size: 11px; text-align: right; white-space: nowrap; }
.fmeta .up { color: var(--red); } .fmeta .dn { color: var(--green); }
#view { overflow-y: auto; min-height: 0; padding: 0 0 40px; }
.overview { padding: 18px 22px; }
.overview h2 { font-size: 15px; margin: 18px 0 8px; }
.overview h2:first-child { margin-top: 0; }
table.t { border-collapse: collapse; width: 100%; margin-bottom: 10px; }
table.t th, table.t td {
  text-align: left; padding: 4px 10px; border-bottom: 1px solid var(--line);
  font-family: ui-monospace, Consolas, monospace; font-size: 11.5px;
}
table.t th { color: var(--dim); font-weight: 500; position: sticky; top: 0; background: var(--bg); }
table.t tr:hover td { background: var(--panel2); cursor: pointer; }
.fhead {
  position: sticky; top: 0; background: var(--panel); z-index: 5;
  padding: 10px 16px; border-bottom: 1px solid var(--line);
}
.fhead .n { font-family: ui-monospace, Consolas, monospace; font-size: 14px; word-break: break-all; }
.fhead .sub { color: var(--dim); font-size: 12px; margin-top: 3px; }
.badge { padding: 1px 8px; border-radius: 9px; font-size: 11px; margin-left: 8px; }
.cols { display: grid; grid-template-columns: 1fr 1fr; min-height: 0; }
.col { border-right: 1px solid var(--line); min-width: 0; }
.col:last-child { border-right: none; }
.colhead {
  position: sticky; top: 0; background: var(--panel2); padding: 6px 12px;
  font-size: 12px; color: var(--dim); border-bottom: 1px solid var(--line);
  display: flex; justify-content: space-between; z-index: 4;
}
.rows { padding: 4px 0 30px; font-family: ui-monospace, Consolas, monospace;
  font-size: 11.5px; white-space: pre; }
.row { display: flex; gap: 10px; padding: 0 12px; }
.row .addr { color: #565e6b; min-width: 74px; text-align: right; flex: none; }
.row.insn .mnem { color: #d7ba7d; }
.row.insn .txt { color: #c8cfda; }
.row.src {
  color: var(--srcline); background: #1c211b; margin: 2px 0;
  padding-top: 2px; padding-bottom: 2px; border-top: 1px solid #ffffff0d;
  border-bottom: 1px solid #ffffff0d;
}
.row.src .loc { color: #48684a; min-width: 74px; text-align: right; flex: none;
  font-size: 10.5px; padding-top: 1px; }
.row.src .txt { overflow: hidden; text-overflow: ellipsis; }
.row.d1 { background: #d6a72c1e; } .row.d2 { background: #e0555522; }
.row.d3 { background: #37b46b1e; }
.row.d1 .addr, .row.d2 .addr, .row.d3 .addr { color: #aab3c0; }
.legend { position: fixed; bottom: 8px; right: 14px; color: var(--dim);
  font-size: 11px; background: var(--panel); border: 1px solid var(--line);
  border-radius: 4px; padding: 3px 10px; }
.sw { display: inline-block; width: 9px; height: 9px; margin: 0 4px 0 10px;
  border-radius: 2px; vertical-align: -1px; }
.empty { color: var(--dim); font-style: italic; padding: 20px 16px;
  font-family: ui-monospace, Consolas, monospace; font-size: 12px; }
</style>
</head>
<body>
<header>
  <h1><span id="labA"></span> <span class="vs">vs</span> <span id="labB"></span></h1>
  <span class="chip" id="stats"></span>
  <input id="search" placeholder="filter (/ to focus)" />
  <select id="status">
    <option value="all">all</option>
    <option value="exact">exact</option>
    <option value="similar">match (similar+)</option>
    <option value="weak">weak</option>
    <option value="unmatched">unmatched</option>
    <option value="a_only">only A</option>
    <option value="b_only">only B</option>
  </select>
  <select id="sort">
    <option value="dinsn">sort: |&Delta; insns|</option>
    <option value="name">sort: name</option>
    <option value="insns">sort: insns</option>
    <option value="sim">sort: similarity</option>
  </select>
  <span class="chip" id="pos"></span>
</header>
<main>
  <nav id="side"></nav>
  <section id="view"></section>
</main>
<div class="legend">
  <span class="sw" style="background:#d6a72c55"></span>changed
  <span class="sw" style="background:#e0555566"></span>only A
  <span class="sw" style="background:#37b46b55"></span>only B
</div>
<script>
"use strict";
const DATA = __DATA__;
const META = DATA.meta;

const STATUS_COLOR = {exact:"var(--green)", stem:"var(--green)",
  similar:"var(--yellow)", weak:"var(--orange)",
  a_only:"var(--red)", b_only:"var(--red)"};
const STATUS_NAME = {exact:"exact name", stem:"renamed match", similar:"similar code",
  weak:"weak match", a_only:"only in " + META.labelA, b_only:"only in " + META.labelB};

function esc(s) { return s.replace(/&/g,"&amp;").replace(/</g,"&lt;")
  .replace(/>/g,"&gt;").replace(/"/g,"&quot;"); }

// ---- sidebar ----
let filtered = [];
function refilter() {
  const q = document.getElementById("search").value.toLowerCase();
  const st = document.getElementById("status").value;
  filtered = DATA.funcs.filter(f => {
    const s = f.st;
    if (st === "similar" && !(s === "similar" || s === "exact" || s === "stem")) return false;
    if (st === "exact" && s !== "exact") return false;
    if (st === "weak" && s !== "weak") return false;
    if (st === "unmatched" && !(s === "a_only" || s === "b_only")) return false;
    if (st === "a_only" && s !== "a_only") return false;
    if (st === "b_only" && s !== "b_only") return false;
    if (q && !f.n.toLowerCase().includes(q)) return false;
    return true;
  });
  const sort = document.getElementById("sort").value;
  const key = {
    dinsn: f => -Math.abs((f.a ? f.a.n : 0) - (f.b ? f.b.n : 0)),
    name: f => f.n,
    insns: f => -Math.max(f.a ? f.a.n : 0, f.b ? f.b.n : 0),
    sim: f => -(f.score || 0),
  }[sort];
  filtered.sort(key);
  let htmlStr = "";
  for (const f of filtered) {
    const na = f.a ? f.a.n : 0, nb = f.b ? f.b.n : 0;
    const d = nb - na;
    const cls = d > 0 ? "up" : "dn";
    const meta = (f.a && f.b)
      ? `<span class="${cls}">${d>0?"+":""}${d}</span>&nbsp;${na}&rarr;${nb}`
      : (f.a ? na + " insns" : nb + " insns");
    htmlStr += `<div class="frow" data-i="${f.i}">` +
      `<span class="dot" style="background:${STATUS_COLOR[f.st]}"></span>` +
      `<span class="fname" title="${esc(f.n)}">${esc(f.n)}</span>` +
      `<span class="fmeta">${meta}</span></div>`;
  }
  const side = document.getElementById("side");
  side.innerHTML = htmlStr;
  side.querySelectorAll(".frow").forEach(el => {
    el.onclick = () => select(parseInt(el.dataset.i), true);
  });
}

// ---- function view ----
function colRows(side, diffTags) {
  const rows = side ? side.rows : [];
  if (!rows.length) return `<div class="empty">function not present</div>`;
  let out = "", insnIdx = 0;
  for (const r of rows) {
    if (r[0] === 0) {
      const loc = (DATA.files[r[1]] || "?").split("/").slice(-2).join("/") + ":" + r[2];
      const txt = r[3] ? esc(r[3]) : "&nbsp;";
      out += `<div class="row src"><span class="loc">${esc(loc)}</span>` +
             `<span class="txt" title="${esc(r[3])}">${txt}</span></div>`;
    } else {
      const at = r[1].toString(16).padStart(8, "0");
      const sp = r[2].indexOf(" ");
      const mnem = sp < 0 ? r[2] : r[2].slice(0, sp);
      const rest = sp < 0 ? "" : r[2].slice(sp + 1);
      const dc = diffTags ? " d" + diffTags[insnIdx] : "";
      out += `<div class="row insn${dc}"><span class="addr">${at}</span>` +
             `<span class="mnem">${esc(mnem)}</span><span class="txt">${esc(rest)}</span></div>`;
      insnIdx++;
    }
  }
  return `<div class="rows">${out}</div>`;
}

function select(i, scrollSide) {
  document.querySelectorAll(".frow.sel").forEach(e => e.classList.remove("sel"));
  const el = document.querySelector(`.frow[data-i="${i}"]`);
  if (el) { el.classList.add("sel"); if (scrollSide) el.scrollIntoView({block:"nearest"}); }
  const f = DATA.funcs[i];
  const v = document.getElementById("view");
  document.getElementById("pos").textContent = (el ?
    (filtered.indexOf(f) + 1) + " / " + filtered.length : "");
  if (!f) { v.innerHTML = ""; return; }
  const sub = [];
  if (f.a) sub.push(`${META.labelA}: 0x${f.a.addr.toString(16)}, ${f.a.sz} B, ${f.a.n} insns`);
  if (f.b) sub.push(`${META.labelB}: 0x${f.b.addr.toString(16)}, ${f.b.sz} B, ${f.b.n} insns`);
  if (f.a && f.b) {
    const d = f.b.n - f.a.n;
    sub.push(`&Delta; insns: <b style="color:${d>0?"var(--red)":"var(--green)"}">${d>0?"+":""}${d}</b>` +
      `, &Delta; bytes: ${f.b.sz - f.a.sz > 0 ? "+" : ""}${f.b.sz - f.a.sz}`);
  }
  if (f.score != null) sub.push(`similarity: <b>${Math.round(f.score*100)}%</b>`);
  if (f.hint) sub.push(`&#8674; likely inlined into <b>${esc(f.hint.into)}</b> (~${Math.round(f.hint.frac*100)}% of its shape)`);
  v.innerHTML = `<div class="fhead"><div class="n">${esc(f.n)}
    <span class="badge" style="background:${STATUS_COLOR[f.st]}22;color:${STATUS_COLOR[f.st]}">${STATUS_NAME[f.st]}</span></div>
    <div class="sub">${sub.join(" &nbsp;&middot;&nbsp; ")}</div></div>
    <div class="cols">
      <div class="col"><div class="colhead"><span>${META.labelA}</span><span>${f.a ? f.a.n + " insns" : ""}</span></div>${colRows(f.a, f.a && f.a.d)}</div>
      <div class="col"><div class="colhead"><span>${META.labelB}</span><span>${f.b ? f.b.n + " insns" : ""}</span></div>${colRows(f.b, f.b && f.b.d)}</div>
    </div>`;
  v.scrollTop = 0;
}

// ---- overview ----
function fmtB(n) { return n.toLocaleString(); }
function overview() {
  const m = META;
  let h = `<div class="overview"><h2>Summary</h2>
    <table class="t"><tr><th>metric</th><th>${m.labelA}</th><th>${m.labelB}</th></tr>
    <tr><td>functions</td><td>${m.countA}</td><td>${m.countB}</td></tr>
    <tr><td>.text bytes</td><td>${fmtB(m.textA)}</td><td>${fmtB(m.textB)}</td></tr>
    <tr><td>instructions</td><td>${fmtB(m.insnsA)}</td><td>${fmtB(m.insnsB)}</td></tr>
    <tr><td>matched (exact/stem)</td><td colspan="2">${m.nExact} / ${m.nStem}</td></tr>
    <tr><td>matched (similar/weak)</td><td colspan="2">${m.nSimilar} / ${m.nWeak}</td></tr>
    <tr><td>only in one side</td><td colspan="2">${m.nAOnly} + ${m.nBOnly}</td></tr></table>`;
  const movers = DATA.funcs.filter(f => f.a && f.b && (f.st === "exact" || f.st === "stem" || f.st === "similar"))
    .sort((x, y) => Math.abs(y.b.n - y.a.n) - Math.abs(x.b.n - x.a.n)).slice(0, 25);
  h += `<h2>Biggest matched movers (instruction count)</h2>
    <table class="t"><tr><th>function</th><th>${m.labelA}</th><th>${m.labelB}</th><th>&Delta;</th></tr>`;
  for (const f of movers) {
    const d = f.b.n - f.a.n;
    h += `<tr data-i="${f.i}"><td>${esc(f.n)}</td><td>${f.a.n}</td><td>${f.b.n}</td>
      <td style="color:${d>0?"var(--red)":"var(--green)"}">${d>0?"+":""}${d}</td></tr>`;
  }
  h += `</table>`;
  const orphans = DATA.funcs.filter(f => f.st === "a_only" || f.st === "b_only")
    .sort((x, y) => Math.max(y.a?y.a.n:0, y.b?y.b.n:0) - Math.max(x.a?x.a.n:0, x.b?x.b.n:0)).slice(0, 40);
  h += `<h2>Largest functions present on only one side (inlining / outlining)</h2>
    <table class="t"><tr><th>function</th><th>side</th><th>insns</th><th>likely inlined into</th></tr>`;
  for (const f of orphans) {
    h += `<tr data-i="${f.i}"><td>${esc(f.n)}</td>
      <td>${f.st === "a_only" ? m.labelA : m.labelB}</td>
      <td>${f.a ? f.a.n : f.b.n}</td>
      <td>${f.hint ? esc(f.hint.into) + " (~" + Math.round(f.hint.frac*100) + "%)" : "—"}</td></tr>`;
  }
  h += `</table><p style="color:var(--dim)">Pick a function in the sidebar, or press
    <b>/</b> to search. Status colors in the sidebar: green = name match, yellow =
    fuzzy shape match, orange = weak, red = present on one side only.</p></div>`;
  const v = document.getElementById("view");
  v.innerHTML = h;
  v.querySelectorAll("tr[data-i]").forEach(tr => {
    tr.onclick = () => select(parseInt(tr.dataset.i), true);
  });
}

// ---- wiring ----
document.getElementById("labA").textContent = META.labelA;
document.getElementById("labB").textContent = META.labelB;
document.getElementById("stats").innerHTML =
  `<b>${DATA.funcs.length}</b> functions shown &middot; ` +
  `<b>${META.nExact + META.nStem + META.nSimilar + META.nWeak}</b> matched`;
for (const id of ["search", "status", "sort"]) {
  document.getElementById(id).addEventListener("input", () => {
    refilter();
    const keep = selected != null && filtered.includes(DATA.funcs[selected]);
    if (!keep) { selected = null; overview(); }
  });
}
let selected = null;
document.addEventListener("keydown", e => {
  if (e.key === "/" && document.activeElement.id !== "search") {
    e.preventDefault(); document.getElementById("search").focus(); return;
  }
  if ((e.key === "ArrowDown" || e.key === "ArrowUp") && selected != null) {
    e.preventDefault();
    let k = filtered.findIndex(f => f.i === selected);
    k = e.key === "ArrowDown" ? Math.min(k + 1, filtered.length - 1) : Math.max(k - 1, 0);
    if (k >= 0 && filtered[k]) { select(filtered[k].i, true); }
  }
});
refilter();
overview();
</script>
</body>
</html>
"""


def build_output(args, a_funcs, b_funcs, files, pairs, matched_a, matched_b,
                 hints_a, hints_b):
    funcs_out = []
    pair_by_a = {aid: (bid, info) for (aid, bid), info in pairs.items()}

    def side_payload(f, diff):
        return {"addr": f.addr, "sz": f.size, "n": len(f.insns),
                "rows": f.rows, "d": diff}

    for aid, f in enumerate(a_funcs):
        d = {"i": 0, "n": f.name, "a": side_payload(f, None), "b": None, "st": "a_only"}
        if aid in pair_by_a:
            bid, info = pair_by_a[aid]
            g = b_funcs[bid]
            da, db = diff_rows(f, g)
            d["a"] = side_payload(f, da)
            d["b"] = side_payload(g, db)
            d["st"] = info["type"]
            d["score"] = info["score"]
        elif aid in hints_a:
            d["hint"] = hints_a[aid]
        funcs_out.append(d)
    for bid, g in enumerate(b_funcs):
        if bid in matched_b:
            continue
        d = {"i": 0, "n": g.name, "a": None,
             "b": side_payload(g, None), "st": "b_only"}
        if bid in hints_b:
            d["hint"] = hints_b[bid]
        funcs_out.append(d)
    funcs_out.sort(key=lambda d: d["n"])
    for i, d in enumerate(funcs_out):
        d["i"] = i

    meta = {
        "labelA": args.label_a, "labelB": args.label_b,
        "elfA": os.path.abspath(args.elf_a), "elfB": os.path.abspath(args.elf_b),
        "countA": len(a_funcs), "countB": len(b_funcs),
        "textA": sum(f.size for f in a_funcs),
        "textB": sum(f.size for f in b_funcs),
        "insnsA": sum(len(f.insns) for f in a_funcs),
        "insnsB": sum(len(f.insns) for f in b_funcs),
        "nExact": sum(1 for v in pairs.values() if v["type"] == "exact"),
        "nStem": sum(1 for v in pairs.values() if v["type"] == "stem"),
        "nSimilar": sum(1 for v in pairs.values() if v["type"] == "similar"),
        "nWeak": sum(1 for v in pairs.values() if v["type"] == "weak"),
        "nAOnly": len(a_funcs) - len(matched_a),
        "nBOnly": len(b_funcs) - len(matched_b),
        "filesA": len({r[1] for f in a_funcs for r in f.rows if r[0] == SRC}),
        "filesB": len({r[1] for f in b_funcs for r in f.rows if r[0] == SRC}),
    }
    data = {"meta": meta, "files": files, "funcs": funcs_out}
    return data


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ap.add_argument("elf_a")
    ap.add_argument("elf_b")
    ap.add_argument("--label-a", default=None, help="display label for ELF A")
    ap.add_argument("--label-b", default=None, help="display label for ELF B")
    ap.add_argument("-o", "--out", default=None, help="output directory")
    ap.add_argument("--objdump", default=None, help="objdump binary to use")
    ap.add_argument("--only", default=None,
                    help="regex: keep only functions whose name matches")
    ap.add_argument("--similar-threshold", type=float, default=0.60)
    ap.add_argument("--weak-threshold", type=float, default=0.45)
    args = ap.parse_args()
    if args.label_a is None:
        args.label_a = "A: " + os.path.basename(args.elf_a)
    if args.label_b is None:
        args.label_b = "B: " + os.path.basename(args.elf_b)
    if args.out is None:
        stem = "%s_vs_%s" % (os.path.basename(args.elf_a), os.path.basename(args.elf_b))
        args.out = os.path.join(".cache", "asm_compare", stem)

    objdump = find_objdump(args.objdump)
    files, files_idx = [], {}

    def load(path):
        sys.stderr.write("disassembling %s ...\n" % path)
        raw = run_objdump(objdump, path)
        funcs = parse_disassembly(raw, files, files_idx, nm_sizes(path))
        if args.only:
            rx = re.compile(args.only)
            funcs = [f for f in funcs if rx.search(f.name)]
        sys.stderr.write("  %d functions, %d instructions\n"
                         % (len(funcs), sum(len(f.insns) for f in funcs)))
        return funcs

    a_funcs = load(args.elf_a)
    b_funcs = load(args.elf_b)

    pairs, matched_a, matched_b, hints_a, hints_b = match_functions(
        a_funcs, b_funcs, args)
    data = build_output(args, a_funcs, b_funcs, files, pairs, matched_a,
                        matched_b, hints_a, hints_b)

    os.makedirs(args.out, exist_ok=True)
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    page = PAGE.replace("__DATA__", "JSON.parse(" + json.dumps(payload) + ")")
    out_path = os.path.join(args.out, "index.html")
    with open(out_path, "w") as fh:
        fh.write(page)

    m = data["meta"]
    print("\nwrote %s (%.1f MB)" % (out_path, os.path.getsize(out_path) / 1e6))
    print("%-28s %10s %10s" % ("", args.label_a, args.label_b))
    print("%-28s %10d %10d" % ("functions", m["countA"], m["countB"]))
    print("%-28s %10d %10d" % ("instructions", m["insnsA"], m["insnsB"]))
    print("matched: %d exact, %d stem, %d similar, %d weak; "
          "unmatched %d + %d (inlining hints for %d + %d)"
          % (m["nExact"], m["nStem"], m["nSimilar"], m["nWeak"],
             m["nAOnly"], m["nBOnly"],
             len(hints_a), len(hints_b)))
    print("open: file://%s" % os.path.abspath(out_path))


if __name__ == "__main__":
    main()
