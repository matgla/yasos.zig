# Storage: SD card layout, /etc/fstab, mounting

## Layout

The root filesystem is the read-only romfs in flash. Everything writable lives
on the SD card, in four MBR partitions that `cardreformat` lays out (see
[Partitioning and formatting](#partitioning-and-formatting)):

| # | Label     | Type | Default size | Mounted at | Holds                                              |
|---|-----------|------|--------------|------------|----------------------------------------------------|
| 1 | `YASBOOT` | FAT  | 64 MiB       | `/boot`    | `yasboot/*.ybi` update images (docs/bootloader_plan.md §4.5) |
| 2 | `YASVAR`  | ext4 | 256 MiB      | `/var`     | `log/kernel.log`, `tmp/` (the /tmp spill)          |
| 3 | `YASOPT`  | ext4 | 25% of card  | `/opt`     | installed software                                 |
| 4 | `YASHOME` | ext4 | the rest     | `/home`    | `root/`, which is bind-mounted at `/root`          |

Partitions start on 1 MiB boundaries, the first at 1 MiB, which leaves the gap
after the MBR for yasboot (`scripts/write_yasboot.py`).

`/boot` stays FAT because yasboot reads it with a read-only FatFs: FAT32 from
512 MiB up, FAT12/16 below. Its label is written both into the boot sector,
where the kernel and `blkid` read it, and as the root directory's label entry,
where Windows shows it.

Everything else is ext4 through lwext4 (`libs/lwext4`, a fork; kernel driver
`source/fs/ext4/`): 1 KiB blocks, no journal, extents and hashed directories,
one inode per 8 KiB (16 KiB from 1 GiB up), the label in the superblock. Linux
mounts it as ext4 and `e2fsck` checks it. It has what FAT lacks -- permission
bits (execute is enforced), owners, symbolic and hard links, three timestamps.

Why ext4: a host benchmark with the kernel's cache configuration, costed with
the SD driver's timings (seconds, SPI / SDIO), against FAT32:

| Workload                                  | FAT32         | ext4, 1 KiB blocks |
|-------------------------------------------|--------------:|-------------------:|
| 500 small files: create, stat, read, delete | 64.4 / 68.8 | 28.1 / 31.8        |
| `ls -l` of a 500-entry directory          | 9.9 / 11.0    | 2.2 / 4.5          |
| mount and first write, 50% full           | 0.31 / 0.34   | 0.03 / 0.03        |
| 2000 synced log appends                   | 4.4 / 4.4     | 15.3 / 23.2        |
| compiler tree: 200 objects                | 23.8 / 7.8    | 42.6 / 23.0        |

It wins on directories and metadata (hash-indexed lookups instead of a linear
scan), loses on many small synced writes. littlefs was rejected by the same
benchmark: 3-107x slower than FAT everywhere, minutes for the first write after
mounting a half-full volume.

Cost on the RP2350: +60 KB of kernel text, +9 KB of static RAM (four lwext4
mount slots), and on the kernel heap the block caches: a volume holds up to 8
1 KiB blocks while it works, and the blocks nobody references are capped at 8
across all ext4 volumes together (`CONFIG_BLOCK_DEV_CACHE_IDLE_BUDGET` in
`source/fs/ext4/build.zig`), so idle volumes cost next to nothing. The board
defconfigs turn the FAT metadata cache off (`CONFIG_FATFS_CACHE_LINES=0`):
FAT is only `/boot` there, and the cache would hold ~20 KiB for it.
`tests/smoke/kernel_heap_test.py` prints what each step costs.

## /etc/fstab

`etc/fstab` in the tree. The kernel reads it at boot, after mounting the romfs
root and `/dev`, and mounts every line without `noauto`, in order
(`source/fs/mounter.zig`). Without an `/etc/fstab` it mounts a RAM-only
default (`mounter.default_fstab`) and says so.

```
# <source>      <target> <type> <options>                  <dump> <pass>
proc            /proc    proc   defaults                   0 0
LABEL=YASBOOT   /boot    vfat   nofail                     0 2
LABEL=YASVAR    /var     ext4   nofail,x-fallback=ramfs    0 2
LABEL=YASOPT    /opt     ext4   nofail                     0 2
LABEL=YASHOME   /home    ext4   nofail,x-fallback=ramfs    0 2
/home/root      /root    bind   x-mkdir                    0 0
tmpfs           /tmp     tmpfs  spill=/var/tmp             0 0
/dev/fatdisk0   /mnt     vfat   nofail,x-format-blank      0 0
```

Sources: `/dev/<device>`, `LABEL=<label>` (FAT or ext, looked up across every
disk's partitions), a directory for `bind`, anything for the types that need no
device. Types: `ext4` (`ext2`, `ext3` mean the same), `vfat` (`fat`, `msdos`),
`auto` (whichever of the two the device holds), `ramfs`, `tmpfs`, `proc`,
`bind`.

Options, beyond `ro` (enforced by the VFS), `rw`, `defaults`:

| Option             | Meaning                                                          |
|--------------------|------------------------------------------------------------------|
| `noauto`           | skipped at boot and by `mount -a`                                |
| `nofail`           | a failure at boot is logged at info level, not as an error       |
| `x-fallback=ramfs` | if the mount fails, mount an empty RamFs there, so the path stays writable |
| `x-format-blank`   | `vfat`/`ext4`: format the device if its first sectors are all zeros |
| `x-mkdir`          | `bind`: create the source directory first                        |
| `spill=DIR`        | `tmpfs`: where files too big for the RAM arena go (default `CONFIG_TMPFS_SPILL_DIRECTORY`, `/var/tmp`) |

Without a card (QEMU, or a board with the slot empty), `/var` and `/home` are
RAM fallbacks, `/root` is bound into the RAM `/home`, and `/boot` and `/opt`
are the empty romfs directories. The kernel log goes to
`/var/log/kernel.log` only when `/var` is real storage.

## At run time

- `mount`, `umount`, `df`, `blkid` (toybox) work as on Linux; `mount -a`
  mounts what is not mounted yet and skips the rest, so it is safe to repeat.
  `mount LABEL=YASOPT /opt` resolves the label in the kernel.
- `umount` refuses (EBUSY) while a process works inside the mount or has a
  file open under it, while something is mounted below it, and while it holds
  the source of a bind mount (so `/home` stays while `/root` is bound to it).
  The kernel's own users let go instead: unmounting `/var` closes the kernel
  log (lines wait in a 512-byte RAM ring) and stops the /tmp spill, so big
  /tmp files stay in the RAM arena until it is full. Only a /tmp file whose
  data is already in `/var/tmp` keeps `/var` busy -- delete it first. Mounting
  `/var` again (`mount -a`) gives both back; the log restarts in a new file.
- `/proc/mounts`, `/proc/partitions` and `/proc/filesystems` have the Linux
  formats.
- `chmod`, `chown`, `ln -s` and the umask are real (syscalls `fchmodat`,
  `fchownat`, `symlinkat`; libc applies the umask). ext4 keeps what they set;
  FAT and ramfs accept `chmod`/`chown` and keep nothing, as before; the romfs
  root answers EROFS. A script needs `chmod +x` to run from an ext4 volume.

## Devices

Disks register with the block layer (`source/kernel/drivers/block.zig`), which
publishes each MBR slot as `/dev/<disk>p<N>`, numbered from 1 as on Linux:
`/dev/mmc0p1`..`p4` for the card. **This is a renumbering: the first partition
used to be `/dev/mmc0p0`.** A disk whose first sector is a FAT boot sector
rather than an MBR has no partitions and is used whole (the QEMU `/mnt` image).

Block devices stat as `S_IFBLK` and answer `BLKGETSIZE64`, `BLKGETSIZE`,
`BLKSSZGET` and `BLKRRPART` (re-read the partition table; refused while any
partition of the disk is mounted). `off_t` is 32 bits, so tools reaching past
2 GiB on a card use `lseek64`.

## Partitioning and formatting

Three tools, as on Linux, and a script that runs them with the layout above:

- **`fdisk DEVICE`** edits the MBR (`apps/fdisk`): util-linux's commands and
  questions for primary partitions (`p n d t a o l w q`), sizes as `+64M` or,
  a yasos extension, `+25%` of the disk. Nothing reaches the disk before `w`,
  which also has the kernel re-read the table (BLKRRPART; refused while
  anything from the disk is mounted). Commands can be piped; piped input it
  refuses ends the session with nothing written. `fdisk -l DEVICE` lists.
- **`mkfs.fat [-n LABEL] [-F 12|16|32] [-s N] DEVICE`** and
  **`mkfs.ext4 [-L LABEL] DEVICE`** (`apps/mkfs`) format a volume with FatFs
  and lwext4, the code the kernel reads them with. `-p N` formats partition N
  of DEVICE's table instead of all of it -- how an image file on a PC, which
  has no partition nodes, is formatted.
- **`cardreformat [-y] [DEVICE]`** (`/usr/bin/cardreformat`, in the tree
  `usr/bin/cardreformat`) is the layout written down: `fdisk`, then the four
  `mkfs` runs. It defaults to `/dev/mmc0`, asks for YES unless `-y`, and
  refuses a disk with anything mounted from it.

On the device -- everything on the card is lost:

```
cd /                                   # a shell inside a mount keeps it busy
umount /root /home /var /opt /boot     # /root first: it is bound into /home
cardreformat                           # asks for YES
mount -a                               # the new layout, no reboot needed
```

A card that boots with RAM fallbacks (`cat /proc/mounts` shows `ramfs` on
`/var` and `/home`, nothing from `/dev/mmc0`) has nothing to unmount; unmount
the fallbacks anyway if `mount -a` should put the card there. The kernel makes
`/var/log`, the `/var/tmp` spill and `/home/root` itself when it first needs
them.

On a PC, with the same code built for the host (Linux's own `mkfs.ext4` makes
volumes lwext4 cannot use, see below):

```
make -C apps/fdisk host && make -C apps/mkfs host
FDISK=apps/fdisk/build/host/fdisk MKFS_FAT=apps/mkfs/build/host/mkfs.fat \
  MKFS_EXT4=apps/mkfs/build/host/mkfs.ext4 usr/bin/cardreformat /dev/sdX   # or an image file
```

`BOOT_SIZE`, `VAR_SIZE` and `OPT_SIZE` override the sizes (fdisk answers:
`+2M`, `+25%`, ...). `make -C apps/fdisk test` runs the table unit tests and an
image test that lays out a 16 MiB image and checks it with `sfdisk`, `blkid`,
`fsck.fat` and `e2fsck`. A card can also be checked on a PC:
`e2fsck -f /dev/sdX2` (yasos has no fsck).

## In QEMU

`scripts/qemu_mount.py --sdcard` puts a 16 MiB partitioned image (made by
`cardreformat` with the host tools, sizes shrunk to fit) in the an524's fatdisk
window, where it
shows up as `/dev/fatdisk0p1`..`p4` and /etc/fstab mounts it like a card.

```
scripts/qemu_mount.py --sdcard -c 'cat /proc/mounts' -c 'df'
scripts/qemu_mount.py --sdcard -c 'echo hi > /root/x' --pull card.img   # card image back
```

## Migrating a card from the old layout

The old kernel mounted the first partition, whatever it was, at `/root`, as
FAT. The new one mounts by label, so an old card boots with RAM fallbacks and
its data untouched. To keep it: `mount /dev/mmc0p1 /mnt`, copy what matters to the PC
(`scripts/transfer.py`), `umount /mnt`, run `cardreformat`, reboot, copy it back
under `/root` (the tcc corpus goes to `/root/ci` as before).

## Known limits

- No journal: a power cut in the middle of a metadata update can leave an
  ext4 volume needing `e2fsck` on a PC, as FAT would need `fsck.fat`. lwext4
  writes through (every metadata block goes to the card when it changes), and
  the superblock's free totals are brought up to date at unmount, so after an
  unclean stop `e2fsck -n` reports "free blocks count wrong" for the totals
  only -- harmless, it fixes them.
- A card formatted by Linux's `mke2fs` defaults (journal, 64bit, flex_bg,
  metadata_csum) is not what lwext4 is built for here; use yasos's
  `mkfs.ext4` (on the device, or the host build), or Linux's with
  `-O ^has_journal`.
- lwext4 cannot seek past the end of a file (no holes): `lseek` beyond EOF is
  EINVAL. `ftruncate` to grow writes zeros.
- FAT12/16 has no FSInfo sector, so the first `df` or allocation after mounting
  `/boot` scans its FAT: 64 sectors at the default size, once per mount.
- Fork changes in `libs/lwext4` (not upstream): a clock hook
  (`ext4_set_clock`) so creating, writing, truncating and unlinking keep
  timestamps; xattr API stubs when xattrs are compiled out; `ext4_user_*`
  prototypes; mkfs fixes for a partial last block group (free count) and for
  inodes per group not a multiple of 8 (bitmap padding) -- both made `e2fsck`
  complain about almost every freshly made volume.
- The SPI SD driver issues one command per sector; multi-block transfers would
  speed up every filesystem on the MSPC board.
- toybox `mount -a` does not implement `nofail`: a line that cannot mount is
  reported even so.
