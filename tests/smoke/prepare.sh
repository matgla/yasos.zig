#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
ROOT_DIR=$(realpath "$SCRIPT_DIR/../..")
cd $SCRIPT_DIR
python3 -m venv smoke_venv
if [ $? -ne 0 ]; then
    echo "Failed to create virtual environment. Please check your Python installation."
    exit 1
fi
source smoke_venv/bin/activate
pip3 install -r requirements.txt
if [ $? -ne 0 ]; then
    echo "Failed to install required Python packages. Please check your internet connection and package sources."
    exit 1
fi
cd $ROOT_DIR
zig build defconfig -Ddefconfig_file=$SCRIPT_DIR/configs/pimoroni_pico_plus2_and_vga_defconfig
if [ $? -ne 0 ]; then
    echo "Failed to configure project. Please check configuration output."
    exit 1
fi
zig build -Doptimize=ReleaseFast 
if [ $? -ne 0 ]; then
    echo "Failed to build project. Please check build output."
    exit 1
fi
./build_rootfs.sh -c -o rootfs.img
if [ $? -ne 0 ]; then
    echo "Failed to build root filesystem. Please check build_rootfs.sh output."
    exit 1
fi
openocd -f flash_rp2350.cfg
if [ $? -ne 0 ]; then
    echo "Failed to flash the device. Please check OpenOCD configuration and connection."
    exit 1
fi

