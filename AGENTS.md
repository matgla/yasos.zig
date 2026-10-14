# AGENTS.md — yasos.zig

Orientation for AI agents working in this repo. Keep this file current as
workflows change.

## What this is

YasOS is a small operating system (Zig kernel + HAL + userspace) for ARMv8-M
(Cortex-M33/M23). Userspace C is built with a custom fork of **TinyCC**
(`libs/tinycc`, a submodule) that targets ARM Thumb-2 via its own IR pipeline.
The compiler is **self-hosting**: a gcc-built **cross** (`libs/tinycc/bin/armv8m-tcc`,
x86, emits ARM) compiles tinycc's own source into the **native** `tcc` that runs
on the device.

## Current major effort: fixing self-host miscompiles

Most remaining `libs/tinycc/tests/tests2` failures are **self-host miscompiles** —
the cross compiles a tinycc function into wrong ARM, so the on-device `tcc`
miscompiles test programs even though the host cross compiles them correctly.

> **READ THIS FIRST for that work:**
> [`libs/tinycc/docs/selfhost_miscompile_debugging.md`](libs/tinycc/docs/selfhost_miscompile_debugging.md)
> — the repeatable workflow: FAT-drive device round-trips → confirm
> host-correct/device-wrong → narrow feature→pass (`-dump-ir-passes=all` on a
> debug cross) → instrument the pass → disassemble the cross's output of the
> tinycc function vs a golden `arm-none-eabi-gcc` reference → fix (source
> workaround **or** fix the cross codegen bug) → regress. Worked example:
> `09_do_while` (fixed in `ir/regalloc.c ra_resolve_phis`).

The same bug class recurs across tests; fixing the underlying **cross** codegen
bug (rather than a per-function source workaround) often clears several tests at
once — prefer that when a bug class repeats.

## Key tooling

- **`scripts/kernel_compare.py`** — A/B the tcc `-O2` kernel against the
  Zig/LLVM kernel by **guest instruction counts** (gated icount plugin, one
  QEMU boot per workload; `scripts/board_model.py setup` provides the
  plugin-enabled QEMU). Runs userland apps, tcc compiles/runs and the on-board
  zig (`build-obj -ofmt=c`, then tcc compiles the C — the device zig has no
  ELF linker). `--store` saves a baseline; a bare run diffs rc + output hashes
  (failure) and instruction deltas (warn at `--count-warn`, fail with
  `--fail-on-count`). Per-PC CSVs for hotspot work land in
  `.cache/kernel_compare/insns/`.
- **`scripts/qemu_fatdisk_run.py`** + **`scripts/fatimg/`** — host-readable FAT
  drive mounted at `/mnt` on the QEMU guest. Drop sources in, pull device-compiled
  binaries out, **no kernel rebuild, no RAM scan**. This is the fast inner loop.
  (Long names and subdirectories work on the an524 kernel as of 2026-09-30 —
  `qemu_mount.py` relies on them; the old 8.3-only / `ls /mnt` panic notes were
  from an earlier kernel.)
- **`scripts/qemu_mount.py DIR`** — boot the an524 kernel with a host directory
  at `/mnt` (long names, subdirectories, ≤16 MB): `-c CMD` runs commands and
  exits with their status, no `-c` gives a console (Ctrl-] quits), `--dest`
  copies it into a guest directory, `--pull OUT` brings `/mnt` back afterwards.
  The real-board counterpart is **`scripts/transfer.py -r DIR /abs/dest`**
  (zmodem over the debug-probe UART).
- **Developing on the target (no network, no git there):** the PC keeps the
  checkout. `scripts/run_qemu.sh` always mounts a host directory at `/mnt`
  (`--mount DIR`, `YASOS_QEMU_MNT`, default `.cache/qemu_mnt`; `--no-mount`) and
  merges the guest's changes back when QEMU exits. For a board,
  **`scripts/target_sync.py push|pull|status HOST_DIR /abs/board/dir`** moves
  only changed files (rz up, `sz` down). Both are three-way: a file changed on
  both sides is never overwritten -- the target's copy lands as `<file>.target`,
  and push holds that file back until the `.target` is deleted.
- **`scripts/tcc_selfhost.py --qemu | --uart --dest /abs/dir`** — the tinycc
  self-host test: builds the stage-2 native tcc with the cross in
  `.cache/tcc_selfhost`, sends sources + host-cross objects, the device's tcc
  builds tinycc (compared with the host objects), then that new tcc rebuilds
  itself and must reach a byte-identical fixpoint. `--tu REGEX` for a quick
  compile-only check; `--stages 2` to skip the fixpoint.
- **Storage layout** ([`docs/storage.md`](docs/storage.md)): the kernel mounts
  from `/etc/fstab` (in-tree `etc/fstab`) -- SD partitions by `LABEL=`: FAT
  `/boot` (yasboot reads it), ext4 `/var /opt /home` (lwext4 fork in
  `libs/lwext4`, driver `source/fs/ext4/`), `/root` bound to `/home/root`, `/tmp` spilling to
  `/var/tmp`, kernel log in `/var/log`. Partitions are `/dev/mmc0p1..4`
  (1-based). `cardreformat` (romfs `/usr/bin`, in-tree `usr/bin/`) lays a card
  out with `fdisk` + `mkfs.fat`/`mkfs.ext4` (host builds for a PC:
  `make -C apps/fdisk host`, `make -C apps/mkfs host`); `scripts/qemu_mount.py --sdcard`
  boots QEMU with a partitioned card image. No card: `/var` and `/home` are RAM.
- **`scripts/board_model.py`** ([`docs/board_model.md`](docs/board_model.md)) — profile
  on-device tcc compiles **at board speed on QEMU**: a TCG plugin
  (`tools/board_model/rp2350_timing.c`) models the RP2350's XIP cache / flash /
  PSRAM costs on a board-shaped an524 image and drives the guest clock, so tcc's
  own `-bench`/`PASS_TIME` read Pico Plus 2 time (within ~3-7% of the board).
  `setup`, `image NAME --tinycc REV|DIR`, `run IMAGE [-k ...]`, `report`,
  `compare A B`, `calibrate`. Host and plain-QEMU profiles mis-rank passes for
  the board — use this before optimising compile time.
- **`scripts/qemu_capture_yaff.py`** — older RAM-scan capture (slower/flakier;
  prefer the FAT drive).
- **`scripts/run_qemu_smoke.sh`** — the pytest smoke suite on QEMU (no hardware).
  `--no-build` reuses the current kernel; `-k <name>` selects tests.
- **`scripts/vfs_cache_baseline.py --kernel ELF`** — FAT/ext4 repeated-read,
  compile and spawn traffic on a perf-profiling kernel. Keeps raw UART logs,
  cache counters and hashes; `--board-model` uses a board-shaped kernel with
  the RP2350 timing plugin (the disk remains RAM-backed). For the boards'
  cache-off FAT path, configure `configs/qemu_mps3_an524_nofatcache_defconfig`,
  build, then use the smoke runner's `--no-build` so it retains that config.

## Build / run

```bash
./build_rootfs.sh -o rootfs.img        # build cross+native tcc, userspace, romfs image
rm -rf .zig-cache && zig build -Doptimize=ReleaseSafe   # kernel (re-embeds rootfs.img via incbin)
./scripts/run_qemu_smoke.sh --no-build tcc_suite_test.py        # full tcc suite on QEMU
./scripts/run_qemu_smoke.sh --no-build tcc_suite_test.py -k 09_do_while
```

- The native `tcc` lives in the incbin'd romfs, so changing it needs the romfs +
  kernel rebuilt. Native rebuild ~3-5 min; kernel re-embed ~1 min.
- `rm libs/tinycc/.yasos-build/{cross,native-stage1,native-stage2}.stamp` to force
  rebuilds (drop the `cross` stamp only when a file compiled into the cross changed).
- `NATIVE_TCC_OPT_OVERRIDE=-O0 ./build_rootfs.sh …` overrides the native opt level
  for experiments (default `-O1`).
- tinycc-internal build/test details: [`libs/tinycc/CLAUDE.md`](libs/tinycc/CLAUDE.md).

## Gotchas (these waste time)

- **`pkill -f qemu-system-arm` self-kills the shell** (its own cmdline matches the
  pattern). Kill QEMU by `comm`:
  `ps -eo pid,comm | awk '$2=="qemu-system-arm"{print $1}' | xargs -r kill -9`.
  Never write `until ! pgrep -f qemu_fatdisk_run; …` — the loop never exits.
- **Stale ARM objects break the x86 cross link** ("file in wrong format"):
  `rm -rf libs/tinycc/{armv8m-arch,armv8m-ir,armv8m-*.o,*.o}` before a cross build.
- **Never hand-build the cross with plain `make`** (e.g. for a private-copy
  self-host cross): a bare make over an old `config.mak` drops
  `-DTARGETOS_YasOS=1` and the rootfs sysroot paths from `build_rootfs.sh`'s
  cross configure. Without the YasOS target define the cross reports
  "(ARM Linux)", its target predefines change, and its objects differ from
  the device compiler's by 8-byte stack-frame shifts — every host-vs-device
  comparison then "fails" without any miscompile. Always build crosses
  through `./build_rootfs.sh` (or replicate its exact configure line).
- **`-O0`-native shifts the bug** elsewhere — not a clean bisector.
- The bump commit is **not** automatically the cause — verify by reverting.

## Memory

Persistent findings live in the agent memory at
`~/.claude/projects/-home-matgla-repos-yasos-zig/memory/` (indexed by `MEMORY.md`).
The tinycc self-host bugs, the FAT-drive design, and the debugging guide are all
indexed there — check it before re-deriving anything.
