# RP2350 board model: board-speed profiles on QEMU

Profiling on-device tcc compiles on the host, or on plain QEMU, puts the time in
the wrong places. On the Pimoroni Pico Plus 2, tcc's code and read-only data
execute in place from flash, its heap spills from the 432 KB of process SRAM into
PSRAM, and both flash and PSRAM sit behind one 16 KB XIP cache whose misses each
cost a QSPI transaction -- about a hundred core cycles at 532 MHz. QEMU's
mps3-an524 charges none of that, so its per-pass ratios to the board are flat
(~6x) while the board's real ones range from 2.6x to 10x per pass.

The board model puts those costs back and keeps everything else as it is: the
same kernel, the same userspace, the smoke harness unchanged, and tcc's own
`-bench` / `PASS_TIME` output -- which, under the model, reads board time.

Against the 2026-10-07 board run (Pico Plus 2, 532 MHz) the model predicts each
compile's board time within 3.2% on average (max 5.6%) over the 27 slowest
suite compiles, and within ~7% on held-out tests of the calibration set.

## Pieces

| | |
|---|---|
| `tools/board_model/rp2350_timing.c` | QEMU TCG plugin. Counts instructions (CPI), simulates the XIP cache (16 KB, 2-way, 8-byte lines) for instruction fetches and data accesses to flash and PSRAM, charges misses / writebacks / uncached PSRAM stores, and writes modeled board time into the kernel's `yasos_modeled_clock_ns`. Idle (WFI) time counts only while every core is idle. |
| `hal/source/arm/qemu_mps3/source/time.zig` | the an524 clock reads `yasos_modeled_clock_ns` when it is nonzero (only the plugin sets it) |
| `hal/source/arm/qemu_mps3/source/memory.zig` | under the model, PSRAM pages are cleared the board's way (uncached word stores from `yasos_uncached_zero`, which the plugin charges as such) |
| `scripts/board_model.py` | builds QEMU + plugin, builds images, runs the smoke tcc suites on an image, reports, compares, calibrates |
| `tests/smoke/profiling.py` | `YASOS_SMOKE_RESULTS_DIR`: one JSON line per compile per xdist worker (bench rows + PASS_TIME), so profiles survive `-n` |

An **image** is a copy of a yasos tree configured for an524 with the board's
memory map (process SRAM 432 KB, PSRAM 8 MB -- the linker script of the copy is
resized), so the kernel's SRAM-then-PSRAM tiering spills tcc's heap exactly where
the board does, with its tinycc swapped for whatever revision you are measuring.

## Workflow

```bash
scripts/board_model.py setup                       # once: QEMU 11.1.2 with plugins + the plugin
scripts/board_model.py image base                  # tinycc as in this tree
scripts/board_model.py image mine --tinycc ~/repos/my-tcc-worktree   # a checkout (working tree) ...
scripts/board_model.py image old  --tinycc f6728d73                  # ... or a libs/tinycc revision
scripts/board_model.py run base -k strlen          # -O2 by default; any pytest -k slice of tcc_suite_test.py
scripts/board_model.py run base --opt-levels='-O0 -O1 -O2'   # the whole tcc suite
scripts/board_model.py report base-<stamp>         # slowest compiles, passes summed over the suite
scripts/board_model.py compare base-<stamp> mine-<stamp>
```

`run` drives the image's own `scripts/run_qemu_smoke.sh --no-build` (one QEMU
per xdist worker, `-n` defaults to half the CPUs) with the plugin loaded and
`-bench` on, and keeps everything under `.cache/board_model/runs/<run>/`.
It returns pytest's exit status and records it in `run.json`. Smoke logs,
including plugin counters, are copied to the run's `smoke_logs/` before the
next run can overwrite the image's working logs.
`--tinycc-patch FILE` applies a patch on top of the chosen tinycc.

`setup` needs glib development files: the static prefix in `.cache/qemu_plugin`
if present, otherwise the system's (`glib2-devel` + `meson`). Fedora's own
`qemu-system-arm` is built without plugin support.

## Reading the results

* **Per compile**: `report` lists modeled board ms with the opt / alloc / codegen
  split from `-bench`.
* **Per pass, suite-wide**: `PASS_TIME` self times summed over every compile --
  the ranking to optimise against, since a pass that is 2% everywhere can beat
  one that is 30% of a single test.
* **Plugin summary**: each QEMU's log (`smoke_logs/qemu_*.log` in the run directory) ends
  with instruction count, base vs stall cycles, and hit/miss counts by kind.
  For the slowest torture compiles, instruction-fetch misses are about a third of
  board time: where tcc's hot code sits in flash matters as much as most passes.
* **Small deltas in passes a change did not touch** are usually code layout: a
  different tcc binary maps differently onto the 2-way XIP cache. That is real on
  the board too, but it is not the change's algorithmic cost. Compare instruction
  counts (plugin summary) to tell the two apart.

The [2026-10-07 compiler profile](board_model_tcc_profile_2026-10-07.md)
records a PSRAM-emulated baseline, an aggregate-folding optimization, and its
validation results.

## What to optimise next

`scripts/selfhost_profile.py` answers this for the self-compile, one QEMU per
translation unit of the `tcc_selfhost.py` payload (frozen in
`.cache/board_model/selfhost_src` on first use, so comparisons share an input):

```bash
scripts/board_model.py image mine --tinycc ~/repos/my-tcc-worktree
selfhost_profile.py ab base mine                     # -O0 and -O2: time, and do the objects match?
selfhost_profile.py run mine OUT --nest 2 --opt=-O0  # every unit, keeping per-PC profiles
selfhost_profile.py funcs mine OUT                   # cycles per function, split into fetch and data
selfhost_profile.py callers mine OUT CALLERS irop_get_vreg_w tcc_ir_op_get_src1 --unit ir_regalloc
selfhost_profile.py run nolist WHATIF --fast tcc:names.txt --fast kernel:knames.txt
selfhost_profile.py hotlist nolist OUT --kb 128 --module tcc --marks libs/tinycc/source/driver/hot_functions.txt
```

* A profile reads only its own build: `run` stamps `OUT/image.sha256` and refuses
  to add to results of another build of an image with the same name.
* `--opt` replaces the level in the response file. Appending it would not do:
  `-O2 ... -O0` keeps the passes `-O2` turned on, so the objects differ from `-O0`.
* `--nest 2` runs the compile under two shells, as `build.sh` does: they hold
  memory the compile cannot have.
* `callers` is what a host profile cannot give you: the host cross inlines the
  accessors the device calls. It needs a run of the same build (`BASE` above) to
  find the SRAM copies, whose address nothing records, and a function in the
  block has two entries, both counted. Veneers and PLT stubs are skipped, so a
  caller is the real call site. `FN` may be `name+OFFSET`, for a block inside a
  function. `--attr ENTRY,ZERO,LOOP` counts each run of the block `LOOP` by who
  called `ENTRY` and who called `ZERO`: bytes cleared, per caller of `__tcc_memset`
  and of `tcc_mallocz`, is `--attr __tcc_memset,tcc_mallocz,.Lset_16`.
* `run --fast` charges nothing for fetches from the listed functions: what a
  placement would buy, before building it. Run it on an image without a list.
  It is an upper bound: the real block also pays for veneers and pool memory.

The model ranks; only the board decides. `scripts/board_selfhost.py` builds the
board image and runs the self-compile on the rig at each level:

```bash
scripts/board_selfhost.py --build              # -O0 and -O2; logs in .cache/board_selfhost/<label>/
scripts/board_selfhost.py --opt=-O0 --no-wait  # queue what is built; prints how to watch
scripts/board_selfhost.py --logs               # collect them later
```

It queues on `/var/lock/rp2350-board.lock`, keeps its images in its own directory
until it holds the lock, and compares their hashes before and after flashing. The
board's tree (`/root/selfhost-<label>`, the checkout's name by default) and the rig's
directory are per label, so a manifest never describes another session's files. The
first run in a label sends everything. The rig's side is in `scripts/rig/`.

## Calibration

```bash
scripts/board_model.py calibrate .cache/remote_smoke_logs/<host>/<run> <image> --write
```

replays ~40 board compiles from a board run's logs (exact commands, spread over
compile times), one QEMU each, and fits CPI and the cache costs by non-negative
least squares (alternate tests held out). `--write` stores them in
`.cache/board_model/params.json`, which `run` passes to the plugin; without it the
plugin's built-in defaults (the 2026-10-07 fit) apply.

**The image's tinycc must be the board's** -- the same commit and the same local
changes the board's rootfs was built from -- or the fit chases the difference: a
tinycc from before f6728d73 put limits-fnargs at +185%.

Fitted 2026-10-07: CPI 2.2, instruction-fetch miss 122 cycles, data miss 84,
uncached PSRAM store 178, cache hit and writeback ~0 (absorbed by the others),
plus ~16 ms per compile outside the model (SD-card reads of the source on the
board, process start).

## Limits

* One core's work at a time: the second core's idle time is excluded, SMP
  contention is not modelled.
* SRAM bank contention, DMA, the SD card and the UART cost nothing beyond CPI.
* The an524 userspace is soft-float, the board's is hardware FP -- negligible for
  the compiler, not for FP-heavy test programs (only compiles are timed).
* Calibrated against one board at one clock; refit after changing clocks, QSPI
  timing or the cache configuration.
