# Time zones

The kernel keeps UTC and has no idea of zones: `gettimeofday` reports
`tz_minuteswest` 0 and `settimeofday` ignores its `tz`, as on Linux. Local time
is libc's work (`libs/libc/localtime.c`): `localtime`, `mktime`, `strftime`'s
`%z`/`%Z`, `ctime` and everything built on them (`date`, `ls -l`, `make`'s
messages) follow the zone the process finds.

## Where the zone comes from

| `TZ`                              | zone                                                     |
|-----------------------------------|----------------------------------------------------------|
| unset                             | `/etc/localtime`, else UTC                               |
| `""`                              | UTC                                                      |
| `Europe/Warsaw`                   | the TZif file `$TZDIR/Europe/Warsaw`, else `/usr/share/zoneinfo/Europe/Warsaw` |
| `/path/to/file`                   | that TZif file                                           |
| `CET-1CEST,M3.5.0,M10.5.0/3`      | a POSIX TZ string: the rules written out, no file needed |

A leading `:` is skipped. A name is tried as a file first, as glibc does
(`EST5EDT` is both a valid POSIX string and a zone with real history); a value
with a comma is always a POSIX string. Anything that is neither a readable zone
nor a valid string is UTC. Names containing `..` are refused.

The zone is looked up once and kept; a process that changes `TZ` gets the new
zone at its next `localtime` (or `tzset`). `/etc/localtime` is read once per
process.

## The image

- `/usr/share/zoneinfo`: the whole IANA database, compiled at image build time
  from the in-tree [`tools/tzdata/tzdata.zi`](../tools/tzdata/README.md) by the
  host's `zic -b slim`, so every build ships the same zones. About 200 KB of
  romfs for 600 names (aliases become symlinks via `scripts/rootfs_dedupe.py`).
  No host `zic`: the build warns and the image has only POSIX strings and UTC.
- `/etc/localtime` -> `/var/etc/localtime`: the romfs is read-only, so the
  choice lives on the card's `/var`. Dangling (no card, nothing chosen) is UTC.
- `settz` (in-tree `usr/bin/settz`, `man settz`): `settz Europe/Warsaw` makes
  `/var/etc/localtime` a link to the zone (a link, not a copy, so a newer
  image's tzdata applies without running it again), `settz -u` removes it,
  `settz -l` lists the zones, `settz` alone shows the setting. Without a card
  `/var` is RAM and the choice lasts until reboot.

## What the code does

- TZif versions 1-4 (RFC 8536). The version 2+ body (64-bit times) is used when
  present; leap-second records are skipped (no `right/` zones are shipped).
  Before the first transition type 0 applies, after the last the footer's POSIX
  rules (or the last type when there is no footer).
- POSIX strings: `<...>` quoted names, `Jn`/`n`/`Mm.w.d` rules, rule times from
  -167 to 167 hours (RFC 8536's extension). Without a rule (`EST5EDT`) the US
  rules apply, as in glibc and musl. Rules are applied to every year,
  1970 or not; glibc applies none before 1970.
- `mktime` normalises out-of-range fields. A time skipped by a spring-forward
  jump is read with the offset from before it (02:30 -> 03:30 daylight time);
  with `tm_isdst` set, the time is read with that flavour's offset, so it picks
  one of the two 01:30s of the fall-back night. Both as glibc.
- `tzname`, `timezone` and `daylight` are set as glibc sets them; `daylight` is
  also set for a zone that only had daylight time in the past.
- Zone abbreviations are kept for the life of the process, so a `tm_zone` from
  before a change of `TZ` stays valid (toybox `date` switches `TZ` to parse its
  input).
- The kernel's static libc (`YASLIBC_NOOS`) has no files: only `TZ` strings and
  UTC, and the kernel calls none of this.

`time_t` is 32 bits on the device: times after 2038-01-19 do not exist there,
whatever the zone.

## Tests

`make -C libs/libc/tests` runs `tz_tests.c`: `localtime_r`, `mktime` and the
`tzset` globals compared with the host's glibc every 3 h 17 min 13 s from 1901
(1970 for POSIX strings) to 2100, in a dozen awkward zones (Lord Howe's
half-hour DST, Casablanca's negative DST, Apia skipping a day, Troll, Dublin),
for POSIX strings, the host's fat files and a slim set built with `zic -b slim`
the way the image is; plus gaps, overlaps, bad values and `timegm`
normalisation. The IANA cases are skipped on a host without zoneinfo.

`strptime_tests.c` compares `strptime` with glibc's on toybox's `date -d` /
`touch -d` formats, `sort -M`'s `%b` and the edge cases (two-digit years,
`%C`, `%j`, `%p`, padding, `%z`, `%s`, refusals): fields and where parsing
stopped must agree.
