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

- **`scripts/qemu_fatdisk_run.py`** + **`scripts/fatimg/`** — host-readable FAT
  drive mounted at `/mnt` on the QEMU guest. Drop sources in, pull device-compiled
  binaries out, **no kernel rebuild, no RAM scan**. This is the fast inner loop.
  (8.3 UPPERCASE names → use `tcc -x c`; don't `ls /mnt` — kernel readdir panics.)
- **`scripts/qemu_capture_yaff.py`** — older RAM-scan capture (slower/flakier;
  prefer the FAT drive).
- **`scripts/run_qemu_smoke.sh`** — the pytest smoke suite on QEMU (no hardware).
  `--no-build` reuses the current kernel; `-k <name>` selects tests.

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
- **`-O0`-native shifts the bug** elsewhere — not a clean bisector.
- The bump commit is **not** automatically the cause — verify by reverting.

## Memory

Persistent findings live in the agent memory at
`~/.claude/projects/-home-matgla-repos-yasos-zig/memory/` (indexed by `MEMORY.md`).
The tinycc self-host bugs, the FAT-drive design, and the debugging guide are all
indexed there — check it before re-deriving anything.
