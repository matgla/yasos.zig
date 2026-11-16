/*
 Copyright (c) 2026 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

/* strip: take the debug data out of a YAFF image.
 *
 *   strip [-o OUTPUT] [-f DEBUGFILE] FILE...
 *
 * A -g link appends a YaffDebugHeader blob to the image (tccyaff.h).  strip
 * cuts it off; with -f it first copies it to DEBUGFILE and leaves in its
 * place a small blob naming that file (.yaff_debuglink).  Both carry the
 * image's CRC-32, so a debugger can tell a debug file that belongs to the
 * image from a stale one.  The image itself -- everything the loader reads,
 * [0, debug_offset) -- is copied byte for byte but for the header's two debug
 * fields.
 *
 * Everything streams through a small buffer: on the board a -g tcc is a few
 * megabytes, most of it debug data, and there is no room to hold it.
 */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "tccyaff.h"

#define CHUNK 4096

static const char *program = "strip";

static uint32_t crc_table[256];

static void crc_init(void) {
  uint32_t i, k;
  for (i = 0; i < 256; ++i) {
    uint32_t c = i;
    for (k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    crc_table[i] = c;
  }
}

/* zlib's crc32: start at 0, feed the bytes, the result is the checksum. */
static uint32_t crc_update(uint32_t crc, const uint8_t *data, size_t length) {
  crc = ~crc;
  while (length--) crc = crc_table[(crc ^ *data++) & 0xff] ^ (crc >> 8);
  return ~crc;
}

static void fail(const char *path, const char *why) {
  fprintf(stderr, "%s: %s: %s\n", program, path, why);
}

/* Copies `length` bytes of `in` from where it is to `out`, adding them to
 * *crc when it is given. */
static int copy_bytes(FILE *in, FILE *out, uint32_t length, uint32_t *crc) {
  uint8_t buffer[CHUNK];
  while (length) {
    size_t want = length < sizeof(buffer) ? length : sizeof(buffer);
    if (fread(buffer, 1, want, in) != want) return -1;
    if (crc) *crc = crc_update(*crc, buffer, want);
    if (out && fwrite(buffer, 1, want, out) != want) return -1;
    length -= want;
  }
  return 0;
}

/* The CRC that identifies an image: [0, debug_offset) with the header's debug
 * fields as zero (tccyaff.h, "image_crc"). */
static int image_crc(FILE *in, const YaffHeader *header, uint32_t *crc) {
  YaffHeader zeroed = *header;
  zeroed.debug_offset = 0;
  zeroed.debug_length = 0;
  *crc = crc_update(0, (const uint8_t *)&zeroed, sizeof(zeroed));
  if (fseek(in, sizeof(YaffHeader), SEEK_SET) != 0) return -1;
  return copy_bytes(in, NULL, header->debug_offset - sizeof(YaffHeader), crc);
}

/* Whether the blob is no more than a link to a separate debug file -- what a
 * stripped image keeps, which has nothing in it to split off. */
static int blob_is_only_a_link(FILE *in, uint32_t at, const YaffDebugHeader *dh) {
  uint32_t i;
  for (i = 1; i < dh->section_count; ++i) {
    YaffDebugSection section;
    if (fseek(in, at + dh->sections_offset + i * sizeof(section), SEEK_SET) != 0 ||
        fread(&section, 1, sizeof(section), in) != sizeof(section))
      return 0;
    if (section.type != YAFF_SHT_DEBUGLINK) return 0;
  }
  return 1;
}

/* The blob a stripped image keeps: null section, .yaff_debuglink naming
 * `debug_name`.  Returns its length, 0 when the name does not fit. */
static uint32_t make_link_blob(uint8_t *out, uint32_t room, const char *debug_name, uint32_t crc) {
  static const char names[] = "\0" YAFF_DEBUGLINK_NAME;
  YaffDebugHeader dh;
  YaffDebugSection sections[2];
  uint32_t name_len = (uint32_t)strlen(debug_name) + 1;
  uint32_t names_size = sizeof(names);
  uint32_t data_at = (uint32_t)(sizeof(dh) + sizeof(sections) + names_size + 3) & ~3u;
  uint32_t total = (data_at + name_len + 3) & ~3u;
  if (total > room) return 0;
  memset(out, 0, total);
  memset(&dh, 0, sizeof(dh));
  memset(sections, 0, sizeof(sections));
  memcpy(dh.magic, YAFF_DEBUG_MAGIC, 4);
  dh.version = YAFF_DEBUG_VERSION;
  dh.section_count = 2;
  dh.size = total;
  dh.sections_offset = sizeof(dh);
  dh.names_offset = sizeof(dh) + sizeof(sections);
  dh.names_size = names_size;
  dh.image_crc = crc;
  sections[1].name = 1;
  sections[1].type = YAFF_SHT_DEBUGLINK;
  sections[1].offset = data_at;
  sections[1].size = name_len;
  sections[1].alignment = 1;
  memcpy(out, &dh, sizeof(dh));
  memcpy(out + sizeof(dh), sections, sizeof(sections));
  memcpy(out + dh.names_offset, names, names_size);
  memcpy(out + data_at, debug_name, name_len);
  return total;
}

static const char *base_name(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

/* Writes `path` through a temporary next to it, so an interrupted strip never
 * leaves a half-written program where the old one was. */
static FILE *open_temporary(const char *path, char *temporary, size_t room) {
  if ((size_t)snprintf(temporary, room, "%s.strip-tmp", path) >= room) return NULL;
  return fopen(temporary, "wb");
}

static int finish_temporary(FILE *f, const char *temporary, const char *path, mode_t mode) {
  if (fflush(f) != 0 || fclose(f) != 0) {
    unlink(temporary);
    return -1;
  }
  chmod(temporary, mode & 07777);
  if (rename(temporary, path) != 0) {
    unlink(temporary);
    return -1;
  }
  return 0;
}

static int strip_file(const char *path, const char *output, const char *debug_file) {
  FILE *in = NULL, *out = NULL, *debug = NULL;
  YaffHeader header, written;
  YaffDebugHeader dh;
  struct stat st;
  char temporary[1024], debug_temporary[1024];
  uint8_t link[512];
  uint32_t link_length = 0, crc = 0;
  long file_size;
  int rc = 1;

  if (!output) output = path;
  in = fopen(path, "rb");
  if (!in) {
    fail(path, strerror(errno));
    return 1;
  }
  if (fstat(fileno(in), &st) != 0) st.st_mode = 0755;
  if (fseek(in, 0, SEEK_END) != 0 || (file_size = ftell(in)) < 0 || fseek(in, 0, SEEK_SET) != 0 ||
      fread(&header, 1, sizeof(header), in) != sizeof(header) || memcmp(header.magic, "YAFF", 4) != 0) {
    fail(path, "not a YAFF image");
    goto done;
  }
  if (header.yaff_version != YAFF_VERSION) {
    fail(path, "unsupported YAFF version");
    goto done;
  }
  if (header.debug_offset &&
      (header.debug_offset < sizeof(header) || header.debug_offset > (uint32_t)file_size ||
       header.debug_length < sizeof(dh) || header.debug_length > (uint32_t)file_size - header.debug_offset)) {
    fail(path, "debug data outside the file");
    goto done;
  }
  if (header.debug_offset) {
    if (fseek(in, header.debug_offset, SEEK_SET) != 0 || fread(&dh, 1, sizeof(dh), in) != sizeof(dh) ||
        memcmp(dh.magic, YAFF_DEBUG_MAGIC, 4) != 0 || dh.size != header.debug_length) {
      fail(path, "debug data is not a YDBG blob");
      goto done;
    }
  }

  /* Nothing to take out -- no debug data, or only the link a stripped image
   * keeps, which is how a debugger finds its debug file: done, but -o still
   * asks for a copy. */
  if (!header.debug_offset || (!debug_file && blob_is_only_a_link(in, header.debug_offset, &dh))) {
    if (debug_file) {
      fail(path, "has no debug data");
      goto done;
    }
    if (output != path) {
      if (fseek(in, 0, SEEK_SET) != 0 || !(out = open_temporary(output, temporary, sizeof(temporary))) ||
          copy_bytes(in, out, (uint32_t)file_size, NULL) != 0 ||
          finish_temporary(out, temporary, output, st.st_mode) != 0) {
        out = NULL;
        fail(output, "cannot write");
        goto done;
      }
      out = NULL;
    }
    rc = 0;
    goto done;
  }

  if (debug_file && blob_is_only_a_link(in, header.debug_offset, &dh)) {
    fail(path, "is already stripped (its debug data is in a separate file)");
    goto done;
  }

  if (image_crc(in, &header, &crc) != 0) {
    fail(path, "short read");
    goto done;
  }

  /* -f: the blob, verbatim but for the image CRC, as its own file. */
  if (debug_file) {
    YaffDebugHeader copy = dh;
    copy.image_crc = crc;
    debug = open_temporary(debug_file, debug_temporary, sizeof(debug_temporary));
    if (!debug || fwrite(&copy, 1, sizeof(copy), debug) != sizeof(copy) ||
        fseek(in, header.debug_offset + sizeof(dh), SEEK_SET) != 0 ||
        copy_bytes(in, debug, header.debug_length - sizeof(dh), NULL) != 0 ||
        finish_temporary(debug, debug_temporary, debug_file, 0644) != 0) {
      debug = NULL;
      fail(debug_file, "cannot write");
      goto done;
    }
    debug = NULL;
    link_length = make_link_blob(link, sizeof(link), base_name(debug_file), crc);
    if (!link_length) {
      fail(debug_file, "name too long for a debug link");
      goto done;
    }
  }

  /* The image: the same bytes, then the link blob or nothing. */
  written = header;
  written.debug_offset = link_length ? header.debug_offset : 0;
  written.debug_length = link_length;
  out = open_temporary(output, temporary, sizeof(temporary));
  if (!out || fwrite(&written, 1, sizeof(written), out) != sizeof(written) ||
      fseek(in, sizeof(header), SEEK_SET) != 0 ||
      copy_bytes(in, out, header.debug_offset - sizeof(header), NULL) != 0 ||
      (link_length && fwrite(link, 1, link_length, out) != link_length) ||
      finish_temporary(out, temporary, output, st.st_mode) != 0) {
    out = NULL;
    fail(output, "cannot write");
    goto done;
  }
  out = NULL;
  rc = 0;

done:
  if (out) {
    fclose(out);
    unlink(temporary);
  }
  if (debug) {
    fclose(debug);
    unlink(debug_temporary);
  }
  fclose(in);
  return rc;
}

static void usage(void) {
  fprintf(stderr,
          "Usage: %s [-o OUTPUT] [-f DEBUGFILE] FILE...\n"
          "\n"
          "Takes the debug data a -g link put in each YAFF FILE out of it.\n"
          "\n"
          "  -o OUTPUT     write the stripped image there, not over FILE\n"
          "  -f DEBUGFILE  first save the debug data to DEBUGFILE, and leave FILE\n"
          "                naming it, so a debugger can still find it\n"
          "\n"
          "-o and -f take a single FILE.\n",
          program);
}

int main(int argc, char **argv) {
  const char *output = NULL, *debug_file = NULL;
  int i, first = 1, rc = 0;

  crc_init();
  for (i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc) {
      output = argv[++i];
    } else if (!strcmp(argv[i], "-f") && i + 1 < argc) {
      debug_file = argv[++i];
    } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
      usage();
      return 0;
    } else if (!strcmp(argv[i], "--")) {
      ++i;
      break;
    } else if (argv[i][0] == '-' && argv[i][1]) {
      fprintf(stderr, "%s: unknown option '%s'\n", program, argv[i]);
      usage();
      return 2;
    } else {
      break;
    }
  }
  first = i;
  if (first >= argc) {
    usage();
    return 2;
  }
  if ((output || debug_file) && argc - first != 1) {
    fprintf(stderr, "%s: -o and -f take a single FILE\n", program);
    return 2;
  }
  for (i = first; i < argc; ++i) rc |= strip_file(argv[i], output, debug_file);
  return rc;
}
