# Boards on the rig

The CI rig (a Raspberry Pi 5, `hardware/ci_rig/`) carries more than one board,
each on its own Raspberry Pi Debug Probe. A registry on the Pi says which probe
is which board and who may use it. Every job that touches a board takes the
board through `scripts/rig/boards.py`: it waits for the board's lock, then runs
with that board's probe, UART and power ports, and never touches another board.

| Board  | Probe              | Pools      | Features | Lock                              |
|--------|--------------------|------------|----------|-----------------------------------|
| a (lane A) | `E665B83887652F2E` | `ci`,`dev` | (no card) | `/var/lock/rp2350-board.lock` (the one tools without the registry take) |
| b (lane B) | `E665B83887763E2E` | `ci`,`dev` | `sdcard` | `/var/lock/yasos-board-b.lock`    |

Both boards serve CI and your own work. CI tries `a` first and your runs try
`b` first, so they meet only when both are busy. For a longer stretch of your
own work, reserve a board (below): CI then leaves it alone.

## Registering the boards (once, on the Pi)

Plug in one probe at a time, or name each probe's serial with `--probe`:

```bash
cd ~/yasos_remote_smoke                   # any checkout with scripts/rig/boards.py
python3 scripts/rig/boards.py scan        # probes on the bus: serial, USB port, UART
python3 scripts/rig/boards.py register a --probe <SERIAL_A> --pool ci --pool dev \
    --lock /var/lock/rp2350-board.lock --note "lane A"
python3 scripts/rig/boards.py register b --probe <SERIAL_B> --pool ci --pool dev \
    --feature sdcard --note "lane B"
python3 scripts/rig/boards.py install     # yasos-board in ~/.local/bin (optional, see below)
python3 scripts/rig/boards.py list
```

- `--lock /var/lock/rp2350-board.lock` on the CI board keeps it serialised with
  matgla/tinycc's metrics job, which takes that lock itself.
- `--power HUB:PORT` (repeatable) lists the uhubctl ports that power-cycle the
  board. By default it is the probe's own port. A board powered from its own
  USB port needs that port added: `register b --force --power 1:2 --power 3:1`.
- `--type` sets the board profile (`pimoroni_pico_plus2_and_vga` by default,
  `mspc_v2`). Runs only pick a board of the profile they built.
- Re-registering with `--force` changes only the fields you give;
  `unregister NAME` removes a board.
- The registry is `~/.config/yasos-rig/boards.json` (`YASOS_RIG_BOARDS`
  overrides it). With no registry, everything works as it did with one board:
  the old lock, and no probe selection.

## Using a board

```bash
boards.py list                              # boards, their probes, who holds each
boards.py run --board b -- CMD ...          # board b, waiting while it is busy
boards.py run --pool ci -- make ...         # first free board of pool ci
boards.py run --board auto -- CMD           # first free board of pool dev, dedicated first
```

### Reserving a board

```bash
boards.py reserve b --note "kernel debug"   # 24 h; --hours 0 = until released
boards.py release b
remote_smoke_tui.py --reserve-rig-board b [--reserve-hours 8]   # the same from the PC
remote_smoke_tui.py --release-rig-board b
```

A reserved board leaves every pool but `dev`: CI stops picking it (a CI job
already on it finishes first), and `--board auto` picks it before any other
board, so the TUI's default lands on it. A board named explicitly is taken
reserved or not. With every CI board reserved, CI jobs wait (up to their
`--wait`) and print why. `list` shows who reserved what and for how long.

## Features: jobs that need an SD card

Without a card, `/root`, `/var` and `/home` are RAM -- a few hundred KB on the
Pico Plus 2 -- so a job that sends megabytes there fails (`rz could not write`,
ENOSPC). Such jobs ask for the card:

```bash
boards.py run --pool ci --need sdcard -- make run_selfhost_packaged ...
boards.py register b --force --feature sdcard   # what b has (repeat; --feature '' clears)
```

`--need` skips boards without the feature; a board named with `--board` that
lacks it is an error. CI's `hardware_selfhost` (`/root/selfhost-ci`) and
`hardware_zig_kernel` (`/root/kfull`) need `sdcard`; `hardware_smoke` runs on
either board.

`run` execs `CMD` while holding the lock and sets `YASOS_BOARD`,
`YASOS_PROBE_SERIAL`, `SERIAL_DEVICE` (the board's
`/dev/serial/by-id/...`), `OPENOCD_SCRIPTS`, `YASOS_POWER_PORTS`,
`YASOS_BOARD_STATE` and `YASOS_BOARD_LOCK`. `OPENOCD_SCRIPTS` points to
`scripts/rig/openocd`, whose `interface/cmsis-dap.cfg` adds
`adapter serial $YASOS_PROBE_SERIAL`. So `openocd -f interface/cmsis-dap.cfg`
and the flash cfgs reach this board's probe with no change at the call site.
Exit status 99 means the board was still busy after `--wait` seconds (default
7200).

`YASOS_BOARD_STATE` holds what the board was flashed with (`kernel.sha256`,
`rootfs.sha256`), so a run can skip flashing images the board already holds.
Only jobs run with `--keeps-state` keep those records up to date
(`remote_smoke_tui.py`, `scripts/rig/`). Any other job may flash without
recording it (a CI job, a manual openocd), so taking the board without the flag
deletes the records, and the next run flashes.

### From the PC

- `scripts/remote_smoke_tui.py`: the **Rig board** field (`auto` by default),
  or `--rig-board NAME` for one run. `--list-rig-boards` shows the registry.
  Every command (smoke run, flash, `--connect`, `--reset`, `--rescue`,
  `--power-reset`, the GDB modes) runs under the board's lock, so it waits for
  a CI job on the shared board instead of running over it. Two sessions on the
  rig at the same time need different **Remote repo** paths: each run syncs
  the mirror with `--delete`.
- `scripts/tinycc_board.py`, `scripts/board_selfhost.py`, `scripts/zig_board.py`,
  `scripts/target_sync.py --rig`: `--rig-board NAME`. The default is the TUI's
  cached **Rig board**.

### CI

The hardware jobs in `.github/workflows/yasos_smoke.yml` run their board step
as `boards.py run --pool ci -- make ...`. `scripts/run_container.sh` then
passes only that board's UART into the container, along with the probe
variables and the openocd override. To pin a runner to one board, set
`YASOS_BOARD=<name>` in its `~/actions-runner/.env`. A second CI board needs
only `register c --pool ci`, plus a second runner service if two jobs should
run at once.

### Tools that know nothing of the registry

`boards.py install` puts `yasos-board` in `~/.local/bin`, for checkouts of
other repositories. It also writes `~/.config/openocd/interface/cmsis-dap.cfg`,
which OpenOCD reads before its own scripts: an openocd run that names no probe
goes to the first board of pool `ci`, never to a board someone is working on.
`register` and `unregister` keep that file current.

matgla/tinycc's metrics job (tinycc 15fa4e622b on combined/2026-11-20) runs
its board steps under `yasos-board run --pool ci` when `yasos-board` is on the
runner user's PATH or in its `~/.local/bin`, and `run_benchmark.py` then opens
only that board's probe and UART. So run `boards.py install` as the user the
tinycc runner runs as, with the registry in that user's
`~/.config/yasos-rig/` (or `YASOS_RIG_BOARDS` in the runner's `.env`).
Without the tool it falls back to the old flock and the first probe and UART.
