#!/bin/sh
#
# run_qemu_fb.sh — boot yasos on QEMU with an interactive framebuffer window.
#
# Same as run_qemu.sh, plus:
#   - guest RAM is backed by a host file (`memory-backend-file,share=on`), so
#     the `fbdev` window from linker_script.ld is a fixed slice of that file;
#   - scripts/fbview.py mmaps that slice and puts it in an SDL window, feeding
#     keyboard/mouse back to the guest through a ring buffer in the same window.
#
# No QEMU device model and no QEMU fork: the guest stores pixels to memory and
# the viewer reads that memory. See scripts/fbview.py for the layout.
#
# UART0 stays on stdio, so the shell is in this terminal and the graphics are in
# the window. Quit QEMU with Ctrl-A x; quit just the viewer with Ctrl-Q.
#
# Usage: scripts/run_qemu_fb.sh [--debug] [extra qemu args...]
#   RUN_QEMU_SKIP_BUILD=1   boot the existing ELF, no rebuild
#   FBVIEW_SCALE=n          viewer upscale factor (default 2)
#   YASOS_FB_BACKING=path   RAM backing file (default /tmp/yasos_fb_ram.bin)
#   FBVIEW_PYTHON=path      python with pygame (default .fbview_venv/bin/python)
#
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEFCONFIG="${QEMU_DEFCONFIG:-configs/qemu_mps2_an505_defconfig}"
BACKING="${YASOS_FB_BACKING:-/tmp/yasos_fb_ram.bin}"
RAM_MB=16
FBVIEW_PYTHON="${FBVIEW_PYTHON:-$REPO_ROOT/.fbview_venv/bin/python}"
FBVIEW_SCALE="${FBVIEW_SCALE:-2}"

OPTIMIZE="${YASOS_QEMU_OPTIMIZE:-ReleaseFast}"
if [ "${1:-}" = "--debug" ]; then
    OPTIMIZE="Debug"
    shift
fi

if [ "${RUN_QEMU_SKIP_BUILD:-0}" = "1" ]; then
    echo "RUN_QEMU_SKIP_BUILD=1 set, skipping rootfs/kernel build."
else
    echo "==> Selecting QEMU board defconfig ($DEFCONFIG)..."
    ( cd "$REPO_ROOT" && zig build defconfig -Ddefconfig_file="$DEFCONFIG" )
    echo "==> Building rootfs image..."
    ( cd "$REPO_ROOT" && ./build_rootfs.sh --no-kernel -o rootfs.img )
    echo "==> Building kernel (zig build -Doptimize=$OPTIMIZE)..."
    ( cd "$REPO_ROOT" && zig build -Doptimize="$OPTIMIZE" )
fi

ELF="$REPO_ROOT/zig-out/bin/yasos_kernel"
if [ ! -f "$ELF" ]; then
    echo "error: kernel ELF not found: $ELF" >&2
    exit 1
fi

if [ ! -x "$FBVIEW_PYTHON" ]; then
    echo "error: no python with pygame at $FBVIEW_PYTHON" >&2
    echo "create one with:" >&2
    echo "  python3 -m venv .fbview_venv && .fbview_venv/bin/pip install pygame-ce" >&2
    exit 1
fi

# Fresh, zeroed backing file. Zeroed matters: the fbdev window is not a LOADed
# section, so a stale file would leave a bogus header for the viewer to parse
# until the guest driver rewrites it.
rm -f "$BACKING"
truncate -s "${RAM_MB}M" "$BACKING"
echo "==> RAM backing file: $BACKING (${RAM_MB}M)"

# Start the viewer first so it is already polling when the guest sets a mode.
"$FBVIEW_PYTHON" "$REPO_ROOT/scripts/fbview.py" "$BACKING" --scale "$FBVIEW_SCALE" &
VIEWER_PID=$!
trap 'kill "$VIEWER_PID" 2>/dev/null || true' EXIT INT TERM

echo "==> Booting (Ctrl-A x to quit qemu, Ctrl-Q to close the viewer)"
qemu-system-arm \
    -machine mps2-an505,memory-backend=mem0 \
    -object "memory-backend-file,id=mem0,size=${RAM_MB}M,mem-path=$BACKING,share=on" \
    -cpu cortex-m33 \
    -display none \
    -semihosting-config enable=on,target=native \
    -serial mon:stdio \
    -kernel "$ELF" \
    "$@"
