#!/bin/bash
# Push demo_shot.py to the rig that owns the board and play a take on it.
#
# Everything before the take is quiet and then erased (demo_shot.py clears the
# screen), so the recorded terminal only ever shows the board.  Start the
# recorder first, then run this.
#
#     scripts/demo_shot.sh full
#     scripts/demo_shot.sh vi --cps 20
#     scripts/demo_shot.sh width          # the two-kernel timing beat
#     scripts/demo_shot.sh xip            # /proc/xip around five compiles
#
# The take's transcript comes back to $TAKES (default: the episode's recordings
# directory) as <shot>-<stamp>.raw, next to the video (the keylog goes to
# $TAKES/.sidecars, with the recorder's own working files); feed it to
#     scripts/demo_shot.py --extract <that>.raw hello.bin
# to rebuild the binary the board produced and disassemble it on the host.

set -euo pipefail

RIG=${YASOS_RIG:-mateusz@192.168.0.113}
# The drive root moved when the episode was split in two (README-split.md):
# one folder per part, each with its own recordings/.  The old default
# pointed inside the pre-split tree, which is now _archive-2026-09-03.
PART=${YASOS_PART:-part1-becoming-a-compiler}
TAKES=${YASOS_TAKES:-/shared/data/Youtube/tinycc_closing_gap_to_gcc/$PART/recordings}
SHOT=${1:?usage: demo_shot.sh <shot> [demo_shot.py options]}
shift || true

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scp -q "$here/demo_shot.py" "$RIG:demo_shot.py"

# demo/ goes with it, and under the same name: the `width` shot reads
# demo/div10.c *at take time* -- that is what stops the listing on camera and
# the listing that compiles from drifting apart -- and it looks for it beside
# demo_shot.py.
ssh "$RIG" "mkdir -p demo"
scp -q "$here/demo/"*.c "$RIG:demo/"

# A bare option (--list, --extract, --disasm) is not a take: pass it straight
# through, with no transcript to name after it.
if [[ $SHOT == -* ]]; then
    exec ssh "$RIG" "python3 demo_shot.py $SHOT $*"
fi

stamp=$(date +%Y%m%d-%H%M%S)
name="$SHOT-$stamp"

# -t so the remote side gets a pty and reports THIS terminal's size to vi.
# --quiet, because this wrapper exists to shoot takes: `ssh -t` gives the
# remote side one pty, so its stderr lands on the recorded screen whatever we
# redirect, and twenty-five verdict lines there scroll the take's payoff out of
# the last frames of the clip.  They go to $name.txt instead, and the two lines
# below -- the summary and where to read the rest -- are all that reaches the
# frame.
# The click track.  Nothing is played during a take -- the stage has no audio
# sink and an audio server's timing would drift against the picture -- so the
# board typist writes down *when* each key went out on the wire, and
# utilities/keyclack.py in the video repo synthesises a mechanical keyboard
# from that afterwards, sample-accurate by construction.  The log is written on
# the rig next to the transcript and copied back with it; set YASOS_KEYLOG to
# have it land where the recorder expects it, which is what
# `record-typist-demo.sh` sets $KEYLOG to.
status=0
ssh -t "$RIG" "python3 demo_shot.py $SHOT --transcript $name.raw --report $name.txt --keylog $name.keys --quiet $*" \
    || status=$?

# The keylog is a working file -- nothing plays it, keyclack.py reads it once
# to synthesise the clicks -- so it lands in the hidden folder the recorder
# keeps its own sidecars in (record-typist-demo.sh, $SIDEDIR) rather than among
# the takes.  The transcript and the verdicts stay beside the video: those are
# read by hand.
SIDE=${YASOS_SIDEDIR:-$TAKES/.sidecars}
mkdir -p "$TAKES" "$SIDE"
scp -q "$RIG:$name.raw" "$RIG:$name.txt" "$TAKES/" 2>/dev/null || true
scp -q "$RIG:$name.keys" "$SIDE/" 2>/dev/null || true
if [ -n "${YASOS_KEYLOG:-}" ] && [ -s "$SIDE/$name.keys" ]; then
    cp -f "$SIDE/$name.keys" "$YASOS_KEYLOG"
fi
[ -s "$TAKES/$name.txt" ] && tail -1 "$TAKES/$name.txt" >&2
echo "verdicts: $TAKES/$name.txt" >&2
echo "transcript: $TAKES/$name.raw" >&2
exit $status
