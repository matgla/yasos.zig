#!/usr/bin/env bash
# Build the host-side fatimg tool against the FatFs vendored in apps/mkfs.
# Output: scripts/fatimg/fatimg
#
# ff.h includes "ffconf.h" from its own directory first, and the FatFs
# submodule ships one with FF_USE_MKFS 0 -- an -I in front of it is never
# consulted, and f_mkfs goes missing at link time.  So, as apps/mkfs does, the
# sources are compiled from a copy that sits next to this directory's ffconf.h.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FF="$REPO/apps/mkfs/libs/fatfs/source"
CC="${CC:-gcc}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$FF/ff.c" "$FF/ff.h" "$FF/diskio.h" "$FF/ffunicode.c" "$FF/ffsystem.c" "$WORK/"
cp "$HERE/ffconf.h" "$WORK/"

"$CC" -O2 -Wall -I"$HERE" -I"$WORK" \
    "$HERE/fatimg.c" "$HERE/diskio.c" \
    "$WORK/ff.c" "$WORK/ffunicode.c" "$WORK/ffsystem.c" \
    -o "$HERE/fatimg"
echo "built $HERE/fatimg"
