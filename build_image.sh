#!/bin/bash
# Build the board packages: one rootfs, then a kernel and a package per board.
#
#   ./build_image.sh <defconfig> [<defconfig>...]
#
# e.g. ./build_image.sh pimoroni_pico_plus2_and_vga_defconfig mspc_defconfig
#
# On RP2350 the kernel does not embed the romfs (it is flashed on its own at
# 0x10120000, scripts/flash_rp2350_image.cfg), and build_rootfs.sh reads only
# a few config.json keys (rootfs_key below), so boards that agree on those can
# share one rootfs.img.  The rootfs is built for the first defconfig; a later
# board whose keys differ stops the build instead of getting a rootfs built for
# another configuration.  Each package is output/<board>_<version>.tar.gz with
# that board's kernel and the shared rootfs.img.

if [ $# -lt 1 ]; then
    echo "usage: $0 <defconfig> [<defconfig>...]"
    exit 1
fi

SCRIPT_DIR=$(dirname "$0")

# The config.json values build_rootfs.sh reads: the CPU (zig left out, romfs
# size check), the userspace FP mode and the FP runtime linkage.
rootfs_key() {
    python3 - "$SCRIPT_DIR/config/target/config.json" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
# The applications menu (apps/Kconfig, CONFIG_APP_*) decides what goes in too.
keys = ["cpu", "build_userspace_hardware_fp",
        "build_userspace_fp_mfpu", "build_userspace_fp_shared"]
keys += sorted(k for k in c if k.startswith("app_"))
print(" ".join("%s=%s" % (k, c.get(k)) for k in keys))
PYEOF
}

configure() {
    echo "Configuring with defconfig: $1"
    if ! zig build defconfig -Ddefconfig_file="$SCRIPT_DIR/configs/$1"; then
        echo "Failed to configure project. Please check configuration output."
        exit 1
    fi
}

# ReleaseSafe by default so the image the board runs carries the same safety
# checks (overflow, bounds, null-unwrap) as the QEMU gate — otherwise the two
# CI legs exercise different kernels and a safety-check regression can only ever
# be caught by one of them. Override with YASOS_KERNEL_OPTIMIZE for a size- or
# speed-sensitive build.
export KERNEL_OPTIMIZE="${YASOS_KERNEL_OPTIMIZE:-ReleaseSafe}"
export YASOS_KERNEL_OPTIMIZE="$KERNEL_OPTIMIZE"

configure "$1"
ROOTFS_KEY=$(rootfs_key)

# Root filesystem first, kernel second -- the same order as
# scripts/run_qemu_smoke.sh. The kernel is compiled by the cross tcc by default
# (build.zig -Dkernel_cc=tcc), and build_rootfs.sh is what builds that cross
# (libs/tinycc/bin/armv8m-tcc), so a kernel build before it fails at configure
# time on a fresh checkout with MissingCrossTcc. The kernel also .incbin's
# rootfs.img on the QEMU boards, so building it first only produced a kernel
# the rootfs step then had to rebuild anyway. --no-kernel: the kernel is built
# below, where a failure stops the package instead of being one of
# build_rootfs.sh's skips.
# YASOS_IMAGE_ZIG=<zig fork source>: the device Zig compiler goes into the image too
# (build_rootfs.sh --zig; apps/zig/fetch_fork.sh fetches the pinned fork), for the
# releases and the board jobs that build the kernel on the board. CONFIG_APP_ZIG
# does the same from the configuration.
ZIG_ARGS=""
if [ -n "${YASOS_IMAGE_ZIG:-}" ]; then
    ZIG_ARGS="--zig $YASOS_IMAGE_ZIG"
fi
echo "Building root filesystem ($ROOTFS_KEY)..."
./build_rootfs.sh -c -o rootfs.img --no-kernel $ZIG_ARGS
if [ $? -ne 0 ]; then
    echo "Failed to build root filesystem. Please check build_rootfs.sh output."
    exit 1
fi
echo "Root filesystem build completed successfully."

PACKAGE_VERSION=$(git describe --tags --always)
first=1
for defconfig in "$@"; do
    if [ $first -eq 0 ]; then
        configure "$defconfig"
        key=$(rootfs_key)
        if [ "$key" != "$ROOTFS_KEY" ]; then
            echo "ERROR: $defconfig needs a different rootfs than $1:"
            echo "       $1: $ROOTFS_KEY"
            echo "       $defconfig: $key"
            echo "       Build it in a separate ./build_image.sh run."
            exit 1
        fi
    fi
    first=0

    echo "Building kernel for $defconfig with -Doptimize=$KERNEL_OPTIMIZE"
    if ! zig build -Doptimize="$KERNEL_OPTIMIZE"; then
        echo "Failed to build project. Please check build output."
        exit 1
    fi
    echo "Kernel build completed successfully."

    PACKAGE_NAME="${defconfig%_defconfig}_${PACKAGE_VERSION}"
    STAGE="$SCRIPT_DIR/output/target_package/${PACKAGE_NAME}"
    echo "Creating package $PACKAGE_NAME..."
    rm -rf "$SCRIPT_DIR/output/target_package/"
    mkdir -p "$STAGE"

    cp $SCRIPT_DIR/zig-out/bin/yasos_kernel "$STAGE/"
    cp $SCRIPT_DIR/rootfs.img "$STAGE/"
    # yaff_arch_test.py needs one unpacked YAFF executable to corrupt and re-upload;
    # rootfs/ is a build product, so a board runner that only unpacks this package
    # has no other copy of it. Ships from the same build as rootfs.img, so the donor
    # always matches the flashed image. CONFIG_APP_HELLO_WORLD=n leaves it out of
    # the image and of the package.
    if [ -f $SCRIPT_DIR/rootfs/usr/bin/hello ]; then
        mkdir -p "$STAGE/rootfs/usr/bin"
        cp $SCRIPT_DIR/rootfs/usr/bin/hello "$STAGE/rootfs/usr/bin/"
    fi
    # The device Zig compiler (CONFIG_APP_ZIG, YASOS_IMAGE_ZIG) reads its lib from
    # the SD card, not the romfs: sdcard/var/lib/zig goes to /var/lib/zig on the
    # card (scripts/zig_board.py push does it on the rig). sdcard/ outlives a build
    # without zig, so it ships only with the compiler it belongs to.
    if [ -f $SCRIPT_DIR/rootfs/usr/bin/zig ] && [ -d $SCRIPT_DIR/sdcard/var/lib/zig ]; then
        mkdir -p "$STAGE/sdcard/var/lib"
        cp -r $SCRIPT_DIR/sdcard/var/lib/zig "$STAGE/sdcard/var/lib/"
    fi
    cp $SCRIPT_DIR/scripts/flash_rp2350_image.cfg "$STAGE/flash_rp2350.cfg"
    cp $SCRIPT_DIR/scripts/flash_kernel_rp2350_image.cfg "$STAGE/flash_kernel_rp2350.cfg"
    cp $SCRIPT_DIR/scripts/run_hw_smoke.sh "$STAGE/"

    # Bundle the symbol-bearing ELFs so on-device HardFault stacktraces can be
    # decoded later (kernel + rootfs.img are already at the package top level).
    $SCRIPT_DIR/scripts/collect_decode_bundle.sh "$STAGE/decode_bundle" --symbols-only

    tar -czvf ${PACKAGE_NAME}.tar.gz -C $SCRIPT_DIR/output/target_package .
    mv ${PACKAGE_NAME}.tar.gz $SCRIPT_DIR/output/
    echo "Packaging $PACKAGE_NAME completed successfully."
done
