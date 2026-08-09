#!/bin/bash

# Power-cycle the debug probe's USB power to recover a wedged RP2350 that
# OpenOCD's sysresetreq + rescue DP cannot clear (the classic case being a
# double-fault lockup, "clearing lockup after double fault", see reset_target.sh).
# Called from session.py when no prompt appears after a reset.
#
# The board has no independently switchable USB port on this rig (it's powered
# off the probe), so we cut power to the whole chain the probe is on. Two
# methods, primary then fallback:
#   1. uhubctl per-port VBUS cut at the RPi ROOT-hub port the probe's hub plugs
#      into (Pi 5 root hubs are ppps). This is a real VBUS cut.
#   2. sysfs unbind/rebind of the probe's top-level hub device (mirrors
#      sysfs_usb_reset() in scripts/remote_smoke_tui.py) when uhubctl is absent
#      or the port-power cut fails.
# Either way the probe is dropped, so /dev/ttyACM* re-enumerates and session.py
# reopens the serial handle afterwards.
#
# The probe is auto-detected by USB vendor id (default 2e8a, the Pico /
# Debugprobe); the RPi root bus/port and the top-level hub are derived from its
# sysfs path (e.g. probe 1-2.1 -> bus 1, root port 2, top hub 1-2). Override the
# vendor with $1 or YASOS_SMOKE_PROBE_VID; off-time with
# YASOS_SMOKE_POWER_OFF_SECONDS. Exit 0 once cycled, 2 if the probe can't be
# located (caller keeps the original reset error), 3 if both methods fail.

set -u

VID="${1:-${YASOS_SMOKE_PROBE_VID:-2e8a}}"
# Hold power off for at least 5s so the board and its bulk caps fully discharge
# (a shorter cut often leaves SRAM/peripherals latched and the lockup intact).
OFF_SECONDS="${YASOS_SMOKE_POWER_OFF_SECONDS:-5}"
if [[ ! "$OFF_SECONDS" =~ ^[0-9]+$ ]] || (( OFF_SECONDS < 5 )); then
    OFF_SECONDS=5
fi

# Locate the probe's sysfs device by vendor id.
devname=""
for dev in /sys/bus/usb/devices/*/; do
    [[ -f "$dev/idVendor" ]] || continue
    if [[ "$(cat "$dev/idVendor" 2>/dev/null)" == "$VID" ]]; then
        devname=$(basename "$dev")
        break
    fi
done
if [[ -z "$devname" ]]; then
    echo "power_reset_target: no USB device with vendor $VID found; skipping power reset" >&2
    exit 2
fi

# Derive addressing from the probe's sysfs name "<bus>-<port>[.<port>...]":
#   bus / root_port -> the RPi root-hub port for the uhubctl VBUS cut
#   top_port        -> the top-level hub device for the sysfs unbind fallback
bus="${devname%%-*}"
path="${devname#*-}"
root_port="${path%%.*}"
top_port="$devname"
while [[ "$top_port" == *.* ]]; do
    top_port="${top_port%.*}"
done

wait_for_serial() {
    # Wait for the debug-probe CDC port to come back before returning; session.py
    # then reopens the serial handle (the /dev node may have changed). Returns 0
    # regardless -- _reopen_serial is the authority on whether serial recovered.
    for _wait in $(seq 1 30); do
        if ls /dev/ttyACM* >/dev/null 2>&1; then
            echo "power_reset_target: serial re-enumerated." >&2
            sleep 1
            return 0
        fi
        sleep 1
    done
    echo "power_reset_target: WARNING serial did not re-enumerate within 30s" >&2
    return 0
}

# --- Primary: RPi root-hub per-port VBUS cut (Pi 5 ppps) ---
uhubctl_bin=$(command -v uhubctl 2>/dev/null || echo /usr/sbin/uhubctl)
if [[ -x "$uhubctl_bin" ]]; then
    echo "power_reset_target: port-power cycle via uhubctl (hub $bus port $root_port, ${OFF_SECONDS}s off)..." >&2
    if sudo "$uhubctl_bin" -l "$bus" -p "$root_port" -a off -r 100 >&2 2>&1; then
        sleep "$OFF_SECONDS"
        # The root hub itself stays powered (only its port went off), so the 'on'
        # command can still address it; retry against transient USB errors.
        for _attempt in 1 2 3; do
            sudo "$uhubctl_bin" -l "$bus" -p "$root_port" -a on -r 100 >&2 2>&1 && break
            sleep 1
        done
        wait_for_serial
        exit 0
    fi
    echo "power_reset_target: uhubctl port-power failed; falling back to hub unbind..." >&2
else
    echo "power_reset_target: uhubctl not found; using sysfs hub unbind..." >&2
fi

# --- Fallback: sysfs unbind/rebind of the probe's top-level hub ---
if [[ ! -e "/sys/bus/usb/drivers/usb/$top_port" ]]; then
    echo "power_reset_target: hub $top_port not bound to the usb driver; cannot cycle" >&2
    exit 3
fi
echo "power_reset_target: unbinding hub $top_port (power OFF); waiting ${OFF_SECONDS}s..." >&2
if ! echo "$top_port" | sudo tee /sys/bus/usb/drivers/usb/unbind >/dev/null; then
    echo "power_reset_target: unbind of $top_port failed" >&2
    exit 3
fi
sleep "$OFF_SECONDS"
echo "$top_port" | sudo tee /sys/bus/usb/drivers/usb/bind >/dev/null || true
echo "power_reset_target: rebound hub $top_port (power ON); waiting for re-enumeration..." >&2
wait_for_serial
exit 0
