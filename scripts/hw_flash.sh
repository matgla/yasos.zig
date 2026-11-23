#!/bin/bash
# Flash the staged images (rootfs.img, zig-out/bin/yasos_kernel) onto the RP2350 on
# the debug probe: flash_rp2350.cfg, with one retry after an RP2350 debug-port
# rescue when the first attempt fails.  The board CI jobs (run_hw_*.sh) start here.
#
# The jobs of one CI run flash the same images one after another, but another
# flasher on the rig (matgla/tinycc's metrics runner) can come in between, so the
# board is read back instead of trusted: when the flash already holds both images
# byte for byte, the board is only reset.  HW_FLASH_FORCE=1 always programs.
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
# Reading the flash back.  Both cores halted (reset init: a running core 1 writes into
# the work area, see AGENTS.md).  A reset leaves the flash as the booted kernel set it
# up, and the boot ROM sequence of pico-sdk's flash_range_* puts it back in a state
# the debugger can read: connect_internal_flash, flash_exit_xip (the kernel turns on
# continuous read: without this, reads come back shifted), flash_flush_cache,
# flash_enter_cmd_xip.  The address translation (QMI ATRANS) survives the reset too
# -- 0x10000000 can still be partition 1, flash 0x20000 -- so both images are read
# through 0x1c000000, the uncached, untranslated alias: the rootfs (flash 0x120000)
# at 0x1c120000, the kernel ELF, linked for 0x10000000 = flash 0, moved by
# 0x0c000000.  Checksums only (verify_image_checksum), computed on the target; when
# that algorithm fails openocd reads everything over SWD (about 6 minutes), so the
# check gets HW_FLASH_CHECK_TIMEOUT seconds.  Any failure -- mismatch, timeout, a
# reset that loses the DP -- means "program it", as before this check.
board_has_images() {
    timeout "${HW_FLASH_CHECK_TIMEOUT:-60}" \
    openocd -f interface/cmsis-dap.cfg -f target/rp2350.cfg -c "adapter speed 16000" \
        -c init -c "reset init" -c "rp2xxx rom_api_call IF" -c "rp2xxx rom_api_call EX" \
        -c "rp2xxx rom_api_call FC" -c "rp2xxx rom_api_call CX" \
        -c "verify_image_checksum rootfs.img 0x1c120000 bin" \
        -c "verify_image_checksum zig-out/bin/yasos_kernel 0x0c000000" \
        -c "reset run" -c exit
}
if [ "${HW_FLASH_FORCE:-0}" != 1 ] && board_has_images; then
    echo ">> Board already holds this rootfs.img + yasos_kernel (verified); reset only"
    exit 0
fi
echo ">> Flashing rootfs.img + yasos_kernel (no rebuild)"
if ! openocd -f flash_rp2350.cfg; then
    echo ">> Initial flash failed; rescuing DP and retrying once" >&2
    rescue_dp
    openocd -f flash_rp2350.cfg
fi
