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
 *   4. f16/f80/f128 soft float. The compiler only reaches these through
 *      comptime float work; they abort with the symbol name rather than
 *      silently returning nonsense, so if a program ever does need one, the
 *      failure says exactly which routine to write.
 *
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
 */

#include <errno.h>
#include <fcntl.h>
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

/* ── 5. f16 / f80 / f128 soft float ───────────────────────────────────────
 *
 * Reached only through comptime float arithmetic in a program being compiled.
 * Each one aborts with its own name, so a program that needs one names the
 * routine to implement instead of producing a wrong number. The declared
 * signature is deliberately (void): these never return, and giving them their
 * real prototypes would mean writing out 100 of them for no gain. */

/* ── f128, the parts the compiler actually reaches ────────────────────────
 *
 * The Zig compiler holds every comptime float in an f128, so it converts one
 * to f64 whenever it materialises a float value -- which a program need not
 * contain a float to trigger. tinycc's runtime has no f128, and Zig's own
 * compiler-rt cannot be built through the C backend for this target (its ARM
 * routines use asm operand syntax tinycc lacks, and its math aliases name f80
 * symbols that do not exist here), so the few routines the compiler reaches
 * are written out here.
 *
 * The C backend renders f128 under ZIG_TARGET_SOFT_COMPILER_RT_F128_ABI, i.e.
 * as a by-value struct of two 64-bit halves, so that is the parameter type. */
typedef struct { uint64_t lo, hi; } yz_f128;

/* Comparisons. The return values follow the soft-float ABI: __letf2/__lttf2
 * report >0 for "greater", __getf2/__gttf2 report <0 for "less", and both
 * report 1 (resp. -1... any nonzero with the right sign) for unordered, which
 * is why NaN is tested first. */
static int yz_f128_unordered(yz_f128 a, yz_f128 b) {
  const uint64_t ae = (a.hi >> 48) & 0x7FFF, be = (b.hi >> 48) & 0x7FFF;
  const int a_nan = ae == 0x7FFF && ((a.hi & 0x0000FFFFFFFFFFFFULL) | a.lo);
  const int b_nan = be == 0x7FFF && ((b.hi & 0x0000FFFFFFFFFFFFULL) | b.lo);
  return a_nan || b_nan;
}

/* -1, 0 or 1 for a<b, a==b, a>b; callers check NaN separately. */
static int yz_f128_cmp(yz_f128 a, yz_f128 b) {
  const int a_neg = (a.hi >> 63) != 0, b_neg = (b.hi >> 63) != 0;
  /* +-0 compare equal whatever their signs. */
  const int a_zero = ((a.hi & 0x7FFFFFFFFFFFFFFFULL) | a.lo) == 0;
  const int b_zero = ((b.hi & 0x7FFFFFFFFFFFFFFFULL) | b.lo) == 0;
  if (a_zero && b_zero) return 0;
  if (a_neg != b_neg) return a_neg ? -1 : 1;
  /* Same sign: the magnitudes order as unsigned integers do, reversed when
   * both are negative. */
  int mag;
  if (a.hi != b.hi)
    mag = (a.hi & 0x7FFFFFFFFFFFFFFFULL) < (b.hi & 0x7FFFFFFFFFFFFFFFULL) ? -1 : 1;
  else if (a.lo != b.lo)
    mag = a.lo < b.lo ? -1 : 1;
  else
    return 0;
  return a_neg ? -mag : mag;
}

int __eqtf2(yz_f128 a, yz_f128 b) { return yz_f128_unordered(a, b) ? 1 : yz_f128_cmp(a, b); }
int __netf2(yz_f128 a, yz_f128 b) { return yz_f128_unordered(a, b) ? 1 : yz_f128_cmp(a, b); }
int __lttf2(yz_f128 a, yz_f128 b) { return yz_f128_unordered(a, b) ? 1 : yz_f128_cmp(a, b); }
int __letf2(yz_f128 a, yz_f128 b) { return yz_f128_unordered(a, b) ? 1 : yz_f128_cmp(a, b); }
int __getf2(yz_f128 a, yz_f128 b) { return yz_f128_unordered(a, b) ? -1 : yz_f128_cmp(a, b); }
/* The C backend's 128-bit integers have the same two-halves shape as its
 * f128, and the compiler builds float values out of them. */
typedef struct { uint64_t lo, hi; } yz_u128;

static int yz_clz64(uint64_t x) {
  int n = 0;
  if (!x) return 64;
  while (!(x & 0x8000000000000000ULL)) { x <<= 1; n++; }
  return n;
}

static void yz_no_float(const char *name) {
  fprintf(stderr, "yasos_compat: %s: f16/f80/f128 arithmetic is not implemented on this target\n", name);
  abort();
}

#define YZ_NO_FLOAT(name)                                                      \
  void name(void) { yz_no_float(#name); }

YZ_NO_FLOAT(__eqhf2)
YZ_NO_FLOAT(__eqxf2)
YZ_NO_FLOAT(__gehf2)
YZ_NO_FLOAT(__gexf2)
YZ_NO_FLOAT(__lehf2)
YZ_NO_FLOAT(__lexf2)
YZ_NO_FLOAT(__lthf2)
YZ_NO_FLOAT(__ltxf2)
YZ_NO_FLOAT(__nehf2)
YZ_NO_FLOAT(__nexf2)
