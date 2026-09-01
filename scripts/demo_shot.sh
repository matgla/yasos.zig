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
#
# The take's transcript comes back to $TAKES (default: the episode's recordings
# directory) as <shot>-<stamp>.raw, next to the video; feed it to
#     scripts/demo_shot.py --extract <that>.raw hello.bin
# to rebuild the binary the board produced and disassemble it on the host.

set -euo pipefail

RIG=${YASOS_RIG:-mateusz@192.168.0.113}
TAKES=${YASOS_TAKES:-/run/media/mateusz/11B5C54B386D163A/Youtube/tinycc_closing_gap_to_gcc/tinycc-closing-gap-to-tcc-7/tinycc-closing-gap-to-tcc/recordings}
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
status=0
ssh -t "$RIG" "python3 demo_shot.py $SHOT --transcript $name.raw --report $name.txt $*" \
    || status=$?

mkdir -p "$TAKES"
scp -q "$RIG:$name.raw" "$RIG:$name.txt" "$TAKES/" 2>/dev/null || true
echo "transcript: $TAKES/$name.raw" >&2
exit $status
