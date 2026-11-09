#!/bin/bash
# Fetch the pinned Zig fork (apps/zig/zig_fork.txt) into a directory, for
# build_rootfs.sh --zig / build_image.sh's YASOS_IMAGE_ZIG.
#
#   fetch_fork.sh <dest>
#
# Only the pinned commit is fetched (depth 1, no history: the fork is a Zig tree,
# several hundred MB with it).  A <dest> already at that commit is left alone.
#
# Copyright (c) 2026 Mateusz Stadnik
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:?destination directory}"
pin() { awk -v k="$1" '$1 == k { print $2 }' "$HERE/zig_fork.txt"; }
URL="$(pin url)"
COMMIT="$(pin commit)"
[ -n "$URL" ] && [ -n "$COMMIT" ] || { echo "fetch_fork: no url/commit in $HERE/zig_fork.txt" >&2; exit 1; }

if [ -d "$DEST/.git" ] && [ "$(git -C "$DEST" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ]; then
    echo "fetch_fork: $DEST is at $COMMIT"
    exit 0
fi
mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" fetch -q --depth 1 "$URL" "$COMMIT"
git -C "$DEST" -c advice.detachedHead=false checkout -q FETCH_HEAD
echo "fetch_fork: $DEST at $(git -C "$DEST" rev-parse --short HEAD) from $URL"
