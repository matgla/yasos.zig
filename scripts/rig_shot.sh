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
#     scripts/rig_shot.sh crosstcc         # the cross compiler compiling tcc
#
# A rig take refuses to start while anything on the Pi already holds the board
# (`pgrep` for pytest/openocd/gdb) -- manual runs take no flock, so this is the
# only guard there is.  Only `rig_dry` skips that check, because it is the one
# take that touches nothing.  `crosstcc` used to skip it too, on the grounds
# that it was a build on this desk; that stopped being true on 2026-09-08, when
# it grew a `--connect` leg and started compiling a test on the board.
#
# NEVER interrupt a take that is mid-flash: OpenOCD holds the probe, and
# killing it there is how the board ends up wedged.  Let it finish or let it
# time out (--rig-timeout, default 20 min).

set -euo pipefail

# The drive root moved when the episode was split in two: one folder per
# part, each with its own recordings/ (README-split.md there). The old
# default pointed inside the pre-split tree, now _archive-2026-09-03.
PART=${YASOS_PART:-part1-becoming-a-compiler}
TAKES=${YASOS_TAKES:-/shared/data/Youtube/tinycc_closing_gap_to_gcc/$PART/recordings}
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
# The keylog is a working file, not a take: it goes in the hidden folder the
# recorder keeps its own sidecars in (record-typist-demo.sh, $SIDEDIR) so that
# a recordings directory lists takes and nothing else.
SIDE=${YASOS_SIDEDIR:-$TAKES/.sidecars}
mkdir -p "$SIDE"

# --cwd so the prompt on camera is the repository, wherever this was invoked
# from, and so the take's own `./scripts/...` lines are the ones a viewer could
# retype.
# The click track: the typist logs when each key was struck and
# utilities/keyclack.py (video repo) synthesises a keyboard from it afterwards.
# Nothing is played during the take -- the stage has no audio sink. Set
# YASOS_KEYLOG to have the log land where the recorder's mux looks for it.
status=0
python3 "$here/demo_shot.py" "$SHOT" --cwd "$repo" \
    --transcript "$TAKES/$name.raw" --report "$TAKES/$name.txt" \
    --keylog "$SIDE/$name.keys" "$@" || status=$?

if [ -n "${YASOS_KEYLOG:-}" ] && [ -s "$SIDE/$name.keys" ]; then
    cp -f "$SIDE/$name.keys" "$YASOS_KEYLOG"
fi

echo "transcript: $TAKES/$name.raw" >&2
exit $status
