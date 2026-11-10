#!/bin/bash
# The tinycc self-host test on the board, from prebuilt pieces (CI's
# hardware_selfhost job): flash the staged images, whose rootfs tcc is built from
# this checkout's tinycc, then run a payload made by
# `scripts/tcc_selfhost.py --prepare-only` on the same checkout: the board's tcc
# builds tinycc (each object against the host cross's), and the tcc it built
# rebuilds itself to a byte-identical fixpoint.
#
#   scripts/run_hw_selfhost.sh <payload-dir> [stages: 2|3, default 3]
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
PAYLOAD="${1:?payload directory (tcc_selfhost.py --prepare-only)}"
STAGES="${2:-3}"
./scripts/hw_flash.sh
exec python3 scripts/tcc_selfhost.py --uart --payload "$PAYLOAD" --dest /root/selfhost-ci \
    --stages "$STAGES" ${SERIAL_DEVICE:+--serial "$SERIAL_DEVICE"}
