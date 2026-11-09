#!/bin/bash
# The kernel built on the board, from prebuilt pieces (CI's hardware_zig_kernel
# job): flash the staged images (built with build_image.sh's YASOS_IMAGE_ZIG, so
# the rootfs carries the device zig), then run a package made by
# `scripts/kernel_tcc/zig_device.py full --package`: the device zig renders the
# kernel and compiler-rt to C, tcc builds zigfix, the fix-ups and every command of
# the kernel's tcc plan through the link, and every output must equal the host
# reference's byte for byte.
#
#   scripts/run_hw_zig_kernel.sh <package-dir>
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
cd "$(dirname "$0")/.."
PACKAGE="${1:?package directory (zig_device.py full --package)}"
./scripts/hw_flash.sh
exec python3 scripts/kernel_tcc/zig_device.py board-run --package "$PACKAGE" \
    ${SERIAL_DEVICE:+--serial "$SERIAL_DEVICE"}
