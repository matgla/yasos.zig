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
export YASOS_SMOKE_TCC_OPT_LEVELS="${YASOS_SMOKE_TCC_OPT_LEVELS:--O0 -O1 -O2}"
export YASOS_SMOKE_ENABLE_GCC_TORTURE="${YASOS_SMOKE_ENABLE_GCC_TORTURE:-1}"

# Point the in-test reset/reflash recovery (session.py -> reflash_target.sh) at
# the same prebuilt binaries so a mid-run board recovery also avoids a rebuild.
export YASOS_SMOKE_REMOTE_KERNEL="$KERNEL"
export YASOS_SMOKE_REMOTE_ROOTFS="$ROOTFS"
export YASOS_SMOKE_ROOTFS_ADDRESS="$ROOTFS_ADDR"

# gcc-torture sources live in a submodule nested under libs/tinycc; CI fetches it
# via the recursive checkout, but fetch it here too (shallow, idempotent) so a
# manual run outside CI still works. Mirrors scripts/run_qemu_smoke.sh.
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

echo ">> Running on-device smoke suite (opt levels: $YASOS_SMOKE_TCC_OPT_LEVELS, gcc-torture: $YASOS_SMOKE_ENABLE_GCC_TORTURE)"
# Forward SERIAL_DEVICE as run_tests.sh's positional arg; empty => auto-detect.
exec ./tests/smoke/run_tests.sh "${SERIAL_DEVICE:-}"
