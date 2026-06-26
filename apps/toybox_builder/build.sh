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

TOYBOX_CFLAGS="-I$1/usr/include -g${TOYBOX_EXTRA_CFLAGS:+ }$TOYBOX_EXTRA_CFLAGS"
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="$TOYBOX_CFLAGS" LDFLAGS="-Wl,-oformat=elf32-littlearm -lm" make toybox
mv -f ../toybox/toybox ../toybox/toybox.elf
# Per-image stack profile: toybox applets (and the shell) run in 16 KiB rather
# than the 32 KiB default that tcc needs — sized via the YAFF stack_size hint
# (-stack-size). Validated against the smoke suite; raise if deeper shell
# recursion / complex scripts overflow (stack-overflow detection will flag it).
CROSS_COMPILE=../../libs/tinycc/bin/armv8m-t CFLAGS="$TOYBOX_CFLAGS" LDFLAGS="-lm -stack-size=16384" make toybox
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
