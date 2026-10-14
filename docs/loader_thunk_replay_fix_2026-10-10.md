# Loader thunk replay fix — 2026-10-10

Closes the deleted tinycc report
`libs/tinycc/docs/bugs/kernel-thunk-replay-generic-loop.md` ("Thunk replay
retains generic layout checks, runtime division and stack traffic"): the
thunk suffix of a template replay kept generic layout checks, a runtime
division by the thunk template size, and a per-slot `memcpy` that forced
layout values to survive a call. The measured warm-launch cost of that loop
was 8,648 instructions with 1,692 direct scalar SP accesses; after the fix
it is 2,538 instructions with 94, and the whole TCC warm launch gate is
**−7.36%**.

## What changed

`dynamic_loader/source/template.zig`, `module.zig` and
`tools/yasld_prelink.zig` (uncommitted at the time of this measurement):

- **An explicit layout contract.** `template.thunk_size` is a comptime `16`;
  `module.thunk_code()` returns `*const [thunk_size]u8` and still checks the
  assembly data symbol (`indirect_call_thunk_template_size`) against it at
  runtime — a panic in every optimize mode, so replay and allocation never
  run against an arbitrary assembly template. `View.valid` and `View.fits`
  require `slot_size == thunk_size` exactly, where they previously accepted
  any multiple of 4 ≥ 16. The prelink tool's synthetic template `.skip`s
  `template.thunk_size` bytes from the same constant.
- **A specialized pair loop.** `View.apply` hands the thunk-only suffix
  (`entries[next..]`) to `replay_thunks`, which walks `[2]Entry` pairs
  directly: the two code words are read once before the loop, the slot
  offset is `(r9.at >> 8 - first) * 4 - thunk_r9_offset` — pure ALU, no
  `Layout.thunk_offset` bounds re-check, no `udiv`, no call, no layout
  reloads. The helper was removed.

The codegen the report quoted is gone from the loop. Before (frozen
before-kernel, one entry of the old suffix):

```asm
100392a0:  ldr   r0, [sp, #148]      /* layout lengths, reloaded per entry */
100392a2:  ldr   r1, [sp, #140]
...
100392ba:  ldr   r2, [sp, #172]      /* thunk_code.len: runtime divisor */
100392bc:  udiv  r3, r1, r2
100392c0:  muls  r3, r2
100392c2:  subs  r0, r1, r3          /* offset % len */
100392d4:  bl    memcpy              /* per slot */
100392d8:  ldrd  r0, r1, [sp, #144]  /* word_at layout reloads */
100392dc:  ldrd  r2, r3, [sp, #136]
```

After (one pair per iteration, `[0x100392c8, 0x1003932e)` in the after
kernel): `ldrd` of the pair, `lsl #2 / sub #8` offset math, one hoisted SP
load for the thunk base, two base-indexed loads, four `str.w`. No division,
no calls, no other SP traffic.

## Validation

### Codegen and contract gates

`dynamic_loader/tests/test_thunk_replay_codegen.py` (both ReleaseFast and
ReleaseSafe) builds `tests/thunk_replay_codegen.zig` through Zig's C backend
for thumb/cortex-m33, compiles it with the cross `armv8m-tcc -O2`, and
asserts the `replay` export contains no `[us]div` and no relocations to
`memcpy`/`memmove`/division helpers. It also assembles the real
`indirect_call_thunk.S` with the cross and checks the template against the
Zig constant: the two literal loads at +8/+12 (`dff80490 dff804f0`), a
zeroed descriptor, and a trailing size symbol of 16, with `slot_size()`
compiling to `movs r0, #16`. Wired into `dynamic_loader/build.zig` as
`zig build test-thunk-codegen`; `zig build test` (14 template host tests,
parser, integer hash) all pass.

### Correctness on device

A one-off kernel built with `zig build -Dverify_templates` (every warm load
replays into scratch **and** performs the full relocation, comparing the
two) ran the same 50-launch payload with rc=0 and no mismatch reports; an
ad-hoc counter in that build recorded 28 indirect calls actually executed
through replayed thunk slots. The full 15-workload kernel_compare battery
on the after-TCC kernel matches the after-LLVM kernel's outputs and return
codes everywhere (`zig-version` exits 255 under both — the known device-zig
rootfs issue, unchanged by this fix).

## Measurement

Four kernels from one rootfs and cross: before/after × tcc(`-O2`)/llvm, the
before trees being the after trees with only this fix reverted (the
copy-runs and split data/GOT loop work predates it, so this A/B isolates
the thunk change). Six boots per variant in alternating order, 50
`/bin/true` launches per boot, guest instruction counts from the icount
plugin. Raw logs, per-PC CSVs, kernels and hashes:
`.cache/thunk_replay_fix/` (`summary.json`, `manifest.json`,
`warm-results.json`, `battery.log`, `before-tcc.s`/`after-tcc.s`).

| Metric (per warm launch) | before | after | Δ |
| --- | ---: | ---: | ---: |
| TCC whole launch gate | 123,477 | 114,384 | **−7.36%** |
| LLVM whole launch gate | 95,525 | 83,281 | −12.82% |
| `load_from_template` total | 31,993 | 25,935 | −18.94% |
| Thunk replay loop | 8,648 | 2,538 | −70.65% |
| Thunk loop scalar SP accesses | 1,692 (1,504 ld + 188 st) | 94 (ld only) | −94.4% |
| Thunk loop SP transfer bytes | 8,272 | 376 | −95.5% |
| Data loop (isolation check) | 11,802 | 11,802 | 0 |
| GOT loop (isolation check) | 9,738 | 9,738 | 0 |

The 94 remaining SP loads are one hoisted thunk-base load per pair (94
pairs per `/bin/true` launch). The report's frozen-ELF numbers (8,648;
1,504 loads + 188 stores) reproduce exactly in the before variant; the
whole-function total is slightly lower than the report's 32,074 because the
copy-runs change landed in between. The LLVM kernel gains more than TCC
(−12.82% vs −7.36%), so the TCC/LLVM warm ratio moves from 1.293× to
1.373×: this fix removes real TCC cost — and more cost that both compilers
were paying — without narrowing that particular ratio.

Kernels (sha256 in `manifest.json`): before-tcc `73b789c3…`, after-tcc
`7aaf38a9…`, before-llvm `10c976df…`, after-llvm `aa333d1d…`, verify-tcc
`89f8600a…`; rootfs `ce19f5b7…`, cross `cc6aeef8…`.

## Report closure

The tinycc bug report was deleted per the docs/bugs convention (git history
keeps it); the evidence index row in
`libs/tinycc/docs/bugs/kernel-bottlenecks-2026-10-09.md` and the bugs
README record the fix and this page.
