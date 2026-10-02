#!/usr/bin/env bash
# Host end-to-end test: lay out a 16 MiB image the way usr/bin/cardreformat does
# a card (fdisk, then mkfs.fat and mkfs.ext4, all host builds) and check it
# with Linux tools that share no code with ours, FatFs or lwext4 (sfdisk,
# blkid, fsck.fat, e2fsck). Tools that are missing are skipped, not failed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/../../.."
export FDISK="$HERE/../build/host/fdisk"
export MKFS_FAT="$REPO/apps/mkfs/build/host/mkfs.fat"
export MKFS_EXT4="$REPO/apps/mkfs/build/host/mkfs.ext4"
export BOOT_SIZE=+2M VAR_SIZE=+4M OPT_SIZE=+2M
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/card.img"

truncate -s 16M "$IMG"
"$REPO/usr/bin/cardreformat" -y "$IMG" >/dev/null

if command -v sfdisk >/dev/null; then
  starts=$(sfdisk -d "$IMG" | awk -F'[=,]' '/start=/{gsub(/ /,"",$2); print $2}')
  [ "$(echo "$starts" | wc -l)" -eq 4 ] || { echo "expected 4 partitions"; exit 1; }
else
  starts="2048 6144 14336 18432"
fi

labels=""
i=0
for start in $starts; do
  i=$((i + 1))
  if command -v blkid >/dev/null; then
    label=$(blkid -p -O $((start * 512)) -s LABEL -o value "$IMG")
    labels="$labels $label"
  fi
  size=$(sfdisk -d "$IMG" 2>/dev/null | awk -F'[=,]' -v n="$i" '/start=/{c++; if (c==n) {gsub(/ /,"",$4); print $4}}')
  type=$(sfdisk -d "$IMG" 2>/dev/null | awk -F'type=' -v n="$i" '/start=/{c++; if (c==n) print $2}')
  dd if="$IMG" of="$WORK/p$i" bs=512 skip="$start" count="${size:-4096}" status=none
  if [ "$type" = "83" ]; then
    if command -v e2fsck >/dev/null; then
      e2fsck -fn "$WORK/p$i" >/dev/null 2>&1 || { echo "e2fsck failed on partition $i"; exit 1; }
    fi
  elif command -v fsck.fat >/dev/null; then
    fsck.fat -n "$WORK/p$i" >/dev/null || { echo "fsck.fat failed on partition $i"; exit 1; }
  fi
done
if command -v blkid >/dev/null; then
  [ "$labels" = " YASBOOT YASVAR YASOPT YASHOME" ] || { echo "labels:$labels"; exit 1; }
fi

# A second run over an existing card keeps the MBR's boot code bytes.
printf 'BOOTCODE' | dd of="$IMG" bs=1 seek=0 conv=notrunc status=none
"$REPO/usr/bin/cardreformat" -y "$IMG" >/dev/null
[ "$(head -c 8 "$IMG")" = "BOOTCODE" ] || { echo "boot code lost"; exit 1; }

# The default layout does not fit 16 MiB: fdisk refuses, nothing is formatted.
truncate -s 16M "$WORK/small.img"
if env -u BOOT_SIZE -u VAR_SIZE -u OPT_SIZE "$REPO/usr/bin/cardreformat" -y "$WORK/small.img" >/dev/null 2>&1; then
  echo "accepted a card too small"; exit 1
fi

# A whole-disk FAT volume (the old card layout) is replaced, not kept in front
# of the table.
"$MKFS_FAT" "$WORK/small.img" >/dev/null
"$REPO/usr/bin/cardreformat" -y "$WORK/small.img" >/dev/null
[ "$(sfdisk -d "$WORK/small.img" 2>/dev/null | grep -c start=)" -eq 4 ] || { echo "old FAT volume survived"; exit 1; }

# mkfs refuses a partition the table does not have.
if "$MKFS_EXT4" -p 3 "$WORK/p1" >/dev/null 2>&1; then
  echo "mkfs.ext4 formatted a missing partition"; exit 1
fi
echo "image test passed"
