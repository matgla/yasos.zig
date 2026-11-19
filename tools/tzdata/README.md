# tzdata.zi — the IANA time zone database, as zic input

`build_rootfs.sh` compiles this file with the host's `zic -b slim` into
`/usr/share/zoneinfo` in the image (libc reads it: `libs/libc/localtime.c`,
[`docs/timezones.md`](../../docs/timezones.md)). It is kept in the tree so
every build ships the same zones whatever tzdata the build machine has; only
`zic` comes from the host (glibc's libc-bin / glibc-common).

`tzdata.zi` is the compact, single-file form of the tz database's source
that tzdata packages install next to the binaries
(`/usr/share/zoneinfo/tzdata.zi`), and that `make tzdata.zi` produces in a
checkout of <https://github.com/eggert/tz>. Public domain, as the file's
header says.

Version: the first line (`# version 2026f`).

To update: copy a newer `/usr/share/zoneinfo/tzdata.zi` here (or one from a
tz release) and rebuild the rootfs.
