#!/bin/bash
# Flash the staged images (rootfs.img, zig-out/bin/yasos_kernel) onto the RP2350 on
# the debug probe: flash_rp2350.cfg, with one retry after an RP2350 debug-port
# rescue when the first attempt fails.  The board CI jobs (run_hw_*.sh) start here.
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
for artifact in rootfs.img zig-out/bin/yasos_kernel; do
    [ -f "$artifact" ] || { echo "hw_flash: $artifact missing -- stage the package first" >&2; exit 1; }
done
rescue_dp() {
    openocd -f interface/cmsis-dap.cfg -f target/rp2350-rescue.cfg \
        -c "adapter speed 5000" -c "init" -c "exit" 2>/dev/null || true
    sleep 1
}
echo ">> Flashing rootfs.img + yasos_kernel (no rebuild)"
if ! openocd -f flash_rp2350.cfg; then
    echo ">> Initial flash failed; rescuing DP and retrying once" >&2
    rescue_dp
    openocd -f flash_rp2350.cfg
fi
