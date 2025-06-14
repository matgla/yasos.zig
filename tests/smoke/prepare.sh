#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
ROOT_DIR=$(realpath "$SCRIPT_DIR/../..")
cd $SCRIPT_DIR
python3 -m venv smoke_venv
source smoke_venv/bin/activate
pip3 install -r requirements.txt
cd $ROOT_DIR
zig build defconfig -Ddefconfig_file=$SCRIPT_DIR/configs/pimoroni_pico_plus2_and_vga_defconfig
zig build -Doptimize=ReleaseFast 
./build_rootfs.sh -c -o rootfs.img
openocd -f flash_rp2350.cfg

