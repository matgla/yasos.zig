/*
 * sdbench — measure the storage floor underneath the smoke suite.
 *
 * The question this exists to answer is whether the SD path is worth tuning at
 * all: reads already stream through CMD18 multi-block, but writes go one CMD24
 * plus a busy-wait per 512-byte sector, so the two directions are expected to
 * come out very differently. Sequential runs at several block sizes show where
 * the multi-block path stops helping, and the small-random figures give the
 * per-operation latency that a single-sector write actually costs.
 *
 * Output is one space-separated key=value line per measurement so it can be
 * pasted into a report or parsed without a second tool.
 *
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

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

/* Sized to outrun the FatFs disk cache (4 lines x 4 KiB) by two orders of
 * magnitude, so nothing measured here is served from RAM. */
#define DEFAULT_TOTAL_BYTES (1024u * 1024u)
#define SECTOR 512u
#define MAX_BLOCK 32768u
#define RANDOM_OPS 256u

static unsigned char buffer[MAX_BLOCK];

static long long now_us(void)
{
    struct timeval tv;
    if (gettimeofday(&tv, NULL) != 0) {
        return -1;
    }
    return (long long)tv.tv_sec * 1000000LL + (long long)tv.tv_usec;
}

/* KiB/s, computed in 64-bit and handed back narrow so the result can be
 * printed without depending on %llu. Zero elapsed reports as zero rather than
 * dividing by it. */
static unsigned long throughput_kib_s(unsigned long bytes, long long elapsed_us)
{
    if (elapsed_us <= 0) {
        return 0;
    }
    return (unsigned long)(((unsigned long long)bytes * 1000000ULL) /
                           ((unsigned long long)elapsed_us * 1024ULL));
}

/* Deterministic offsets, so two runs visit the same sectors and can be
 * compared. Any LCG will do; this is the Numerical Recipes one. */
static unsigned long lcg(unsigned long *state)
{
    *state = *state * 1664525UL + 1013904223UL;
    return *state;
}

static void report(const char *name, unsigned long block, unsigned long bytes,
                   long long elapsed_us, unsigned long ops)
{
    printf("%s bs=%lu bytes=%lu us=%ld kib_s=%lu", name, block, bytes,
           (long)elapsed_us, throughput_kib_s(bytes, elapsed_us));
    if (ops > 0) {
        printf(" ops=%lu us_per_op=%lu", ops,
               (unsigned long)(elapsed_us / (long long)ops));
    }
    printf("\n");
    fflush(stdout);
}

static int fill_buffer(void)
{
    unsigned long state = 0x5eed1234UL;
    unsigned int i;
    for (i = 0; i < MAX_BLOCK; ++i) {
        buffer[i] = (unsigned char)(lcg(&state) >> 16);
    }
    return 0;
}

/* Sequential write of `total` bytes in `block`-sized calls. The close is timed
 * separately: it is where FatFs flushes its metadata, and folding that into the
 * write figure would quietly tax whichever block size did the fewest calls. */
static int bench_sequential_write(const char *path, unsigned long block,
                                  unsigned long total)
{
    long long start, elapsed, close_start, close_elapsed;
    unsigned long written = 0;
    int fd;

    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "sdbench: cannot create %s\n", path);
        return -1;
    }

    start = now_us();
    while (written < total) {
        unsigned long chunk = total - written;
        ssize_t n;
        if (chunk > block) {
            chunk = block;
        }
        n = write(fd, buffer, chunk);
        if (n <= 0) {
            fprintf(stderr, "sdbench: write failed at %lu\n", written);
            close(fd);
            return -1;
        }
        written += (unsigned long)n;
    }
    elapsed = now_us() - start;

    close_start = now_us();
    close(fd);
    close_elapsed = now_us() - close_start;

    report("seq_write", block, written, elapsed, written / block);
    printf("seq_write_close bs=%lu us=%ld\n", block, (long)close_elapsed);
    fflush(stdout);
    return 0;
}

static int bench_sequential_read(const char *path, unsigned long block,
                                 unsigned long total)
{
    long long start, elapsed;
    unsigned long readed = 0;
    int fd;

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "sdbench: cannot open %s\n", path);
        return -1;
    }

    start = now_us();
    while (readed < total) {
        unsigned long chunk = total - readed;
        ssize_t n;
        if (chunk > block) {
            chunk = block;
        }
        n = read(fd, buffer, chunk);
        if (n <= 0) {
            break;
        }
        readed += (unsigned long)n;
    }
    elapsed = now_us() - start;
    close(fd);

    report("seq_read", block, readed, elapsed, readed / block);
    return 0;
}

/* Single-sector reads at scattered offsets — the case the multi-block read path
 * cannot help, and the one the FAT metadata window actually looks like. */
static int bench_random_read(const char *path, unsigned long total)
{
    unsigned long state = 0xa5a5f00dUL;
    unsigned long sectors = total / SECTOR;
    long long start, elapsed;
    unsigned long done = 0;
    unsigned int i;
    int fd;

    if (sectors == 0) {
        return 0;
    }

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "sdbench: cannot open %s\n", path);
        return -1;
    }

    start = now_us();
    for (i = 0; i < RANDOM_OPS; ++i) {
        unsigned long sector = lcg(&state) % sectors;
        if (lseek(fd, (off_t)(sector * SECTOR), SEEK_SET) < 0) {
            break;
        }
        if (read(fd, buffer, SECTOR) != (ssize_t)SECTOR) {
            break;
        }
        done += SECTOR;
    }
    elapsed = now_us() - start;
    close(fd);

    report("rand_read", SECTOR, done, elapsed, done / SECTOR);
    return 0;
}

static int bench_random_write(const char *path, unsigned long total)
{
    unsigned long state = 0xa5a5f00dUL;
    unsigned long sectors = total / SECTOR;
    long long start, elapsed;
    unsigned long done = 0;
    unsigned int i;
    int fd;

    if (sectors == 0) {
        return 0;
    }

    fd = open(path, O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "sdbench: cannot open %s\n", path);
        return -1;
    }

    start = now_us();
    for (i = 0; i < RANDOM_OPS; ++i) {
        unsigned long sector = lcg(&state) % sectors;
        if (lseek(fd, (off_t)(sector * SECTOR), SEEK_SET) < 0) {
            break;
        }
        if (write(fd, buffer, SECTOR) != (ssize_t)SECTOR) {
            break;
        }
        done += SECTOR;
    }
    elapsed = now_us() - start;
    close(fd);

    report("rand_write", SECTOR, done, elapsed, done / SECTOR);
    return 0;
}

static void usage(void)
{
    printf("usage: sdbench [-k] [-s <kib>] [<directory>]\n");
    printf("  -k         keep the scratch file instead of removing it\n");
    printf("  -s <kib>   total bytes per pass, in KiB (default %u)\n",
           DEFAULT_TOTAL_BYTES / 1024u);
    printf("  directory  where to put the scratch file (default .)\n");
}

int main(int argc, char **argv)
{
    static const unsigned long blocks[] = { 512, 4096, 32768 };
    unsigned long total = DEFAULT_TOTAL_BYTES;
    const char *directory = ".";
    char path[256];
    int keep = 0;
    unsigned int i;
    int argi;

    for (argi = 1; argi < argc; ++argi) {
        if (strcmp(argv[argi], "-k") == 0) {
            keep = 1;
        } else if (strcmp(argv[argi], "-s") == 0 && argi + 1 < argc) {
            total = (unsigned long)atol(argv[++argi]) * 1024UL;
        } else if (strcmp(argv[argi], "-h") == 0) {
            usage();
            return 0;
        } else {
            directory = argv[argi];
        }
    }

    if (total < SECTOR) {
        fprintf(stderr, "sdbench: size must be at least one sector\n");
        return 1;
    }

    snprintf(path, sizeof(path), "%s/sdbench.tmp", directory);
    fill_buffer();

    printf("sdbench file=%s bytes=%lu random_ops=%u\n", path, total,
           RANDOM_OPS);
    fflush(stdout);

    for (i = 0; i < sizeof(blocks) / sizeof(blocks[0]); ++i) {
        if (blocks[i] > total) {
            continue;
        }
        if (bench_sequential_write(path, blocks[i], total) != 0) {
            return 1;
        }
        if (bench_sequential_read(path, blocks[i], total) != 0) {
            return 1;
        }
    }

    if (bench_random_read(path, total) != 0) {
        return 1;
    }
    if (bench_random_write(path, total) != 0) {
        return 1;
    }

    if (!keep) {
        unlink(path);
    }

    printf("sdbench done\n");
    return 0;
}
