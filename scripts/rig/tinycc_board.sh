#!/bin/bash
# tinycc_board.sh DIR LOCK_WAIT FLASH|NOFLASH ROOTFS_SHA KERNEL_SHA ARGS..., on the rig; see
# scripts/tinycc_board.py.  DIR holds img/ and py/.  Images stay in DIR until the board is
# ours: another session's upload into the shared workdir would otherwise be flashed.
set -u
D=$1 WAIT=$2 FLASH=$3 RS=$4 KS=$5
shift 5
HERE=$(cd "$(dirname "$0")" && pwd)
REMOTE=${YASOS_RIG_REMOTE:-$HOME/yasos_remote_smoke}
W=$REMOTE/workdir
exec 9>/var/lock/rp2350-board.lock
if ! flock -n 9; then
  echo "tinycc_board: the board is busy, waiting up to $WAIT s for it"
  flock -w "$WAIT" 9 || { echo "tinycc_board: still busy"; exit 99; }
fi
check() {
  [ "$(sha256sum < "$W/rootfs.img" | cut -d' ' -f1)" = "$RS" ] &&
    [ "$(sha256sum < "$W/yasos_kernel" | cut -d' ' -f1)" = "$KS" ] || { echo "IMAGE CHANGED $1"; exit 8; }
}
if [ "$FLASH" = FLASH ]; then
  cp "$D/img/rootfs.img" "$W/rootfs.img.new" && mv "$W/rootfs.img.new" "$W/rootfs.img"
  cp "$D/img/yasos_kernel" "$W/yasos_kernel.new" && mv "$W/yasos_kernel.new" "$W/yasos_kernel"
  check before
  bash "$HERE/reflash.sh" "$RS" "$KS" > "$D/reflash.log" 2>&1
  rc=$?
  echo "tinycc_board: flashed, rc=$rc"
  [ $rc = 0 ] || { tail -20 "$D/reflash.log"; exit $rc; }
  check after
fi
cd "$REMOTE" || exit 1
exec workdir/venv/bin/python "$D/py/tinycc_board.py" "$@"
