#!/bin/sh 

echo "Building kernel with defconfig: $1"

SCRIPT_DIR=$(dirname "$0")
zig build defconfig -Ddefconfig_file=$SCRIPT_DIR/configs/$1

if [ $? -ne 0 ]; then
    echo "Failed to configure project. Please check configuration output."
    exit 1
fi
# ReleaseSafe by default so the image the board runs carries the same safety
# checks (overflow, bounds, null-unwrap) as the QEMU gate — otherwise the two
# CI legs exercise different kernels and a safety-check regression can only ever
# be caught by one of them. Override with YASOS_KERNEL_OPTIMIZE for a size- or
# speed-sensitive build.
#
# Exported, not just local: build_rootfs.sh below re-embeds rootfs.img and
# rebuilds the kernel itself, and it reads the same variable. Without the export
# it would fall back to its own default and quietly replace the kernel built
# here with one at a different optimize level — the packaged ELF would not be
# the one this line asked for.
export KERNEL_OPTIMIZE="${YASOS_KERNEL_OPTIMIZE:-ReleaseSafe}"
export YASOS_KERNEL_OPTIMIZE="$KERNEL_OPTIMIZE"
echo "Building kernel with -Doptimize=$KERNEL_OPTIMIZE"
zig build -Doptimize="$KERNEL_OPTIMIZE"
if [ $? -ne 0 ]; then
    echo "Failed to build project. Please check build output."
    exit 1
fi

echo "Kernel build completed successfully."

echo "Building root filesystem..."
./build_rootfs.sh -c -o rootfs.img
if [ $? -ne 0 ]; then
    echo "Failed to build root filesystem. Please check build_rootfs.sh output."
    exit 1
fi
echo "Root filesystem build completed successfully."

echo "Creating package..."
rm -rf $SCRIPT_DIR/output/target_package/
mkdir -p $SCRIPT_DIR/output/target_package

PACKAGE_VERSION=$(git describe --tags --always)
PACKAGE_NAME="${1%_defconfig}_${PACKAGE_VERSION}"

mkdir -p $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}

cp $SCRIPT_DIR/zig-out/bin/yasos_kernel $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/
cp $SCRIPT_DIR/rootfs.img $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/
# yaff_arch_test.py needs one unpacked YAFF executable to corrupt and re-upload;
# rootfs/ is a build product, so a board runner that only unpacks this package
# has no other copy of it. Ships from the same build as rootfs.img, so the donor
# always matches the flashed image.
mkdir -p $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/rootfs/usr/bin
cp $SCRIPT_DIR/rootfs/usr/bin/hello $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/rootfs/usr/bin/
cp $SCRIPT_DIR/scripts/flash_rp2350_image.cfg $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/flash_rp2350.cfg
cp $SCRIPT_DIR/scripts/flash_kernel_rp2350_image.cfg $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/flash_kernel_rp2350.cfg
cp $SCRIPT_DIR/scripts/run_hw_smoke.sh $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/

# Bundle the symbol-bearing ELFs so on-device HardFault stacktraces can be
# decoded later (kernel + rootfs.img are already at the package top level).
$SCRIPT_DIR/scripts/collect_decode_bundle.sh \
    $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/decode_bundle --symbols-only

tar -czvf ${PACKAGE_NAME}.tar.gz -C $SCRIPT_DIR/output/target_package .
mv ${PACKAGE_NAME}.tar.gz $SCRIPT_DIR/output/
echo "Packaging completed successfully."
