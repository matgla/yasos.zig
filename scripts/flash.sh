#!/bin/bash
#
# flash.sh — program the locally attached RP2350 board over SWD with OpenOCD.
#
# Default flashes rootfs.img at the rootfs address, then the kernel ELF
# (verified), then reset-runs. Each image is first checked against what the board
# already holds with an on-target CRC (verify_image_checksum: ~2 s for the rootfs,
# ~0.2 s for the kernel) and is only programmed when it differs, so an unchanged
# rootfs no longer costs its ~28 s erase+write. The check is checksum-only on
# purpose: `program ... preverify` uses verify_image, which on a mismatch falls
# back to a byte compare that reads the whole image back (~10 s for the rootfs).
# --force programs regardless. --kernel-only leaves the rootfs partition alone
# without even checking it. --restart programs nothing and only resets the board.
#
# Before flashing, the kernel is built with `zig build -Doptimize=ReleaseFast`
# (--optimize picks another mode, --no-build skips the build, --kernel PATH
# implies --no-build). The build is refused unless config/target is configured
# for an RP2350: a QEMU run repoints that shared config with `zig build
# defconfig`, and building it would flash a QEMU kernel into the board. The
# script never re-runs defconfig itself, since that would discard local
# menuconfig changes.
#
# Every attempt is the plain local invocation
#   openocd -f interface/cmsis-dap.cfg -f target/rp2350.cfg -c "adapter speed N"
# plus the program commands. Programming starts at 15000 kHz. Past ~15 MHz the
# write is no longer clock-bound (15.6, 20 and 25 MHz all erase+write the rootfs
# in ~28 s), and 25000, the fastest SWCLK the Debug Probe (firmware
# debugprobe-v2.3.1) connects at at all (31250 cannot read the DP IDR), failed
# intermittently; --speed still accepts up to 25000. Older probe firmware
# desyncs above 8000 kHz
# ("CMSIS-DAP command mismatch"); on failure the script rescues the DP (clears a
# QSPI Quad I/O / double-fault lockup left by a prior run) and retries at 8000,
# 4000, then 2000 kHz.
#
# Usage:
#   scripts/flash.sh [options]
#
# Options:
#   -k, --kernel-only       Program the kernel only, leave the rootfs alone.
#   -f, --force             Program even when the board already holds the image.
#   -r, --restart           Only restart the board (reset-run); program nothing.
#   -O, --optimize MODE     zig build mode: Debug, ReleaseSafe, ReleaseFast,
#                           ReleaseSmall (default ReleaseFast).
#       --no-build          Flash the existing zig-out kernel without building.
#       --kernel PATH       Kernel ELF, implies --no-build
#                           (default zig-out/bin/yasos_kernel)
#       --rootfs PATH       Rootfs image        (default rootfs.img)
#       --rootfs-address A  Rootfs flash address (default 0x10100000)
#       --interface CFG     OpenOCD probe config (default interface/cmsis-dap.cfg)
#       --target CFG        OpenOCD target config (default target/rp2350.cfg)
#       --speed KHZ         Adapter speed, capped at 25000 (default 15000)
#       --full-erase        Erase the whole flash bank before programming.
#       --rescue            Also rescue the DP before the first attempt.
#       --no-reset          Leave the core halted after programming.
#   -h, --help              Show this help.
#
# Env overrides: OPENOCD, YASOS_FLASH_INTERFACE_CFG, YASOS_FLASH_TARGET_CFG,
# YASOS_FLASH_RESCUE_CFG.
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

OPENOCD="${OPENOCD:-openocd}"
INTERFACE_CFG="${YASOS_FLASH_INTERFACE_CFG:-interface/cmsis-dap.cfg}"
TARGET_CFG="${YASOS_FLASH_TARGET_CFG:-target/rp2350.cfg}"
RESCUE_CFG="${YASOS_FLASH_RESCUE_CFG:-target/rp2350-rescue.cfg}"

KERNEL="$REPO_ROOT/zig-out/bin/yasos_kernel"
ROOTFS="$REPO_ROOT/rootfs.img"
ROOTFS_ADDR=0x10100000
SPEED=15000
KERNEL_ONLY=0
FORCE=0
RESTART=0
OPTIMIZE=ReleaseFast
BUILD=1
FULL_ERASE=0
RESCUE=0
RESET=1

need_arg() {
    [ "$2" -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -k|--kernel-only) KERNEL_ONLY=1; shift ;;
        -f|--force) FORCE=1; shift ;;
        -r|--restart) RESTART=1; shift ;;
        -O|--optimize) need_arg "$1" "$#"; OPTIMIZE="$2"; shift 2 ;;
        --optimize=*) OPTIMIZE="${1#*=}"; shift ;;
        --no-build) BUILD=0; shift ;;
        --kernel) need_arg "$1" "$#"; KERNEL="$2"; BUILD=0; shift 2 ;;
        --kernel=*) KERNEL="${1#*=}"; BUILD=0; shift ;;
        --rootfs) need_arg "$1" "$#"; ROOTFS="$2"; shift 2 ;;
        --rootfs=*) ROOTFS="${1#*=}"; shift ;;
        --rootfs-address) need_arg "$1" "$#"; ROOTFS_ADDR="$2"; shift 2 ;;
        --rootfs-address=*) ROOTFS_ADDR="${1#*=}"; shift ;;
        --interface) need_arg "$1" "$#"; INTERFACE_CFG="$2"; shift 2 ;;
        --interface=*) INTERFACE_CFG="${1#*=}"; shift ;;
        --target) need_arg "$1" "$#"; TARGET_CFG="$2"; shift 2 ;;
        --target=*) TARGET_CFG="${1#*=}"; shift ;;
        --speed) need_arg "$1" "$#"; SPEED="$2"; shift 2 ;;
        --speed=*) SPEED="${1#*=}"; shift ;;
        --full-erase) FULL_ERASE=1; shift ;;
        --rescue) RESCUE=1; shift ;;
        --no-reset) RESET=0; shift ;;
        -h|--help) sed -n '2,/^[^#]/{/^#/p}' "$0"; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ "$KERNEL_ONLY" = 1 ] && [ "$FULL_ERASE" = 1 ]; then
    echo "error: --full-erase wipes the rootfs; it cannot be combined with --kernel-only" >&2
    exit 2
fi
if [ "$RESTART" = 1 ] && [ "$RESET" = 0 ]; then
    echo "error: --restart and --no-reset contradict each other" >&2
    exit 2
fi
if ! [[ "$SPEED" =~ ^[0-9]+$ ]] || [ "$SPEED" -eq 0 ]; then
    echo "error: --speed must be a positive integer (kHz), got '$SPEED'" >&2
    exit 2
fi
if ! command -v "$OPENOCD" >/dev/null 2>&1; then
    echo "error: '$OPENOCD' not found in PATH" >&2
    exit 1
fi

case "$OPTIMIZE" in
    Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
    *) echo "error: --optimize must be Debug, ReleaseSafe, ReleaseFast or ReleaseSmall, got '$OPTIMIZE'" >&2
       exit 2 ;;
esac

if [ "$RESTART" = 0 ] && [ "$BUILD" = 1 ]; then
    TARGET_JSON="$REPO_ROOT/config/target/config.json"
    target=$(python3 -c 'import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("cpu", ""), c.get("board", ""))' "$TARGET_JSON" 2>/dev/null) || target=""
    cpu=${target%% *}
    board=${target#* }
    if [ "$cpu" != rp2350 ]; then
        echo "error: config/target is configured for cpu '${cpu:-<none>}' (board '${board:-<none>}'), not rp2350." >&2
        echo "       Select the board first: zig build defconfig -Ddefconfig_file=configs/mspc_defconfig" >&2
        echo "       or pass --no-build to flash the existing zig-out kernel." >&2
        exit 1
    fi
    command -v zig >/dev/null 2>&1 || { echo "error: zig not found in PATH" >&2; exit 1; }
    echo ">> Building kernel for $board: zig build -Doptimize=$OPTIMIZE"
    ( cd "$REPO_ROOT" && zig build -Doptimize="$OPTIMIZE" ) || {
        echo "error: zig build failed" >&2; exit 1; }
fi

# OpenOCD parses program's path as a Tcl word, so hand it absolute paths that do
# not depend on where the script was started from. A restart needs no images.
if [ "$RESTART" = 0 ]; then
    KERNEL=$(realpath -e "$KERNEL" 2>/dev/null) || {
        echo "error: kernel ELF not found (build it with 'zig build')" >&2; exit 1; }
    if [ "$KERNEL_ONLY" = 0 ]; then
        ROOTFS=$(realpath -e "$ROOTFS" 2>/dev/null) || {
            echo "error: rootfs image not found (build it with './build_rootfs.sh -c -o rootfs.img'," >&2
            echo "       or pass --kernel-only)" >&2
            exit 1
        }
    fi
fi

(( SPEED > 25000 )) && SPEED=25000

rescue_dp() {
    "$OPENOCD" -f "$INTERFACE_CFG" -f "$RESCUE_CFG" \
        -c "adapter speed 5000" -c "init" -c "shutdown" >/dev/null 2>&1 || true
    sleep 1
}

# Program FILE (at ADDR, empty for an ELF) with program's OPTS unless the board's
# flash already matches it. A mismatch also prints OpenOCD's own
# "Error: checksum mismatch" line; that is the check failing, not the flash.
TCL_FLASH_IF_CHANGED='proc flash_if_changed {name file addr opts} {
    if {[catch {verify_image_checksum $file {*}$addr}] == 0} {
        echo ">> $name unchanged on the board, skipped"
    } else {
        echo ">> $name differs from the board, programming"
        program $file {*}$addr {*}$opts
    }
}'

if [ "$RESTART" = 1 ]; then
    what=Restart
    echo ">> Restarting the board"
elif [ "$KERNEL_ONLY" = 1 ]; then
    what=Flash
    echo ">> Flashing kernel only: $KERNEL"
else
    what=Flash
    echo ">> Flashing rootfs $ROOTFS @ $ROOTFS_ADDR + kernel $KERNEL"
fi

[ "$RESCUE" = 1 ] && rescue_dp

speed=$SPEED
for attempt in 1 2 3 4; do
    cmd=( "$OPENOCD" -f "$INTERFACE_CFG" -f "$TARGET_CFG"
          -c "adapter speed $speed" -c "init" )
    if [ "$RESTART" = 1 ]; then
        cmd+=( -c "reset run" )
    else
        cmd+=( -c "reset halt" )
        [ "$FULL_ERASE" = 1 ] && cmd+=( -c "flash erase_address 0x10000000 0" )
        if [ "$FORCE" = 1 ]; then
            [ "$KERNEL_ONLY" = 0 ] && cmd+=( -c "program {$ROOTFS} $ROOTFS_ADDR" )
            cmd+=( -c "program {$KERNEL} verify" )
        else
            cmd+=( -c "$TCL_FLASH_IF_CHANGED" )
            [ "$KERNEL_ONLY" = 0 ] && cmd+=( -c "flash_if_changed rootfs {$ROOTFS} $ROOTFS_ADDR {}" )
            cmd+=( -c "flash_if_changed kernel {$KERNEL} {} verify" )
        fi
        [ "$RESET" = 1 ] && cmd+=( -c "reset run" )
    fi
    cmd+=( -c "shutdown" )

    echo ">> Attempt $attempt at ${speed} kHz:$(printf ' %q' "${cmd[@]}")"
    if "${cmd[@]}"; then
        echo ">> $what OK."
        exit 0
    fi
    [ "$attempt" = 4 ] && break

    if (( speed > 8000 )); then speed=8000
    elif (( speed > 4000 )); then speed=4000
    elif (( speed > 2000 )); then speed=2000
    else speed=1000; fi
    echo ">> Attempt $attempt failed; rescuing DP and retrying at ${speed} kHz" >&2
    rescue_dp
done

echo "error: ${what,,} failed after 4 attempts" >&2
exit 1
