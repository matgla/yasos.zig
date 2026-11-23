#!/bin/bash

# Copyright (c) 2025 Mateusz Stadnik
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

if [[ "$(uname)" == "Darwin" ]]; then
    GETOPT_CMD="/opt/homebrew/opt/gnu-getopt/bin/getopt"
else
    GETOPT_CMD="getopt"
fi

# Use getopt to parse long options
PARSED_ARGS=$(${GETOPT_CMD} -o c:v:i --long command:,container_version:,interactive -- "$@")

# Exit if getopt fails
if [ $? -ne 0 ]; then
    echo "Error parsing arguments"
    exit 1
fi

# Reorder arguments
eval set -- "$PARSED_ARGS"

# Default values
COMMAND=""
CONTAINER_VERSION=""
CONTAINER_INTERACTIVE=""

# Parse arguments
while true; do
    case "$1" in
        -c|--command)  COMMAND="$2"; shift 2 ;;
        -v|--container_version) CONTAINER_VERSION="$2"; shift 2 ;;
        -i|--interactive) shift; CONTAINER_INTERACTIVE="-it" ;;
        --) shift; break ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
# Define your probe's VID and PID
PROBE_ALLOWED_LIST=(
    "2e8a:000c"
)

if [[ "$(uname)" == "Darwin" ]]; then
    USB_DEVICES=""
else 
    USB_DEVICES=$(lsusb)
fi
for PAIR in "${PROBE_ALLOWED_LIST[@]}"; do
    if echo "$USB_DEVICES" | grep -q "$PAIR"; then
        MATCHED_DEVICE="$PAIR"
        break
    fi
done

PROBE_UART_DEVICE=""
CONTAINER_BOARD_ENV=""

if [[ -n "${YASOS_PROBE_SERIAL:-}" && "$(uname)" != "Darwin" ]]; then
    # A board taken with scripts/rig/boards.py run: only its UART goes in (the
    # other board's job owns the rest), under the /dev name it resolves to, and
    # openocd inside selects its probe through the same interface override.
    if [[ -n "${SERIAL_DEVICE:-}" && -e "$SERIAL_DEVICE" ]]; then
        uart=$(readlink -f "$SERIAL_DEVICE")
        PROBE_UART_DEVICE="--device=$uart:$uart "
        CONTAINER_BOARD_ENV="-e SERIAL_DEVICE=$uart"
    fi
    CONTAINER_BOARD_ENV="$CONTAINER_BOARD_ENV -e YASOS_BOARD -e YASOS_BOARD_TYPE -e YASOS_PROBE_SERIAL -e YASOS_POWER_PORTS"
    if [[ -n "${OPENOCD_SCRIPTS:-}" ]]; then
        CONTAINER_BOARD_ENV="$CONTAINER_BOARD_ENV -v $OPENOCD_SCRIPTS:/opt/yasos-rig-openocd:ro -e OPENOCD_SCRIPTS=/opt/yasos-rig-openocd"
    fi
    echo "Board ${YASOS_BOARD:-?}: probe $YASOS_PROBE_SERIAL, UART ${SERIAL_DEVICE:-not found}"
elif [[ -n "$MATCHED_DEVICE" && "$(uname)" != "Darwin" ]]; then
    # Find the corresponding UART device (assuming /dev/ttyUSB or /dev/ttyACM)
    UART_DEVICES=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null)
    for UART_DEVICE in $UART_DEVICES; do
        PROBE_UART_DEVICE="$PROBE_UART_DEVICE--device=$UART_DEVICE:$UART_DEVICE "
    done
fi

CONTAINER_MOUNT_UART=""
if [ ! -z "$PROBE_UART_DEVICE" ]; then
    echo "Found probe UART devices: $PROBE_UART_DEVICE"
    CONTAINER_MOUNT_UART="$PROBE_UART_DEVICE --device=/dev/bus/usb"
fi

if [[ -z "$CONTAINER_INTERACTIVE" && -z "$COMMAND" ]]; then
    echo "Error: nor --interactive or --command provided, nothing to do..." 
    exit 1
fi

podman run $CONTAINER_MOUNT_UART $CONTAINER_BOARD_ENV --userns=keep-id -v $(pwd):/workspace ${CONTAINER_INTERACTIVE} -w /workspace matgla/yasos.zig:${CONTAINER_VERSION} ${COMMAND}

