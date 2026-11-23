#!/bin/bash
# run_selfhost.sh DIR ROOTFS_SHA KERNEL_SHA DEST delta|full LEVEL..., on the rig; see
# scripts/board_selfhost.py.  DIR holds img/, py/, payload<LEVEL>/ and gets logs/.
#
# Images live in DIR until the board is ours: another session's upload into the shared
# workdir would otherwise be flashed in place of ours, under our hashes.
set -u
D=$1 RS=$2 KS=$3 DEST=$4 MODE=$5
shift 5
HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE=${YASOS_RIG_REMOTE:-$HOME/yasos_remote_smoke}
W=$REMOTE/workdir
# The board: boards.py beside this script (YASOS_BOARD, else the first free board of pool
# dev; without a registry the single legacy board lock).  NOLOCK = not taken in 3000 s.
if [ -z "${YASOS_BOARD_LOCK_HELD:-}" ]; then
  export YASOS_RIG_HELD_MARK=$D/.board-held.$$
  rm -f "$YASOS_RIG_HELD_MARK"
  python3 "$HERE/boards.py" run --keeps-state --wait 3000 --what "run_selfhost $D" -- \
    bash "$0" "$D" "$RS" "$KS" "$DEST" "$MODE" "$@"
  rc=$?
  # Never got the board: busy (99) or no such board (2, boards.py says why above).
  [ $rc != 0 ] && [ ! -e "$YASOS_RIG_HELD_MARK" ] && echo "NOLOCK rc=$rc"
  rm -f "$YASOS_RIG_HELD_MARK"
  exit $rc
fi
[ -n "${YASOS_RIG_HELD_MARK:-}" ] && : > "$YASOS_RIG_HELD_MARK"
# Per board: the images it is flashed from and what it holds (reflash.sh derives the same).
IMG=$W
if [ -n "${YASOS_BOARD_STATE:-}" ] && [ -n "${YASOS_BOARD:-}" ]; then
  IMG=$W/board-$YASOS_BOARD
  echo "board $YASOS_BOARD"
fi
mkdir -p "$IMG"
check() {
  [ "$(sha256sum < "$IMG/rootfs.img" | cut -d' ' -f1)" = "$RS" ] &&
    [ "$(sha256sum < "$IMG/yasos_kernel" | cut -d' ' -f1)" = "$KS" ] || { echo "IMAGE CHANGED $1"; exit 8; }
}
cp "$D/img/rootfs.img" "$IMG/rootfs.img.new" && mv "$IMG/rootfs.img.new" "$IMG/rootfs.img"
cp "$D/img/yasos_kernel" "$IMG/yasos_kernel.new" && mv "$IMG/yasos_kernel.new" "$IMG/yasos_kernel"
check before
mkdir -p "$D/logs"
bash "$HERE/reflash.sh" "$RS" "$KS" > "$D/logs/reflash.log" 2>&1
rc=$?
echo "reflash rc=$rc"
[ $rc = 0 ] || exit $rc
check after
cd "$REMOTE" || exit 1
for L in "$@"; do
  workdir/venv/bin/python "$HERE/measure.py" "$D/payload$L" "$MODE" "$D/py" "$DEST" > "$D/logs/$L.log" 2>&1
  echo "$L measure rc=$?"
  check "after $L"
  MODE=delta
done
echo BOARD_DONE
