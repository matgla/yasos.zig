# Path lookup cost — plan

**Status (2026-08-04):** three fixes built and measured; the path→node cache
this document originally proposed is **rejected**, and the reason the others
work is not the one this document started with — see
[What the cost actually is](#what-the-cost-actually-is-cache-lines-not-directory-entries).

| Step | State |
|---|---|
| Resolve a FAT path once per `get()` instead of twice | done, −49% on big directories |
| Shard the corpus into ~51-entry bucket directories | done (harness) |
| Rebalance the FAT cache: 4x8 -> 8x4 lines, same 16 KiB | done, `open` −66% with sharding |
| Stop probing `{B}` before `/usr/lib` for every `-l` | done, 12 opens/compile -> 9, 3 misses -> 0 |
| `IFileSystem.supports_symlinks()`, so a miss skips the symlink walk | done, FAT miss −58% |
| Directory-entry cache inside the FAT layer | proposed, measure first |
| ~~VFS path→node cache~~ | rejected, would save ~1.3 ms/compile at real risk |

## Why

`open()` costs **1.9 ms on average across a suite run** — 11 615 calls, 22.2 s,
6.6% of compile time over tests2+ir_tests. That is more than `mmap` now costs
and second only to serial output. Instrumenting the syscall (`openprof`, see
`perf_profile.OpenPhase`) splits it three ways:

| Phase | What it is | Share |
|---|---|---|
| resolve | `determine_path_for_file`: cwd join + normalisation | ~3% |
| **lookup** | **the VFS walk that turns a path into a node** | **~91%** |
| attach | descriptor allocation | ~6% |

So the cost is one thing: finding the file. And it scales with how many files
share the directory:

| Location | Entries | open | of which lookup |
|---|---|---|---|
| romfs (XIP), small dir | few | 181 us | 149 us |
| FAT `/root/ci` | 2 | 290 us | 253 us |
| FAT `sources/tests2` | ~200 | 2 271 us | 2 231 us |
| FAT `sources/ir_tests` | ~513 | 17 281 us | 17 242 us |
| FAT `gcc_torture/execute` | ~1 685 | 13 006 us | 12 967 us |

The last two are not monotonic because the FAT sector cache
(`CONFIG_FATFS_CACHE_LINES=4` x `CONFIG_FATFS_CACHE_LINE_SECTORS=8` = 16 KiB)
cannot hold a directory whose entries run to ~100 KiB, so which one wins
depends on what was touched last. Both are 45-95x the small-directory cost.

The same tcc compile pays **4.04 ms for 12 opens** when its files sit in a small
directory and ~23 ms in the suite's corpus layout. Across 4449 tests that
difference is roughly **85 s, ~8% of a 1055 s run**, spent walking directory
entries.

## What was built: one walk per `get()`, not two

`FatFs.get()` used to probe with `Dir.open` — which resolves the whole path and
then fails, for a file — and then open the file, resolving the path a second
time. Every FatFs entry point walks the directory linearly, so a file open in a
populated directory paid that walk **twice**.

It now opens the file first, keeping the handle it gets, and only falls back to
`stat` (then `Dir.open`, which is the only thing that can confirm a volume root)
when that fails. Files cost one walk; directories cost what they always did.

Measured on the device, same probe as above:

| Location | Entries | before | after |
|---|---|---|---|
| romfs, small dir | few | 181 us | 183 us |
| FAT `/root/ci` | 2 | 290 us | 217 us |
| FAT `sources/tests2` | ~200 | 2 271 us | 2 044 us |
| FAT `sources/ir_tests` | ~513 | 17 281 us | **8 771 us** |
| FAT `gcc_torture/execute` | ~1 685 | 13 006 us | **6 604 us** |

Over 69 gcc_execute compiles: `open` fell from **1699 us to 1109 us** average
(1.43 s -> 0.93 s, 5.5% -> 3.7% of compile) and on-target time from 27.57 s to
27.05 s. 229 device tests pass, including the FAT create/format and vi write
paths.

## What changed the plan

The original estimate here — 60-90 s off a suite run from a path→node cache —
assumed the expensive opens repeat. They do not. Per compile the ~12 opens
split into two groups that a cache treats very differently:

- **7 runtime files** (`crt1.o`, `crti.o`, `crtn.o`, `libc.so`, `libm.so`,
  `librp2350fp.so`, `libtcc1.a`) — opened by *every* compile, so perfectly
  cacheable, but they live in the XIP romfs and cost ~180 us each. Caching all
  of them saves **~1.3 ms per compile**.
- **the source file** — the expensive one (6.6 ms even after the fix) and
  **unique to each test**, so a cache never sees it twice.

A path→node cache therefore buys ~1.3 ms/compile, and it buys it at a price:
`FatFsFile.create` opens the FatFs handle eagerly and `size()` reads from that
handle, so a cached node carries the file's size *as of caching*. Any writer
that changes the file leaves the cache serving a stale node, which in this
suite means a compile reading the previous test's output binary. Holding a live
`FIL` per cached entry is its own hazard.

**Not worth it.** The measurement says the cost is in *resolving a path in a
big directory*, not in repeating a resolution — so the fix has to make the walk
cheaper, not skip it.

## What the cost actually is: cache lines, not directory entries

Sharding the corpus into 32 bucket directories (~51 entries instead of ~1685)
changed the open cost by 8%. That did not fit "the walk is linear in entries",
so the next probe put the same file at several depths and opened each one
twice. With the cache at its old 4 lines x 8 sectors:

| Path | 1st open | 2nd open |
|---|---|---|
| FAT depth 1 | 1299 us | **188 us** |
| FAT depth 2 | 1176 us | **214 us** |
| FAT depth 4, small dirs | 1953 us | 3405 us |
| FAT depth 7, 51-entry dir | 5750 us | 5745 us |
| FAT depth 5, 1685-entry dir | 6818 us | 6693 us |

A shallow path goes warm and costs 0.2 ms; a deep one never goes warm at all,
and 51 entries against 1685 barely differ. **Resolving a path touches one
directory per component, each wants a cache line, and there were four.** A
seven-component path evicted its own levels on every open.

Trading run length for line count — 4 x 8 -> **8 x 4**, the same 16 KiB — is
the whole fix:

| Path | 4 x 8 | 8 x 4 |
|---|---|---|
| FAT depth 1 | 1299 / 188 us | **200 / 183 us** |
| FAT depth 4, small dirs | 1953 / 3405 us | **238 / 241 us** |
| FAT depth 7, 51-entry dir | 5750 / 5745 us | 3660 / **328 us** |
| FAT depth 5, 1685-entry dir | 6818 / 6693 us | 5022 / 6796 us |

Note the last row: the 1685-entry directory still cannot go warm, because its
entries alone exceed the cache. **Sharding and line count only pay together** —
sharding makes the leaf directory small enough to cache, and the extra lines
let the six shared parent levels stay cached across tests while it does.

Over 69 gcc_execute compiles, the two together took `open` from **1699 us to
578 us** average (1.43 s -> 0.49 s, 5.5% -> 2.0% of compile).

## Fewer opens: the library search probed the wrong directory first

Nine of the ~12 opens a compile makes are the runtime link, and three of those
were guaranteed misses. tcc searched `{B}` (= `/usr/lib/tcc`) before `/usr/lib`,
but on YasOS every `.so` lives in `/usr/lib` and `{B}` holds only `libtcc1.a`,
which is reached by its own path rather than by a `-l` search. So every compile
probed `{B}/libc.so`, `{B}/libm.so` and `{B}/librp2350fp.so`, missed all three,
and found each one on the next path.

A miss is not free: the VFS answers a failed lookup by walking the path
component by component looking for a symlink (`resolve_symlinks`, one `stat`
per component), which is why the failed probes cost ~1 ms each against ~0 ms
for the hit that followed.

`./configure --libpaths` cannot fix this: it writes the value into `config.h`
inside `#if !(TCC_TARGET_...)`, and this compiler is built with
`TCC_TARGET_ARM` defined, so the configured `/usr/lib:{B}:/lib` is discarded
and tcc.h's generic default ships instead. The order is now correct in tcc.h
for `TARGETOS_YasOS`, where it cannot be silently dropped.

Measured on a hello-world compile: **12 opens (3 finding nothing) and 4.04 ms
-> 9 opens (0 finding nothing) and 2.31 ms**. Over the 69-test slice, `open`
fell to **476 us** average, 1.2% of compile.

## What to do next, in order

**1. Shorten the corpus path.** `/root/ci/sources/v2/gcc_torture/execute/09/x.c`
is seven components, and each one is a directory to resolve and a cache line to
hold. The measurement above prices a component at roughly 0.2-0.5 ms warm.
Flattening the category prefix (`/root/ci/s/ge/09/x.c`) would drop two or three
of them for free.

**2. Retire the old flat tree.** `/root/ci/sources/{tests2,ir_tests,gcc_torture}`
still holds the pre-sharding copy. Nothing reads it, but deleting it reclaims
~4 MiB and removes the only directories on the device that are too big to
cache.

**3. ~~Make a failed lookup cheap.~~ Done.** `IFileSystem.supports_symlinks()`
answers for the *format*, not the contents: romfs and ramfs say yes (romfs
carries the toybox `--symlink` install), FAT and littlefs say no, and
`ReadOnlyFileSystem` defaults to no. `VirtualFileSystem.get` now asks the mount
that owns each path component before statting it, so a filesystem that cannot
represent a link is never walked looking for one.

Priced by flipping FAT's answer and re-running the same probe:

| Failed lookup | says "yes" (as before) | says "no" |
|---|---|---|
| FAT, depth 2, warm | 455 us | **264 us** |
| FAT, depth 7, warm | 1616 us | **672 us** |
| FAT, depth 7, cold | 5623 us | **4796 us** |

A warm miss seven components deep costs **58% less**. It does not show up in
the compile suite, because after the library-path fix a compile has no failed
lookups left to skip — this is for everything else that misses: shell PATH
searches, `rm -f` of a path that is not there, include probes into directories
that do not have the header.

**4. Only then consider a directory-entry cache** keyed on (directory, name).
With the geometry fixed, the remaining cost is the first touch of each bucket;
an entry cache would remove that too, but measure before building — 8 x 4 may
already have taken most of it.

## Validation

- `io_profile_test.py::test_profile_open_cost_by_directory` — the table above.
- A `--profile` run: watch `open` in the "Syscall time by call" table and the
  `openprof` trace's `resolve/lookup/attach` split.
- Correctness gate for anything touching lookups: the full tcc suite (it
  creates and removes an output binary per test, so a stale or wrong node shows
  up immediately), plus `mkfs_fat_test.py` and `vi_test.py` for the
  create/rename/unlink and write paths.
