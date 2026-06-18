#!/bin/sh
#
# run_qemu.sh — boot the yasos.zig kernel on QEMU's mps2-an505 (Cortex-M33).
#
# Usage: scripts/run_qemu.sh [path/to/kernel.elf] [extra qemu args...]
#   With NO ELF argument the script first (re)builds the userspace rootfs image
#   and then the kernel that embeds it, so the run always reflects the current
#   sources, before booting zig-out/bin/yasos_kernel.
#   Pass an explicit ELF path to skip the build and boot that image as-is.
#
# To skip the rootfs/kernel rebuild set RUN_QEMU_SKIP_BUILD=1.
#
# The kernel must already be configured for the QEMU board, e.g.:
#   zig build defconfig -Ddefconfig_file=configs/qemu_mps2_an505_defconfig
#
# UART0 is wired to stdio. Quit QEMU with Ctrl-A x.
#
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

ELF=""
if [ "$#" -gt 0 ]; then
    ELF="$1"
    shift
fi

if [ -z "$ELF" ]; then
    if [ "${RUN_QEMU_SKIP_BUILD:-0}" = "1" ]; then
        echo "RUN_QEMU_SKIP_BUILD=1 set, skipping rootfs/kernel build."
    else
        # Build userspace first: rootfs.img is embedded into the kernel ELF via
        # `.incbin "rootfs.img"`, so it has to exist (and be current) before the
        # kernel is built. zig build then re-embeds the fresh image. build_rootfs.sh
        # aborts on any tool-build failure, and `set -e` makes that abort us too,
        # so we never boot a stale/half-built image.
        echo "==> Building rootfs image (build_rootfs.sh -o rootfs.img)..."
        ( cd "$REPO_ROOT" && ./build_rootfs.sh -o rootfs.img )
        echo "==> Building kernel (zig build)..."
        ( cd "$REPO_ROOT" && zig build )
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
