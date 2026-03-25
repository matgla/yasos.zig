# Yasos.zig (**WIP**)

> [!CAUTION]
> **_work in progress_** - it may contains bugs, unoptimized implementations or stubs instead of real functionalities.

The Yasos.zig project is general purpose operating system for microcontollers.
Created in mind to be optimized for resource contrained devices, but with POSIX compatibility and userland which is similar the Linux or Unix operating systems.

# Supported Boards

Implementation is ongoing on MSPC v2 board.
MSPCv2 board is RP2350 custom development board.
Project is maintained inside [MSPCv2](https://github.com/matgla/mspc/tree/mspc_v2)

Pimoroni Pico Plus 2 + Pimoroni VGA board is also supported configuration verified under regression tests.

# Zig version
Zig language is under heavily development, which means frequent changes of standard library and language API.

`main` branch should be compatible with zig version specified in `build.zig.zon -> minimum zig version`.

# How to build
Yasos.zig project requires working `arm-none-eabi-gcc` toolchain for pico-sdk compilation.
Also `python3` is necessary to use pykconfig lib and to convert elf files into yaff.

You can use preconfigured docker environment by calling:
```
make pull_container
make start_env
```

To configure project call:
```
zig build menuconfig
```

Then select `Board selection` -> `MSPC v2/Pimoroni Pico Plus2` since they are only supported board right now.

After configuration use:

```
zig build -Doptimize=ReleaseFast
or for debug build:
zig build -Doptimize=Debug
```

To create rootfs image use:
```
./build_rootfs.sh -c -o rootfs.img
```

# Flashing
After successful building of kernel and rootfs.img flashing can be done using openocd scripts

Kernel only:
```
openocd -f flash_kernel_rp2350.cfg
```

Kernel and rootfs:
```
openocd -f flash_rp2350.cfg
```

# Pimoroni Pico Plus 2 Setup
Connect wiring to UART console and SWD debugger (PicoProbe) as shown on below diagram:

![Pimoroni Pico Wiring](docs/pimoroni_pico_plus2_connection.png)

# Remote smoke runner

If the board is attached to another Linux machine, use [scripts/remote_smoke_tui.py](/home/mateusz/repos/yasos.zig/scripts/remote_smoke_tui.py) to build locally, upload artifacts with `scp`, flash through `ssh`, and run the smoke suite on the remote host.

The script stores its configuration in `.cache/remote_smoke_runner.json`, so once `ssh target`, remote repository path, serial device, and board are filled in, later runs can be started without re-entering them:

```bash
python3 scripts/remote_smoke_tui.py
python3 scripts/remote_smoke_tui.py --run-cached
python3 scripts/remote_smoke_tui.py --run-cached --flash-only
python3 scripts/remote_smoke_tui.py --run-cached --gdb
python3 scripts/remote_smoke_tui.py --run-cached --reset --gdb
python3 scripts/remote_smoke_tui.py --run-cached --debug --gdb
python3 scripts/remote_smoke_tui.py --run-cached --test-retries 2
python3 scripts/remote_smoke_tui.py --run-cached --tests tests/smoke/cd_test.py tests/smoke/ls_test.py
python3 scripts/remote_smoke_tui.py --run-cached --pytest-args 'tests/smoke/tcc_suite_test.py::test_run_tcc_test_suite[00_assignment.c] -x'
```

The remote runner also exposes a cached `OpenOCD speed` field. It defaults to `20000` and is passed as `adapter speed` during the remote flash step, so you can tune CMSIS-DAP speed per host/debug probe without editing repo-level `.cfg` files.

The TUI also caches `Test retries`. It defaults to `1` and is passed to pytest as `--reruns`, which helps mask occasional UART noise without rerunning the entire suite manually.

Pass `--flash-only` to upload and flash the artifacts on the remote host, then stop without creating the remote Python venv or running pytest.

Pass `--tests` to override the cached smoke selection for one run with an explicit list of pytest paths or nodeids. This is useful for reproducing order-dependent failures on the remote board host without editing the cached TUI configuration.

Pass `--test-retries` to override the cached retry count for one run when you want to increase or disable automatic reruns for transient serial noise.

Pass `--pytest-args` to override the cached pytest argument string for one run when you need full pytest syntax such as `-k`, `-x`, or custom nodeid expressions.

Pass `--gdb` to build the kernel locally, rsync the kernel ELF plus `scripts/yasld_gdb.py` and the locally-built app/library ELF outputs referenced by that helper into the remote repository, and open an interactive GDB attach session over SSH without flashing the target. When a previously uploaded kernel exists in the configured remote work directory, the GDB session prefers that flashed kernel ELF as the main symbol file so the symbols match what is already running on the board; otherwise it falls back to the freshly synced repository copy. The remote host is checked for `rsync`, `openocd`, and one of `arm-none-eabi-gdb`, `gdb-multiarch`, or `gdb` before the session starts. Combine `--reset --gdb` to reset-halt the target before GDB attaches.

The remote host is expected to have:

- `openocd`
- `python3` with `venv`
- `rsync`
- access to the same repository checkout path configured in the TUI
- the debug probe and UART device for the selected board