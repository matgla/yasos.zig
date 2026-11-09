#!/bin/bash
# Stage a build_image.sh package for the board jobs, without rebuilding: unpack
# the tarball in <artifact-dir> and put its kernel at zig-out/bin/yasos_kernel,
# rootfs.img at the repo root and rootfs/usr/bin/hello (yaff_arch_test.py's
# donor executable) under rootfs/.
#
#   scripts/stage_hw_package.sh <artifact-dir>
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
ART="${1:?artifact directory}"
pkg=$(find "$ART" -name '*.tar.gz' | head -n1)
if [ -z "$pkg" ]; then echo "no package tarball found in $ART/" >&2; exit 1; fi
tar -xzf "$pkg" -C "$ART"
# Exclude the decode_bundle/ copies so we pick the package top-level
# kernel + rootfs (the bundle holds symbol ELFs for decoding only).
kernel=$(find "$ART" -name yasos_kernel -not -path '*/decode_bundle/*' | head -n1)
rootfs=$(find "$ART" -name rootfs.img -not -path '*/decode_bundle/*' | head -n1)
# yaff_arch_test.py corrupts this executable field by field and checks
# the loader refuses it; rootfs/ is gitignored, so the checkout has no
# copy and it has to come from the package.
donor=$(find "$ART" -path '*/rootfs/usr/bin/hello' -not -path '*/decode_bundle/*' | head -n1)
if [ -z "$kernel" ] || [ -z "$rootfs" ] || [ -z "$donor" ]; then
  echo "package missing yasos_kernel, rootfs.img or rootfs/usr/bin/hello" >&2; exit 1
fi
mkdir -p zig-out/bin rootfs/usr/bin
cp "$kernel" zig-out/bin/yasos_kernel
cp "$rootfs" rootfs.img
cp "$donor" rootfs/usr/bin/hello
