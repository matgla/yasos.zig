/**
 * touch.c
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, either version
 * 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be
 * useful, but WITHOUT ANY WARRANTY; without even the implied
 * warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 * PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General
 * Public License along with this program. If not, see
 * <https://www.gnu.org/licenses/>.
 */

/*
 * touch -- update a file's timestamps, creating it if it is not there.
 *
 * The version this replaces opened every named file with fopen(path, "w"),
 * which is not what touch does: "w" truncates, so `touch existing-file` threw
 * the file away.  It also never touched a timestamp, because until now there
 * were no timestamps to touch -- every file on the system reported mtime 0.
 * Both halves are fixed here, on top of the utimensat(2) the kernel now
 * implements.
 *
 * Two consequences worth stating, because they are what this was for:
 *
 *  - `touch` on romfs fails, with "Read-only file system".  It has to: the
 *    image has no timestamp field, so there is nowhere to write one, and a
 *    touch that silently did nothing would leave `make` believing a
 *    prerequisite had moved when it had not.
 *
 *  - `touch` on a FAT volume rounds down to an even second.  That is the
 *    format -- see source/fs/fatfs/fat_time.zig -- not a bug here.
 *
 * Usage:
 *   touch [-acm] [-r REF | -d DATE | -t STAMP] FILE...
 *
 *   -a   set only the access time
 *   -m   set only the modification time
 *   -c   do not create a file that does not exist
 *   -r   take the times from REF instead of the current time
 *   -d   use DATE: @SECONDS, or "YYYY-MM-DD[ |T]hh:mm[:ss[.frac]]",
 *        "YYYY-MM-DD", "hh:mm[:ss]" (today), or date(1)'s own output
 *        ("Tue Jul  1 12:34:56 CEST 2025"); local time unless followed by
 *        Z or +hh[:mm] / -hh[:mm]
 *   -t   use STAMP, POSIX's [[CC]YY]MMDDhhmm[.ss], in local time
 */

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *program) {
  fprintf(stderr, "Usage: %s [-acm] [-r REF | -d DATE | -t STAMP] FILE...\n", program);
}

/* -d: the formats toybox's date -d takes (lib/xwrap.c xparsedate), so the
   two read the same strings. Fields a format leaves out come from now: a bare
   time is today. Returns 0 and fills `out`, or -1. */
static int parse_date(const char *str, struct timespec *out) {
  static const char *const formats[] = {
      "%Y-%m-%d %T", "%Y-%m-%dT%T", "%a %b %e %H:%M:%S %Z %Y", "%H:%M:%S",
      "%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M", "%Y-%m-%d", "%H:%M",
  };
  const char *p;
  char *end;

  out->tv_nsec = 0;
  if (*str == '@') {
    errno = 0;
    long long secs = strtoll(str + 1, &end, 10);
    if (end == str + 1 || errno)
      return -1;
    p = end;
    if (*p == '.') {
      long scale = 100000000L;
      for (p++; isdigit((unsigned char)*p); p++, scale /= 10)
        out->tv_nsec += (*p - '0') * scale;
    }
    if (*p)
      return -1;
    out->tv_sec = (time_t)secs;
    return 0;
  }

  time_t now = time(NULL);
  for (size_t i = 0; i < sizeof(formats) / sizeof(formats[0]); i++) {
    struct tm tm;
    localtime_r(&now, &tm);
    tm.tm_hour = tm.tm_min = tm.tm_sec = 0;
    tm.tm_isdst = -1;
    if (!(p = strptime(str, formats[i], &tm)))
      continue;
    long nsec = 0;
    if (*p == '.' && isdigit((unsigned char)p[1])) {
      long scale = 100000000L;
      for (p++; isdigit((unsigned char)*p); p++, scale /= 10)
        nsec += (*p - '0') * scale;
    }
    while (*p == ' ')
      p++;
    /* A zone of its own: UTC, or an offset from it. */
    int zoned = 0;
    long gmtoff = 0;
    if (*p == 'Z' || *p == '+' || *p == '-') {
      struct tm off;
      memset(&off, 0, sizeof(off));
      const char *q = strptime(p, "%z", &off);
      if (!q)
        continue;
      zoned = 1;
      gmtoff = off.tm_gmtoff;
      p = q;
    }
    while (*p == ' ')
      p++;
    if (*p)
      continue;
    time_t t;
    if (zoned) {
      tm.tm_isdst = 0;
      t = timegm(&tm) - gmtoff;
    } else {
      t = mktime(&tm);
    }
    if (t == (time_t)-1 && (tm.tm_year != 69 || tm.tm_mon != 11 || tm.tm_mday != 31))
      return -1;
    out->tv_sec = t;
    out->tv_nsec = nsec;
    return 0;
  }
  return -1;
}

/* -t [[CC]YY]MMDDhhmm[.ss], local time. A two-digit year is 1969-2068, as
   POSIX has it; without one, this year. */
static int parse_stamp(const char *str, struct timespec *out) {
  const char *dot = strchr(str, '.');
  size_t digits = dot ? (size_t)(dot - str) : strlen(str);
  const char *format;
  for (size_t i = 0; i < digits; i++)
    if (!isdigit((unsigned char)str[i]))
      return -1;
  if (digits == 8)
    format = "%m%d%H%M";
  else if (digits == 10)
    format = "%y%m%d%H%M";
  else if (digits == 12)
    format = "%C%y%m%d%H%M";
  else
    return -1;
  if (dot && !(isdigit((unsigned char)dot[1]) && isdigit((unsigned char)dot[2]) && !dot[3]))
    return -1;

  time_t now = time(NULL);
  struct tm tm;
  localtime_r(&now, &tm);
  tm.tm_sec = 0;
  tm.tm_isdst = -1;
  char buf[16];
  memcpy(buf, str, digits);
  buf[digits] = '\0';
  const char *p = strptime(buf, format, &tm);
  if (!p || *p)
    return -1;
  if (dot)
    tm.tm_sec = (dot[1] - '0') * 10 + (dot[2] - '0');
  if (tm.tm_sec > 60)
    return -1;
  out->tv_sec = mktime(&tm);
  out->tv_nsec = 0;
  return 0;
}

int main(int argc, char *argv[]) {
  int set_access = 0;
  int set_modify = 0;
  int no_create = 0;
  const char *reference = NULL;
  const char *date = NULL;
  const char *stamp = NULL;

  int index = 1;
  for (; index < argc; ++index) {
    const char *arg = argv[index];
    if (arg[0] != '-' || arg[1] == '\0') {
      break;
    }
    if (strcmp(arg, "--") == 0) {
      ++index;
      break;
    }
    for (int c = 1; arg[c] != '\0'; ++c) {
      switch (arg[c]) {
      case 'a':
        set_access = 1;
        break;
      case 'm':
        set_modify = 1;
        break;
      case 'c':
        no_create = 1;
        break;
      case 'r':
      case 'd':
      case 't': {
        /* Each takes a value, either glued on or as the next word. */
        const char *value;
        if (arg[c + 1] != '\0') {
          value = &arg[c + 1];
        } else if (index + 1 < argc) {
          value = argv[++index];
        } else {
          usage(argv[0]);
          return 1;
        }
        if (arg[c] == 'r')
          reference = value;
        else if (arg[c] == 'd')
          date = value;
        else
          stamp = value;
        c = (int)strlen(arg) - 1;
        break;
      }
      default:
        usage(argv[0]);
        return 1;
      }
    }
  }

  if (index >= argc) {
    usage(argv[0]);
    return 1;
  }

  /* Neither -a nor -m means both, which is the common case. */
  if (!set_access && !set_modify) {
    set_access = 1;
    set_modify = 1;
  }

  if ((reference != NULL) + (date != NULL) + (stamp != NULL) > 1) {
    fprintf(stderr, "touch: -r, -d and -t each give the time; use one\n");
    return 1;
  }

  struct timespec times[2];
  const struct timespec *requested = NULL;

  if (date != NULL || stamp != NULL) {
    if ((date ? parse_date(date, &times[0]) : parse_stamp(stamp, &times[0])) != 0) {
      fprintf(stderr, "touch: invalid date '%s'\n", date ? date : stamp);
      return 1;
    }
    times[1] = times[0];
    requested = times;
  } else if (reference != NULL) {
    struct stat reference_info;
    if (stat(reference, &reference_info) != 0) {
      fprintf(stderr, "touch: cannot stat '%s'\n", reference);
      return 1;
    }
    times[0] = reference_info.st_atim;
    times[1] = reference_info.st_mtim;
    requested = times;
  } else if (!set_access || !set_modify) {
    /* One half only. UTIME_OMIT is how the other half is left alone; with
       both halves wanted, a NULL `times` says "now" and says it more
       cheaply. */
    times[0].tv_sec = 0;
    times[0].tv_nsec = set_access ? UTIME_NOW : UTIME_OMIT;
    times[1].tv_sec = 0;
    times[1].tv_nsec = set_modify ? UTIME_NOW : UTIME_OMIT;
    requested = times;
  }

  if (requested == times && (reference != NULL || date != NULL || stamp != NULL) &&
      (!set_access || !set_modify)) {
    /* -r, -d or -t with -a or -m: keep the given value for the half that was
       asked for and omit the other. */
    if (!set_access) {
      times[0].tv_nsec = UTIME_OMIT;
    }
    if (!set_modify) {
      times[1].tv_nsec = UTIME_OMIT;
    }
  }

  int status = 0;
  for (; index < argc; ++index) {
    const char *path = argv[index];

    if (!no_create) {
      /* O_CREAT without O_TRUNC: bring the file into existence if it is not
         there, and leave every byte of it alone if it is. */
      int fd = open(path, O_WRONLY | O_CREAT, 0666);
      if (fd >= 0) {
        close(fd);
      } else if (access(path, F_OK) != 0) {
        fprintf(stderr, "touch: cannot create '%s'\n", path);
        status = 1;
        continue;
      }
      /* A file that exists but could not be opened for writing (a directory,
         or a read-only mount) still gets its timestamps tried below -- the
         open was only ever about creating it. */
    }

    if (utimensat(AT_FDCWD, path, requested, 0) != 0) {
      fprintf(stderr, "touch: cannot set times on '%s'\n", path);
      status = 1;
    }
  }

  return status;
}
