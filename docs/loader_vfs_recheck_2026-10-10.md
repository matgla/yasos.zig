# Loader/VFS F1 traffic baseline — 2026-10-10

F1's instrumentation and simulator baselines are implemented. No data-cache,
romfs geometry, fstat semantics or board-policy optimization is included in
this change. F3's QEMU cache-off configuration is also provided. The earlier
L1–L4 work remains intact.

## Counters and their scope

With `CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y`, `cacheprof` records
report FAT line hits/misses and bypass requests/sectors; romfs lookup
hits/misses, overlength misses and six path-length buckets; and ext4 bcache
hits/misses, physical read requests/sectors and cache-fill sectors.
There are 18 SRAM-resident u32 atomics (72 bytes). A production build has
zero counter slots, no counter updates and no lwext4 profiling callbacks.
The C compiler and translated headers receive the same stats configuration.

`phase=run` uses the existing system-wide exec/reset window. A resetting
`sys_perf_dump` reports before clearing, so `tcc -bench` does not discard its
compile traffic. Reports drain the cache counters to avoid counting a child's
traffic again when its waiting shell exits. `phase=load` separately reports
the delta inside `load_executable_node`, including image reads and dependency
loads, before exec clears the counters. That delta excludes the initial VFS
lookup and shebang sniff. Failed loads also report their loader-body delta.

These are aggregate counters, not per-process accounting under concurrent
workloads. Individual accesses are atomic; snapshots/resets across multiple
counters are not transactional. u32 counts wrap. Use short, serial workloads
with a waiting parent, as in the existing profiling workflow.

`ext4_cached_sectors` measures successful physical cache fills. Subtracting
it from `ext4_read_sectors` gives direct traffic, including byte reads,
write read/modify/write traffic and device probes. This is a useful
cache-vs-direct split, **not a universal metadata-vs-file-data classifier**.
FAT bypasses likewise include large data reads and all reads when caching is
disabled. Hits/misses count line probes; bypasses are reported separately.
Overlength romfs lookups count as both a miss and an overflow, once per probe;
insertion does not count them again.

## Reproduction and raw artifacts

Enable perf profiling in the target configuration, then build a kernel and run:

```sh
zig build -Doptimize=ReleaseFast -Dkernel_cc=llvm --prefix .cache/vfs-profile
yasos_venv/bin/python scripts/vfs_cache_baseline.py \
  --kernel .cache/vfs-profile/bin/yasos_kernel --out .cache/vfs-traffic
```

The script boots FAT and partitioned FAT/ext4 disks separately, copies
headers to ext4 for the ext4 compile workload, and measures two reads,
compiles and executable launches. It also checks write/read freshness,
rename/unlink and romfs overlength accounting. Setup warms metadata;
“first” is the first measured operation, **not a cold-cache guarantee**.
It preserves serial transcripts, per-command counters, `/proc/meminfo`,
kernel/rootfs hashes and configuration. `--config` supplies the configuration
used for a previously built kernel. `--board-model` uses the existing RP2350
timing plugin with a kernel built using `board_model.board_shape`.

This run's artifacts are in `.cache/loader_vfs_f1/`:

| Artifact | Contents |
| --- | --- |
| `before_hashes.json`, `after_hashes.json` | Source, rootfs and binary hashes |
| `before.json`, `before/insns/` | Pre-change production LLVM baseline |
| `after/results-*.json`, `after/insns/` | Final production LLVM measurements |
| `profile.json`, `profile-run/insns/` | Standard profiling workload battery |
| `storage/`, `storage-tcc/` | FAT/ext4 records and raw UART transcripts |
| `storage-nofatcache/` | FAT read-through/write-without-combining records |
| `storage-board-model/` | Board-shaped kernel + timing plugin records |
| `*-unit.log`, `smoke-*.log` | Test results |

`kernel_compare.py` now saves cache profiles in its workload JSON, and
`--store PATH` writes to the supplied path. The smoke timing parser preserves
runtime and loader counters separately; `io_profile_test.py` prints hit rates
and bypass/sector counts.

## Traffic results

The plain QEMU LLVM and TinyCC kernels produced the same traffic counts.
The board-shaped TinyCC kernel with the RP2350 timing plugin reproduced them.
These block devices are RAM-backed: the plugin models CPU/XIP/PSRAM cost,
**not SD command latency or DMA bounce copies**. Physical-board validation
remains outstanding; no serial board was available in this session.

| Workload | First | Again |
| --- | --- | --- |
| ext4 file read | 29 requests / 207 sectors; 68 bcache hits | Same |
| ext4 compile, copied stdio headers | 42 requests / 61 sectors; 270 bcache hits | 42 requests / 61 sectors; 290 hits |
| ext4 executable loader body | 2 requests / 2 sectors; 2 bcache hits | Same |
| FAT 64 KiB read, cache on | 32 bypass requests / 128 sectors; 3 hits | Same |
| FAT 64 KiB read, cache off | 35 bypass requests / 131 sectors | Same |
| FAT compile, cache on | 16 hits / 2 misses | 18 hits / 1 miss |
| FAT compile, cache off | 18 bypass requests / 18 sectors | 19 requests / 19 sectors |
| FAT executable loader body, cache on | 2 hits | 2 hits |
| FAT executable loader body, cache off | 2 bypass requests / 2 sectors | Same |

All ext4 read/compile/spawn rows above have zero bcache misses and zero
cache-fill sectors: warmed metadata is reused, while direct file bytes are
fetched again. This is evidence for investigating F2(a), but does not yet
establish its cold-read instruction/copy cost or the right readahead geometry.
The test intentionally compiles against ext4 copies of the headers. Ordinary
`kernel_compare.py` compiles use romfs headers and RAM files and therefore
cannot alone decide an ext4 policy.

The stdio compile's romfs paths fit the existing limit: zero overflows. The
explicit long missing path produces two overflow probes (including VFS
fallback) and the corresponding length bucket/misses. Thus these workloads
provide no reason to increase `max_path`. Misses include unsuccessful include
searches; they are not by themselves proof of capacity eviction.

With FAT caching on, `/proc/meminfo` reports `MemKernelUsed=125400 B`; off,
`104792 B`, measured at the same point before setup. Delta: **20608 B**
(16 KiB read lines + 4 KiB combining + 128 B line descriptors), shared across
mounts. `docs/storage.md` already records why boards leave it off: FAT is
only `/boot`, and holding about 20 KiB for it was undesirable. No board
defconfig is changed.

## Validation and gates

- Host Debug tests: 7 LookupCache, 19 ext4 and 28 FatFs tests pass, plus
  their root discovery tests. ReleaseSafe host translation encountered the
  existing glibc fortified `open/openat` wrapper errors; Debug completed.
- Python profile/timing tests: 36 pass, including separate load/run windows,
  multiple reports around a reset, aggregation and old transcripts.
- Profiling QEMU instruments: all 5 tests in `io_profile_test.py` and
  `syscall_profile_test.py` pass.
- Cache-off QEMU: all 5 `vi_test.py` tests pass. Dedicated FAT workloads also
  pass write/read, rename/unlink and compile/launch checks with the cache both
  on and off. `mkfs_fat_test.py` currently contains only a commented-out test
  and collects no tests; it cannot serve as the plan's mkfs acceptance gate.
- Production A/B: all 15 workloads retain exit status and output hashes,
  with zero warnings at the existing 5% instruction threshold. Runs were
  taken before→after and after→before. Repeating the identical old binary
  also changes some instruction counts; small changes are not claimed as wins.
  The existing `zig-version` workload returns 255 in both production builds
  because the shipped development C backend does not support that command.

Production kernel SHA-256:

```text
before ca5b6ac6b126c549edbbb3d95331e48bfaa88bde0089b2457b64469b78e32f4f
after  11d32203978c2db24d58b3ab3fcc53e483b786f4345ac802b25f9285ec17993f
```

The cache-off smoke configuration is
`configs/qemu_mps3_an524_nofatcache_defconfig`. Configure/build it explicitly
and run `scripts/run_qemu_smoke.sh --no-build ...`; omitting `--no-build`
selects the runner's default cache-on configuration again.

Remaining work: F2 needs a data-cache/readahead implementation and its cold-read,
coherence and full compiler regressions; F3's board policy needs physical SD
measurements; F4 needs a live open-node stat API. In particular, current FAT
and ext4 `size()` methods read per-handle cached sizes, so simply replacing
`sys_fstat`'s path walk with `size()` would violate the cross-fd freshness
acceptance condition. F5 needs separate RAM-walk and capacity measurements.
No F2/F4/F5 optimization is marked complete by this instrumentation patch.
