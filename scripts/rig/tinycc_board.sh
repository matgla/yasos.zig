#!/bin/bash
# tinycc_board.sh DIR LOCK_WAIT FLASH|NOFLASH ROOTFS_SHA KERNEL_SHA ARGS..., on the rig; see
# scripts/tinycc_board.py.  DIR holds img/ and py/.  Images stay in DIR until the board is
# ours: another session's upload into the shared workdir would otherwise be flashed.
#
# The board comes from boards.py beside this script: YASOS_BOARD names one, else the board
# DIR used last (DIR/rig-board: the card keeps what earlier calls pushed there), else the
# first free board of pool dev.  Without a board registry: the single legacy board lock.
set -u
D=$1 WAIT=$2 FLASH=$3 RS=$4 KS=$5
shift 5
HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE=${YASOS_RIG_REMOTE:-$HOME/yasos_remote_smoke}
W=$REMOTE/workdir
if [ -z "${YASOS_BOARD_LOCK_HELD:-}" ]; then
  if [ -z "${YASOS_BOARD:-}" ] && [ -s "$D/rig-board" ] &&
     python3 "$HERE/boards.py" env "$(cat "$D/rig-board")" > /dev/null 2>&1; then
    YASOS_BOARD=$(cat "$D/rig-board"); export YASOS_BOARD
  fi
  export YASOS_RIG_HELD_MARK=$D/.board-held.$$
  rm -f "$YASOS_RIG_HELD_MARK"
  python3 "$HERE/boards.py" run --keeps-state --wait "$WAIT" --what "$(basename "$0") $D" -- \
    bash "$0" "$D" "$WAIT" "$FLASH" "$RS" "$KS" "$@"
  rc=$?
  if [ $rc != 0 ] && [ ! -e "$YASOS_RIG_HELD_MARK" ]; then
    [ $rc = 99 ] && echo "tinycc_board: still busy" || echo "tinycc_board: no board (boards.py rc=$rc)"
  fi
  rm -f "$YASOS_RIG_HELD_MARK"
  exit $rc
fi
[ -n "${YASOS_RIG_HELD_MARK:-}" ] && : > "$YASOS_RIG_HELD_MARK"
# Per board: the images it is flashed from and what it holds (reflash.sh derives the same).
IMG=$W
if [ -n "${YASOS_BOARD_STATE:-}" ] && [ -n "${YASOS_BOARD:-}" ]; then
  IMG=$W/board-$YASOS_BOARD
  echo "$YASOS_BOARD" > "$D/rig-board"
  echo "tinycc_board: board $YASOS_BOARD"
fi
mkdir -p "$IMG"
check() {
  [ "$(sha256sum < "$IMG/rootfs.img" | cut -d' ' -f1)" = "$RS" ] &&
    [ "$(sha256sum < "$IMG/yasos_kernel" | cut -d' ' -f1)" = "$KS" ] || { echo "IMAGE CHANGED $1"; exit 8; }
}
if [ "$FLASH" = FLASH ]; then
  cp "$D/img/rootfs.img" "$IMG/rootfs.img.new" && mv "$IMG/rootfs.img.new" "$IMG/rootfs.img"
  cp "$D/img/yasos_kernel" "$IMG/yasos_kernel.new" && mv "$IMG/yasos_kernel.new" "$IMG/yasos_kernel"
  check before
  bash "$HERE/reflash.sh" "$RS" "$KS" > "$D/reflash.log" 2>&1
  rc=$?
  echo "tinycc_board: flashed, rc=$rc"
  [ $rc = 0 ] || { tail -20 "$D/reflash.log"; exit $rc; }
  check after
fi
cd "$REMOTE" || exit 1
exec workdir/venv/bin/python "$D/py/tinycc_board.py" "$@"
