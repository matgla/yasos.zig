#!/bin/bash
#
# run_qemu_smoke.sh — build the yasos.zig kernel for QEMU (mps2-an505 / Cortex-M33)
# and run the pytest smoke suite against it. No hardware, no OpenOCD, no SSH.
#
# The smoke Session connects to QEMU's UART over a PTY (see
# tests/smoke/framework/qemu.py); it is activated purely by exporting
# YASOS_QEMU_KERNEL, so the existing tests run unmodified.
#
# Usage:
#   scripts/run_qemu_smoke.sh [options] [pytest args...]
#
# Options:
#   --no-build         Skip configure/build; use the existing kernel ELF.
#   --rebuild-rootfs   Regenerate rootfs.img (needed when userspace changed).
#   -h, --help         Show this help.
#
# Any non-option arguments are passed through to pytest. With none, the default
# set is the core target tests plus the tcc suites:
#   cd_test.py ls_test.py ps_test.py shell_test.py tcc_test.py tcc_suite_test.py
# The tcc tests currently FAIL (known tinycc bug + a serial-upload corruption on
# QEMU) and are enabled so they run as fixes land. Pass files to override, e.g.
#   scripts/run_qemu_smoke.sh tcc_suite_test.py -k 00_assignment
# Run the whole suite with:  scripts/run_qemu_smoke.sh .
# Runs in parallel by default (one QEMU per pytest-xdist worker, using all CPUs
# via -n auto). Override the worker count by passing your own -n:
#   scripts/run_qemu_smoke.sh . -n 4
# Disable parallelism with -n 0 or YASOS_SMOKE_XDIST=0.
# Note: the per-test timing/profiling summaries are skipped under -n (they
# aggregate in-process), and pytest's -s output interleaves across workers.
#
# Logs: each run's per-test session logs, logs/failed/, and the qemu process
# logs are collected into .cache/qemu_smoke_logs/ (analogous to the remote
# runner's .cache/remote_smoke_logs/); cleared and repopulated every run.
#
# The GCC torture smoke tests (tcc_suite_test.py gcc_compile/gcc_execute) are
# enabled by default; the gcc-testsuite submodule under libs/tinycc is fetched
# (shallow) on first use. Disable with YASOS_SMOKE_ENABLE_GCC_TORTURE=0.
#
# Environment overrides (consumed by tests/smoke/framework/qemu.py):
#   YASOS_QEMU_BIN, YASOS_QEMU_MACHINE, YASOS_QEMU_CPU,
#   YASOS_QEMU_EXTRA_ARGS, YASOS_QEMU_BOOT_TIMEOUT
#   YASOS_QEMU_OPTIMIZE   zig optimize mode for the build (default ReleaseFast)
#   YASOS_SMOKE_ENABLE_GCC_TORTURE   default 1 here; set 0 to skip GCC torture
#   YASOS_SMOKE_XDIST     pytest-xdist worker count (default auto = all CPUs);
#                         set 0 to run serially
#   YASOS_SMOKE_TCC_OPT_LEVELS   tcc -O levels to exercise across all suites
#                         (default "-O0 -O1 -O2"); e.g. set "-O0" for one level
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

DEFCONFIG="configs/qemu_mps2_an505_defconfig"
OPTIMIZE="${YASOS_QEMU_OPTIMIZE:-ReleaseFast}"
KERNEL="$REPO_ROOT/zig-out/bin/yasos_kernel"
VENV="$REPO_ROOT/.qemu_smoke_venv"
SMOKE_DIR="$REPO_ROOT/tests/smoke"
# Collected per-run logs land here, analogous to the remote runner's
# .cache/remote_smoke_logs/. Cleared and repopulated on every run.
QEMU_SMOKE_LOGS_DIR="$REPO_ROOT/.cache/qemu_smoke_logs"

DO_BUILD=1
REBUILD_ROOTFS=0
PYTEST_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build) DO_BUILD=0; shift ;;
        --rebuild-rootfs) REBUILD_ROOTFS=1; shift ;;
        -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
        --) shift; while [ "$#" -gt 0 ]; do PYTEST_ARGS+=("$1"); shift; done ;;
        *) PYTEST_ARGS+=("$1"); shift ;;
    esac
done

if [ "${#PYTEST_ARGS[@]}" -eq 0 ]; then
    # Core target tests plus the tcc suites. The tcc tests are expected to FAIL
    # for now (known tinycc miscompiles + a serial-upload corruption on QEMU);
    # they are enabled here so they run as fixes land. Override by passing files.
    PYTEST_ARGS=(cd_test.py ls_test.py ps_test.py shell_test.py tcc_test.py tcc_suite_test.py)
fi

if [ "$DO_BUILD" -eq 1 ]; then
    echo ">> Configuring: $DEFCONFIG"
    zig build defconfig -Ddefconfig_file="$DEFCONFIG"

    if [ ! -f "$REPO_ROOT/rootfs.img" ] || [ "$REBUILD_ROOTFS" -eq 1 ]; then
        echo ">> Building rootfs.img"
        # --no-kernel: this script runs its own `zig build` below, so skip
        # build_rootfs's built-in kernel rebuild to avoid a redundant build.
        ./build_rootfs.sh -c -o rootfs.img --no-kernel
    else
        echo ">> Reusing existing rootfs.img (pass --rebuild-rootfs to regenerate)"
    fi

    echo ">> Building kernel: -Doptimize=$OPTIMIZE"
    zig build -Doptimize="$OPTIMIZE"
fi

if [ ! -f "$KERNEL" ]; then
    echo "error: kernel ELF not found: $KERNEL" >&2
    echo "       build it first (omit --no-build)." >&2
    exit 1
fi

# Minimal venv: QEMU mode needs only pyserial + pytest (no pyudev/pyocd).
if [ ! -x "$VENV/bin/python" ]; then
    echo ">> Creating venv: $VENV"
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --disable-pip-version-check \
    pyserial==3.5 pytest==8.4.0 pytest-rerunfailures==14.0 pytest-xdist==3.8.0

# GCC torture smoke tests run by default; pass YASOS_SMOKE_ENABLE_GCC_TORTURE=0
# to skip them. The test sources live in the gcc-testsuite submodule nested
# inside libs/tinycc — fetch it (shallow) on first use. A user-provided
# GCC_TORTURE_PATH points at an external checkout, so no fetch is needed then.
# Exercise all optimization levels under QEMU by default. This iterates every
# suite (tests2, ir_tests, gcc-torture) at -O0/-O1/-O2 — tests2/ir_tests ids get
# tagged [-ON] when more than one level is configured. Override with a custom
# list (space/comma separated), e.g. YASOS_SMOKE_TCC_OPT_LEVELS="-O0".
export YASOS_SMOKE_TCC_OPT_LEVELS="${YASOS_SMOKE_TCC_OPT_LEVELS:--O0 -O1 -O2}"

export YASOS_SMOKE_ENABLE_GCC_TORTURE="${YASOS_SMOKE_ENABLE_GCC_TORTURE:-1}"
case "$YASOS_SMOKE_ENABLE_GCC_TORTURE" in
    1|true|yes|on)
        GCC_TORTURE_DIR="$REPO_ROOT/libs/tinycc/tests/gcctestsuite/gcc-testsuite/gcc/testsuite/gcc.c-torture"
        if [ -z "${GCC_TORTURE_PATH:-}" ] && [ ! -d "$GCC_TORTURE_DIR" ]; then
            echo ">> Fetching gcc-testsuite submodule (first run, shallow clone)"
            git -C "$REPO_ROOT/libs/tinycc" submodule update --init --depth 1 \
                tests/gcctestsuite/gcc-testsuite
        fi
        ;;
esac

# Run one QEMU per pytest-xdist worker in parallel by default, using all
# available CPUs. Override the worker count by passing your own -n (e.g. -n 4),
# or disable parallelism with -n 0 / YASOS_SMOKE_XDIST=0.
XDIST_DEFAULT="${YASOS_SMOKE_XDIST:-auto}"
have_n=0
for arg in "${PYTEST_ARGS[@]}"; do
    case "$arg" in
        -n|-n[0-9]*|-nauto|-nlogical|--numprocesses|--numprocesses=*) have_n=1; break ;;
    esac
done
if [ "$have_n" -eq 0 ] && [ "$XDIST_DEFAULT" != "0" ]; then
    PYTEST_ARGS+=(-n "$XDIST_DEFAULT")
fi

export YASOS_QEMU_KERNEL="$KERNEL"
echo ">> Running smoke tests on QEMU ($(basename "$KERNEL"))"
cd "$SMOKE_DIR"

# Start each run with an empty logs dir so the collected set reflects only this
# run (mirrors the remote runner clearing the device's logs/ before a run).
rm -rf "$SMOKE_DIR/logs"

# Don't let a non-zero pytest exit (expected while tcc tests fail) abort the
# script before logs are collected.
set +e
"$VENV/bin/python" -m pytest -s "${PYTEST_ARGS[@]}"
status=$?
set -e

# Collect this run's logs (per-test session logs, logs/failed/, and the qemu
# process logs) into .cache/qemu_smoke_logs/ — the local analogue of the remote
# runner's .cache/remote_smoke_logs/.
if [ -d "$SMOKE_DIR/logs" ]; then
    rm -rf "$QEMU_SMOKE_LOGS_DIR"
    mkdir -p "$QEMU_SMOKE_LOGS_DIR"
    cp -a "$SMOKE_DIR/logs/." "$QEMU_SMOKE_LOGS_DIR/"
    echo ">> Collected smoke logs in ${QEMU_SMOKE_LOGS_DIR#"$REPO_ROOT"/}"
    if [ -d "$QEMU_SMOKE_LOGS_DIR/failed" ]; then
        echo ">> Failed-test logs in ${QEMU_SMOKE_LOGS_DIR#"$REPO_ROOT"/}/failed"
    fi
fi

exit "$status"
