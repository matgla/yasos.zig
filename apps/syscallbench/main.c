/*
 * syscallbench — what a system call costs the caller, end to end.
 *
 * The kernel's own profiler times from the SVC entry stamp to the end of the
 * handler, which excludes the return trampoline -- and on this kernel a non-fast
 * syscall returns through a second SVC with its own exception entry and return.
 * Measuring from user code is the only way to see the whole round trip.
 *
 * The arms are chosen so the interesting numbers are differences between them,
 * which cancels the loop, the libc wrapper and the timer:
 *
 *   getpid     a "fast" syscall — one exception entry and one return.
 *   close(-1)  a trampoline syscall whose handler returns immediately, so
 *              close(-1) - getpid isolates the trampoline itself.
 *   lseek      a trampoline syscall with a real handler body, for scale.
 *
 * Each arm is also run with the FPU live. The kernel disables lazy FP stacking
 * (disable_lazy_fp_stacking in source/arch/arm-m/process.zig), so every
 * exception entry from FP context eagerly stacks s0-s15 + FPSCR; the _fp arms
 * minus their counterparts price that.
 *
 * Output is one space-separated key=value line per arm, matching sdbench.
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
#include <sys/perf.h>
#include <sys/time.h>
#include <unistd.h>

/* Enough calls that the two gettimeofday syscalls bracketing a trial are noise
 * (they are themselves fast-path calls costing about what one measured call
 * costs), few enough that a trial fits inside one scheduling quantum often
 * enough for the minimum to land clean. */
#define DEFAULT_ITERS 20000u

/* The scheduler preempts every CONFIG_PROCESS_CONTEXT_SWITCH_PERIOD ms, and a
 * preempted trial reads high by the whole quantum. Averaging would fold that
 * in; the minimum over several trials reports the uncontended cost, which is
 * the one that changes when the path changes. */
#define TRIALS 7

/* Single precision on purpose: the FPU is fpv5-sp-d16, so a `double` expression
 * compiles to DCP or softfloat calls that never set CONTROL.FPCA and so never
 * cause an FP exception frame -- it would measure nothing. `float` keeps the
 * work in s0-s15, the state whose stacking is being priced.
 *
 * Volatile so the compiler can neither hoist the FP work out of the loop nor
 * fold it away: FPCA is only set if the instructions really execute. */
static volatile float fp_state = 1.0f;
static volatile int sink;

static unsigned long long now_us(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (unsigned long long)tv.tv_sec * 1000000ull + (unsigned long long)tv.tv_usec;
}

/* One FP operation, matching what the _fp arms do per iteration. Measured on
 * its own in the fp_loop arm so it can be subtracted back out. */
static void touch_fp(void) {
  fp_state = fp_state * 1.0000001f + 1.0f;
  if (fp_state > 1.0e6f) {
    fp_state = 1.0f;
  }
}

typedef void (*arm_fn)(int fd);

static void arm_loop(int fd) { (void)fd; sink += 1; }
static void arm_fp_loop(int fd) { (void)fd; touch_fp(); sink += 1; }
static void arm_getpid(int fd) { (void)fd; sink += getpid(); }
static void arm_getpid_fp(int fd) { (void)fd; touch_fp(); sink += getpid(); }
static void arm_close_bad(int fd) { (void)fd; sink += close(-1); }
static void arm_close_bad_fp(int fd) { (void)fd; touch_fp(); sink += close(-1); }
static void arm_lseek(int fd) { sink += (int)lseek(fd, 0, SEEK_CUR); }

/* Nanoseconds per call, minimum over TRIALS. us*1000/iters keeps the whole
 * computation in integers; at these iteration counts the elapsed microseconds
 * are large enough that the truncation is far below the differences reported. */
static unsigned long run_arm(arm_fn fn, int fd, unsigned int iters) {
  unsigned long best = 0;
  for (int trial = 0; trial < TRIALS; trial++) {
    const unsigned long long start = now_us();
    for (unsigned int i = 0; i < iters; i++) {
      fn(fd);
    }
    const unsigned long long elapsed = now_us() - start;
    const unsigned long per_call = (unsigned long)((elapsed * 1000ull) / iters);
    if (trial == 0 || per_call < best) {
      best = per_call;
    }
  }
  return best;
}

/* Differences are the product here, and a difference of two independently
 * minimised measurements can come out negative when the two arms are within
 * noise of each other. Reporting that as a huge unsigned number would be worse
 * than reporting the zero it actually means. */
static long difference(unsigned long a, unsigned long b) {
  return (long)a - (long)b;
}

int main(int argc, char **argv) {
  unsigned int iters = DEFAULT_ITERS;
  if (argc > 1) {
    const long parsed = strtol(argv[1], NULL, 10);
    if (parsed <= 0) {
      fprintf(stderr, "usage: %s [iterations]\n", argv[0]);
      return 1;
    }
    iters = (unsigned int)parsed;
  }

  /* lseek needs a real descriptor. Its own file, opened read-only, so the arm
   * measures the seek path and cannot disturb anything else. */
  const int fd = open("/bin/syscallbench", O_RDONLY);
  if (fd < 0) {
    fprintf(stderr, "syscallbench: cannot open self for the lseek arm\n");
    return 1;
  }

  printf("syscallbench: iters=%u trials=%d\n", iters, TRIALS);

  const unsigned long loop = run_arm(arm_loop, fd, iters);
  const unsigned long fp_loop = run_arm(arm_fp_loop, fd, iters);
  const unsigned long getpid_ns = run_arm(arm_getpid, fd, iters);
  const unsigned long getpid_fp_ns = run_arm(arm_getpid_fp, fd, iters);
  const unsigned long close_ns = run_arm(arm_close_bad, fd, iters);
  const unsigned long close_fp_ns = run_arm(arm_close_bad_fp, fd, iters);
  const unsigned long lseek_ns = run_arm(arm_lseek, fd, iters);

  /* Per-arm cost with the loop scaffolding removed, so each number is the
   * syscall round trip and nothing else. The _fp arms subtract the FP loop, so
   * the FP arithmetic itself is gone too and what remains is the stacking. */
  const long getpid_net = difference(getpid_ns, loop);
  const long close_net = difference(close_ns, loop);
  const long lseek_net = difference(lseek_ns, loop);
  const long getpid_fp_net = difference(getpid_fp_ns, fp_loop);
  const long close_fp_net = difference(close_fp_ns, fp_loop);

  printf("arm=loop ns=%lu\n", loop);
  printf("arm=fp_loop ns=%lu\n", fp_loop);
  printf("arm=getpid ns=%lu net_ns=%ld path=fast\n", getpid_ns, getpid_net);
  printf("arm=close_bad ns=%lu net_ns=%ld path=trampoline\n", close_ns, close_net);
  printf("arm=lseek ns=%lu net_ns=%ld path=trampoline\n", lseek_ns, lseek_net);
  printf("arm=getpid_fp ns=%lu net_ns=%ld path=fast fpu=live\n", getpid_fp_ns, getpid_fp_net);
  printf("arm=close_bad_fp ns=%lu net_ns=%ld path=trampoline fpu=live\n", close_fp_ns, close_fp_net);

  /* trampoline_ns  the second exception round trip, over a fast-path call.
   *   fp_tax_fast    eager FP stacking across one entry + one return.
   *   fp_tax_slow    the same across the trampoline's two of each, so roughly
   *                  twice fp_tax_fast -- a check on both.
   *   handler_ns     lseek's handler body on top of close(-1)'s path. */
  printf("derived: trampoline_ns=%ld fp_tax_fast_ns=%ld fp_tax_slow_ns=%ld handler_lseek_ns=%ld\n",
         difference(close_net < 0 ? 0 : (unsigned long)close_net,
                    getpid_net < 0 ? 0 : (unsigned long)getpid_net),
         difference(getpid_fp_net < 0 ? 0 : (unsigned long)getpid_fp_net,
                    getpid_net < 0 ? 0 : (unsigned long)getpid_net),
         difference(close_fp_net < 0 ? 0 : (unsigned long)close_fp_net,
                    close_net < 0 ? 0 : (unsigned long)close_net),
         difference(lseek_net < 0 ? 0 : (unsigned long)lseek_net,
                    close_net < 0 ? 0 : (unsigned long)close_net));

  /* The kernel's view of the very same calls. Its totals stop at the end of the
   * handler, so total_us well below the net_ns figures above is not a
   * disagreement -- it is the return trampoline, measured by difference. */
  perf_dump_print(0);

  close(fd);
  return 0;
}
