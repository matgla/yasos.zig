/* yasos_compat.c -- the support layer that lets the Zig compiler's C output
 * link and run on YasOS.
 *
 * `zig build -Donly-c -Dofmt=c` renders the compiler as one 70 MB C file that
 * believes it is running on thumb-linux-musl with libc. That is deliberate:
 * YasOS is not a target Zig knows, and its libc is already Linux-flavoured
 * (O_* values, AT_FDCWD = -100, MAP_ANONYMOUS = 0x20, errno 1..34), so the gap
 * is small enough to bridge from this side rather than by teaching std a new
 * OS. What is missing falls into four groups, and each has its own section:
 *
 *   1. compiler-rt: 128-bit integer arithmetic and the two mul-with-overflow
 *      helpers. tcc's libtcc1.a stops at 64 bits.
 *   2. __atomic_* builtins. tcc emits calls for these; libtcc1.a has none.
 *   3. POSIX calls YasOS's libc does not have yet, most importantly statx(),
 *      which is how Zig stats a file on Linux.
 *   4. f16/f80/f128 soft float -- NOT here: Zig's own compiler-rt provides it,
 *      rendered through the C backend by apps/zig/build_compiler_rt.sh. See
 *      section 5 at the bottom.
 *
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

/* Report a failing shim when YASOS_ZIG_ALL_STUBS is set: a call implemented
 * here fails in the caller's vocabulary ("Unexpected"), and the name is what
 * identifies it. */
static long yz_trace(const char *name, long rc) {
  if (rc < 0 && getenv("YASOS_ZIG_ALL_STUBS"))
    fprintf(stderr, "yasos_compat: %s() -> %ld errno=%d\n", name, rc, errno);
  return rc;
}

/* ── 1. compiler-rt: 128-bit integers ─────────────────────────────────────
 *
 * These MUST use the same struct layout zig.h declares them with, because the
 * struct is what the ABI is built around: zig.h line ~2029 is
 *   typedef struct { zig_align(ZIG_TARGET_MAX_INT_ALIGNMENT) uint64_t lo;
 *                     int64_t hi; } zig_i128;
 * and ZIG_TARGET_MAX_INT_ALIGNMENT is 8 on this target (zig.c defines it at
 * the top). Declaring them any other way -- two uint64 arguments, say -- links
 * cleanly and then passes garbage. */

typedef struct {
  uint64_t lo __attribute__((aligned(8)));
  uint64_t hi;
} yz_u128;

typedef struct {
  uint64_t lo __attribute__((aligned(8)));
  int64_t hi;
} yz_i128;

static yz_u128 yz_u128_make(uint64_t hi, uint64_t lo) {
  yz_u128 r;
  r.hi = hi;
  r.lo = lo;
  return r;
}

static int yz_u128_ge(yz_u128 a, yz_u128 b) {
  if (a.hi != b.hi)
    return a.hi > b.hi;
  return a.lo >= b.lo;
}

static yz_u128 yz_u128_shl1(yz_u128 a) {
  return yz_u128_make((a.hi << 1) | (a.lo >> 63), a.lo << 1);
}

static yz_u128 yz_u128_sub(yz_u128 a, yz_u128 b) {
  uint64_t lo = a.lo - b.lo;
  uint64_t borrow = a.lo < b.lo;
  return yz_u128_make(a.hi - b.hi - borrow, lo);
}

/* 64x64 -> 128 on 32-bit halves: the one piece that has to be exact. */
static yz_u128 yz_mul64(uint64_t a, uint64_t b) {
  uint32_t a0 = (uint32_t)a, a1 = (uint32_t)(a >> 32);
  uint32_t b0 = (uint32_t)b, b1 = (uint32_t)(b >> 32);
  uint64_t p00 = (uint64_t)a0 * b0;
  uint64_t p01 = (uint64_t)a0 * b1;
  uint64_t p10 = (uint64_t)a1 * b0;
  uint64_t p11 = (uint64_t)a1 * b1;
  uint64_t mid = (p00 >> 32) + (uint32_t)p01 + (uint32_t)p10;
  uint64_t lo = ((mid & 0xffffffffu) << 32) | (uint32_t)p00;
  uint64_t hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
  return yz_u128_make(hi, lo);
}

/* Unsigned 128/128 division, restoring shift-subtract. Slow (128 iterations)
 * and correct; the compiler reaches it for big comptime integers, never in a
 * loop that matters. */
static void yz_udivmod(yz_u128 n, yz_u128 d, yz_u128 *q_out, yz_u128 *r_out) {
  yz_u128 q = yz_u128_make(0, 0);
  yz_u128 r = yz_u128_make(0, 0);
  int i;

  if (d.hi == 0 && d.lo == 0) {
    /* Same contract as the hardware: undefined, so pick something loud-ish
       rather than looping. */
    if (q_out)
      *q_out = yz_u128_make(~(uint64_t)0, ~(uint64_t)0);
    if (r_out)
      *r_out = yz_u128_make(0, 0);
    return;
  }

  for (i = 127; i >= 0; i--) {
    uint64_t bit = (i >= 64) ? ((n.hi >> (i - 64)) & 1) : ((n.lo >> i) & 1);
    r = yz_u128_shl1(r);
    r.lo |= bit;
    if (yz_u128_ge(r, d)) {
      r = yz_u128_sub(r, d);
      if (i >= 64)
        q.hi |= (uint64_t)1 << (i - 64);
      else
        q.lo |= (uint64_t)1 << i;
    }
  }
  if (q_out)
    *q_out = q;
  if (r_out)
    *r_out = r;
}

static yz_u128 yz_i128_abs(yz_i128 v, int *negative) {
  yz_u128 u = yz_u128_make((uint64_t)v.hi, v.lo);
  *negative = v.hi < 0;
  if (*negative) {
    /* two's complement negate */
    u.lo = ~u.lo + 1;
    u.hi = ~u.hi + (u.lo == 0 ? 1 : 0);
  }
  return u;
}

static yz_i128 yz_i128_from(yz_u128 u, int negative) {
  yz_i128 r;
  if (negative) {
    uint64_t lo = ~u.lo + 1;
    uint64_t hi = ~u.hi + (lo == 0 ? 1 : 0);
    r.lo = lo;
    r.hi = (int64_t)hi;
  } else {
    r.lo = u.lo;
    r.hi = (int64_t)u.hi;
  }
  return r;
}

/* ── 2. __atomic_* builtins ───────────────────────────────────────────────
 *
 * The compiler is built -Dsingle-threaded and YasOS gives a process one
 * thread, so the only concurrency an atomic could be guarding against here is
 * the process against itself. Plain accesses are therefore correct AND
 * complete: no LDREX/STREX pair, no interrupt masking. If the compiler is ever
 * built multi-threaded, every one of these has to grow a real implementation
 * -- that is the whole reason they are gathered in one block. */

uint8_t __atomic_load_1(const volatile void *p, int m) {
  (void)m;
  return *(const volatile uint8_t *)p;
}
uint16_t __atomic_load_2(const volatile void *p, int m) {
  (void)m;
  return *(const volatile uint16_t *)p;
}
uint32_t __atomic_load_4(const volatile void *p, int m) {
  (void)m;
  return *(const volatile uint32_t *)p;
}
void __atomic_store_1(volatile void *p, uint8_t v, int m) {
  (void)m;
  *(volatile uint8_t *)p = v;
}
void __atomic_store_2(volatile void *p, uint16_t v, int m) {
  (void)m;
  *(volatile uint16_t *)p = v;
}
void __atomic_store_4(volatile void *p, uint32_t v, int m) {
  (void)m;
  *(volatile uint32_t *)p = v;
}
uint8_t __atomic_fetch_add_1(volatile void *p, uint8_t v, int m) {
  uint8_t old = *(volatile uint8_t *)p;
  (void)m;
  *(volatile uint8_t *)p = (uint8_t)(old + v);
  return old;
}
uint8_t __atomic_fetch_sub_1(volatile void *p, uint8_t v, int m) {
  uint8_t old = *(volatile uint8_t *)p;
  (void)m;
  *(volatile uint8_t *)p = (uint8_t)(old - v);
  return old;
}
uint16_t __atomic_fetch_or_2(volatile void *p, uint16_t v, int m) {
  uint16_t old = *(volatile uint16_t *)p;
  (void)m;
  *(volatile uint16_t *)p = (uint16_t)(old | v);
  return old;
}
uint32_t __atomic_fetch_add_4(volatile void *p, uint32_t v, int m) {
  uint32_t old = *(volatile uint32_t *)p;
  (void)m;
  *(volatile uint32_t *)p = old + v;
  return old;
}
uint32_t __atomic_fetch_sub_4(volatile void *p, uint32_t v, int m) {
  uint32_t old = *(volatile uint32_t *)p;
  (void)m;
  *(volatile uint32_t *)p = old - v;
  return old;
}
uint32_t __atomic_fetch_or_4(volatile void *p, uint32_t v, int m) {
  uint32_t old = *(volatile uint32_t *)p;
  (void)m;
  *(volatile uint32_t *)p = old | v;
  return old;
}
uint32_t __atomic_fetch_xor_4(volatile void *p, uint32_t v, int m) {
  uint32_t old = *(volatile uint32_t *)p;
  (void)m;
  *(volatile uint32_t *)p = old ^ v;
  return old;
}
uint32_t __atomic_exchange_4(volatile void *p, uint32_t v, int m) {
  uint32_t old = *(volatile uint32_t *)p;
  (void)m;
  *(volatile uint32_t *)p = v;
  return old;
}
int __atomic_compare_exchange_4(volatile void *p, void *expected,
                                uint32_t desired, int weak, int success,
                                int failure) {
  uint32_t current = *(volatile uint32_t *)p;
  (void)weak;
  (void)success;
  (void)failure;
  if (current == *(uint32_t *)expected) {
    *(volatile uint32_t *)p = desired;
    return 1;
  }
  *(uint32_t *)expected = current;
  return 0;
}

/* ── 3. POSIX calls YasOS's libc does not have ───────────────────────────── */

/* Zig reads errno through __errno_location(); YasOS exposes errno directly. */
int *__errno_location(void) { return &errno; }

/* statx(2). Zig's Io.Threaded stats every file this way on Linux, so this is
 * the one shim on the hot path for a compile. Two translations matter:
 *
 *   - the AT_ flags Zig passes are Linux's (SYMLINK_NOFOLLOW 0x100,
 *     EMPTY_PATH 0x1000); YasOS's fcntl.h uses 0x1 for SYMLINK_NOFOLLOW and
 *     has no EMPTY_PATH at all, so the values cannot be forwarded as-is;
 *   - the mask returned has to advertise at least TYPE, MODE, NLINK, MTIME,
 *     CTIME, INO and SIZE, or statFromLinux() rejects the result as
 *     error.Unexpected (lib/std/Io/Threaded.zig `linux_statx_check`). */

#define LINUX_AT_SYMLINK_NOFOLLOW 0x100
#define LINUX_AT_EMPTY_PATH 0x1000
#define LINUX_STATX_BASIC_STATS 0x000007ffU

struct linux_statx_timestamp {
  int64_t tv_sec;
  uint32_t tv_nsec;
  int32_t __reserved;
};

struct linux_statx {
  uint32_t stx_mask;
  uint32_t stx_blksize;
  uint64_t stx_attributes;
  uint32_t stx_nlink;
  uint32_t stx_uid;
  uint32_t stx_gid;
  uint16_t stx_mode;
  uint16_t __spare0;
  uint64_t stx_ino;
  uint64_t stx_size;
  uint64_t stx_blocks;
  uint64_t stx_attributes_mask;
  struct linux_statx_timestamp stx_atime;
  struct linux_statx_timestamp stx_btime;
  struct linux_statx_timestamp stx_ctime;
  struct linux_statx_timestamp stx_mtime;
  uint32_t stx_rdev_major;
  uint32_t stx_rdev_minor;
  uint32_t stx_dev_major;
  uint32_t stx_dev_minor;
  uint64_t stx_mnt_id;
  uint32_t stx_dio_mem_align;
  uint32_t stx_dio_offset_align;
  uint64_t stx_subvol;
  uint32_t stx_atomic_write_unit_min;
  uint32_t stx_atomic_write_unit_max;
  uint32_t stx_atomic_write_segments_max;
  uint32_t stx_dio_read_offset_align;
  uint32_t stx_atomic_write_unit_max_opt;
  uint32_t __spare2[1];
  uint64_t __spare3[9];
};

static void yz_fill_timestamp(struct linux_statx_timestamp *dst,
                              const struct timespec *src) {
  dst->tv_sec = (int64_t)src->tv_sec;
  dst->tv_nsec = (uint32_t)src->tv_nsec;
  dst->__reserved = 0;
}

int statx(int dirfd, const char *path, unsigned int flags, unsigned int mask,
          struct linux_statx *out) {
  struct stat st;
  int rc;

  (void)mask;
  memset(out, 0, sizeof(*out));

  if ((flags & LINUX_AT_EMPTY_PATH) && (path == NULL || path[0] == '\0')) {
    rc = fstat(dirfd, &st);
  } else if (dirfd == AT_FDCWD || path[0] == '/') {
    rc = (flags & LINUX_AT_SYMLINK_NOFOLLOW) ? lstat(path, &st)
                                             : stat(path, &st);
  } else {
    rc = fstatat(dirfd, path, &st,
                 (flags & LINUX_AT_SYMLINK_NOFOLLOW) ? AT_SYMLINK_NOFOLLOW : 0);
  }
  if (rc != 0)
    return (int)yz_trace("statx", rc);

  out->stx_mask = LINUX_STATX_BASIC_STATS;
  out->stx_blksize = (uint32_t)st.st_blksize ? (uint32_t)st.st_blksize : 512;
  out->stx_nlink = st.st_nlink;
  out->stx_uid = st.st_uid;
  out->stx_gid = st.st_gid;
  out->stx_mode = st.st_mode;
  out->stx_ino = st.st_ino;
  out->stx_size = st.st_size;
  out->stx_blocks = st.st_blocks;
  yz_fill_timestamp(&out->stx_atime, &st.st_atim);
  yz_fill_timestamp(&out->stx_mtime, &st.st_mtim);
  yz_fill_timestamp(&out->stx_ctime, &st.st_ctim);
  out->stx_btime = out->stx_ctime;
  out->stx_dev_major = (uint32_t)st.st_dev;
  return 0;
}

/* Positional and vectored I/O, spelled out in terms of what YasOS has. The
 * p-variants save and restore the file offset rather than leaving it moved,
 * which is the whole contract callers rely on. */

struct yz_iovec {
  void *iov_base;
  size_t iov_len;
};

ssize_t pread(int fd, void *buf, size_t count, int64_t offset) {
  off_t saved = lseek(fd, 0, SEEK_CUR);
  ssize_t n;
  if (saved < 0)
    return -1;
  if (lseek(fd, (off_t)offset, SEEK_SET) < 0)
    return -1;
  n = read(fd, buf, count);
  lseek(fd, saved, SEEK_SET);
  return yz_trace("pread", n);
}

ssize_t pwrite(int fd, const void *buf, size_t count, int64_t offset) {
  off_t saved = lseek(fd, 0, SEEK_CUR);
  ssize_t n;
  if (saved < 0)
    return -1;
  if (lseek(fd, (off_t)offset, SEEK_SET) < 0)
    return -1;
  n = write(fd, buf, count);
  lseek(fd, saved, SEEK_SET);
  return yz_trace("pwrite", n);
}

ssize_t readv(int fd, const struct yz_iovec *iov, int iovcnt) {
  ssize_t total = 0;
  int i;
  for (i = 0; i < iovcnt; i++) {
    ssize_t n;
    if (iov[i].iov_len == 0)
      continue;
    n = read(fd, iov[i].iov_base, iov[i].iov_len);
    if (n < 0)
      return total > 0 ? total : yz_trace("readv", -1);
    total += n;
    if ((size_t)n < iov[i].iov_len)
      break; /* short read ends the call, as readv does */
  }
  return total;
}

ssize_t writev(int fd, const struct yz_iovec *iov, int iovcnt) {
  ssize_t total = 0;
  int i;
  for (i = 0; i < iovcnt; i++) {
    ssize_t n;
    if (iov[i].iov_len == 0)
      continue;
    n = write(fd, iov[i].iov_base, iov[i].iov_len);
    if (n < 0)
      return total > 0 ? total : yz_trace("writev", -1);
    total += n;
    if ((size_t)n < iov[i].iov_len)
      break;
  }
  return total;
}

ssize_t preadv(int fd, const struct yz_iovec *iov, int iovcnt,
               int64_t offset) {
  off_t saved = lseek(fd, 0, SEEK_CUR);
  ssize_t n;
  if (saved < 0)
    return -1;
  if (lseek(fd, (off_t)offset, SEEK_SET) < 0)
    return -1;
  n = readv(fd, iov, iovcnt);
  lseek(fd, saved, SEEK_SET);
  return yz_trace("preadv", n);
}

ssize_t pwritev(int fd, const struct yz_iovec *iov, int iovcnt,
                int64_t offset) {
  off_t saved = lseek(fd, 0, SEEK_CUR);
  ssize_t n;
  if (saved < 0)
    return -1;
  if (lseek(fd, (off_t)offset, SEEK_SET) < 0)
    return -1;
  n = writev(fd, iov, iovcnt);
  lseek(fd, saved, SEEK_SET);
  return yz_trace("pwritev", n);
}

/* 64-bit file offsets. Zig's std for thumb-linux-musleabi has musl's 64-bit
 * off_t, so zig.c declares lseek(int, int64_t, int) returning int64_t and
 * ftruncate(int, int64_t); YasOS's libc takes and returns a 32-bit long. Under
 * AAPCS an int64_t argument takes an even register pair, so the two sides do
 * not even agree on WHERE the value is: ftruncate read its length from r1 --
 * whatever was left there -- and every file Zig trimmed after writing (the
 * whole ZIR cache, via Io.File.Writer.end) came out empty, while lseek got
 * its whence from the offset's low word and returned a garbage high word.
 * build_zig.sh renames Zig's calls to these, which narrow in range. */
int64_t yz_lseek64(int fd, int64_t offset, int whence) {
  if (offset > LONG_MAX || offset < LONG_MIN) {
    errno = EOVERFLOW;
    return -1;
  }
  return lseek(fd, (long)offset, whence);
}

int yz_ftruncate64(int fd, int64_t length) {
  if (length < 0 || length > LONG_MAX) {
    errno = length < 0 ? EINVAL : EFBIG;
    return -1;
  }
  return ftruncate(fd, (off_t)length);
}

/* One process, one compiler: the cache lock has nobody to exclude. */
int flock(int fd, int operation) {
  (void)fd;
  (void)operation;
  return 0;
}

/* Not cryptographic, and it does not pretend to be: Zig uses this to salt hash
 * maps and to name temporary files. xorshift64 seeded from the clock and the
 * pid is enough for both. */
ssize_t getrandom(void *buf, size_t len, unsigned int flags) {
  static uint64_t state;
  unsigned char *out = buf;
  size_t i;

  (void)flags;
  if (state == 0) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    state = ((uint64_t)ts.tv_sec << 20) ^ (uint64_t)ts.tv_nsec ^
            ((uint64_t)getpid() << 32) ^ 0x9e3779b97f4a7c15ull;
  }
  for (i = 0; i < len; i++) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    out[i] = (unsigned char)(state >> 24);
  }
  return (ssize_t)len;
}

/* Calls that exist so the link resolves. None of them is on the path a
 * `zig build-obj -ofmt=c` takes: Zig only forks to run an external linker,
 * only opens sockets for the build runner's IPC, and only changes uid/gid or
 * scheduling affinity in code that never runs here. ENOSYS is what Zig's own
 * fallbacks look for. */
/* Each stub says so once, the first time it is called. A port fails in the
 * caller's vocabulary -- Zig reports "Unexpected" and names a file that had
 * nothing to do with it -- so the one thing worth knowing, which unimplemented
 * call was reached, is exactly what gets lost. Set YASOS_ZIG_QUIET to silence
 * them once a program is known to tolerate the refusals. */
static int yz_quiet(void) {
  static int state; /* 0 unknown, 1 quiet, 2 loud */
  if (state == 0)
    state = getenv("YASOS_ZIG_QUIET") ? 1 : 2;
  return state == 1;
}

static void yz_stub_called(const char *name, int *reported) {
  if (*reported || yz_quiet())
    return;
  if (!getenv("YASOS_ZIG_ALL_STUBS"))
    *reported = 1;
  fprintf(stderr, "yasos_compat: %s() is not implemented here; returning ENOSYS\n", name);
}

#define YZ_ENOSYS_STUB(name, proto)                                            \
  int name proto {                                                             \
    static int reported;                                                       \
    yz_stub_called(#name, &reported);                                          \
    errno = ENOSYS;                                                            \
    return -1;                                                                 \
  }

YZ_ENOSYS_STUB(fchdir, (int fd))
YZ_ENOSYS_STUB(fork, (void))
YZ_ENOSYS_STUB(setpgid, (int pid, int pgid))
YZ_ENOSYS_STUB(setregid, (unsigned int r, unsigned int e))
YZ_ENOSYS_STUB(setreuid, (unsigned int r, unsigned int e))
YZ_ENOSYS_STUB(accept4, (int s, void *a, void *l, int f))
YZ_ENOSYS_STUB(listen, (int s, int backlog))
YZ_ENOSYS_STUB(socketpair, (unsigned int d, unsigned int t, unsigned int p,
                            int *sv))
YZ_ENOSYS_STUB(getsockname, (int s, void *a, unsigned int *l))
YZ_ENOSYS_STUB(recvmsg, (int s, void *m, int f))
YZ_ENOSYS_STUB(sendmsg, (int s, const void *m, int f))
YZ_ENOSYS_STUB(sendmmsg, (int s, void *m, unsigned int n, int f))
YZ_ENOSYS_STUB(clock_getres, (int id, struct timespec *res))
YZ_ENOSYS_STUB(clock_nanosleep, (int id, int flags, const struct timespec *req,
                                 struct timespec *rem))
YZ_ENOSYS_STUB(wait4, (int pid, int *status, int options, void *rusage))
YZ_ENOSYS_STUB(copy_file_range, (int fdin, int64_t *offin, int fdout,
                                 int64_t *offout, size_t len,
                                 unsigned int flags))
YZ_ENOSYS_STUB(sendfile, (int out, int in, int64_t *off, size_t count))

/* An alternate signal stack for a kernel that delivers no signals: there is
 * nothing to install it for, and nothing to go wrong if a caller thinks it has
 * one. Reporting "disabled" and succeeding keeps the runtimes that arm one at
 * startup (Zig's does) on their normal path -- refusing sends them down an
 * error path with half-built state behind it. */
#define YZ_SS_DISABLE 2

struct yz_sigaltstack {
  void *ss_sp;
  int ss_flags;
  size_t ss_size;
};

int sigaltstack(const struct yz_sigaltstack *ss, struct yz_sigaltstack *old_ss) {
  (void)ss;
  if (old_ss) {
    old_ss->ss_sp = NULL;
    old_ss->ss_flags = YZ_SS_DISABLE;
    old_ss->ss_size = 0;
  }
  return 0;
}

/* One CPU as far as a process is concerned: YasOS schedules a process on either
 * core, but nothing here lets a program pin itself, so the honest answer is a
 * one-CPU mask rather than a refusal. Callers use this to size thread pools. */
int sched_getaffinity(int pid, size_t cpusetsize, void *mask) {
  (void)pid;
  if (mask == NULL || cpusetsize < sizeof(unsigned long)) {
    errno = EINVAL;
    return -1;
  }
  memset(mask, 0, cpusetsize);
  *(unsigned long *)mask = 1;
  return 0;
}

/* The ELF auxiliary vector does not exist here; 0 is "not present", which is
 * what every caller checks for. */
unsigned long getauxval(unsigned long type) {
  (void)type;
  return 0;
}

/* ── 4. libm gaps ─────────────────────────────────────────────────────────
 *
 * Derived rather than tabulated: these are used by Zig's float formatting and
 * by std.math, not by anything whose last bit the compiler depends on. */

extern double exp(double);
extern double log(double);
extern double ldexp(double, int);
extern float expf(float);
extern float logf(float);

#define YZ_LN2 0.693147180559945309417
#define YZ_LOG2E 1.442695040888963407360

/* ── 5. f16 / f80 / f128 soft float ─────────────────────────────────
 *
 * Not here any more. The Zig compiler holds every comptime float in an f128,
 * so it converts one to f64 whenever it materialises a float value -- which a
 * program need not contain a float to trigger -- and it reaches far more of
 * these than is worth writing by hand.
 *
 * Zig's own compiler-rt supplies all of them, and it renders through the C
 * backend for this target like anything else: see apps/zig/build_compiler_rt.sh
 * and apps/zig/strip_naked_asm.py, which adapt the two things tinycc cannot
 * take (named inline-asm operands in eight ARM EABI wrappers, and second
 * exported names expressed as attribute aliases of an assembler name).
 * Link the resulting object next to this one. */
