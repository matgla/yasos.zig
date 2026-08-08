#!/usr/bin/env bash
# Build the host-side fatimg tool against the FatFs vendored in apps/mkfs.
# Output: scripts/fatimg/fatimg
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FF="$REPO/apps/mkfs/libs/fatfs/source"
CC="${CC:-gcc}"

"$CC" -O2 -Wall -I"$HERE" -I"$FF" \
    "$HERE/fatimg.c" "$HERE/diskio.c" \
    "$FF/ff.c" "$FF/ffunicode.c" "$FF/ffsystem.c" \
    -o "$HERE/fatimg"
echo "built $HERE/fatimg"
