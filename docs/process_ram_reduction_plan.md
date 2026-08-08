# YASOS Per-Process RAM Reduction Plan

Goal: cut per-process RAM. Profiling reframed the target: toybox's malloc **heap
is small (~36 KiB)**; the per-process footprint is dominated by the **loader**,
and within both, by **page-rounding** (the kernel process pool is page-granular,
4 KiB min, so every sub-page allocation burns a whole page).

## Measured baseline (QEMU, perf split: `proc pid=N heap=H loader=L` pages)

| process | heap (was→8KB pool) | loader | notes |
|---|---|---|---|
| applet (ls) | 9 → 3 pages | 20 | clone_exec_args fix already landed (27990cf) |
| tcc | 16 → 6 pages | 38 | big allocs (>=4096) bypass pool, unaffected |
| shell | 9 → 3 pages | 23 | |

32 KiB pool (`MSETLEN`) was inherited 2010 baggage, never tuned. 8 KiB already
reclaimed applet −24 KiB / tcc −40 KiB heap with 0 regressions (4 tests pass).

---

## Status: Phase A DONE (7372dc6), B DONE (e30b730), C Stage 0 DONE (74a1513).
## Combined (QEMU): applet 136→~66 KiB (−51%), tcc 216→144 KiB (−33%),
## shell 128→~76 KiB (−41%). Phase C Stage 0 below; 0b/1 + dead-code cleanup pending.

## Phase A — libc pool + buffers  ✅ DONE

**A1. Pool `MSETLEN` 8 KiB → 4 KiB** (`libs/libc/malloc.c:32`).

**A2. `MSETMAX` 4096 → 2048** (`malloc.c:24`). *Required*, not optional: after
`mk_pool()` malloc does NOT recheck fit (malloc.c:286), so a pooled alloc bigger
than `MSETLEN − overhead(~48B)` overflows the mmap → heap corruption. A 4 KiB
pool therefore mandates `MSETMAX ≤ ~4048`; 2048 leaves margin. Side effect:
allocs in [2048,4096) move to direct 1-page mmap — **measure** (few expected).

**A3. Shrink buffers ("we don't need them large"):**
- `BUFSIZ` 1024 → 512 (`stdio.h:43`): static `_ibuf/_obuf/_ebuf` = 3×, saves
  ~1.5 KiB/proc libc BSS; also every `fopen` buffer. Watch tcc I/O syscall count.
- DIR readdir `buf[2048]` → 1024 (`dirent.c:14`): per-opendir buffer; helps ls.

**A4. Build (`--rebuild-rootfs`) + measure gate:**
- applet heap pages (expect ~2), tcc heap pages, **tcc compile time** (the real
  risk: 4 KiB → more pools → more mmap churn + `old_pools` pinning).
- If tcc regresses (time or pages): fall back to **tiered pool** (4 KiB first
  pool that covers light applets, grow to 16/32 KiB for heavy users — needs a
  per-pool `len` field + audit all ~8 `MSETLEN` munmap sites) OR revert to 8 KiB.

## Phase B — loader arena merge (kills page-rounding waste, ~16-20 KiB/proc)

**B1. Correctness first:** `retain_thunks` is dead (0 callers, confirmed) and
`LoadedUniqueData.destroy` (module.zig:286) frees `lazy_thunks` but NOT regular
`thunks` — relies on bulk pool teardown. Resolve before B2 (either wire frees or
delete the refcount machinery; vfork re-runs load_module per child so nothing
aliases thunks).

**B2. One process-pool arena per module:** today `ThunkHolderData` struct(16B) +
data, `LazyThunkHolderData` struct(28B) + thunk_data + info_data are ~5 separate
page-rounded allocs (module.zig:67-107, 203, 244). Bump-suballocate them from a
single arena (RWX, process pool, so thunk code stays user-executable). `destroy`
frees only the arena. Target: ~8.6 of 20 loader pages are this waste.

## Phase C Stage 0 ✅ DONE (74a1513)

Imported calls already relocate to `bl PLT[n]` at LINK time and that PLT
stub lives in XIP flash (shared), loading both GOT words + switching R9 on
every call — the per-process lazy thunk was only the initial GOT target.
Now PLT imports resolve eagerly (find_symbol → fill GOT {fn, target_r9});
the shared flash stub dispatches. Loader −3 pg/proc. Trade-off: all imports
resolve at load, not first call (load time unchanged, O(1) hash).

### Remaining (optional)
- **Dead-code cleanup:** the lazy machinery (LazyThunkHolderData /
  generate_lazy_thunk / lazy_resolve / sys_dl_resolve / lazy_resolver_thunk.S)
  is now unused — remove it to save flash.
- **Stage 0b:** fn-ptr indirect_call thunks (28 B, embed R9+fn) → a flash
  stub flavor that SAVES/RESTORES R9 (the bare .plt stub does not — BX
  tail-call only). ~1.4 KiB/proc, MED risk.
- **Stage 1:** true lazy binding via the PLT's currently-unimplemented
  GOT==0 fallback (shared resolver stub). HIGH risk, tcc-backend work.

## Phase C original notes — thunks lazy / flash  (DESIGN DECISION)

Lazy code-gen exists; lazy **space** does not — loader eagerly reserves a thunk
for every import (toybox: 208 PLT symbols, calls a handful). Two convergent
options (defer until A+B measured):
- **Flash-resident shared PLT stub**: the already-flash `.plt` stub implements
  the exact R9-relative GOT dispatch the per-process thunk bodies duplicate.
  Eliminate per-process thunk bodies; keep only the per-process GOT (toybox
  2.2 KiB, irreducible). Cross-cuts tcc backend (PLT emit) + YAFF writer +
  loader; needs device validation.
- Lazy thunk-space allocation (grow on first call). Same payoff, more bespoke;
  synthesis prefers the flash-PLT framing.

## Do NOT
- Reuse `old_pools` freelists in malloc (pins pools, breaks reclaim invariant).
