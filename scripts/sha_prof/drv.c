#include <stdio.h>
/* the ir_tests mibench_sha workload, minus printf: 50 x sha over 256 bytes */
#include "sha.h"
static unsigned char buf[256];
volatile int sink;
int main(void)
{
  SHA_INFO s; int i, j, sum = 0;
  for (i = 0; i < 256; i++) buf[i] = (unsigned char)((i * 7 + 13) & 0xFF);
  for (i = 0; i < 50; i++) {
    buf[0] = (unsigned char)('A' + (i % 26));
    sha_init(&s); sha_update(&s, buf, 256); sha_final(&s);
    sum = 0; for (j = 0; j < 5; j++) sum += (int)(s.digest[j] & 0xFF);
  }
  sink = sum;
  __asm__ volatile("movs r0, #0x18\n\tldr r1, =0x20026\n\tbkpt 0xab");
  return 0;
}
void *memcpy(void *d, const void *s, unsigned n){unsigned char *a=d;const unsigned char *b=s;while(n--)*a++=*b++;return d;}
void *memset(void *d, int c, unsigned n){unsigned char *a=d;while(n--)*a++=(unsigned char)c;return d;}
