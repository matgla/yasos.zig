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
 *   touch [-acm] [-r REF] FILE...
 *
 *   -a   set only the access time
 *   -m   set only the modification time
 *   -c   do not create a file that does not exist
 *   -r   take the times from REF instead of the current time
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *program) {
  fprintf(stderr, "Usage: %s [-acm] [-r REF] FILE...\n", program);
}

int main(int argc, char *argv[]) {
  int set_access = 0;
  int set_modify = 0;
  int no_create = 0;
  const char *reference = NULL;

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
        /* -r takes the reference path, either glued on or as the next word. */
        if (arg[c + 1] != '\0') {
          reference = &arg[c + 1];
          c = (int)strlen(arg) - 1;
        } else if (index + 1 < argc) {
          reference = argv[++index];
        } else {
          usage(argv[0]);
          return 1;
        }
        break;
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

  struct timespec times[2];
  const struct timespec *requested = NULL;

  if (reference != NULL) {
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

  if (reference != NULL && (!set_access || !set_modify)) {
    /* -r with -a or -m: keep the reference value for the half that was asked
       for and omit the other. */
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
