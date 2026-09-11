/*
 * fpbench -- what each of the three ways to do floating point actually costs.
 *
 * Copyright (c) 2026 Mateusz Stadnik
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 *
 * ## The four arms
 *
 * One source, built four times, differing only in flags to the compiler:
 *
 *   soft      -mfpu=none -mfp-lib=shared
 *             Every operation is an __aeabi_ call into libsoftfp.so: bit-exact
 *             IEEE-754 in C, and the only arm that would run on a part with no
 *             FP hardware at all.
 *
 *   hwlib     -mfp-inline=none -mfp-lib=shared
 *             Every operation is still an __aeabi_ call, but into
 *             librp2350fp.so, whose doubles are DCP sequences and whose floats
 *             are FPv5-SP instructions.  The hardware runs; the caller pays a
 *             cross-module call through the GOT to reach it.
 *
 *   hwstatic  -mfp-inline=none -mfp-lib=static
 *             The same runtime, copied into this program at link time.  The
 *             only thing that separates it from hwlib is the dynamic linkage,
 *             so hwlib - hwstatic is what going through the OS's loader costs.
 *
 *   inline    -mfp-lib=shared
 *             The backend lowers what it can straight into the instruction
 *             stream and calls librp2350fp.so for the rest.  On RP2350 that is
 *             float add/sub/mul/div and double add/sub/compare inline;
 *             double multiply, divide and every conversion still call.
 *
 * The rows where all four arms agree are not filler -- they are the control.
 * A conversion is a library call in every arm, so if `i2d` moves between two
 * columns, the harness moved, not the code.
 *
 * ## Why every operand is volatile
 *
 * Without it the measurement is of an empty loop.  tcc folds constant FP
 * expressions, and it folds them *unevenly*: several passes match on the
 * __aeabi_ libcall names, so they fire in the soft arm and miss the arm whose
 * operations were lowered inline.  A benchmark that let that happen would
 * report the soft path as infinitely fast.  Volatile operands and a volatile
 * result make every arm execute exactly the operations it names.
 *
 * The cost of that traffic -- two loads, one store, the loop counter -- is in
 * every reported figure, and it is *identical across arms*, because it is
 * integer code compiled from the same source with the same optimiser.  So the
 * differences between columns are exact.  For a per-row figure with the
 * scaffolding removed, the `baseline` arm does the same two-loads/one-store on
 * a 64-bit integer, and `net_ns` subtracts it.
 *
 * ## Reporting
 *
 * Each build writes its own results to /tmp/fpbench.<mode> as well as printing
 * them, and any of the builds run with --report joins the files it finds into
 * one table.  That is not elegance for its own sake: this kernel's vfork gives
 * a child that shares the parent's descriptor table until it execs, so a
 * driver that redirected four children into four files would be writing
 * through the parent's own stdout.  Letting each program open its own file
 * needs no fork at all.
 *
 * Usage:
 *   fpbench-<mode> [iterations]     run this mode, print and record it
 *   fpbench-<mode> --report         print the table of every recorded mode
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#ifndef FPBENCH_MODE
#define FPBENCH_MODE "unknown"
#endif

/* Enough iterations that the two gettimeofday calls bracketing a trial are
 * noise even for the cheapest arm (an inline double add is a handful of
 * cycles), few enough that the slowest -- a software double divide -- still
 * fits a trial into a fraction of a second. */
#define DEFAULT_ITERS 20000u

/* The scheduler preempts every CONFIG_PROCESS_CONTEXT_SWITCH_PERIOD ms and a
 * preempted trial reads high by the whole quantum.  The minimum over several
 * trials reports the uncontended cost, which is the one that changes when the
 * lowering changes.  Same argument, and same constant, as apps/syscallbench. */
#define TRIALS 7

#define RESULT_DIR "/tmp"
#define MAX_MODES 8

/* Operands chosen so no operation lands on a fast path or a special value:
 * both are normal, neither is a power of two, the quotient is irrational and
 * the product needs a real 53-bit multiply.  A denormal would be worse than
 * unrepresentative -- the DCP flushes those to zero, so it would time a
 * different computation than the soft arm does. */
static volatile double da = 3.14159265358979;
static volatile double db = 1.41421356237309;
static volatile float fa = 3.14159265f;
static volatile float fb = 1.41421356f;
static volatile long long ia = 0x0123456789abcdefLL;
static volatile long long ib = 0x76543210fedcba98LL;
static volatile int ii = 1234567;

static volatile double dsink;
static volatile float fsink;
static volatile long long isink;

typedef void (*kernel_fn)(unsigned int n);

/* Each kernel is one operation plus the loads and store that keep it honest.
 * `while (n--)` rather than a counted for-loop so the arms cannot differ in
 * how the induction variable is strength-reduced. */
static void k_baseline(unsigned int n) { while (n--) isink = ia ^ ib; }
static void k_dadd(unsigned int n) { while (n--) dsink = da + db; }
static void k_dsub(unsigned int n) { while (n--) dsink = da - db; }
static void k_dmul(unsigned int n) { while (n--) dsink = da * db; }
static void k_ddiv(unsigned int n) { while (n--) dsink = da / db; }
static void k_dcmp(unsigned int n) { while (n--) isink = (da < db); }
static void k_fadd(unsigned int n) { while (n--) fsink = fa + fb; }
static void k_fsub(unsigned int n) { while (n--) fsink = fa - fb; }
static void k_fmul(unsigned int n) { while (n--) fsink = fa * fb; }
static void k_fdiv(unsigned int n) { while (n--) fsink = fa / fb; }
static void k_fcmp(unsigned int n) { while (n--) isink = (fa < fb); }
static void k_i2d(unsigned int n) { while (n--) dsink = (double)ii; }
static void k_d2i(unsigned int n) { while (n--) isink = (int)da; }
static void k_f2d(unsigned int n) { while (n--) dsink = (double)fa; }
static void k_d2f(unsigned int n) { while (n--) fsink = (float)da; }

struct arm {
  const char *name;
  kernel_fn fn;
};

static const struct arm arms[] = {
    {"baseline", k_baseline}, {"dadd", k_dadd}, {"dsub", k_dsub}, {"dmul", k_dmul}, {"ddiv", k_ddiv},
    {"dcmp", k_dcmp},         {"fadd", k_fadd}, {"fsub", k_fsub}, {"fmul", k_fmul}, {"fdiv", k_fdiv},
    {"fcmp", k_fcmp},         {"i2d", k_i2d},   {"d2i", k_d2i},   {"f2d", k_f2d},   {"d2f", k_d2f},
};

#define ARM_COUNT ((int)(sizeof(arms) / sizeof(arms[0])))

static unsigned long long now_us(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return (unsigned long long)tv.tv_sec * 1000000ull + (unsigned long long)tv.tv_usec;
}

/* Picoseconds per operation, minimum over TRIALS.  Picoseconds because an
 * inline double add on this part is a few nanoseconds and the interesting
 * ratios live in the second digit; us*1000000/iters keeps it all in integers
 * and cannot overflow at these iteration counts (a 1 s trial is 1e12 ps). */
static unsigned long run_arm(kernel_fn fn, unsigned int iters) {
  unsigned long best = 0;
  int trial;
  for (trial = 0; trial < TRIALS; trial++) {
    unsigned long long start, elapsed;
    unsigned long per_op;
    start = now_us();
    fn(iters);
    elapsed = now_us() - start;
    per_op = (unsigned long)((elapsed * 1000000ull) / iters);
    if (trial == 0 || per_op < best) {
      best = per_op;
    }
  }
  return best;
}

static void result_path(char *out, size_t len, const char *mode) {
  snprintf(out, len, RESULT_DIR "/fpbench.%s", mode);
}

static int run(unsigned int iters) {
  unsigned long ps[ARM_COUNT];
  char path[64];
  FILE *f;
  int i;

  printf("fpbench: mode=%s iters=%u trials=%d\n", FPBENCH_MODE, iters, TRIALS);

  for (i = 0; i < ARM_COUNT; i++) {
    ps[i] = run_arm(arms[i].fn, iters);
  }

  result_path(path, sizeof(path), FPBENCH_MODE);
  f = fopen(path, "w");
  if (!f) {
    fprintf(stderr, "fpbench: cannot record to %s\n", path);
  }

  for (i = 0; i < ARM_COUNT; i++) {
    /* net is the operation with the loop and the volatile traffic taken out.
     * It can come out at or below zero for an arm that is genuinely as cheap
     * as the baseline -- an inline double compare is one CDP -- and printing
     * that as a huge unsigned number would be worse than printing the zero it
     * means. */
    long net = (long)ps[i] - (long)ps[0];
    if (net < 0) {
      net = 0;
    }
    printf("mode=%s op=%s ps=%lu net_ps=%ld\n", FPBENCH_MODE, arms[i].name, ps[i], net);
    if (f) {
      fprintf(f, "%s %lu\n", arms[i].name, ps[i]);
    }
  }

  if (f) {
    fclose(f);
    printf("fpbench: recorded %s\n", path);
  }
  return 0;
}

struct mode_result {
  char name[16];
  unsigned long ps[ARM_COUNT];
  int present;
};

/* The order the table columns appear in, which is the order the story goes in:
 * software, then hardware one call away, then hardware with the call taken out
 * of the way, then hardware with the call gone. */
static const char *const mode_order[] = {"soft", "hwlib", "hwstatic", "inline"};
#define MODE_COUNT ((int)(sizeof(mode_order) / sizeof(mode_order[0])))

static int load_mode(const char *name, struct mode_result *out) {
  char path[64];
  char op[32];
  unsigned long value;
  FILE *f;

  result_path(path, sizeof(path), name);
  f = fopen(path, "r");
  if (!f) {
    return 0;
  }

  memset(out, 0, sizeof(*out));
  snprintf(out->name, sizeof(out->name), "%s", name);
  while (fscanf(f, "%31s %lu", op, &value) == 2) {
    int i;
    for (i = 0; i < ARM_COUNT; i++) {
      if (strcmp(op, arms[i].name) == 0) {
        out->ps[i] = value;
        break;
      }
    }
  }
  fclose(f);
  out->present = 1;
  return 1;
}

static int report(void) {
  struct mode_result modes[MODE_COUNT];
  int found = 0;
  int m, i;

  for (m = 0; m < MODE_COUNT; m++) {
    if (load_mode(mode_order[m], &modes[m])) {
      found++;
    } else {
      modes[m].present = 0;
    }
  }

  if (found == 0) {
    fprintf(stderr, "fpbench: no results in " RESULT_DIR "; run each fpbench-<mode> first\n");
    return 1;
  }

  printf("ns per operation, loop and volatile traffic subtracted\n\n");
  printf("%-9s", "op");
  for (m = 0; m < MODE_COUNT; m++) {
    if (modes[m].present) {
      printf("%10s", mode_order[m]);
    }
  }
  /* The one ratio worth putting on the same line as the numbers: what taking
   * the call out bought, for the operations where it could be taken out. */
  if (modes[0].present && modes[3].present) {
    printf("%12s", "soft/inline");
  }
  printf("\n");

  for (i = 1; i < ARM_COUNT; i++) {
    printf("%-9s", arms[i].name);
    for (m = 0; m < MODE_COUNT; m++) {
      long net;
      if (!modes[m].present) {
        continue;
      }
      net = (long)modes[m].ps[i] - (long)modes[m].ps[0];
      if (net < 0) {
        net = 0;
      }
      printf("%7ld.%02ld", net / 1000, (net % 1000) / 10);
    }
    if (modes[0].present && modes[3].present) {
      long soft = (long)modes[0].ps[i] - (long)modes[0].ps[0];
      long fast = (long)modes[3].ps[i] - (long)modes[3].ps[0];
      if (fast > 0 && soft > 0) {
        printf("%9ld.%02ldx", soft / fast, ((soft * 100) / fast) % 100);
      } else {
        printf("%11s", "-");
      }
    }
    printf("\n");
  }

  printf("\nbaseline (loop + two loads + one store, integer): ");
  for (m = 0; m < MODE_COUNT; m++) {
    if (modes[m].present) {
      printf("%s=%lu.%02lu ns ", mode_order[m], modes[m].ps[0] / 1000, (modes[m].ps[0] % 1000) / 10);
    }
  }
  printf("\n");
  return 0;
}

int main(int argc, char **argv) {
  unsigned int iters = DEFAULT_ITERS;

  if (argc > 1 && strcmp(argv[1], "--report") == 0) {
    return report();
  }

  if (argc > 1) {
    long parsed = strtol(argv[1], NULL, 10);
    if (parsed <= 0) {
      fprintf(stderr, "usage: %s [iterations] | %s --report\n", argv[0], argv[0]);
      return 1;
    }
    iters = (unsigned int)parsed;
  }

  return run(iters);
}
