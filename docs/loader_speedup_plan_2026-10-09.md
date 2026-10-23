# Loader speedup — implementation and validation plan

**Implementation updated 2026-10-09.** L1–L4 are implemented in the working
tree, including the validation and ownership fixes below. Results and remaining
integration limitations are recorded in §6. The F-items remain in
[`loader_vfs_speedup_plan_2026-10-09.md`](loader_vfs_speedup_plan_2026-10-09.md).

The parent's L3 format-change proposal is superseded here: YAFF already
carries the relocation and symbol-table offsets, and the writer in
[`tccyaff.c`](../libs/tinycc/source/obj/tccyaff.c) populates them. **No YAFF
format change is needed.** Per-image parser caching and bulk thunk-code
generation remain separate follow-ups, outside these four changes.

## 0. Review findings and baseline

### 0.1 Implementation status

| Item | Implemented behavior | Validation |
| --- | --- | --- |
| L1 | Explicit full/selective copy mode, safe thunk-prefix clearing, validated v3 precache, differential build option | Host coverage; whole-rootfs prelink; RAM and flash differential boots |
| L2 | Exec from the resolved node, bounded mapped sniff, rewind and complete stream reads, error cleanup | Mocks; direct exec/shebang/argv smoke; RamFs logical-length correction |
| L3 | Recorded offsets, bounded layout validation, 32-entry immutable-image validation memo, one dependency-header check | Parser malformed cases; full rootfs; architecture and compiler suites |
| L4 | Exact direct lookup, bounded authoritative negatives, filename checks and mount-generation invalidation | Strict acquisition mocks; transient failures, limits, allocation failures and namespace tests |

Corrections to the original plan:

- L1 removes initialization copies/clears, **not replay entries**. K1 still
  targets the same entry list; re-profile its relative cost after L1.
- The 9,115 sentinel-scan instructions are a whole-launch family, not a
  measurement of the imported-table extent walk alone. The `memcpy` and
  `memset` families likewise include callers outside the loader.
- `openprof.calls` counts `sys_open`, not arbitrary VFS `get`s. It cannot
  establish the proposed loader acquisition counts.
- `View.fits` checks thunk bytes, but the loader's private `fits` helper
  checks dependencies and data/GOT lengths. Static copy-run coverage and
  descriptor validation now happen on capture/precache acceptance.
- Read-only `/lib` does not bound distinct missing names, make transient
  errors permanent, or prove that its mount cannot change.
- Existing `shell_test.py` runs `sh script`; it does not exercise direct
  `execve` shebang handling.

### 0.2 Measurement and attribution

Capture a baseline snapshot of the existing dirty tree before implementation
changes. Include unrelated existing edits in its identity without discarding
them; HEAD alone is insufficient.
For an item's total speedup claim, reconstruct a control without that item's
draft while retaining unrelated changes. The current draft snapshot is only
a baseline for subsequent fixes, not the original unoptimized behavior.

| What | How | Reference / limitation |
| --- | --- | --- |
| Warm launch | Repeat the [October 9 recheck](kernel_performance_recheck_2026-10-09.md) driver: five warmups, 50 measured launches, six alternating boots per variant | TCC: 153,627 CPU0 / 154,597 both-CPU instructions; LLVM: 108,626 / 109,146 |
| Function attribution | Per-PC CSVs and disassembly from the same capture | Both-CPU, exclusive instructions: `load_from_template` 34,252; `memcpy` 14,177; `memset` 9,826; sentinel scanning 9,115; `Parser.create` 6,672. Inlining changes boundaries |
| Workload regression | `scripts/kernel_compare.py` | Fresh boot per workload; its battery does not automatically reproduce the repeated warm driver |
| Load phase timing | `dump_phases` in `source/kernel/modules.zig`, `loadphase` lines | First load arms the clock for later loads; nested phases can overlap, so do not sum as exclusive times |
| Per-spawn load time | `tests/smoke/timing.py`, `load kind=` lines | Use serial samples (`-n 0`); document timer boundaries, especially sniff/lookup time after L2 |
| Cache behavior | `/proc/meminfo` loader-cache fields and `template.stats` | Separate RAM hits, precache hits, misses, bytes, captures and evictions |
| Acquisition counts | Strict mocks plus temporary counters at relevant `get`, directory-`get` and iterator sites | Separate exec opens from dependency/precache opens and symlink probes; `openprof` is supplementary |
| Card latency | Fixed FAT/ext4 workload on hardware or calibrated board model | Plain QEMU instructions do not establish SD-card time saved |

Keep compiler sources, kernel optimize mode/config, workload sources and
rootfs payloads fixed. Record dirty source/submodule snapshots, tool versions,
kernel/rootfs/cache hashes and guest output hashes. For L1, build each side's
matching precache from **identical YAFF files** with a saved, sorted path list;
regenerating the cache alone need not recompile userspace.

Exercise three cache states: valid flash precache on fresh boot; no usable
precache with empty RAM cache; repeated RAM hits. Warm `/bin/true` alone does
not measure capture overhead or resolver misses. Stale precaches impose cold
relocation on **each boot**, and again after eviction, not just the first boot.

Repeat A/B in both orders, report spread, and require improvement beyond
observed variation on the target workload without unexplained regressions on
the other compiler variant. Do not promise proportional instruction savings
from bytes skipped or add savings across items.

## 1. L1 — copy only image bytes that replay leaves untouched

Sources: [`template.zig`](../dynamic_loader/source/template.zig)
(`finish_capture`, `copy_from_image`, `View.apply`, precache reader),
[`module.zig`](../dynamic_loader/source/module.zig)
(`LoadedUniqueData.create`, `ThunkHolderData.create`),
[`loader.zig`](../dynamic_loader/source/loader.zig)
(`load_from_template`, `verify_template`), and
[`yasld_prelink.zig`](../dynamic_loader/tools/yasld_prelink.zig).

### 1.1 Design

The original template path copies all process data and GOT bytes and clears
the whole thunk pool, then replay overwrites relocated words/generated slots.
Keep cold relocation as the reference: full image copy, full thunk clear,
relocation, then live copy relocations.

Retain `CopyRun { start: u32, end: u32 }`, half-open **word** indices over
logical `[process-data][got]`. Process data excludes the shared
`const_rodata_length` prefix. The physical region is
`[process-data][bss][got]`: split a crossing run into two copies, skipping bss.
Derive runs from the complement of captured stores. Store them and
`slots_written` (complete leading generated prefix) in RAM templates and precache.
Initialize those runs, always zero bss, zero thunk slots
`[slots_written, thunk_count)`, then replay the unchanged entry list.

`View.apply` copies a **16-byte slot template**, including descriptor
placeholders, at its r9 entry, then writes descriptor values. Bulk-copying
identical code is separate work because slots interleave code and
process-specific descriptors.

Make initialization mode explicit. The draft's empty `copy_runs` means full
copy, but an all-replayed region also has an empty complement and needs
**zero** copying. Serialize a mode such as `copy_all` versus `copy_runs`;
empty runs in the latter mode mean zero bytes copied. Finalize this in the
v3 format; reject both v1 and the earlier draft v2.

Cap selective metadata at 64 runs: 512 bytes per template, plus header growth
and alignment. Beyond the cap, retain replay with full image copy. This is
an initial limit, not a measured optimum; report run counts and capture cost.

### 1.2 Conditions and validation

1. **Coverage:** selective copies and replay stores cover every process-data
   and GOT byte exactly. Full-copy fallback intentionally overlaps replay.
   Require word-sized/aligned ranges for selective capture; otherwise use
   the existing safe path, including trailing bytes.
2. **Thunk prefix:** `slots_written <= thunk_count`. Every prefix slot must
   have both descriptor stores and the r9 entry that triggers slot-template
   copying. Later complete descriptors are allowed: relocation phases reserve
   separate ranges, and weak references/reuse can leave interior holes. Clear
   the whole tail before replaying those later slots. Taking the maximum marked
   slot does not prove a safe prefix. Reject partial descriptors and unexpected
   thunk stores in release builds.
3. **Weak/reuse behavior:** unresolved weak references and thunk reuse can
   leave unused capacity. Keep it zero so `find_thunk` cannot match unused
   descriptors; preserve function-pointer equality.
4. **bss/live data:** keep bss zero initialization and apply copy relocations
   after replay from dependencies' live data, including bss destinations.
   Never cache their source bytes.
5. **Serialized metadata:** use checked arithmetic for lengths/counts; bound
   children, kinds and entry indices; require ordered unique entries; check
   run order/non-overlap/bounds, mode and slot coverage. Reject a bad view
   before partial replay and cold-relocate. `fits` alone is insufficient.
   Validate static metadata once on template construction/acceptance rather
   than scanning every entry on each warm hit.
6. **Layout/accounting:** adding fields can unalign precache child u64 hashes
   (v3 has a 32-byte template header; records remain 4-byte aligned); reader alignment must match the
   writer. Keep runs in the pinned/reclaimable RAM block, counted by `bytes()`.
7. **Compatibility:** new exact-version readers reject v1/v2; old readers reject
   v3; both cold-relocate rather than reinterpret blobs. No YAFF bump. Revert
   with matching precache/rootfs and kernel re-embedding.

### 1.3 Tests and acceptance

Strengthen `verify_templates`: full relocation into the real module versus
selective initialization + replay into scratch with the same bases. Poison
scratch first to expose unwritten bytes; compare **all bytes**, including
tails; make mismatches fail the run. The implementation exposes `-Dverify_templates=true`, fails on allocation
errors or mismatches, and reports checked/failed counts in `/proc/meminfo`.
There is no silent skip path. This mode runs
the reference load, so ordinary template-hit execution also needs coverage.

Match the copy-relocation stage on both sides: the current reference has
already applied live copies, while scratch replay alone has not. Apply those
copies to scratch destinations from the same dependency state and include
bss in the final comparison. The scratch allocation includes bss, while template capture continues to
exclude it.

Required host cases:

- Full versus selective start with relocated bases; no/all stores; empty
  data/GOT; boundary-crossing runs; RELRO, bss and non-word-sized fallback.
- Full, empty and partially used thunk pools; weak NULL; reuse; interior hole
  preserved and cleared; partial descriptor rejected by capture.
- Exactly 64/65 runs; zero-copy distinct from full-copy fallback; allocation
  failure leaves cold relocation available.
- Writer/reader round-trip; stale version/thunk-layout rejection; truncated
  blobs, overflowing counts and invalid modes/runs/entries/slots.

The draft synthetic test replays the same entries onto both starts: it proves
initialization equivalence, not equivalence to relocation. Run differential
QEMU coverage with **RAM templates and flash precache**, ordinary full tcc,
vfork/shell/make smoke coverage and the self-host fixpoint. Add a live-copy
fixture if the current writer/suite does not emit copy relocations.

**Acceptance:** zero differential mismatches/skips on selected cases;
ordinary hits covered; no new suite failures; self-host fixpoint; measured
warm improvement with copied/cleared bytes, cold capture cost, RAM/flash
growth and eviction behavior reported. The run cap bounds added run bytes,
not the whole cache or replay list.

## 2. L2 — reuse the resolved executable node

Sources: [`syscall_handlers.zig`](../source/kernel/interrupts/syscall_handlers.zig)
(`shebang_exec`, `sys_execve`),
[`process_manager.zig`](../source/kernel/process_manager.zig) (`prepare_exec`),
and [`modules.zig`](../source/kernel/modules.zig)
(`load_executable`, `load_executable_node`).

### 2.1 Design and correctness requirements

Pass the resolved node from sniffing through loading; retain the by-path
wrapper for boot/other callers. Acquire a normal executable once, or a
shebang script once and its interpreter once. These are **loader file
acquisitions**: normalization/symlink resolution can perform more FS work.

- Bound mapped sniffing by `min(size, 128)`. Handle empty/tiny files before
  dereferencing a header. Preserve current bounded shebang syntax/argv rules
  and ENOEXEC fallback; recursive interpreter handling is outside this change.
- Unmapped sniffing advances `IFile`'s cursor. **Seek to zero and check the
  result** before loading the same node, or explicitly retain/include the
  prefix in the image buffer. The draft does neither; RAM/FAT binaries would
  start loading after their header.
- Loop over valid positive partial reads until the known size is filled.
  Early EOF is `ExecFormatError`; propagate/map negative read errors according
  to the IFile contract. Do not retry EOF via arbitrary seeks or zero-fill
  the missing tail. Fix backing-filesystem bugs separately. Chunk size is a
  measured performance choice, not a universal 4 KiB requirement; smaller
  requests can increase card overhead.
- Check size conversion, minimum header length and allocation bounds before
  parsing mapped/copied images. Pair L3 checks with a known image length;
  a raw pointer does not establish file bounds.
- The caller owns the node until transfer; the loader then deletes it once
  on every exit. On interpreter-open failure, free the script node, duplicated
  interpreter/path and rewritten argv block. Free the path on load failure
  in `prepare_exec`, whose current cleanup is success-only. Release image
  allocations on read/parse/load/install failure. Test allocation failures
  around these transitions.
- Free temporary nodes/arguments before successful vfork handoff, which can
  bypass caller defers. Keep loader/cache mutation under the loader lock and
  preserve `/proc/<pid>/exe` reporting.
- Sharing a node prevents independent sniff/load resolution of different
  files; it does not freeze writable file contents. Do not claim snapshot
  atomicity for concurrent modification.

### 2.2 Tests and acceptance

Strict mocks must prove no executable-path `get` in the node loader and
exactly-once cleanup on success, non-file, seek failure, EOF, negative read,
parse failure and allocation failure. Read mocks must populate real
image/prefix bytes, not just return counts. Include partial-read completion
and positive partial read followed by EOF; the latter must not call yasld.

Add **direct execve** fixtures for mapped/unmapped binaries and scripts,
shebang with/without argument, argv forwarding, malformed/overlong lines,
missing interpreter, empty/tiny files, shell fallback without shebang and
`envp == NULL`. Run vfork success/failure coverage. `shell_test.py` alone
does not test this path; `yaff_arch_test.py` does not test truncation.

Run a FAT executable via `qemu_mount.py`, plus RAM/ext4 cases where available.
Count acquisitions at loader call sites: one normal/two shebang, excluding
libraries/precache. Keep timing windows consistent: the old loader timer
excluded the earlier shebang sniff. Report board/model latency separately.

**Acceptance:** complete images load from byte zero; truncation fails;
ownership/direct-shebang/vfork tests pass; `/proc` behavior preserved; no new
smoke failures; one redundant executable acquisition removed.

## 3. L3 — existing table offsets and less duplicate work

Sources: [`parser.zig`](../dynamic_loader/source/parser.zig) (`Parser.create`),
[`item_table.zig`](../dynamic_loader/source/item_table.zig),
[`header.zig`](../dynamic_loader/source/header.zig), and
[`loader.zig`](../dynamic_loader/source/loader.zig)
(`process_header`, `import_child_modules`, `load_module`).

### 3.1 Design

Use `relocations_offset`, `imported_symbols_offset` and
`exported_symbols_offset`. Remove name walks used **only to locate subsequent
tables**. Parsing still spans the module name, reads hash-table metadata and
constructs views; dependency iteration/symbol lookup remain. Do not target
near-zero parser instructions or elimination of all sentinel scans.

Compute each stride once in `ItemTable.size()` and each next pointer once
in `Iterator.next()`. `iter()` still scans `size()` to establish its end;
this does not make a complete traversal single-pass. Iterator redesign and
parser-view caching are separate work.

Pass an already-validated dependency header only through the private load
path for the **same image and length** within that lifetime. Independent
executable/dlopen entries must validate; avoid a public validation bypass.

### 3.2 Offset contract

`offset != 0 && offset < text_offset` is only a plausibility test: it accepts
header pointers, misalignment, overlap and overflowing spans, and can reject
legal empty-table boundaries. `process_header` checks version/architecture
and data alignment; it does not currently validate all table bounds.

Before direct addressing:

1. Validate header/architecture-section spans before reading them. Check
   alignment, `text_offset` and section arithmetic against known image length.
2. Check metadata lower bounds, table alignment/order, fixed relocation
   `count * stride` spans and lookup/hash-table spans with checked arithmetic.
   Require names to terminate inside their bounded table before scanning them.
3. Permit empty spans at boundaries where the writer allows them; nonempty
   spans need sufficient bytes. Test equality at boundaries instead of the
   blanket `< text_offset` rule.
4. Reject inconsistent nonzero offsets; do not silently reinterpret them via
   an unbounded chained fallback. The current YAFF writer supplies offsets.
   Keep zero-offset compatibility only for a demonstrated supported producer,
   with bounded walks and explicit fixtures; otherwise reject missing fields.

The executable caller knows size, but the library resolver returns only an
address. Carry `{ address, length }` or equivalent trusted mapping metadata
through dependency resolution and prelink. Do not infer available length
solely from unvalidated header fields. This is an API change, not a format
change. Validate at the input boundary, memoizing successful structural
validation for stable romfs image identities so a full name scan is not
reintroduced on every warm load. Copied/mutable images need fresh validation.

### 3.3 Tests and acceptance

- Valid parser cases: zero/single/multiple entries, long names/padding,
  dependencies, relocation kinds, lookup/hash tables, empty boundaries and
  the explicit zero-offset policy. Compare relative addresses **and contents**.
- Reject header-pointing/misaligned/overlapping/out-of-file offsets,
  overflowing counts, truncated arrays and unterminated names without faults.
- Item tables: empty iteration, final item visited once, padding and lookup
  semantics preserved.
- Cross-check direct versus bounded chained addresses over frozen rootfs and
  representative device-produced images. The draft only logs discrepancies:
  make a mismatch fail the run and record checked-image counts.
- Generate precaches on each side using **the same cache format and frozen
  image list**; require byte identity. Comparing L1's v1 with v2 cannot prove
  parser equivalence. Cover images not collected by prelink with parser/tcc
  tests.

**Acceptance:** identical valid parse results/cache bytes; malformed inputs
rejected; no new architecture/tcc failures; self-host fixpoint; redundant
extent walks and second dependency-header checks removed. Report first-time
validation and warm costs separately, with measured parser/scan deltas.

## 4. L4 — direct library probe and bounded negative caching

Source: [`modules.zig`](../source/kernel/modules.zig)
(`file_resolver`, `probe_library_path`, `is_requested_file`, resolver cache).

### 4.1 Design and conditions

The scan uses directory `get` and **exact** `file.interface.name()` equality,
not suffix matching. First probe `/lib/<name>` with the same file/name/mapping
checks. A successful direct hit uses one top-level `get`, no iterator or
entry opens. A cold romfs lookup may still scan directory headers; a lookup
cache hit is not guaranteed.

Keep scan fallback until equivalence is established. Internally distinguish
found, authoritative not-found and failed-to-determine. A fallback miss costs
**one probe + one `/lib` get + iteration/entry opens**, not one probe total.

- Validate a single filename component: reject empty names, `/`, `.` and `..`,
  plus embedded NUL if representable. These did not match the flat scan;
  direct lookup must not escape `/lib`. Check the returned file name to
  preserve existing behavior around symlinks.
- A 64-byte path-buffer overflow is not absence. Fall back to scanning or
  bounded allocation for supported longer names; test the boundary.
- Cache negatives only after an authoritative direct `NoEntry` on immutable
  romfs. Iterator `next()` also returns null for some allocation/I/O failures,
  so scan exhaustion alone is not proof of absence. Never
  cache OOM, I/O/permission failure, iterator failure or skipped entry-open
  errors. The draft currently collapses several failures into null and can
  cache them permanently. Cache-allocation failure simply leaves an answer
  uncached.
- Default `etc/fstab` leaves `/lib` in romfs. Enforce unchanged namespace and
  mapping lifetime for permanent entries; refuse dependency mappings on mutable/unknown backings, since the current
  resolver cannot pin their lifetime. If mounting over `/lib` is supported, invalidate on namespace
  changes. Cached positive addresses need the lifetime rule too.
- Start with explicit negative limits: **32 entries and 4 KiB of copied key
  bytes**, with eviction or no insertion on overflow. Input-controlled name
  diversity is not a bound. Keep negatives separate/tagged so their churn
  cannot evict working positive mappings. Free keys on replacement/eviction/
  deinit; serialize mutation with the loader lock. Report cache outcomes
  without adding unbounded diagnostic storage.

### 4.2 Tests and acceptance

Mocks: direct mapped hit without scan; direct miss/fallback hit; authoritative
fallback miss; repeated negative without FS calls; nonmapped/name-mismatch
hits; prefix/suffix collisions; invalid components; long names; formatting
and cache-allocation failure. Inject lookup/iterator/entry-open failures and
require a later retry to succeed. Exceed both negative limits and verify
cleanup. Test the chosen mutable-mount/namespace-change policy.

Capture first resolver use on fresh boot: the first tcc compile may already
have warm libc/libm entries from boot shell startup. Count probes, fallback
scans, entry opens and cache outcomes. Run tcc/shell coverage and compare
resolved image identities/addresses.

**Acceptance:** one top-level get/no explicit scan for present direct hits;
zero FS calls for resident repeated authoritative negatives; transient errors
retry; both negative limits enforced; results preserved; cold/miss costs
recorded.

## 5. Sequencing and gates

Snapshot the baseline, then complete **L3 → L4 → L2 → L1** where practical,
coordinating L3's length-carrying API with resolver/exec-node changes. Measure
single-stride cleanup separately from structural validation/direct offsets.
Interleaved drafts are not isolated A/B evidence: use saved snapshots or
separate checkouts without reverting the user's tree. Re-rank after each
result. L1 needs a matching regenerated cache/rootfs and kernel rebuild;
L2/L4 kernel changes do not inherently require userspace recompilation.

### 5.1 Commands and test ownership

Run both graphs. Root kernel tests use **stub yasld** and do not establish
that real parser/template tests passed:

```sh
zig build test
(cd dynamic_loader && zig build test)
(cd dynamic_loader && zig build prelink)
```

Regenerate from a saved sorted image-path list using
`dynamic_loader/zig-out/bin/yasld-prelink OUTPUT rootfs/lib -`.
`build_rootfs.sh` normally generates the cache before packing romfs, but a
prelink failure permits an uncached rootfs. Verify the intended cache
version/hits rather than assuming the build tested precache. Rebuild the
kernel after replacing its embedded `rootfs.img`.

After building the intended kernel/rootfs:

```sh
./scripts/run_qemu_smoke.sh --no-build tcc_suite_test.py
./scripts/run_qemu_smoke.sh --no-build vfork_test.py shell_test.py make_test.py yaff_arch_test.py
./scripts/tcc_selfhost.py --qemu
```

Include new direct-exec/error fixtures in the selected smoke set. Use `-n 0`
for timing attribution, not necessarily all correctness runs. Record baseline
failures/skips by test and optimization level. Existing compiler/self-host
failures must not be relabeled loader regressions; they also do not prove
loader correctness. New targeted tests must pass; failing required gates
remain explicitly incomplete.

Preserve the shared performance baseline:

```sh
python3 scripts/kernel_compare.py --baseline .cache/loader_review/baseline.json --store .cache/loader_review/baseline.json
python3 scripts/kernel_compare.py --baseline .cache/loader_review/baseline.json
```

Specify both paths: the current script chooses the output from `--baseline`
when `--store` has a non-default argument; bare `--store` uses the shared
default even if `--baseline` was supplied.

The first command records A; rebuild the changed sources before B. Archive
each run's manifests/CSVs separately. This battery supplements §0's repeated
warm driver. Disable differential verification/verbose tracing for performance.

### 5.2 Required gate matrix

| Gate | L1 | L2 | L3 | L4 |
| --- | --- | --- | --- | --- |
| Loader host tests + prelink build | Required | Build compatibility | Required | Build compatibility |
| Root kernel tests/mocks | Required | Required | Required | Required |
| New targeted success/error cases | Required | Required | Required | Required |
| Full tcc QEMU suite, no new failures | Required | Required | Required | Required |
| vfork + shell + make smoke | Required | Required | Shell integration | Shell integration |
| Malformed-input coverage | Precache | Truncation | Tables/architecture | Resolver |
| Differential boot: RAM and precache | Required | — | Required for changed parser/cache path | — |
| Self-host fixpoint | Required | Final integration | Required | Final integration |
| Precache validation | New-format round-trip | — | Same-format byte comparison | — |
| Warm profile + workload A/B | Required | Required | Required | Required, plus cold resolver |
| Acquisition-count mocks/counters | — | Required | — | Required |
| Heap/cache lifetime and bounds | Runs/reclaim | Error cleanup | Validation memo | Negative limits |

Self-hosting is substantial, not a cheap per-edit check. Use slices while
developing, full required gates before landing, and a final integrated
fixpoint. Heap acceptance permits bounded cache warmup, then requires a
stable plateau and correct release/reclaim, rather than literally no growth
while populating new templates/negative entries.

## 6. Completion record

The implementation is present for all four items. The self-host fixpoint gate
initially failed for setup reasons unrelated to the loader (§6.1) and passed
on a coherent rerun the same evening (§6.4). Local artifacts live under
`.cache/loader_finish/` and are intentionally outside version control.

### 6.1 Correctness and compatibility

- Root `zig build test --summary all`: complete graph passed, 465 kernel tests
  and 123 filesystem tests, plus HAL/architecture graphs. (Found broken when
  reviewed end-of-day: the last edit to the new
  `VirtualFileSystem.SymlinkFallbackUsesActualBackingLifetime` test omitted
  the `root.get("var")`/`mutable.mount()` expectations that mounting `/var`
  over a mock root requires, so the graph aborted deterministically — the
  16:17 verification log recorded a failure the completion notes had already
  claimed as green. Fixed by adding the expectations in call order; the full
  graph passes again.)
- Standalone `zig build test prelink -Dverify_templates=true`: 13 host tests
  (12 template, one multi-case parser test). Both graphs use temporary Zig
  cache directories; root tests alone use stub yasld.
- Whole frozen rootfs: 46 YAFF images loaded, zero skipped, 42 v3 templates;
  85 differential checks, zero mismatches. Regenerating with the final reader
  produced byte-identical v3 cache bytes. The installed rootfs was repacked
  and re-embedded; userspace images were not recompiled.
- Full compiler suite at `-O0/-O1/-O2`, including GCC torture: **14,618 passed,
  231 skipped, four failed**. The isolated control has the same totals and
  the same four failures: `ir_tests/894_asm_machine_call.c` at all three
  optimization levels, and `gcc_execute/990128-1` at `-O2`. The verification
  kernel and ordinary TCC kernel both reproduced this set.
- The 28 vfork/shell/make/YAFF smoke cases pass on the ordinary TCC kernel,
  flash verification kernel and RAM verification kernel. Direct exec tests
  cover a shebang optional argument (`sh --`), retained arguments/status,
  64 missing-interpreter attempts and subsequent successful exec. Strict host
  mocks additionally cover partial shebang reads and bounded mapped sniffing.
- Three runs of the 5-warmup/50-launch driver: RAM verification reached
  **516 checked, zero failed**, 13,864 template bytes; kernel heap stayed at
  **125,268 B**. Flash verification reached **519 checked, zero failed**,
  zero RAM-template bytes; kernel heap stayed at **125,196 B**. Legacy cache
  rejection, capture and repeated RAM replay were exercised separately.
- The strict complete-read contract exposed a RamFs bug: `IFile.size()`
  included `RamFsData` allocation overhead. It now returns payload length;
  in-memory and spilled-file tests agree with readable bytes. EOF fails the
  load, positive partial reads progress, and failed acquisition frees memory.

Self-hosting used a private cross built from the current tinycc sources with
rootfs library paths (the installed cross's default paths pointed at host
`/usr/lib`). Both stages compiled all 76 translation units and the newly
built compiler produced a working hello. The final run reported **14
identical / 63 differing fixpoint artifacts**, and **4 identical / 72
differing objects versus the host cross**. This does **not** satisfy the
fixpoint gate.

The control-payload comparison (`selfhost-control.log`, same payload and
cross, the HEAD-loader control kernel) completed later the same day and
reproduced the failure **exactly** — identical differing-object sets,
identical counts — so the loader changes did not alter a single self-host
outcome. The discrepancy was then traced to two setup defects, not a
miscompile and not the loader:

1. The payload/reference objects were built while `ra:loop_split` was
   temporarily **default-on** in the working tree (the 15:42 warm-census
   flip), while the romfs `tcc` executing stage 2 predated it — and the
   payload sources compiled into the stage-3 compiler carried the default-on
   state, so stages 2 and 3 could not agree. The tree reverted to
   default-off (`TCC_LOOP_SPLIT=1` opt-in) until the seed-172 miscompile was
   fixed (`8395ce4c`: the loop group's entry copy sorted before the def
   group's write-back at their shared insertion point), which flipped the
   default back on — verified by the seed-172 repro, the loop_split
   regression ir_tests, and a 401-seed `diff_olevels` sweep with zero
   divergences.
2. The private cross itself was hand-built with plain `make` and only path
   overrides, which drops `-DTARGETOS_YasOS=1` from
   `build_rootfs.sh`'s cross configure. That define changes the compiler's
   target predefines and frame layout: a cross built without it emits
   objects whose stack frames differ by 8 bytes from the device compiler's
   (verified by disassembly on `cmp_eq.c`), which alone accounts for
   host-vs-device differences on most TUs.

A coherent rerun (fresh rootfs/kernel/payload all built from the reverted
tree via `build_rootfs.sh` + `tcc_selfhost.py --prepare-only`, probe TU
byte-identical between the reference and the device `tcc` before the run)
is recorded in §6.4.

### 6.2 Repeated performance result

The control restores HEAD's four loader changes in an isolated source copy,
retains the surrounding working tree, and shares the RamFs length correction.
Both sides use the same private cross, ReleaseFast kernel configuration and
identical YAFF payloads; prelink produces matching **v1 control / v3 changed**
caches. This measures the combined L1–L4 change, not each item's isolated gain.
No shared performance baseline was overwritten.

Six alternating boots per build, five warmups and 50 measured `/bin/true`
launches per boot, guest instructions per launch:

| Kernel | Control CPU0 mean [min, max] | Changed CPU0 mean [min, max] | Both CPUs mean: control → changed | Change |
| --- | ---: | ---: | ---: | ---: |
| TCC | 151,786 [151,055, 152,333] | 139,291 [138,410, 140,168] | 152,736 → 140,227 | **−8.19%** |
| LLVM | 108,546 [108,278, 108,985] | 99,450 [99,163, 100,106] | 109,068 → 99,948 | **−8.36%** |

(The means above are recomputed from the archived `warm-results.json` /
`warm.log` summary; an earlier edit of this table quoted a preceding batch —
151,492→139,634 / 108,464→99,475, −7.80% / −8.26% — same conclusions.)

CPU0 exclusive attribution in those captures: TCC `Parser.create` fell from
6,672 to 1,065 instructions and `load_from_template` from 33,781 to 32,047;
LLVM `Parser.create` fell from 2,595 to 546. Whole-launch memcpy/memset also
fell; they include non-loader callers and cannot be assigned wholly to L1.

The fresh-boot workload battery compared exit codes and output hashes for
both kernel backends: **zero comparison failures**. Zig workloads were skipped
because the frozen rootfs has no Zig executable. Small cold-workload count
increases remain visible (largest initial sample: LLVM sha256sum +3.08%);
this result is a repeated warm-launch gain, not a blanket claim that every
first-time load becomes faster. Card latency, isolated per-item A/B and
cold RAM-capture attribution remain unmeasured.

### 6.3 Reproduction and artifacts

The `before/` snapshot preserves the initial dirty-source hashes, original
kernel, rootfs and cache. `manifest.json` records final sources, YAFF payloads,
config, tools, kernels and cache identities. The isolated `control/` and
`control-{tcc,llvm}/` builds permit repeating comparisons without reverting
the user's working tree. `warm.py`, `warm-results.json` and `insns/*.csv`
record repetitions, spread and attribution. `battery-{control,final}/` holds
workload JSON, output hashes and per-PC CSVs.

```sh
zig build test
(cd dynamic_loader && zig build test prelink -Dverify_templates=true)
# Frozen sorted paths include non-YAFF files; prelink loads only YAFF images.
dynamic_loader/zig-out/bin/yasld-prelink OUTPUT rootfs/lib - < .cache/loader_finish/images.txt
./scripts/run_qemu_smoke.sh --no-build tcc_suite_test.py -n 8
./scripts/run_qemu_smoke.sh --no-build vfork_test.py shell_test.py make_test.py yaff_arch_test.py -n 4
./yasos_venv/bin/python .cache/loader_finish/warm.py
./yasos_venv/bin/python .cache/loader_finish/selfhost2-run.py
./yasos_venv/bin/python scripts/kernel_compare.py --skip-build --work .cache/loader_finish/battery-final --baseline .cache/loader_finish/baseline.json
```

Verification is opt-in for the real loader and prelink. Ordinary optimized
builds leave it off. The v3 reader rejects v1/v2 before replay; the earlier
reader rejects v3. No YAFF writer or format bump was needed. Bulk thunk-code
generation and per-image parser caching remain separate follow-ups.

### 6.4 Self-host rerun on a coherent toolchain (2026-10-09, evening)

After the §6.1 root-cause, the whole chain was rebuilt from the reverted
(loop_split-off) working tree and the gate rerun:

- `./build_rootfs.sh -o rootfs.img` — fresh cross through its exact configure
  (with `-DTARGETOS_YasOS=1`, rootfs sysroot), fresh romfs `tcc`, userspace,
  v3 precache, kernel re-embed (`zig-out/bin/yasos_kernel`, sha256
  `532a146e…`; `rootfs.img` `c13baf95…`).
- `tcc_selfhost.py --prepare-only --work .cache/loader_finish/selfhost2` —
  payload and reference objects from the same tree and the same in-tree cross.
- Pre-flight: one probe TU (`cmp_eq.c`, rsp 059) compiled on the device with
  the romfs `tcc` and compared with the payload reference — byte-identical
  (`d64e258e…`), so device and host compilers agreed before the long run.
- Full stages 2+3 under QEMU on the changed-loader kernel
  (`selfhost2-run.py`, log `selfhost2/run_20261009_164152.log`):

```
SELFHOST stage 2 vs host cross: 76 identical, 0 differ
SELFHOST stage 2 tcc identical to the host-cross link
SELFHOST new tcc builds a working hello
SELFHOST stage 3: the new tcc compiles itself
SELFHOST fixpoint: 77 identical, 0 differ
SELFHOST stage 3 vs host cross: 76 identical, 0 differ
SELFHOST RESULT PASS fixpoint
```

**Gate status:** the §5.2 "Self-host fixpoint — Required" row is satisfied
for L1 on the changed loader, and as "final integration" for L2/L4. The
§6.2 performance numbers remain those measured on the pre-rebuild
kernel/rootfs pair recorded in `manifest.json`; the refresh only changed the
compiler state of the userspace payloads, not the loader.
