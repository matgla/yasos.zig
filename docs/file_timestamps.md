# Time and file timestamps

How this system knows what time it is, and what each filesystem does with that.

## The problem this solves

Until this landed, every file on the board reported `mtime` 0. `ls -l` printed
the same date for romfs, for `/tmp` and for a file written a second earlier, and
`touch` moved nothing — it was a `fopen(path, "w")` that emptied the file
instead. The consequence that mattered: **`make` could never see a prerequisite
as newer than its target**, so incremental builds on the device were driven by
target *existence* alone. Delete the object and it rebuilds; edit the source and
nothing happens.

## The clock

There is no battery-backed RTC on any of these boards, so at reset there is
nothing to read a date out of. `hal.time.get_time_us()` counts microseconds
since *this* boot and knows nothing about the epoch.

`source/kernel/time.zig` builds the wall clock on top of it as a single offset:

```
realtime_us() = hal.time.get_time_us() + realtime_offset_us
```

`settimeofday(2)` stores `wanted - uptime` into that offset; `gettimeofday(2)`
and `time(2)` read it back. The monotonic clock underneath is never touched, so
anything measuring a *duration* across a clock set — `sleep`, the scheduler,
`apps/time` — sees the time that actually passed, not the size of the jump.

The offset lives in a `Seq64` seqlock rather than an atomic: it is 64 bits on a
32-bit core, and a plain two-word read can tear across a `settimeofday` on the
other core and return an instant that never existed.

### Where it starts

The offset does not start at zero. It starts at the **build time of the image
this kernel embeds** — `rootfs.img`'s mtime, read by `build.zig`
(`rootfs_build_epoch`) and passed in as a build option.

That matters because the mount points are created *during boot*, before anything
can set the clock, and ramfs stores an absolute instant (it has to — otherwise
`touch -d 2001` would drift the next time the clock moved). With a zero offset,
`/tmp` and `/root` were stamped 1970 and stayed 1970 for the rest of the boot no
matter what the clock was set to afterwards. Starting from the build time makes
that stamp a real date, correctly ordered before everything written since.

It is the image's mtime rather than "now" on purpose: "now" changes on every
invocation and would invalidate the build cache each time, where the image's
timestamp only moves when the image does — which is exactly when the kernel is
relinked anyway, since it embeds it.

Either way the clock advances at one second per second, so a file written after
another has a larger timestamp, which is the only property `make` needs. Setting
the clock sharpens the instant without changing that. One visible consequence:
after the harness sets the clock, `/tmp` and `/root` still read as of the build
while everything re-dated from an uptime (romfs, `/dev`) reads as of boot. Both
are before anything written since, which is what the ordering has to give.

### Who sets it

- `date -s @SECONDS` (toybox's `date`, CONFIG_DATE), typed at the shell.
- The smoke harness, once per boot, from the host's clock —
  `Session._set_target_clock` in `tests/smoke/framework/session.py`. It hangs
  off the reset path rather than a fixture because a reset is exactly when the
  clock needs setting: that covers a whole suite (one reset at the start) and a
  single test against a board that has just rebooted, with no per-test command
  in either case.

## What each filesystem does

| | timestamps | `utimens` |
|---|---|---|
| **ramfs** (`/tmp`, `/root` fallback) | per inode, microsecond, from the kernel clock | yes |
| **romfs** (`/`) | the whole image reports its mount time | refused (`EROFS`) |
| **FatFs** (`/mnt`, SD) | one per directory entry, two-second granularity; the volume root reports mount time | modification time only |
| **procfs** (`/proc`) | now, on every stat | refused (`EROFS`) |
| **driverfs** (`/dev`) | mount time | refused (`EROFS`) |
| **littlefs** | none | refused (`ENOTSUP`) |

procfs is the one that answers "now" rather than a stored instant, and that is
the honest answer rather than a shrug: nothing there is stored, so a file's
contents are produced by the read that asks for them and the moment it was last
modified *is* the moment you asked. Linux answers the same way.

**ramfs** keeps a `FileTimes` on the body (`RamFsData`), so hard links share one
set — timestamps belong to the inode, not to the name. Directories keep theirs
in the allocation that already held the refcount, because a directory handle is
copied by value on clone and anything a second handle must see has to live
behind a pointer. Writing moves modification and change; reading moves access;
adding or removing a directory entry rewrites the directory and moves its
modification time.

**romfs** has no timestamp field anywhere in the format — not per entry, not in
the volume header — and its contents cannot change while it is mounted, so one
date for the whole image is all there is to say. It records the *uptime* it was
mounted at and re-dates that against the current offset on every `stat`. Stamped
with the wall clock at mount instead, the whole rootfs would read 1970 forever,
because the mount happens long before anything sets the clock.

**FatFs** needed two halves. Reading: `FILINFO.fdate`/`ftime` converted in
`source/fs/fatfs/fat_time.zig`, which also clamps at both ends — FAT's epoch is
1980 and its year is an unsigned offset from it, so an unclamped write of the
default 1970 clock would underflow. Writing: FatFs asks for the date through a
context-free C callback (`get_fattime`), so the only way to hand it a clock is a
global; zfat exposes `rtc_hook` and `FatFs.init` points it at the kernel clock.
The build previously passed `static-rtc` to zfat, which compiles FatFs with
`FF_FS_NORTC` and stamps every entry with one fixed date — that switch is gone
from `build.zig`.

FAT stores seconds in units of two, so a timestamp written and read straight
back can come back up to a second earlier. That is the format, and it is why
`make` compares with *older than* rather than *not equal*.

## utimensat(2)

`touch` reaches the filesystems through `utimensat`. `UTIME_NOW` and
`UTIME_OMIT` are resolved in the syscall handler, so a filesystem is handed
`TimeStamps{ accessed: ?timespec, modified: ?timespec }` with `null` meaning
"leave this one alone" and never has to know the sentinels exist.

A filesystem that cannot store a timestamp **fails** rather than accepting and
ignoring: a `touch` reported as having worked, on a file whose date cannot move,
leaves `make` believing a prerequisite is newer than it is.

## Stat'ing a mount point itself

The VFS routes a path by stripping the mount's prefix, so `stat("/tmp")` reaches
the filesystem mounted there as `stat("")`. ramfs normalised that through
`std.fs.path.resolve`, which answers `"."` for anything that reduces to nothing
— it is written for a caller that has a working directory, and a filesystem does
not. The `"."` then became a lookup for an entry named `.`, so `/tmp` could not
be stat'd at all and `ls -la /` printed a row of question marks where it should
be. `resolve_into` now maps both the empty string and `"."` to the root.

## readlink(2)

Found while reading the same `ls -l` output: `readlinkat` in libc was a stub that
`memcpy`'d the literal string `"/usr/bin/sh"` into the caller's buffer and
reported success, so every symbolic link in the system read back as the shell —
`/bin` and `/lib`, which point at `usr/bin` and `usr/lib`, both displayed as
`-> /usr/bin/sh`. The kernel had a working readlink all along (the VFS resolves
links with it); there was simply no syscall in front of it. There is now
(`sys_readlink`), and `readlink`/`readlinkat` both go through it.

## The trap that cost the most time here

`time_t` was `long long` while `struct timespec.tv_sec` was `long`. POSIX says
that field *is* a `time_t`, and toybox's `ls -l` reads a date with
`localtime(&st->st_mtime)` — so it handed `localtime` a four-byte field to read
eight bytes out of, taking `tv_nsec` as the high word. This was invisible while
every timestamp was zero and produced years like 8581 the moment they were not.
`time_t` is now `long`, which costs the 2038 rollover and buys a `struct stat`
whose layout does not change.

The second half of that trap: `libs/libc/Makefile` tracked no header
dependencies, so narrowing the type left objects behind that still used the old
one. Not a link error — a libc whose `localtime` disagreed with its callers
about a struct. Every object there now depends on every header.

## Still not done

`ls -l` prints `d---------` for everything: no filesystem here reports permission
bits, only the `S_IFxxx` type. romfs and ramfs have nowhere to store a mode
(neither format has one), so this would be a policy — "everything is 0755, or
0644 for a regular file" — rather than stored data. Harmless for now because
nothing in this kernel enforces permissions, but a program that checks
`st_mode & S_IXUSR` before exec'ing would refuse.
