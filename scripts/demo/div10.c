#include <stdio.h>

static unsigned a[1024];

unsigned udiv10(const unsigned *p, unsigned n) {
  unsigned s = 0;
  __asm__ volatile(
    "movs  r3, #10\n"
    "1:\n"
    "ldr.w r4, [%1], #4\n"
    "udiv  r5, r4, r3\n"
    "adds  %0, %0, r5\n"
    "subs  %2, %2, #1\n"
    "bne   1b\n"
    : "+r"(s), "+r"(p), "+r"(n) : : "r3", "r4", "r5", "cc");
  return s;
}

unsigned recip10(const unsigned *p, unsigned n) {
  unsigned s = 0;
  __asm__ volatile(
    "movw  r3, #0xCCCD\n"
    "movt  r3, #0xCCCC\n"
    "1:\n"
    "ldr.w r4, [%1], #4\n"
    "umull r5, r6, r4, r3\n"
    "lsrs  r6, r6, #3\n"
    "adds  %0, %0, r6\n"
    "subs  %2, %2, #1\n"
    "bne   1b\n"
    : "+r"(s), "+r"(p), "+r"(n) : : "r3", "r4", "r5", "r6", "cc");
  return s;
}

int main(int argc, char **argv) {
  unsigned i, r = 1, s = 0;
  int u = argc > 1 && *argv[1] == 'u';
  for (i = 0; i < 1024; i++) { r = r * 1103515245 + 12345; a[i] = r; }
  for (i = 0; i < 60000; i++) s += u ? udiv10(a, 1024) : recip10(a, 1024);
  printf("%s  %u\n", u ? "udiv" : "recip", s);
  return 0;
}
