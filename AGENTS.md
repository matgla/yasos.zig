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
  at `/mnt` (long names, subdirectories, ≤256 MB): `-c CMD` runs commands and
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
- **`scripts/tinycc_board.py push | make | run CMD | pull | all`** — work on
  tinycc on the board: the whole repository (or `--sources-only`) goes to
  `/root/tinycc/tree/src` as a compressed delta (first push ~5.5 min, then only
  what changed), `make` runs `./configure && make` there (`--configure=` for
  options; plain `./configure` needs none on YasOS), `pull` brings the board's
  edits back with the target_sync three-way merge, and a push refuses to
  overwrite a file edited on the board. Default is the rig's board under its
  lock (`--flash` installs this checkout's images first); `--serial DEV` for a
  probe on this PC, `--qemu all` for a guest (sources in `/tmp`: QEMU's RAM
  `/root` holds ~14 MB). tinycc side: `libs/tinycc/docs/native_build.md`.
- **`scripts/kernel_tcc/zig_device.py prepare | qemu | tcc | full`** — the whole kernel
  built ON the target: `prepare` captures the two C-backend compiles of `zig build
  kernel-tcc-plan` (kernel, compiler-rt) and ships every source, generated .zig and the
  device zig lib; `qemu` renders them with the device zig (must equal the fork's host
  compiler at `-j1`); `full` does renders + `scripts/kernel_tcc/zigfix.c` (the Python
  fix-ups in C, built by tcc on the device) + all plan commands through the link in one
  QEMU boot, compared output by output with the same script run on the host.
- **Board self-build CI** (`.github/workflows/yasos_smoke.yml`): `hardware_selfhost` runs
  `scripts/run_hw_selfhost.sh` (the build_hw package + a `tcc_selfhost.py --prepare-only`
  payload, `tcc_selfhost.py --uart --payload`, stage 3 fixpoint); `hardware_zig_kernel` runs
  `scripts/run_hw_zig_kernel.sh` (an image built with `YASOS_IMAGE_ZIG=<fork>` from
  `apps/zig/fetch_fork.sh`, the fork pinned in `apps/zig/zig_fork.txt`, and a
  `zig_device.py full --package` package; `zig_device.py board-run` compares every output
  with the host reference). From this PC: `zig_device.py full --board [--flash]` (rig).
  Host references use the fork's SINGLE-THREADED host compiler
  (`.cache/zig-build/host-st`, built by build_zig.sh): single-threaded, the fork creates a
  declaration's Nav on first use, which numbers the C differently from a threaded build.
- **`scripts/zig_board.py [--flash] push | run CMD`** — the device zig on the rig's board:
  `./build_rootfs.sh -c -o rootfs.img --zig ~/repos/zig-0171` keeps it in an rp2350 image
  (3.7 MB; the build fails if the image passes the 8 MB romfs region), `push` puts its lib
  on the card (`/var/lib/zig` -> `/var/lib/zigm/tree/src`), `run` runs a command under the
  board lock. A `std.fmt` build-obj takes ~10 s and 2.5 MB on the Pico Plus 2.
- **`scripts/tcc_selfhost.py --qemu | --uart --dest /abs/dir`** — the tinycc
  self-host test: builds the stage-2 native tcc with the cross in
  `.cache/tcc_selfhost`, sends sources + host-cross objects, the device's tcc
  builds tinycc (compared with the host objects), then that new tcc rebuilds
  itself and must reach a byte-identical fixpoint. `--tu REGEX` for a quick
  compile-only check; `--stages 2` to skip the fixpoint.
- **Storage layout** ([`docs/storage.md`](docs/storage.md)): the kernel mounts
  from `/etc/fstab` (in-tree `etc/fstab`) -- SD partitions by `LABEL=`: FAT
  `/boot` (yasboot reads it), ext4 `/var /home` (lwext4 fork in
  `libs/lwext4`, driver `source/fs/ext4/`), swap on a type-82 partition
  (processes waiting in `waitpid` are written out when the pool is full), `/root` bound to `/home/root`, `/tmp` spilling to
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
  `compare A B`, `calibrate`; `kernel` builds this tree's kernel with the board's
  memory map (`.cache/board_model/kernel`) for `qemu_mount.py --kernel`: real workloads
  in 8 MB, swap and fragmentation included (run with zig 0.17.1 first in PATH). Host and plain-QEMU profiles mis-rank passes for
  the board — use this before optimising compile time.
- **`scripts/selfhost_profile.py`** — where a self-compile's board time goes, on a
  board-model image: `run` (units of the tcc_selfhost payload), `funcs` (cycles per
  function across tcc, libc and the kernel), `allocs` (misses per allocation site
  and what SRAM could hold; needs a `-DTCC_ALLOC_PROFILE` image), `compare`,
  `poolmap` (who owns SRAM, `/proc/poolmap`), `identity` (do two images' crosses
  produce the same objects), `hotlist` (regenerate a `--hot-text`/`--ram-text` list,
  `--marks` keeps its `=` marks), `callers` (the device's call graph; the host's
  inlining hides it), `ab` (two images at -O0 and -O2: time and object identity),
  `run --fast` (what if these functions cost no fetch). The device tcc keeps its heap in PSRAM and its hot IR
  arrays in an SRAM arena (`MAP_SLOW` / `MAP_FAST`, see `libs/tinycc/source/driver/libtcc.c`).
- **`scripts/board_selfhost.py`** — the self-compile on the rig's board at each level:
  `--build` for the board config + images, `--opt=-O0` for one level, `--no-wait` and
  `--logs`. Holds the board lock, flashes private images with hash checks, and keeps a
  per-checkout tree on the card (`/root/selfhost-<label>`). Rig side: `scripts/rig/`.
- **`scripts/qemu_capture_yaff.py`** — older RAM-scan capture (slower/flakier;
  prefer the FAT drive).
- **`scripts/run_qemu_smoke.sh`** — the pytest smoke suite on QEMU (no hardware).
  `--no-build` reuses the current kernel; `-k <name>` selects tests.
- **`scripts/stack_overflow_sweep.py [--kernel ELF] [--step N]`** — overflow a
  process stack at every depth of the ext4 and FAT paths on a QEMU SD card; fails
  on a panic, a broken filesystem afterwards, or a process killed holding a
  filesystem lock. Run it after changing those paths or their `stack_needed`
  margins (`source/fs/ext4/ext4fs.zig`, `source/fs/fatfs/fs_lock.zig`): the smoke
  suite has no card. Its sweep without a disk is in `tests/smoke/user_fault_test.py`.
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
- **`zig build` on the board** (fork `-ftcc`): a prebuilt maker plus a configurer compiled
  on the device, its C at tcc `-O0`. Pico Plus 2, hello: cold 14 min, rebuild after an edit
  7 min, cached 4 s; the fixed cost is the configurer (6.3 MB of C). The shipped std ZIR
  (`<lib>/zir/`) is keyed by file path and compiler version, not content: a lib file edited
  on the card without regenerating `zir/` compiles the OLD source, and a fork commit with a
  new `git describe` starts every cache cold.
- **LDREX/STREX never succeed in RP2350 PSRAM** (the global monitor does not cover it). User
  code gets plain atomics from libtcc1 (`-DTCC_ATOMICS_PLAIN`); the kernel keeps exclusives
  for its locks in SRAM. A process spinning with no children and no I/O: read the `Resume:`
  line of `/proc/<pid>/status` for its pc.
- **Watching a build on the board: no shell loops.** A loop with `$(...)` or pipes allocates
  and can starve the pool or block a swap-in until the watchdog kills the build (5 s, exit
  137; pid 1 panics). Use a non-allocating tracer.
- **Killing the local `zig_board.py` does not stop the job on the rig**, and it keeps the
  board lock. Filter processes by `comm`, never by text that matches your own command line.
- **Never hand-build the cross with plain `make`** (e.g. for a private-copy
  self-host cross): a bare make over an old `config.mak` drops
  `-DTARGETOS_YasOS=1` and the rootfs sysroot paths from `build_rootfs.sh`'s
  cross configure. Without the YasOS target define the cross reports
  "(ARM Linux)", its target predefines change, and its objects differ from
  the device compiler's by 8-byte stack-frame shifts — every host-vs-device
  comparison then "fails" without any miscompile. Always build crosses
  through `./build_rootfs.sh` (or replicate its exact configure line).
- **Flash with both cores halted: never `set USE_CORE 0` around `program`.** OpenOCD's
  work area is SRAM 0x20010000, the start of the process pool on the PSRAM boards, so a
  running core 1 writes into the buffer being programmed. Erase and write report nothing;
  verify shows `Was 0x00` / SRAM pointers at a repeatable address. A Pi reboot does not
  clear it. For reset-only and GDB commands core 0 alone is fine.
- **`source/kernel/hot_functions.txt` rots silently:** Zig's inner numbers (`__func_N`,
  `struct_N`) move with any edit and differ per board, and `--ram-text` drops what it cannot
  find. After kernel changes run `scripts/hot_functions_refresh.py`; rank new lists only on
  a kernel with no list.
- **`-O0`-native shifts the bug** elsewhere — not a clean bisector.
- The bump commit is **not** automatically the cause — verify by reverting.

## Memory

Persistent findings live in the agent memory at
`~/.claude/projects/-home-matgla-repos-yasos-zig/memory/` (indexed by `MEMORY.md`).
The tinycc self-host bugs, the FAT-drive design, and the debugging guide are all
indexed there — check it before re-deriving anything.
