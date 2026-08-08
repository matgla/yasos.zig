#!/bin/bash
#
# run_hw_smoke.sh — flash a *prebuilt* yasos.zig image (kernel + rootfs) onto the
# RP2350 board and run the on-device smoke suite, WITHOUT rebuilding anything.
#
# This is the "script to run" that ships in the release/smoke package alongside
# the rootfs + kernel. CI's build_hw job builds those binaries once in the cloud;
# the hardware_smoke job stages them to the canonical repo paths
# (zig-out/bin/yasos_kernel + ./rootfs.img) and calls this script — so the board
# runner never runs `zig build` / build_rootfs.sh (no host recompilation).
#
# Run it from a repo checkout, inside the toolchain container (openocd + python +
# the debug-probe USB passthrough), e.g. via `make run_smoke_tests_packaged`.
# The flash + serial paths reuse the existing configs (flash_rp2350.cfg,
# reset_target.sh, reflash_target.sh), so the staged paths above are required.
#
# Usage:
#   scripts/run_hw_smoke.sh [--opt-levels LEVELS] [--no-gcc-torture]
#
# Options:
#   --opt-levels LEVELS   tcc -O levels the smoke suites run at (default
#                         "-O0 -O1 -O2"). Every suite -- tests2, ir_tests and
#                         gcc-torture -- runs once per level, so a single level
#                         is roughly a third of the wall time. Space- or
#                         comma-separated; use the comma form when the value has
#                         to survive `make`/run_container.sh word splitting, e.g.
#                         --opt-levels -O0,-O2. Overrides YASOS_SMOKE_TCC_OPT_LEVELS.
#   --no-gcc-torture      Skip the gcc-torture suites on device.
#   -h, --help            Show this help.
#
# Env (with defaults):
#   YASOS_SMOKE_TCC_OPT_LEVELS       tcc -O levels to exercise (default "-O0 -O1 -O2")
#   YASOS_SMOKE_ENABLE_GCC_TORTURE   run gcc-torture on device (default 1)
#   YASOS_SMOKE_ROOTFS_ADDRESS       rootfs flash address     (default 0x10100000)
#   SERIAL_DEVICE                    debug-probe tty          (default: auto-detect)
#   GCC_TORTURE_PATH                 external gcc-torture checkout (skips submodule fetch)
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

OPT_LEVELS="${YASOS_SMOKE_TCC_OPT_LEVELS:-}"
ENABLE_GCC_TORTURE="${YASOS_SMOKE_ENABLE_GCC_TORTURE:-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --opt-levels)
            [ "$#" -ge 2 ] || { echo "error: --opt-levels needs a value" >&2; exit 2; }
            OPT_LEVELS="$2"; shift 2
            # run_container.sh expands its --command unquoted, so a
            # space-separated value arrives here as several arguments. Absorb
            # the rest rather than choking on the second level.
            while [ "$#" -gt 0 ] && [ "${1#-O}" != "$1" ]; do
                OPT_LEVELS="$OPT_LEVELS $1"; shift
            done ;;
        --opt-levels=*) OPT_LEVELS="${1#*=}"; shift ;;
        --no-gcc-torture) ENABLE_GCC_TORTURE=0; shift ;;
        -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Accept the comma form (the one that survives run_container.sh's unquoted
# command expansion) and report it the way the suites will read it.
OPT_LEVELS="${OPT_LEVELS//,/ }"

KERNEL="$REPO_ROOT/zig-out/bin/yasos_kernel"
ROOTFS="$REPO_ROOT/rootfs.img"
ROOTFS_ADDR="${YASOS_SMOKE_ROOTFS_ADDRESS:-0x10100000}"

for artifact in "$KERNEL" "$ROOTFS"; do
    if [ ! -f "$artifact" ]; then
        echo "error: prebuilt artifact missing: $artifact" >&2
        echo "       stage the build_hw package first (kernel ->" >&2
        echo "       zig-out/bin/yasos_kernel, rootfs.img -> repo root)." >&2
        exit 1
    fi
done

rescue_dp() {
    # Clear QSPI Quad I/O / double-fault lockup left by a prior run before
    # programming (same rescue the reset/reflash paths use).
    openocd -f interface/cmsis-dap.cfg -f target/rp2350-rescue.cfg \
        -c "adapter speed 5000" -c "init" -c "exit" 2>/dev/null || true
    sleep 1
}

# flash_rp2350.cfg programs rootfs.img @ 0x10100000 + zig-out/bin/yasos_kernel
# relative to cwd (= REPO_ROOT). A board left wedged by a prior run can refuse the
# first program; rescue the DP and retry once before giving up.
echo ">> Flashing prebuilt image (no rebuild): $(basename "$ROOTFS") @ $ROOTFS_ADDR + $(basename "$KERNEL")"
if ! openocd -f flash_rp2350.cfg; then
    echo ">> Initial flash failed; rescuing DP and retrying once" >&2
    rescue_dp
    openocd -f flash_rp2350.cfg
fi

# Match the QEMU gate's coverage on real silicon: all -O levels + gcc-torture.
export YASOS_SMOKE_TCC_OPT_LEVELS="${OPT_LEVELS:--O0 -O1 -O2}"
export YASOS_SMOKE_ENABLE_GCC_TORTURE="${ENABLE_GCC_TORTURE:-1}"

# Point the in-test reset/reflash recovery (session.py -> reflash_target.sh) at
# the same prebuilt binaries so a mid-run board recovery also avoids a rebuild.
export YASOS_SMOKE_REMOTE_KERNEL="$KERNEL"
export YASOS_SMOKE_REMOTE_ROOTFS="$ROOTFS"
export YASOS_SMOKE_ROOTFS_ADDRESS="$ROOTFS_ADDR"

# gcc-torture sources live in a submodule nested under libs/tinycc that points
# at the whole gcc repo. Fetch only gcc.c-torture sparsely (~16 MB, idempotent)
# via download_gcc_tests.sh so a manual run outside CI still works without the
# ~1.3 GB full submodule clone. Mirrors scripts/run_qemu_smoke.sh.
case "$YASOS_SMOKE_ENABLE_GCC_TORTURE" in
    1|true|yes|on)
        GCC_TORTURE_DIR="$REPO_ROOT/libs/tinycc/tests/gcctestsuite/gcc-testsuite/gcc/testsuite/gcc.c-torture"
        if [ -z "${GCC_TORTURE_PATH:-}" ] && [ ! -d "$GCC_TORTURE_DIR" ]; then
            echo ">> Fetching gcc-torture tests (sparse + partial, ~16 MB)"
            bash "$REPO_ROOT/libs/tinycc/tests/gcctestsuite/download_gcc_tests.sh"
        fi
        ;;
esac

echo ">> Running on-device smoke suite (opt levels: $YASOS_SMOKE_TCC_OPT_LEVELS, gcc-torture: $YASOS_SMOKE_ENABLE_GCC_TORTURE)"
# Forward SERIAL_DEVICE as run_tests.sh's positional arg; empty => auto-detect.
exec ./tests/smoke/run_tests.sh "${SERIAL_DEVICE:-}"
