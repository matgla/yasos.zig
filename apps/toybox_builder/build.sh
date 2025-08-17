#!/bin/sh 

cd "$(dirname "$0")"
pwd
cp yasos.config ../toybox/.config
PATCH_FILE="0001-Removed-gc-sections.patch"
cp $PATCH_FILE ../toybox/
cd ../toybox  

if git apply --check "$PATCH_FILE"; then
    echo "Patch can be applied. Applying now..."
    git apply "$PATCH_FILE"
else
    echo "Patch already applied or conflicts exist. Skipping."
fi

CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="-I$1/usr/include -g" LDFLAGS="-Wl,-oformat=elf32-littlearm" make toybox
mv -f ../toybox/toybox ../toybox/toybox.elf
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="-I$1/usr/include -g" make toybox
# PREFIX=$1 CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t make install
cp ../toybox/toybox $1/bin/toybox

