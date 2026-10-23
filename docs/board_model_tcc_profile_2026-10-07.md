# TCC compile profile with PSRAM emulation — 2026-10-07

The forward-predecessor index in aggregate constant folding reduces
`gcc_execute/pr92904[-O2]` compile time from **12,933 to 12,547 modeled board
ms (3.0%)**. Its `const_agg_fold` pass drops from **1,077 to 625 ms (42.0%)**.
Generated objects remain byte-identical in the checked corpus.

## Configuration and baselines

QEMU 11.1.2 with `rp2350_timing`, 336 KB process SRAM, 8 MB PSRAM, and the
shared 16 KB XIP cache. The built-in fitted timing parameters were used;
no recalibration was performed. These are modeled Pico Plus 2 results,
not new measurements on physical hardware.

`psram-current` contains tinycc **19ffeb0a plus the working-tree changes
present at the start of this experiment**. `psram-agg-index` uses the same
sources plus the change to `source/opt/flat/scalar/const_aggregate.c`.
Both images use the cached `base` image's YasOS sources and board memory
map, with rootfs and kernel rebuilt for each compiler. Image metadata is
in `.cache/board_model/images/<image>/board_model_image.json`.

The older `base` image uses **f6728d73 plus its recorded board patch**.
Comparing it with `psram-current` measures existing compiler improvements,
not changes made in this experiment.

## Selected compile results

Nine common tests, all at `-O2`:

| Test | Older base, ms | Current baseline, ms | Indexed variant, ms |
| --- | ---: | ---: | ---: |
| gcc_compile/pr34093 | 14,547 | 3,135 | 3,109 |
| ir_tests/448_shift64_lowering.c | 13,701 | 5,629 | 5,623 |
| gcc_compile/pr82052 | 10,070 | 5,566 | 5,571 |
| gcc_execute/strlen-5 | 12,759 | 10,406 | 10,441 |
| gcc_execute/pr92904 | 12,978 | 12,933 | 12,547 |
| gcc_execute/20040709-1 | 11,812 | 11,430 | 11,357 |
| gcc_execute/20040709-2 | 10,850 | 10,851 | 10,718 |
| gcc_execute/20040709-3 | 11,243 | 10,979 | 10,946 |
| gcc_compile/20040709-1 | 91 | 89 | 89 |
| Total | 98,052 | 71,019 | 70,401 |

The current compiler is 27.6% faster than the older image on this selected
slice. The new index saves another 0.9% across the nine common compiles.
Small changes in unrelated passes include XIP cache layout effects; this
slice is deliberately weighted toward slow compiles and is not a claim
about the whole suite's speedup.

## Change and instruction-count check

Aggregate folding previously scanned every earlier instruction at each
forward control-flow join. It now builds predecessor lists once and visits
only incoming forward branches. Reverse insertion preserves the old
ascending predecessor order. Back-edge joins keep their existing handling.
The index uses scope-owned `small_sequence` storage and adds eight bytes
of scratch space per IR instruction when the aggregate analysis reaches
its dataflow phase.

A separate `pr92904` replay without `-bench` confirmed reduced compiler work:

| Counter | Baseline | Indexed variant | Change |
| --- | ---: | ---: | ---: |
| Instructions | 1,678,500,310 | 1,642,340,540 | -2.15% |
| Data-cache misses | 25,017,693 | 23,085,063 | -7.73% |
| Instruction-fetch misses | 8,214,071 | 8,392,011 | +2.17% |
| PSRAM accesses | 84,780,402 | 80,637,274 | -4.89% |
| Whole-session modeled ms | 13,169.6 | 12,747.5 | -3.20% |

These counters include boot and shell overhead. They confirm that the
benefit persists without pass-timing instrumentation; whole-session time
is distinct from the compile-only times above.

## Validation

* Focused native run: **10 passed**, including `172_const_agg_fold.c`.
* Cross-compiler object comparison at `-O0/-O1/-O2`: **3,081 successful
  compiles produced byte-identical objects**, with 27 matching compile
  failures and no mismatches. Corpus: top-level IR sources, tests2 sources,
  and five selected GCC execute sources. This is a compile comparison,
  not execution of the cross-produced objects.
* Full native IR run at all three levels: **2,575 passed, 32 failed**.
  All 32 exact failed test IDs reproduced on `psram-current`; no new
  failures were found in the checked set. Failure IDs and comparison are
  saved in `.cache/board_model/agg-failure-ids.json` and
  `.cache/board_model/agg-native-regression-comparison.json`.
* Unity manifests regenerated; whitespace checks passed. Benchmark runner
  failure propagation and log preservation were checked with a simulated
  failing pytest process, and real failed runs returned status 1.

The native suite is not fully passing. This experiment classifies its
failures against the baseline rather than fixing unrelated compiler or
harness issues. A self-host fixpoint and a physical-board rerun were not
performed.

## Next profile targets

The indexed variant's IR run contains 2,605 timed compiles totaling 1,017.5
modeled seconds. The largest exclusive pass totals are:

| Pass | Seconds | Share of timed-pass total |
| --- | ---: | ---: |
| cg:dry | 67.97 | 12.8% |
| ra2:ssaopt | 45.50 | 8.6% |
| P:requirements | 39.80 | 7.5% |
| ra:ssa_post_ra | 37.57 | 7.1% |
| cg:emit | 36.35 | 6.8% |
| cg:rehearsal | 20.38 | 3.8% |

The timed-pass total is 532.1 seconds; these percentages are not shares
of total compile time. Priorities are to split the remaining `ra2:ssaopt`
overhead into its untimed operations, identify repeated analysis rebuilds
inside `P:requirements`, and reduce work in the discovery codegen walk
while preserving scratch-register and branch-layout correctness.

## Reproduce using the saved images

```bash
scripts/board_model.py run psram-current -n 4 \
  -k 'pr92904 or pr82052 or 20040709 or strlen-5 or pr34093 or 448_shift64'
scripts/board_model.py run psram-agg-index -n 4 \
  -k 'pr92904 or pr82052 or 20040709 or strlen-5 or pr34093 or 448_shift64 or 172_const_agg'
scripts/board_model.py compare psram-current-hotspots psram-agg-hotspots
scripts/board_model.py run psram-agg-index -n 8 --opt-levels='-O0 -O1 -O2' \
  -k test_run_ir_test_suite
scripts/board_model.py report psram-agg-ir-regression
```

Recorded runs are under `.cache/board_model/runs/`: `psram-old-hotspots`,
`psram-current-hotspots`, `psram-agg-hotspots`, `psram-agg-ir-regression`,
`psram-current-ir-failure-check`, `psram-current-ir-sret-check`, and
`psram-agg-counters`. The patch and object-comparison artifact are
`.cache/board_model/agg-index.patch` and
`.cache/board_model/agg-object-comparison.json`.

The runner now enables plugin logging, preserves each run's smoke logs,
records and returns pytest's exit status, excludes deleted tracked files
from checkout exports, and clears inherited `DEBUG` for the rootfs build
because Toybox interprets it as a command prefix.
