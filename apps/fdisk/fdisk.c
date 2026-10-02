/*
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

/* fdisk: edit a disk's MBR partition table.
 *
 * The util-linux dialogue for the DOS label, primary partitions only: the same
 * one-letter commands and the same questions in the same order, so what works
 * typed works piped -- `printf 'o\nn\np\n1\n\n+64M\nw\n' | fdisk /dev/mmc0`,
 * as /usr/bin/cardreformat does. Nothing reaches the disk before `w`, and
 * piped input that fdisk refuses ends the session rather than re-asking.
 * Sizes are in sectors of 512 bytes; a new partition starts on a 1 MiB
 * boundary unless told otherwise. Formatting is mkfs's job (mkfs.fat, mkfs.ext4). */

#include "mbr.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static const char *device;
static int device_fd = -1;
static uint64_t device_sectors;
static mbr_table table;
static int echo_input; /* stdin is not a terminal: show what was read */

static void usage(const char *argv0) {
  printf("usage: %s [-l] DEVICE...\n"
         "\n"
         "Change the MBR partition table of DEVICE (a whole disk or an image\n"
         "file). Commands are read from stdin, so they can be piped.\n"
         "\n"
         "  -l   list the partition tables and exit\n",
         argv0);
}

/* ---- the device ---- */

static uint64_t size_in_sectors(int fd) {
  unsigned long long bytes = 0;
  if (ioctl(fd, (int)BLKGETSIZE64, &bytes) == 0 && bytes > 0)
    return bytes / MBR_SECTOR;
  struct stat st;
  if (fstat(fd, &st) == 0 && st.st_size > 0)
    return (uint64_t)st.st_size / MBR_SECTOR;
  return 0;
}

static int read_sector0(int fd, uint8_t *sector) {
  if (lseek(fd, 0, SEEK_SET) != 0)
    return -1;
  size_t done = 0;
  while (done < MBR_SECTOR) {
    ssize_t n = read(fd, sector + done, MBR_SECTOR - done);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return -1;
    done += (size_t)n;
  }
  return 0;
}

static int write_sector0(int fd, const uint8_t *sector) {
  if (lseek(fd, 0, SEEK_SET) != 0)
    return -1;
  size_t done = 0;
  while (done < MBR_SECTOR) {
    ssize_t n = write(fd, sector + done, MBR_SECTOR - done);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      return -1;
    done += (size_t)n;
  }
  return 0;
}

/* /dev/mmc0 -> /dev/mmc0p1, /dev/sda -> /dev/sda1, as Linux names them. */
static const char *partition_name(int index, char *buf, size_t len) {
  size_t n = strlen(device);
  int digit = n > 0 && device[n - 1] >= '0' && device[n - 1] <= '9';
  snprintf(buf, len, "%s%s%d", device, digit ? "p" : "", index + 1);
  return buf;
}

/* Is anything mounted from the device or one of its partitions? */
static int device_in_use(void) {
  FILE *mounts = fopen("/proc/mounts", "r");
  if (!mounts)
    return 0;
  char line[256];
  size_t len = strlen(device);
  int used = 0;
  while (fgets(line, sizeof(line), mounts)) {
    char next = line[len];
    if (strncmp(line, device, len) == 0 &&
        (next == ' ' || next == '\t' || next == 'p' ||
         (next >= '0' && next <= '9'))) {
      fprintf(stderr, "fdisk: %s is in use: %s", device, line);
      used = 1;
    }
  }
  fclose(mounts);
  return used;
}

static uint32_t new_disk_id(void) {
  uint32_t id = (uint32_t)time(NULL) ^ ((uint32_t)getpid() << 16) ^
                0x5941534fu; /* "YASO" */
  return id ? id : 1;
}

/* ---- input ---- */

/* Prompt and read one line, without its newline. -1 at the end of input. */
static int ask(const char *prompt, char *answer, size_t len) {
  fputs(prompt, stdout);
  fflush(stdout);
  if (!fgets(answer, (int)len, stdin)) {
    putchar('\n');
    return -1;
  }
  size_t n = strlen(answer);
  while (n > 0 && (answer[n - 1] == '\n' || answer[n - 1] == '\r'))
    answer[--n] = '\0';
  if (echo_input)
    printf("%s\n", answer);
  return 0;
}

/* Say why an answer was refused. From a terminal the question is asked
 * again; from a pipe it ends the session (-2, nothing written): the lines
 * after a refused one were meant for other questions, and taking them as
 * answers would build -- and `w` would write -- a table nobody asked for. */
static int refuse(const char *why) {
  printf("%s\n", why);
  if (!echo_input)
    return 0;
  fprintf(stderr, "fdisk: %s\n", why);
  return -2;
}

static int parse_number(const char *text, int base, unsigned long *value) {
  while (*text == ' ' || *text == '\t')
    ++text;
  if (*text == '\0')
    return -1;
  char *end;
  errno = 0;
  unsigned long result = strtoul(text, &end, base);
  while (*end == ' ' || *end == '\t')
    ++end;
  if (errno != 0 || *end != '\0' || text[0] == '-')
    return -1;
  *value = result;
  return 0;
}

/* Choose a partition among those for which used(index) == *want_used*.
 * One candidate is taken without asking, as util-linux does -- scripts count
 * on it. -1 when there is none or the input ended, -2 to stop (end of input). */
static int choose_partition(int want_used, int default_index) {
  int candidates[MBR_PARTS], count = 0;
  for (int i = 0; i < MBR_PARTS; ++i)
    if (mbr_used(&table, i) == want_used)
      candidates[count++] = i;
  if (count == 0)
    return -1;
  if (count == 1) {
    printf("Selected partition %d\n", candidates[0] + 1);
    return candidates[0];
  }
  if (default_index < 0)
    default_index = want_used ? candidates[count - 1] : candidates[0];
  char prompt[96], list[32] = "", answer[64];
  for (int i = 0; i < count; ++i) {
    char one[8];
    snprintf(one, sizeof(one), i ? ",%d" : "%d", candidates[i] + 1);
    strcat(list, one);
  }
  snprintf(prompt, sizeof(prompt), "Partition number (%s, default %d): ",
           list, default_index + 1);
  for (;;) {
    if (ask(prompt, answer, sizeof(answer)) != 0)
      return -2;
    if (answer[0] == '\0')
      return default_index;
    unsigned long number;
    if (parse_number(answer, 10, &number) == 0)
      for (int i = 0; i < count; ++i)
        if ((unsigned long)candidates[i] + 1 == number)
          return candidates[i];
    if (refuse("Value out of range.") != 0)
      return -2;
  }
}

/* ---- commands ---- */

static void print_table(void) {
  char size[16], name[256];
  printf("Disk %s: %s, %llu bytes, %llu sectors\n", device,
         mbr_format_size(device_sectors, size, sizeof(size)),
         (unsigned long long)device_sectors * MBR_SECTOR,
         (unsigned long long)device_sectors);
  printf("Units: sectors of 1 * 512 = 512 bytes\n");
  printf("Disklabel type: dos\n");
  printf("Disk identifier: 0x%08x\n", (unsigned)table.disk_id);
  if (mbr_count(&table) == 0)
    return;
  int width = (int)strlen(partition_name(0, name, sizeof(name)));
  if (width < 6)
    width = 6;
  printf("\n%-*s Boot %10s %10s %10s %6s Id Type\n", width, "Device",
         "Start", "End", "Sectors", "Size");
  for (int i = 0; i < MBR_PARTS; ++i) {
    const mbr_part *part = &table.parts[i];
    if (!mbr_used(&table, i))
      continue;
    printf("%-*s %-4s %10u %10u %10u %6s %2x %s\n", width,
           partition_name(i, name, sizeof(name)),
           part->boot == 0x80 ? "*" : "", (unsigned)part->start,
           (unsigned)(part->start + part->sectors - 1),
           (unsigned)part->sectors,
           mbr_format_size(part->sectors, size, sizeof(size)), part->type,
           mbr_type_name(part->type));
  }
}

static void list_types(void) {
  for (int i = 0, code; (code = mbr_type_at(i)) >= 0; ++i)
    printf("%2x  %-22s%s", code, mbr_type_name((uint8_t)code),
           i % 3 == 2 ? "\n" : "");
  printf("\n");
}

static void help(void) {
  printf("\nHelp:\n"
         "   a   toggle a bootable flag\n"
         "   d   delete a partition\n"
         "   l   list known partition types\n"
         "   n   add a new partition\n"
         "   o   create a new empty DOS partition table\n"
         "   p   print the partition table\n"
         "   t   change a partition type\n"
         "   m   print this menu\n"
         "   w   write table to disk and exit\n"
         "   q   quit without saving changes\n\n");
}

/* 0 done (or refused), -2 end of input. */
static int new_partition(void) {
  char answer[64], prompt[160];
  int used = mbr_count(&table);
  if (used == MBR_PARTS) {
    printf("All primary partitions are in use.\n");
    return 0;
  }
  uint32_t lowest = mbr_first_free(&table, MBR_ALIGN);
  if (lowest == 0) {
    printf("No free sectors available.\n");
    return 0;
  }
  printf("Partition type\n"
         "   p   primary (%d primary, 0 extended, %d free)\n",
         used, MBR_PARTS - used);
  for (;;) {
    if (ask("Select (default p): ", answer, sizeof(answer)) != 0)
      return -2;
    if (answer[0] == '\0' || strcmp(answer, "p") == 0)
      break;
    if (refuse("Only primary partitions are supported.") != 0)
      return -2;
  }
  int index = choose_partition(0, -1);
  if (index < 0)
    return index == -2 ? -2 : 0;

  uint32_t disk_last = table.disk_sectors - 1;
  uint32_t first;
  snprintf(prompt, sizeof(prompt), "First sector (%u-%u, default %u): ",
           (unsigned)MBR_ALIGN, (unsigned)disk_last, (unsigned)lowest);
  for (;;) {
    if (ask(prompt, answer, sizeof(answer)) != 0)
      return -2;
    unsigned long value = lowest;
    if (answer[0] == '\0' ||
        (parse_number(answer, 10, &value) == 0 && value <= disk_last)) {
      first = (uint32_t)value;
      if (first != 0 && mbr_range_free(&table, first, first, -1))
        break;
    }
    if (refuse("Value out of range.") != 0)
      return -2;
  }

  uint32_t last_free = mbr_last_free(&table, first);
  uint32_t last;
  snprintf(prompt, sizeof(prompt),
           "Last sector, +/-sectors or +/-size{K,M,G,T,%%} (%u-%u, default "
           "%u): ",
           (unsigned)first, (unsigned)last_free, (unsigned)last_free);
  for (;;) {
    if (ask(prompt, answer, sizeof(answer)) != 0)
      return -2;
    if (mbr_parse_last(answer, first, last_free, table.disk_sectors, &last) ==
            0 &&
        last <= last_free)
      break;
    if (refuse("Value out of range.") != 0)
      return -2;
  }

  mbr_part *part = &table.parts[index];
  part->boot = 0;
  part->type = 0x83;
  part->start = first;
  part->sectors = last - first + 1;
  char size[16];
  printf("\nCreated a new partition %d of type '%s' and of size %s.\n\n",
         index + 1, mbr_type_name(part->type),
         mbr_format_size(part->sectors, size, sizeof(size)));
  return 0;
}

static int delete_partition(void) {
  if (mbr_count(&table) == 0) {
    printf("No partition is defined yet!\n");
    return 0;
  }
  int index = choose_partition(1, -1);
  if (index < 0)
    return index;
  memset(&table.parts[index], 0, sizeof(table.parts[index]));
  printf("\nPartition %d has been deleted.\n\n", index + 1);
  return 0;
}

static int change_type(void) {
  if (mbr_count(&table) == 0) {
    printf("No partition is defined yet!\n");
    return 0;
  }
  int index = choose_partition(1, -1);
  if (index < 0)
    return index;
  char answer[64];
  for (;;) {
    if (ask("Hex code or alias (type L to list all): ", answer,
            sizeof(answer)) != 0)
      return -2;
    if (strcmp(answer, "L") == 0 || strcmp(answer, "l") == 0) {
      list_types();
      continue;
    }
    unsigned long code;
    if (strcmp(answer, "linux") == 0)
      code = 0x83;
    else if (strcmp(answer, "uefi") == 0)
      code = 0xef;
    else if (parse_number(answer, 16, &code) != 0 || code == 0 || code > 0xff) {
      if (refuse("Not a partition type (00 is free space).") != 0)
        return -2;
      continue;
    }
    mbr_part *part = &table.parts[index];
    printf("Changed type of partition '%s' to '%s'.\n\n",
           mbr_type_name(part->type), mbr_type_name((uint8_t)code));
    part->type = (uint8_t)code;
    return 0;
  }
}

static int toggle_bootable(void) {
  if (mbr_count(&table) == 0) {
    printf("No partition is defined yet!\n");
    return 0;
  }
  int index = choose_partition(1, -1);
  if (index < 0)
    return index;
  mbr_part *part = &table.parts[index];
  part->boot = part->boot == 0x80 ? 0x00 : 0x80;
  printf("The bootable flag on partition %d is %s now.\n\n", index + 1,
         part->boot ? "enabled" : "disabled");
  return 0;
}

/* Write the table and have the kernel read it again. 0 on success. */
static int write_table(void) {
  if (device_in_use()) {
    fprintf(stderr, "fdisk: unmount it first; nothing written\n");
    return -1;
  }
  uint8_t sector[MBR_SECTOR];
  mbr_encode(&table, sector);
  if (write_sector0(device_fd, sector) != 0) {
    fprintf(stderr, "fdisk: writing %s failed: %s\n", device, strerror(errno));
    return -1;
  }
  fsync(device_fd);
  printf("The partition table has been altered.\n");
  struct stat st;
  if (fstat(device_fd, &st) == 0 && S_ISBLK(st.st_mode)) {
    printf("Calling ioctl() to re-read partition table.\n");
    if (ioctl(device_fd, (int)BLKRRPART, 0) != 0)
      fprintf(stderr,
              "fdisk: the kernel still uses the old table (%s); reboot to use "
              "the new one\n",
              strerror(errno));
  }
  printf("Syncing disks.\n");
  return 0;
}

/* ---- main ---- */

static int open_device(const char *path, int writable) {
  device = path;
  device_fd = open(path, writable ? O_RDWR : O_RDONLY);
  if (device_fd < 0) {
    fprintf(stderr, "fdisk: cannot open %s: %s\n", path, strerror(errno));
    return -1;
  }
  device_sectors = size_in_sectors(device_fd);
  if (device_sectors <= MBR_ALIGN) {
    fprintf(stderr, "fdisk: %s: too small, or its size is unknown\n", path);
    return -1;
  }
  uint8_t sector[MBR_SECTOR];
  if (read_sector0(device_fd, sector) != 0) {
    fprintf(stderr, "fdisk: cannot read %s: %s\n", path, strerror(errno));
    return -1;
  }
  switch (mbr_parse(sector, device_sectors, &table)) {
  case MBR_OK:
    if (table.disk_id == 0)
      table.disk_id = new_disk_id();
    break;
  case MBR_FILESYSTEM:
    printf("The device contains a FAT filesystem; a write replaces it with a "
           "partition table.\n");
    mbr_clear(&table, new_disk_id());
    break;
  case MBR_GPT:
    printf("The device has a GPT, which fdisk does not edit; a write "
           "replaces it with an MBR.\n");
    mbr_clear(&table, new_disk_id());
    break;
  case MBR_EMPTY:
    printf("Device does not contain a recognized partition table.\n");
    mbr_clear(&table, new_disk_id());
    printf("Created a new DOS disklabel with disk identifier 0x%08x.\n",
           (unsigned)table.disk_id);
    break;
  }
  return 0;
}

int main(int argc, char *argv[]) {
  int list = 0, first_device = argc;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "-l") == 0)
      list = 1;
    else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      usage(argv[0]);
      return 0;
    } else if (argv[i][0] == '-') {
      usage(argv[0]);
      return 2;
    } else {
      first_device = i;
      break;
    }
  }
  if (first_device >= argc || (!list && argc - first_device != 1)) {
    usage(argv[0]);
    return 2;
  }

  if (list) {
    int status = 0;
    for (int i = first_device; i < argc; ++i) {
      if (open_device(argv[i], 0) != 0) {
        status = 1;
        continue;
      }
      print_table();
      printf("\n");
      close(device_fd);
    }
    return status;
  }

  if (open_device(argv[first_device], 1) != 0)
    return 1;
  echo_input = !isatty(STDIN_FILENO);

  char answer[64];
  for (;;) {
    if (ask("Command (m for help): ", answer, sizeof(answer)) != 0) {
      fprintf(stderr, "fdisk: end of input, nothing written\n");
      return 1;
    }
    int rc = 0;
    if (strcmp(answer, "") == 0)
      continue;
    else if (strcmp(answer, "m") == 0)
      help();
    else if (strcmp(answer, "p") == 0) {
      print_table();
      printf("\n");
    }
    else if (strcmp(answer, "l") == 0)
      list_types();
    else if (strcmp(answer, "n") == 0)
      rc = new_partition();
    else if (strcmp(answer, "d") == 0)
      rc = delete_partition();
    else if (strcmp(answer, "t") == 0)
      rc = change_type();
    else if (strcmp(answer, "a") == 0)
      rc = toggle_bootable();
    else if (strcmp(answer, "o") == 0) {
      mbr_clear(&table, new_disk_id());
      printf("Created a new DOS disklabel with disk identifier 0x%08x.\n",
             (unsigned)table.disk_id);
    } else if (strcmp(answer, "w") == 0) {
      int status = write_table() == 0 ? 0 : 1;
      close(device_fd);
      return status;
    } else if (strcmp(answer, "q") == 0) {
      close(device_fd);
      return 0;
    } else {
      char why[96];
      snprintf(why, sizeof(why), "%.64s: unknown command", answer);
      rc = refuse(why);
    }
    if (rc == -2) {
      fprintf(stderr, "fdisk: nothing written\n");
      return 1;
    }
  }
}
