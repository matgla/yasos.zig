#!/bin/sh

# Abort (with a non-zero status the caller checks) if any build step fails,
# instead of silently continuing and returning the exit code of the final
# `ln -sf`. The git-apply checks below stay tolerant because they run as `if`
# conditions, which are exempt from `set -e`.
set -e

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

TOYBOX_CFLAGS="-I$1/usr/include -g${TOYBOX_EXTRA_CFLAGS:+ }$TOYBOX_EXTRA_CFLAGS"
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="$TOYBOX_CFLAGS" LDFLAGS="-Wl,-oformat=elf32-littlearm -lm" make toybox
mv -f ../toybox/toybox ../toybox/toybox.elf
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="$TOYBOX_CFLAGS" LDFLAGS="-lm" make toybox
PREFIX=$1 CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t make install
if [ -f "$1/bin/cal" ]; then
  mv "$1/bin/cal" "$(dirname "$1")/bin/cal"
fi
for applet in ulimit prlimit; do
    if [ ! -e "$1/bin/$applet" ]; then
        ln -sf toybox "$1/bin/$applet"
    fi
done
# cp ../toybox/toybox $1/bin/toybox
