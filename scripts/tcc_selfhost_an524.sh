#!/bin/sh
#
# tcc_selfhost_an524.sh -- the QEMU self-host fixpoint (scripts/tcc_selfhost.py
# --qemu) run against a private mps3-an524 build, so it works whatever board the
# shared tree is configured for.
#
# Usage: scripts/tcc_selfhost_an524.sh [tcc_selfhost.py args...]
#   YASOS_SELFHOST_TREE  private copy (default: .cache/selfhost_an524)
#   PYTHON               interpreter with pyserial (default: python3)
#
# Why a private copy: tcc_selfhost.py --qemu needs an an524 kernel
# (zig-out/bin/yasos_kernel) and the build_rootfs.sh-configured cross
# (libs/tinycc/bin/armv8m-tcc, rootfs crt/lib paths).  The shared tree is
# often a board build (rp2350 kernel: QEMU locks up at reset; rp2350/static
# rootfs: the loader refuses it on an524) and `make cross` in libs/tinycc
# replaces bin/armv8m-tcc with a test-configured cross that links against the
# host's /usr/lib.  Rebuilding all of that in place would clobber the board
# build, so the working tree (uncommitted edits included, .git and build
# caches left behind) is copied and built for an524 there.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TREE=${YASOS_SELFHOST_TREE:-$ROOT/.cache/selfhost_an524}
PYTHON=${PYTHON:-python3}

if ! "$PYTHON" -c 'import serial' 2>/dev/null; then
    echo "tcc_selfhost_an524: $PYTHON has no pyserial (pip install pyserial)" >&2
    exit 2
fi

echo ">> private an524 tree: $TREE"
mkdir -p "$TREE"
rsync -a --delete --exclude='.git' --exclude='/.cache' --exclude='/.zig-cache' \
    --exclude='/zig-out' "$ROOT/" "$TREE/"

cd "$TREE"
echo ">> configure for qemu_mps3_an524"
zig build defconfig -Ddefconfig_file=configs/qemu_mps3_an524_defconfig
# The copied stamps describe the shared tree's build; rebuild everything here.
rm -f libs/tinycc/.yasos-build/*.stamp
echo ">> build rootfs (cross, native tcc, userspace)"
./build_rootfs.sh -c -o rootfs.img --no-kernel > build_rootfs.log 2>&1 || {
    tail -40 build_rootfs.log >&2
    echo "tcc_selfhost_an524: build_rootfs.sh failed, see $TREE/build_rootfs.log" >&2
    exit 1
}
echo ">> build kernel"
zig build -Doptimize=ReleaseSafe

echo ">> self-host fixpoint"
exec "$PYTHON" scripts/tcc_selfhost.py --qemu "$@"
