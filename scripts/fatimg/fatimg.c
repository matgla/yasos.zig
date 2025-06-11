/* fatimg — minimal host-side FAT image tool (mtools substitute).
 *
 * Built against the elm-chan FatFs vendored in apps/mkfs/libs/fatfs so the
 * images it produces are byte-identical to what the on-device zfat mounts.
 * Used by scripts/qemu_fatdisk_run.py to exchange files with the QEMU guest via
 * the host-mmap'd `fatdisk0` window (see hal/.../linker_script.ld + main.zig).
 *
 * NOTE: the FatFs config has FF_USE_LFN=0, so names are 8.3 and upper-cased.
 *
 *   fatimg mkfs <img> [size_kb]   format <img> (create/truncate to size_kb first)
 *   fatimg cp   <img> <host> <fat>  copy host file -> image
 *   fatimg get  <img> <fat> <host>  copy image file -> host
 *   fatimg ls   <img>             list root directory
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ff.h>

int fatimg_open(const char *path);
void fatimg_close(void);

static FATFS g_fs;
static BYTE g_work[8192];

static const char *frtext(FRESULT r) {
  static const char *t[] = {
      "OK",          "DISK_ERR",     "INT_ERR",      "NOT_READY",
      "NO_FILE",     "NO_PATH",      "INVALID_NAME", "DENIED",
      "EXIST",       "INVALID_OBJ",  "WRITE_PROTECTED", "INVALID_DRIVE",
      "NOT_ENABLED", "NO_FILESYSTEM", "MKFS_ABORTED", "TIMEOUT",
      "LOCKED",      "NOT_ENOUGH_CORE", "TOO_MANY_OPEN_FILES", "INVALID_PARAMETER"};
  if ((unsigned)r < sizeof(t) / sizeof(t[0]))
    return t[r];
  return "?";
}

static int do_mount(const char *img) {
  if (fatimg_open(img) != 0) {
    fprintf(stderr, "fatimg: cannot open image '%s'\n", img);
    return -1;
  }
  FRESULT r = f_mount(&g_fs, "0:", 1);
  if (r != FR_OK) {
    fprintf(stderr, "fatimg: mount failed: %s\n", frtext(r));
    fatimg_close();
    return -1;
  }
  return 0;
}

static int cmd_mkfs(int argc, char **argv) {
  /* argv: <img> [size_kb] */
  const char *img = argv[0];
  if (argc >= 2) {
    long kb = strtol(argv[1], NULL, 0);
    FILE *f = fopen(img, "wb");
    if (!f) {
      perror("fatimg: create image");
      return 1;
    }
    if (fseek(f, kb * 1024 - 1, SEEK_SET) != 0 || fputc(0, f) == EOF) {
      perror("fatimg: size image");
      fclose(f);
      return 1;
    }
    fclose(f);
  }
  if (fatimg_open(img) != 0) {
    fprintf(stderr, "fatimg: cannot open image '%s'\n", img);
    return 1;
  }
  MKFS_PARM parm = {.fmt = FM_FAT | FM_SFD, .n_fat = 1, .align = 1,
                    .n_root = 0, .au_size = 0};
  FRESULT r = f_mkfs("0:", &parm, g_work, sizeof(g_work));
  fatimg_close();
  if (r != FR_OK) {
    fprintf(stderr, "fatimg: mkfs failed: %s\n", frtext(r));
    return 1;
  }
  return 0;
}

static int cmd_cp(int argc, char **argv) {
  /* argv: <img> <host> <fat> */
  (void)argc;
  const char *img = argv[0], *host = argv[1], *fat = argv[2];
  if (do_mount(img))
    return 1;
  int rc = 1;
  FILE *hf = fopen(host, "rb");
  if (!hf) {
    perror("fatimg: open host file");
    goto out_unmount;
  }
  FIL ff;
  FRESULT r = f_open(&ff, fat, FA_WRITE | FA_CREATE_ALWAYS);
  if (r != FR_OK) {
    fprintf(stderr, "fatimg: f_open(%s) for write: %s\n", fat, frtext(r));
    fclose(hf);
    goto out_unmount;
  }
  static BYTE buf[4096];
  size_t n;
  rc = 0;
  while ((n = fread(buf, 1, sizeof(buf), hf)) > 0) {
    UINT bw;
    r = f_write(&ff, buf, (UINT)n, &bw);
    if (r != FR_OK || bw != n) {
      fprintf(stderr, "fatimg: f_write: %s\n", frtext(r));
      rc = 1;
      break;
    }
  }
  f_close(&ff);
  fclose(hf);
out_unmount:
  f_mount(0, "0:", 0);
  fatimg_close();
  return rc;
}

static int cmd_get(int argc, char **argv) {
  /* argv: <img> <fat> <host> */
  (void)argc;
  const char *img = argv[0], *fat = argv[1], *host = argv[2];
  if (do_mount(img))
    return 1;
  int rc = 1;
  FIL ff;
  FRESULT r = f_open(&ff, fat, FA_READ);
  if (r != FR_OK) {
    fprintf(stderr, "fatimg: f_open(%s) for read: %s\n", fat, frtext(r));
    goto out_unmount;
  }
  FILE *hf = fopen(host, "wb");
  if (!hf) {
    perror("fatimg: create host file");
    f_close(&ff);
    goto out_unmount;
  }
  static BYTE buf[4096];
  UINT br;
  rc = 0;
  do {
    r = f_read(&ff, buf, sizeof(buf), &br);
    if (r != FR_OK) {
      fprintf(stderr, "fatimg: f_read: %s\n", frtext(r));
      rc = 1;
      break;
    }
    if (br && fwrite(buf, 1, br, hf) != br) {
      perror("fatimg: write host file");
      rc = 1;
      break;
    }
  } while (br == sizeof(buf));
  fclose(hf);
  f_close(&ff);
out_unmount:
  f_mount(0, "0:", 0);
  fatimg_close();
  return rc;
}

static int cmd_ls(int argc, char **argv) {
  (void)argc;
  const char *img = argv[0];
  if (do_mount(img))
    return 1;
  DIR dir;
  FRESULT r = f_opendir(&dir, "0:/");
  if (r != FR_OK) {
    fprintf(stderr, "fatimg: f_opendir: %s\n", frtext(r));
    f_mount(0, "0:", 0);
    fatimg_close();
    return 1;
  }
  FILINFO fno;
  for (;;) {
    r = f_readdir(&dir, &fno);
    if (r != FR_OK || fno.fname[0] == 0)
      break;
    printf("%c %10lu  %s\n", (fno.fattrib & AM_DIR) ? 'd' : '-',
           (unsigned long)fno.fsize, fno.fname);
  }
  f_closedir(&dir);
  f_mount(0, "0:", 0);
  fatimg_close();
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr,
            "usage: %s <mkfs|cp|get|ls> <img> [args...]\n"
            "  mkfs <img> [size_kb]\n"
            "  cp   <img> <hostfile> <fatname>\n"
            "  get  <img> <fatname> <hostfile>\n"
            "  ls   <img>\n",
            argv[0]);
    return 2;
  }
  const char *cmd = argv[1];
  char **rest = &argv[2];
  int nrest = argc - 2;
  if (!strcmp(cmd, "mkfs"))
    return cmd_mkfs(nrest, rest);
  if (!strcmp(cmd, "cp"))
    return (nrest >= 3) ? cmd_cp(nrest, rest) : 2;
  if (!strcmp(cmd, "get"))
    return (nrest >= 3) ? cmd_get(nrest, rest) : 2;
  if (!strcmp(cmd, "ls"))
    return cmd_ls(nrest, rest);
  fprintf(stderr, "fatimg: unknown command '%s'\n", cmd);
  return 2;
}
