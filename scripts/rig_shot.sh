#!/bin/bash
# Play a scripted take of *using* the rig, on this machine.
#
# The sibling of demo_shot.sh, and the difference is which end of the wire the
# take is about.  demo_shot.sh pushes the typist to the Pi and drives the
# board's own shell over serial: the subject is the target.  This runs the
# typist here and drives a shell on this desk: the subject is the loop --
# `remote_smoke_tui.py` building locally, rsyncing to the Pi, flashing the
# board over SWD, and bringing gdb up on it.  Nothing is pushed anywhere,
# because the thing being filmed is what happens on this screen.
#
# Start the recorder first, then:
#
#     scripts/rig_shot.sh rig_flash        # build here, sync, flash over SWD
#     scripts/rig_shot.sh rig_gdb          # reset, run a command, attach gdb
#     scripts/rig_shot.sh rig_full         # both, in one take
#     scripts/rig_shot.sh rig_dry          # the typist alone -- touches nothing
#
# A rig take refuses to start while anything on the Pi already holds the board
# (`pgrep` for pytest/openocd/gdb) -- manual runs take no flock, so this is the
# only guard there is.  `rig_dry` skips that check because it never gets near
# the board.
#
# NEVER interrupt a take that is mid-flash: OpenOCD holds the probe, and
# killing it there is how the board ends up wedged.  Let it finish or let it
# time out (--rig-timeout, default 20 min).

set -euo pipefail

TAKES=${YASOS_TAKES:-/run/media/mateusz/11B5C54B386D163A/Youtube/tinycc_closing_gap_to_gcc/tinycc-closing-gap-to-tcc-7/tinycc-closing-gap-to-tcc/recordings}
SHOT=${1:?usage: rig_shot.sh <rig_flash|rig_gdb|rig_full|rig_dry> [demo_shot.py options]}
shift || true

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)

# A bare option (--list) is not a take.
if [[ $SHOT == -* ]]; then
    exec python3 "$here/demo_shot.py" "$SHOT" "$@"
fi

stamp=$(date +%Y%m%d-%H%M%S)
name="$SHOT-$stamp"
mkdir -p "$TAKES" 2>/dev/null || TAKES=$(mktemp -d)

# --cwd so the prompt on camera is the repository, wherever this was invoked
# from, and so the take's own `./scripts/...` lines are the ones a viewer could
# retype.
status=0
python3 "$here/demo_shot.py" "$SHOT" --cwd "$repo" \
    --transcript "$TAKES/$name.raw" --report "$TAKES/$name.txt" "$@" || status=$?

echo "transcript: $TAKES/$name.raw" >&2
exit $status
