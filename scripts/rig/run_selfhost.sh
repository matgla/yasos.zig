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
exec 9>/var/lock/rp2350-board.lock
flock -w 3000 9 || { echo NOLOCK; exit 99; }
check() {
  [ "$(sha256sum < "$W/rootfs.img" | cut -d' ' -f1)" = "$RS" ] &&
    [ "$(sha256sum < "$W/yasos_kernel" | cut -d' ' -f1)" = "$KS" ] || { echo "IMAGE CHANGED $1"; exit 8; }
}
cp "$D/img/rootfs.img" "$W/rootfs.img.new" && mv "$W/rootfs.img.new" "$W/rootfs.img"
cp "$D/img/yasos_kernel" "$W/yasos_kernel.new" && mv "$W/yasos_kernel.new" "$W/yasos_kernel"
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
