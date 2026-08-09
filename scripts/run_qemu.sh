#!/bin/sh
#
# run_qemu.sh — boot the yasos.zig kernel on QEMU's mps2-an505 (Cortex-M33).
#
# Usage: scripts/run_qemu.sh [--debug] [path/to/kernel.elf] [extra qemu args...]
#   With NO ELF argument the script first (re)builds the userspace rootfs image
#   and then the kernel that embeds it, so the run always reflects the current
#   sources, before booting zig-out/bin/yasos_kernel.
#   Pass an explicit ELF path to skip the build and boot that image as-is.
#
#   The kernel is built -Doptimize=ReleaseFast by default (matches the smoke
#   suite). Pass --debug as the first argument for a Debug build instead, or
#   set YASOS_QEMU_OPTIMIZE to any zig optimize mode.
#
# To skip the rootfs/kernel rebuild set RUN_QEMU_SKIP_BUILD=1.
#
# Before building, the script selects the QEMU board defconfig so the produced
# kernel actually matches the mps2-an505 machine below. Without this the build
# uses whatever board is currently configured (e.g. a real RP2350 / pimoroni
# board), and QEMU then faults at boot:
#   qemu: fatal: Lockup: can't escalate 3 to HardFault (current priority -1)
# Override the defconfig with QEMU_DEFCONFIG=... ; with RUN_QEMU_SKIP_BUILD=1
# no rebuild (and no reconfigure) happens and the existing ELF is booted as-is.
#
# UART0 is wired to stdio. Quit QEMU with Ctrl-A x.
#
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEFCONFIG="${QEMU_DEFCONFIG:-configs/qemu_mps2_an505_defconfig}"

# Kernel build optimize mode. Defaults to ReleaseFast so the QEMU run matches the
# smoke suite (scripts/run_qemu_smoke.sh); a leading --debug selects Debug.
OPTIMIZE="${YASOS_QEMU_OPTIMIZE:-ReleaseFast}"
if [ "${1:-}" = "--debug" ]; then
    OPTIMIZE="Debug"
    shift
fi

ELF=""
if [ "$#" -gt 0 ]; then
    ELF="$1"
    shift
fi

if [ -z "$ELF" ]; then
    if [ "${RUN_QEMU_SKIP_BUILD:-0}" = "1" ]; then
        echo "RUN_QEMU_SKIP_BUILD=1 set, skipping rootfs/kernel build."
    else
        # Select the QEMU board before anything is built, so the rootfs's kernel
        # rebuild and the `zig build` below both target mps2-an505. Skipping this
        # leaves a previously-configured board (e.g. pimoroni_pico_plus2) active
        # and QEMU locks up at boot.
        echo "==> Selecting QEMU board defconfig ($DEFCONFIG)..."
        ( cd "$REPO_ROOT" && zig build defconfig -Ddefconfig_file="$DEFCONFIG" )
        # Build userspace first: rootfs.img is embedded into the kernel ELF via
        # `.incbin "rootfs.img"`, so it has to exist (and be current) before the
        # kernel is built. --no-kernel skips build_rootfs's own kernel rebuild so
        # we don't build the kernel twice at conflicting optimize levels; the
        # `zig build -Doptimize=...` below re-embeds the fresh image at the level
        # we actually want. build_rootfs.sh aborts on any tool-build failure, and
        # `set -e` makes that abort us too, so we never boot a stale image.
        echo "==> Building rootfs image (build_rootfs.sh --no-kernel -o rootfs.img)..."
        ( cd "$REPO_ROOT" && ./build_rootfs.sh --no-kernel -o rootfs.img )
        echo "==> Building kernel (zig build -Doptimize=$OPTIMIZE)..."
        ( cd "$REPO_ROOT" && zig build -Doptimize="$OPTIMIZE" )
    fi
    ELF="$REPO_ROOT/zig-out/bin/yasos_kernel"
fi

if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    echo "build it with: zig build (after selecting the qemu_mps2_an505 defconfig)" >&2
    exit 1
fi

# Any remaining args ("$@") are forwarded to QEMU (e.g. -d int,guest_errors).
exec qemu-system-arm \
    -machine mps2-an505 \
    -cpu cortex-m33 \
    -nographic \
    -semihosting-config enable=on,target=native \
    -serial mon:stdio \
    -kernel "$ELF" \
    "$@"
