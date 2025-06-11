#!/bin/sh
#
# run_qemu.sh — boot the yasos.zig kernel on QEMU's mps2-an505 (Cortex-M33).
#
# Usage: scripts/run_qemu.sh [path/to/kernel.elf]
#   Defaults to zig-out/bin/yasos_kernel.
#
# Build first with the QEMU target:
#   ./build_rootfs.sh && ./build_image.sh        # (re)generate rootfs.img
#   zig build defconfig -Ddefconfig_file=configs/qemu_mps2_an505_defconfig
#   zig build
#
# UART0 is wired to stdio. Quit QEMU with Ctrl-A x.
#
set -eu

ELF="zig-out/bin/yasos_kernel"
if [ "$#" -gt 0 ]; then
    ELF="$1"
    shift
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
