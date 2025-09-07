#!/bin/sh

cd "$(dirname "$0")"
pwd
cp yasos.config ../toybox/.config


for PATCH_FILE in *.patch; do
    echo "Found patch file: $PATCH_FILE"
    cp $PATCH_FILE ../toybox/
done

cd ../toybox

for PATCH_FILE in *.patch; do
    if git apply --check "$PATCH_FILE"; then
        echo "Patch can be applied. Applying now..."
        git apply "$PATCH_FILE"
    else
        echo "Patch already applied or conflicts exist. Skipping."
    fi
done

CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="-I$1/usr/include -g" LDFLAGS="-Wl,-oformat=elf32-littlearm" make toybox
mv -f ../toybox/toybox ../toybox/toybox.elf
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="-I$1/usr/include -g" make toybox
PREFIX=$1 CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t make install
# cp ../toybox/toybox $1/bin/toybox

