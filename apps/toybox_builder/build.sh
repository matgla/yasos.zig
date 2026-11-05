#!/bin/sh

# Abort (with a non-zero status the caller checks) if any build step fails,
# instead of silently continuing and returning the exit code of the final
# `ln -sf`.
set -e

cd "$(dirname "$0")"
pwd
cp yasos.config ../toybox/.config

# The yasos downstream patches now live in the toybox fork
# (git@github.com:matgla/toybox.git), so they are already present in the
# submodule checkout — no patch step needed here.

cd ../toybox

# Keep the curated applet selection from yasos.config. The toybox Makefile
# otherwise regenerates .config via "genconfig.sh -d" (defconfig) whenever
# generated/Config.in is newer than .config — which is always true on a fresh
# checkout, since generated/ is gitignored. defconfig IGNORES our
# "# CONFIG_X is not set" lines and re-enables ~every applet (≈242 vs the
# curated ~12), pulling in commands that call libc functions yasos does not
# provide (dmesg->ctime, hostname->gethostbyname) and breaking the build on CI.
#
# Pre-generate generated/Config.in (no-arg genconfig.sh does this without writing
# .config), then make .config the newest file so both the Makefile and make.sh
# treat it as up-to-date and build exactly the applets yasos.config selects.
scripts/genconfig.sh
touch .config

TOYBOX_CFLAGS="-I$1/usr/include -fvisibility=hidden${TOYBOX_EXTRA_CFLAGS:+ }$TOYBOX_EXTRA_CFLAGS"
export LDOPTIMIZE="-Wl,--gc-sections -Wl,--as-needed"
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="$TOYBOX_CFLAGS" LDFLAGS="-Wl,-oformat=elf32-littlearm -lm" make toybox
mv -f ../toybox/toybox ../toybox/toybox.elf
# Per-image stack profile: toybox applets (and the shell) run in 8 KiB rather
# than the 32 KiB default that tcc needs -- sized via the YAFF stack_size hint
# (-stack-size). Syscalls run on this stack, and they are most of its depth: `cd`
# into the ext4 bind mount at /root reaches 4.3 KiB and a deeper path 4.5 KiB on
# QEMU, before the board's SD driver and hardware exception frames. 4 KiB passed the
# smoke suite, which has no SD card, and overflowed on the first `cd /root`.
# rp2350_timing's watch= measures it; test with qemu_mount.py --sdcard.
# -slow-memory: a shell mostly waits for what it started, so that gets the SRAM.
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="$TOYBOX_CFLAGS" LDFLAGS="-lm -stack-size=8192 -slow-memory" make toybox
PREFIX=$1 CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t make install
if [ -f "$1/bin/cal" ]; then
  mv "$1/bin/cal" "$(dirname "$1")/bin/cal"
fi
# Applets declared TOYFLAG_USR (ulimit, prlimit, clear, and most of what a
# configure script runs: awk, expr, tr, sort, head, find, ...) are installed by
# "make install --long" under $PREFIX/usr/bin.  $PREFIX is already rootfs/usr
# here, so they land in rootfs/usr/usr/bin, which is not on the target's PATH.
# Link every one of them into rootfs/usr/bin, skipping any name a standalone
# app already installed there (apps/sha ships its own sha256sum).
for path in "$1"/usr/bin/*; do
    applet=$(basename "$path")
    # cal is placed by the step above; linking it here too would make that
    # step's mv fail on the next build (rootfs/bin can be rootfs/usr/bin).
    [ "$applet" = cal ] && continue
    if [ ! -e "$1/bin/$applet" ]; then
        ln -sf toybox "$1/bin/$applet"
    fi
done
# cp ../toybox/toybox $1/bin/toybox
