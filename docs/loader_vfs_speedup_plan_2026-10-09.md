# Loader and VFS traffic reduction — plan

**Status (2026-10-09):** L1–L4 are implemented; see the detailed
[implementation and validation record](loader_speedup_plan_2026-10-09.md#6-completion-record).
The measurements below describe the earlier baseline. F1 instrumentation and
QEMU/board-model baselines are implemented; F3's cache-off QEMU configuration
is available. See the [2026-10-10 recheck](loader_vfs_recheck_2026-10-10.md)
for measurements, limitations and the remaining gates. F2/F4/F5 and the F3
board-policy decision remain planned.
It complements
[`kernel_tcc_performance_plan_2026-10-08.md`](kernel_tcc_performance_plan_2026-10-08.md)
(K-items: compiler-side codegen for the replay loop) and
[`vfs_lookup_cache_plan.md`](vfs_lookup_cache_plan.md) (lookup-walk history) —
the L/F items here do not duplicate those, and the overlap rules are called out
per item.

## Why

The two halves have opposite problems, and both are measured:

**The loader generates no card traffic for romfs binaries** — XIP views, shared
text, template replay. Its cost is CPU: copying bytes the replay then
overwrites, and re-deriving table extents every exec. Of a warm `/bin/true`
launch ([`kernel_performance_recheck_2026-10-09.md`](kernel_performance_recheck_2026-10-09.md)):

| Cost | Instructions | Share |
| --- | ---: | ---: |
| `load_from_template` (replay + copies) | 34,252 | 22.2% |
| `memcpy` | 14,177 | 9.2% |
| `memset` | 9,826 | 6.4% |
| Sentinel/span scanning | 9,115 | 5.9% |
| `Parser.create` | 6,672 | 4.3% |

**The filesystem side has no data cache at all.** `ext4_fread` reads file data
straight through to the caller's buffer (`libs/lwext4/src/ext4.c:1904-1936`);
FAT file data likewise; only metadata is cached (ext4 bcache, FatFs `win[]`).
Every re-read of a file re-hits the card. What a card hit costs is dominated by
per-*request* overhead, not wire time: ~1019 µs fixed per request against
21 µs per 512-byte sector (`source/kernel/drivers/mmc/mmc_io.zig:897-908`, and
the lone-sector-vs-multi-block measurement at `source/fs/fatfs/fatfs.zig:476-491`:
~1.6 ms standalone vs ~0.13 ms amortized). Small or fragmented reads are the
enemy; the levers are bigger requests and reuse of already-fetched bytes.

And one configuration fact: **every real-board defconfig disables the FAT line
cache** (`CONFIG_CONFIG_FATFS_CACHE_LINES=0` in
`configs/pimoroni_pico_plus2_and_vga_defconfig:111`, `configs/mspc_defconfig:123`,
`configs/raspberry_pico_2_minimal_defconfig:111`), which also disables the
4 KiB write-combining buffer (`fatfs.zig:583-601` allocates both together).
`docs/storage.md` records the reason: FAT serves only `/boot`, and the cache
would retain about 20 KiB. The geometry
tuning in `vfs_lookup_cache_plan.md` (4×8 → 8×4, same 16 KiB, `open` −66%)
was measured *with* the cache on. The QEMU an524 defconfig leaves the default
(8 lines) on, so the smoke suite has never exercised the boards' no-cache FAT
behavior — a test blind spot independent of what we decide to ship.

On top of both: SDIO DMA cannot target PSRAM/flash windows safely, so user
reads bounce through a static 4 KiB SRAM buffer plus a memcpy (~9.3 µs/sector,
`hal/source/raspberry/rp2350/source/mmc/mmc_sdio.zig:388-432`). Any caching
layer placed in PSRAM changes the copy count; see F2's trade-off.

## What exists today — don't rebuild these

- Loader: XIP shared text/data views per image (`dynamic_loader/source/module.zig:117-139`),
  template RAM LRU (32, pinned-safe, reclaimable) + flash precache
  `/lib/yasld.cache` (`dynamic_loader/source/template.zig:347-389, 568-614`),
  content-hash memo, library resolver cache (`source/kernel/modules.zig:41`),
  SysV-style symbol hash tables (`dynamic_loader/source/parser.zig:95-122`).
- Filesystems: ext4 bcache (metadata; 128 blocks/volume with PSRAM,
  `source/main.zig:575-621`), FAT line cache + write combining (boards: off),
  romfs lookup cache (16 slots × 54-byte paths,
  `source/fs/romfs/lookup_cache.zig:38-103`), romfs XIP zero-copy *for the
  loader only* (`romfs_file.zig:106-126`).
- Rejected with measurements, do not revisit: a VFS-level path→node cache
  (`vfs_lookup_cache_plan.md` — ~1.3 ms/compile at a real staleness hazard;
  the cost is first-resolution in big directories, not repetition).
- Rejected by this analysis: dropping LFN from the kernel FatFs build. The
  FAT-drive workflow (`scripts/qemu_mount.py`, `qemu_fatdisk_run.py`) mounts
  host directories at `/mnt` and **relies on long names** (AGENTS.md). LFN is
  a compile-time FatFs option; it cannot be disabled per-volume.

## Work items

The L-items are expanded to implementation level (conditions, required tests,
acceptance) in
[`loader_speedup_plan_2026-10-09.md`](loader_speedup_plan_2026-10-09.md) —
including the finding that L3 needs no YAFF format change, since the header
already carries the table offsets the loader re-derives by walking.

Savings must not be summed across items: L1 shrinks the very loop K1 optimizes;
F2 changes what F3's counters will report; code size moves XIP behavior.
Re-rank after each landed change.

### L1. Template replay: stop copying what the replay overwrites

**Why first among loader items:** it attacks the top three rows of the launch
table at once (replay stores, `memcpy`, `memset`) without touching the
compiler, and it composes with — but must be measured separately from — K1.

Relevant sources: `dynamic_loader/source/template.zig` (`View.apply` :192,
capture `unwrapped` set :63, `finish_capture` :305, flash precache writer),
`dynamic_loader/source/module.zig` (`LoadedUniqueData.create` :153 —
data/GOT memcpy from image at :210/:220; `ThunkHolderData.create` :102 —
whole-block memset; per-slot `generate_thunk` :234-249).

Today a template hit copies data + GOT from the image and zeroes the whole
thunk block, then the replay overwrites every covered word — each relocated
word is written twice, and a typical GOT is almost fully covered. The capture
already knows which words stayed as-image (`unwrapped`) but drops the set at
`finish_capture`.

Implementation sequence:

1. Carry per-template copy extents out of the capture: which byte ranges of
   `[data][got]` are *not* replay-covered (a `unwrapped`-derived bitmap or
   extent list — pick whichever the replay loop can consume without a branch
   per word), plus the thunk-region extent that actually holds slots (so the
   memset covers descriptors only where unresolved-weak slots need zeros —
   see the K4 warning about zero-descriptor contracts before shrinking any
   clear).
2. `LoadedUniqueData.create` grows a "copy only these extents" mode used on
   template hits; the cold path (`relocate`) keeps today's full copy.
3. Skip clearing only the complete leading generated thunk prefix. Clear
   interior holes and replay later slots normally. Bulk thunk-code generation
   remains a separate follow-up.
4. Template format: this is a format change. Bump the template/precache
   version and have `template.zig`'s loader-side validation reject old
   `/lib/yasld.cache` blobs (they regenerate at rootfs build via
   `tools/yasld_prelink.zig`, so both sides update together in-tree; the
   version guard is for stale rootfs images).
5. Measure. Then re-check whether K1's loop work is still worth its order —
   the unchanged replay-entry list now accounts for a larger share of loading.

**Acceptance:** `verify_templates` double-load comparison (`loader.zig:64`,
debug mode) stays word-exact; warm launch instructions drop with `memcpy`/
`memset` counts falling at least as fast; template bytes and cold capture cost
reported (the RAM LRU budget is content-sized — extents must not price a hit
above the copies they save); full tcc suite on QEMU (every compile loads native
`tcc` through a template — this is the natural stress test); self-host
fixpoint; weak-slot and copy-relocation cases unchanged (copy relocations read
dependencies' *live* data and must not become cached bytes — K6's constraint).

### L2. Exec resolves the path once

Today every `execve` walks the path twice and reads 128 bytes it usually
cannot use: `shebang_exec` does a full VFS `get` + 128-byte read
(`source/kernel/interrupts/syscall_handlers.zig:1073-1080`), then
`load_executable` re-`get`s the same path (`source/kernel/modules.zig:389`);
a `#!` script's interpreter is then resolved a third time. On romfs a warm
`get` is one header read (LookupCache); **on FAT each is a full linear
directory walk** — the multi-millisecond rows in `vfs_lookup_cache_plan.md`.

Implementation sequence:

1. Thread the already-open node/file from `shebang_exec` into
   `prepare_exec`/`load_executable` (an exec-from-open-file path), so the
   sniff and the load share one resolution. `load_executable` keeps its
   by-path entry as the dlopen/other callers' route.
2. For the sniff itself: when `GetMemoryMappingStatus` reports a mapped
   image, read the first 128 bytes through the mapping — no I/O at all. The
   `#!` check then costs a memcmp for every YAFF binary.
3. While there: `load_executable`'s whole-file `read` ignores its return
   (`modules.zig:411`) — short reads are silent corruption today. Check it.

**Acceptance:** execve syscall count of `get`/lookup drops to one per exec
(assert via strict VFS mocks; `openprof` counts only sys_open); script exec (`#! /bin/sh`,
with and without argument) unchanged; FAT-hosted binary exec time falls by
the cost of one directory walk; no behavior change when the file is replaced
between the two old resolutions (this was never guaranteed anyway — the node
is pinned, which is the correct exec semantics).

### L3. Parse tables once per image, not once per exec

This is the loader-side half of tcc-plan K2 — do not duplicate its compiler
half here. The per-exec costs: `Parser.create` strlen-strided scan for the
exported table (`dynamic_loader/source/parser.zig:127-136`, ~6.7 k insns),
`ItemTable.size()` double traversal (`item_table.zig:53-61`), dependency
`process_header` run twice per child (`loader.zig:614` then `:219`).

Implemented: single-stride iteration, direct use of the offsets already
recorded in YAFF, bounded structural validation once per immutable image, and
forwarding the checked dependency header. No YAFF format change was needed.
The validation memo is bounded at 32 images. Parser objects are still rebuilt;
per-image parser caching is a separate follow-up.

**Acceptance:** table extents/names and lookup arrays agree on valid images;
malformed layouts fail before parsing; duplicate extent walks and dependency
header checks are removed. See the detailed plan for the measured gates.

### L4. Resolver: probe `/lib/<name>` directly, keep negative entries

A `file_resolver` miss iterates every entry of `/lib` with a `get` each
(`source/kernel/modules.zig:129-147`) — the comment at :35-40 prices a full
scan at ~1-1.7 ms per library. A direct `get("/lib/<name>")` hits the romfs
LookupCache in one header read when the name matches, and a negative cache
entry stops repeated probes of absent libraries. Keep the directory scan as
the fallback so unusual layouts still resolve.

Implemented: exact filename matching, one direct probe for present libraries,
scan fallback, and negative caching limited to 32 entries / 4096 key bytes.
Only an authoritative direct `NoEntry` can populate a negative; transient
errors and ambiguous iterator exhaustion remain retryable. Mount generations
invalidate cached results. Mutable/unknown `/lib` backings are refused because
the resolver cannot retain their mappings for a process lifetime.

**Acceptance:** strict mocks establish direct-hit and repeated-negative
acquisition counts, retry behavior, limits and invalidation. Runtime load and
compiler checks are recorded in the detailed implementation record.

### F1. Attribution first: cache hit/miss counters and a traffic baseline

Every past win in these docs started with an attribution hook. Today the
in-kernel `disk_read/disk_write` counters
(`source/kernel/interrupts/perf_profile.zig:384-437`) see *through* the
caches, not into them; lwext4's own stats are compiled out
(`CONFIG_BLOCK_DEV_ENABLE_STATS=0`, `source/fs/ext4/build.zig:40`); the FAT
line cache and romfs lookup cache have no counters at all.

Implementation sequence:

1. Counters: FAT line-cache hits/misses (in `DiskWrapper.Shared`,
   `fatfs.zig:497-543`), romfs lookup-cache hits/misses/`max_path` overflow
   (`lookup_cache.zig`), lwext4 bcache stats on. Report through the existing
   `tprof` dump lines next to `diskprof` (the pattern is
   `syscall_handlers.zig:494-510`).
2. Baselines with the counters: the tcc-compile and spawn workloads under
   `scripts/kernel_compare.py --store`, plus `tests/smoke/io_profile_test.py`
   and `syscall_profile_test.py` on QEMU and (once) on the board via
   `scripts/board_model.py` for board-shaped XIP/PSRAM costs.
3. Record: sectors read per compile, per spawn, cache hit rates, and the
   split metadata-vs-data. This is the yardstick every F-item below must
   move, and it decides F2's geometry and F3's verdict.

**Acceptance:** counters cheap enough to leave on in debug builds (aggregate
atomics, no per-call printing); baseline numbers recorded in this document's
successor recheck before any F2/F3 work lands.

### F2. ext4 data readahead and data-block reuse

**Why the biggest filesystem lever:** it is the only item that attacks both
card-traffic terms at once — fewer requests (bigger runs) and zero requests
(reuse) — and it serves the dominant real workloads: tcc re-reading headers,
the loader's whole-file reads of non-XIP executables (`modules.zig:405-412`,
today uncached on every exec), repeated reads of anything.

Relevant sources: `libs/lwext4/src/ext4.c:1883-1945` (`ext4_fread` run
coalescing, per-block extent walk), `libs/lwext4/src/ext4_blockdev.c:311-323`
(direct multi-sector reads), `source/fs/ext4/ext4fs.zig:120-230` (bcache
glue, PSRAM-placed buffers), `source/fs/ext4/build.zig:40-51`, and the DMA
bounce constraint in `hal/source/raspberry/rp2350/source/mmc/mmc_sdio.zig:388-432`.

Two designs, to be chosen by F1's numbers, not taste:

- **(a) Route full-block data reads through the bcache.** Reuse exists
  (metadata already lives there; LRU, per-volume RB-tree, cross-volume trim,
  user allocator). Cost: a miss becomes card → SRAM bounce → memcpy → bcache
  (PSRAM) → memcpy → user — one *more* PSRAM copy than today's direct path,
  bought back on every hit and by readahead filling bcache lines. A hit is
  one PSRAM→PSRAM copy (~9.3 µs/sector measured) with zero card time.
- **(b) Per-file sequential readahead only** (one extra run fetched into a
  small SRAM or PSRAM buffer when a read consumes the tail of the previous).
  Cheaper, no reuse across reads, no invalidation problem beyond truncate.

Readahead policy: fetch the next physical run when the current read ends
within it — `ext4_fread` already computes runs, so the hook is local.
Invalidation is the hazard of (a): the write path
(`source/fs/ext4/ext4_file.zig:39-44` write-back, `ext4_blocks_set_direct`)
must overwrite-or-drop cached data blocks for any LBA it writes. Check the
fork's bcache write path before trusting it; add a write-then-read same-block
test.

**Acceptance:** sectors-per-compile and per-spawn fall (F1 counters) with no
rise in guest instructions for cold single-pass reads; `dd`-style sequential
read throughput improves; write-then-read consistency test; tcc suite green
(a stale data block shows up exactly like the stale-node bug class the tcc
suite already catches); board-model ranking confirms the win survives XIP/
PSRAM costs before shipping the board config.

### F3. Decide the FAT line cache on boards — with numbers

The cache and the write-combining buffer are both off on every board, without
a recorded reason, while the repo's own measurements price the difference at
~1.6 ms vs ~0.13 ms per lone metadata sector. The decision input F1 owes:
hit rate the cache would have achieved on board-shaped workloads, and its
RAM price (default 8 × 4 × 512 = 16 KiB from the kernel heap shared across FAT mounts,
plus the 4 KiB combine buffer). Geometry knowledge already exists:
count-of-lines beats run length (`source/fs/KConfig:66-71`,
`vfs_lookup_cache_plan.md`).

Two sub-decisions: (i) enable on `pimoroni_pico_plus2_and_vga` and `mspc`
(the Pico 2 minimal board has no SD card — leave it at 0); (ii) make the
QEMU/board *config* gap visible: either pin QEMU's defconfig explicitly to
what boards ship, or add one smoke config with the cache off so the blind
spot is covered in one direction.

**Acceptance:** board workload numbers with the counter delta; kernel RAM
accounting recorded (before/after `/proc/meminfo`); `mkfs_fat_test.py`,
`vi_test.py`, FAT create/rename/unlink smoke green with combining re-enabled.

### F4. `fstat`/`stat` from the open node

`sys_fstat` dupes the fd's path and runs a full VFS stat walk
(`syscall_handlers.zig:293-303`) — the node the fd already holds knows its
size. This is the shape behind `ls -l` over a directory (the 2.2 s ext4 vs
9.9 s FAT row in `docs/storage.md:36`) and behind every tool that fstats
what it just opened (tcc, `vi`, toybox). Answer from the node's own
`size()`/attributes, live — not a value cached at open, so an external
truncate is still observed. Path-based `sys_stat` keeps its walk (it must).

**Acceptance:** fstat-after-write/truncate through another fd observes the
new size; `ls -l` cost over a populated directory falls; no change to stat
semantics on symlinks (fstat has none — it is fd-based).

### F5. romfs polish: RAM walk code and lookup-cache sizing

Two known, cheap items: the romfs walk is XIP-fetch-bound
(`docs/fs_open_write_profile.md:94-100` names `.time_critical` as the obvious
next lever — the same move took syscall dispatch down 5.5×,
`docs/syscall_path_profile.md:93-126`); and the 16-slot lookup cache with
`max_path=54` silently excludes longer paths while a single tcc compile's
romfs working set (7 runtime files + headers) overflows 16 slots
(`lookup_cache.zig:41-42`). F1's overflow counter decides the size; budget
~1 KiB for 32 slots and a length histogram before choosing `max_path`.

**Acceptance:** warm romfs open cost drops (RAM walk); overflow counter
reads zero on the compile workload after resizing; kernel RAM delta recorded
(`.time_critical` sections are SRAM-priced — measure, don't assume).

## Execution order and decision gates

1. **F1 first, alone.** No optimization lands before the counters and the
   baseline numbers exist. (L-items need no new counters — the icount rig
   already attributes them — so L1 may proceed in parallel if desired.)
2. **F2** behind F1's numbers: design (a) vs (b) chosen by the measured
   reuse rate (if re-reads are rare in the real workloads, readahead-only
   (b) is the honest choice; if tcc's header re-reads dominate, (a) wins).
3. **L1** next among loader items (largest measured); then **L2** and **F4**
   (small, mechanical, independent — good interleaves while F2 soaks).
4. **F3** decided on F1 + F2's evidence: if F2 already removed the traffic,
   the FAT cache may stay off on RAM-constrained boards — that is a fine
   outcome, the blind-spot config fix is then the only deliverable.
5. **L3/L4/F5** as fill-ins, re-ranked after each substantial change.
6. After each accepted change: `kernel_compare.py` A/B (rc + output hashes +
   icount), the smoke suites named per item, and for anything loader-side a
   self-host fixpoint before calling it done. Board-model ranking before
   shipping any board-config change; physical-board rerun as the final gate.

For every patch: record old/new source and binary hashes, repeat A/B in
opposite order, compare warm and cold cases, save raw samples — the
discipline of `kernel_tcc_performance_plan_2026-10-08.md` §5 applies verbatim.

## Validation index

- Instruction A/B: `scripts/kernel_compare.py` (`docs/kernel_bench_insn_2026-10-08.md`).
- Attribution: `openprof`/`diskprof` tprof lines (`perf_profile.zig`), plus
  the new F1 counters; `tests/smoke/io_profile_test.py`,
  `tests/smoke/syscall_profile_test.py`, `tests/smoke/timing.py`
  (`compile_loader_ms`/`execute_loader_ms`).
- Loader correctness: full tcc suite on QEMU (`scripts/run_qemu_smoke.sh
  tcc_suite_test.py`), `verify_templates` word-exact check, self-host
  (`scripts/tcc_selfhost.py --qemu`), weak-slot/copy-relocation cases.
- Filesystem correctness: `mkfs_fat_test.py`, `vi_test.py`, FAT
  create/rename/unlink smoke, write-then-read same-block (F2a), fstat
  freshness (F4).
- Board realism: `scripts/board_model.py` profile + `compare`, then the
  physical board via `scripts/transfer.py`.
