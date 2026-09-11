/* bench_double.c's dadd kernel, verbatim, plus a marker call so the profile
 * can be cut at the point the kernel starts. */
volatile int sink;

__attribute__((noinline)) int bench_double_add(int iterations)
{
  double acc = 1.0;
  int n;

  for (n = 0; n < iterations; n++)
  {
    double t = (double)(n & 0x3F) * 0.015625 + 0.5;
    acc = acc + t;
    acc = acc - (t * 0.5);
    acc = acc - (t * 0.5);
    acc = acc + 0.0009765625;
  }

  return (int)(acc * 1024.0);
}

int main(void)
{
  sink = bench_double_add(ITERS);
  return 0;
}
