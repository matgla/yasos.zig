#!/bin/bash

# Last-resort recovery: reflash the board (rootfs + kernel) when even a USB
# power cycle (power_reset_target.sh) won't bring it back to a shell prompt.
# Re-programs the same artifacts the runner originally flashed, with the same
# rescue-DP-first + speed-backoff hardening as the flash path in
# scripts/remote_smoke_tui.py. Called from session.py as the final reset rung.
#
# Artifact paths + rootfs flash address come from the runner via env:
#   YASOS_SMOKE_REMOTE_KERNEL    kernel ELF on the remote host (required)
#   YASOS_SMOKE_REMOTE_ROOTFS    rootfs image (optional; programmed if present)
#   YASOS_SMOKE_ROOTFS_ADDRESS   flash address for the rootfs image
# OpenOCD configs/speed default to the RP2350 values used by reset_target.sh and
# can be overridden via YASOS_SMOKE_OPENOCD_*. Exit 0 on a successful program,
# 2 if no kernel artifact is configured (caller keeps the prior failure), 1 if
# every attempt fails.

set -u

KERNEL="${YASOS_SMOKE_REMOTE_KERNEL:-}"
ROOTFS="${YASOS_SMOKE_REMOTE_ROOTFS:-}"
ROOTFS_ADDR="${YASOS_SMOKE_ROOTFS_ADDRESS:-}"
INTERFACE_CFG="${YASOS_SMOKE_OPENOCD_INTERFACE_CFG:-interface/cmsis-dap.cfg}"
TARGET_CFG="${YASOS_SMOKE_OPENOCD_TARGET_CFG:-target/rp2350.cfg}"
RESCUE_CFG="${YASOS_SMOKE_OPENOCD_RESCUE_CFG:-target/rp2350-rescue.cfg}"
ADAPTER_SPEED="${YASOS_SMOKE_OPENOCD_ADAPTER_SPEED:-20000}"

if [[ -z "$KERNEL" || ! -f "$KERNEL" ]]; then
    echo "reflash_target: kernel artifact unavailable (YASOS_SMOKE_REMOTE_KERNEL='$KERNEL'); skipping reflash" >&2
    exit 2
fi

rescue() {
    # Rescue DP clears QSPI Quad I/O / double-fault lockups before programming.
    openocd -f "$INTERFACE_CFG" -f "$RESCUE_CFG" \
        -c "adapter speed 5000" -c "init" -c "exit" 2>/dev/null || true
    sleep 1
}

# Programming bursts a lot of CMSIS-DAP traffic; high interactive speeds desync
# the probe ("CMSIS-DAP command mismatch"). Cap the first attempt at 8000 kHz
# and back off on failure (floor 1000 kHz), mirroring the runner's flash ladder.
speed=$ADAPTER_SPEED
(( speed > 8000 )) && speed=8000

rescue
for attempt in 1 2 3; do
    cmd=( openocd -c "set USE_CORE 0" -f "$INTERFACE_CFG" -f "$TARGET_CFG"
          -c "adapter speed $speed" -c "init" -c "reset halt" )
    if [[ -n "$ROOTFS" && -f "$ROOTFS" && -n "$ROOTFS_ADDR" ]]; then
        cmd+=( -c "program $ROOTFS $ROOTFS_ADDR" )
    fi
    cmd+=( -c "program $KERNEL verify" -c "reset run" -c "exit" )

    echo "reflash_target: attempt $attempt at ${speed}kHz..." >&2
    if "${cmd[@]}"; then
        echo "reflash_target: reflash OK." >&2
        exit 0
    fi

    if (( speed > 4000 )); then speed=4000
    elif (( speed > 2000 )); then speed=2000
    else speed=1000; fi
    echo "reflash_target: attempt $attempt failed; rescuing and retrying at ${speed}kHz..." >&2
    rescue
done

echo "reflash_target: ERROR reflash failed after 3 attempts" >&2
exit 1
