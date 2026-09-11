/* the rig's bench_memcpy workload: 1000 iters of 256+128 copy + 256 checksum */
extern int bench_memcpy(int);
volatile int sink;
int main(void){ sink = bench_memcpy(1000);
  __asm__ volatile("movs r0,#0x18\n\tldr r1,=0x20026\n\tbkpt 0xab"); return 0; }
/* bench_string.c's init fn references these; main never calls it, so stub. */
void register_benchmark(const char*a,int(*b)(int),int c,const char*d){(void)a;(void)b;(void)c;(void)d;}
void register_benchmark_ex(const char*a,int(*b)(int),int c,const char*d,int e){(void)a;(void)b;(void)c;(void)d;(void)e;}
unsigned __tcc_strlen(const char*s){unsigned n=0;while(s[n])n++;return n;}
