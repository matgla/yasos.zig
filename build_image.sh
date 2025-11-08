#!/bin/sh 

echo "Building kernel with defconfig: $1"

SCRIPT_DIR=$(dirname "$0")
zig build defconfig -Ddefconfig_file=$SCRIPT_DIR/configs/$1

if [ $? -ne 0 ]; then
    echo "Failed to configure project. Please check configuration output."
    exit 1
fi
zig build -Doptimize=ReleaseFast
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

git config --global --add safe.directory .
PACKAGE_VERSION=$(git describe --tags --always)
PACKAGE_NAME="${1%_defconfig}_${PACKAGE_VERSION}"

mkdir -p $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}

cp $SCRIPT_DIR/zig-out/bin/yasos_kernel $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/
cp $SCRIPT_DIR/rootfs.img $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/
cp $SCRIPT_DIR/scripts/flash_rp2350_image.cfg $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/flash_rp2350.cfg
cp $SCRIPT_DIR/scripts/flash_kernel_rp2350_image.cfg $SCRIPT_DIR/output/target_package/${PACKAGE_NAME}/flash_kernel_rp2350.cfg

tar -czvf ${PACKAGE_NAME}.tar.gz -C $SCRIPT_DIR/output/target_package .
mv ${PACKAGE_NAME}.tar.gz $SCRIPT_DIR/output/
echo "Packaging completed successfully."
