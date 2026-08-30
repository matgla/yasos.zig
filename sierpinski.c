/* Sierpinski triangle, drawn from Pascal's triangle mod 2.
 *
 * Binomial(i, k) is odd exactly when (i & k) == k -- Kummer's theorem, and the
 * reason the fractal falls out of one bitwise AND instead of a table.  So the
 * whole picture is two nested loops over an induction variable and no
 * arithmetic wider than an int: no libm, no floating point, nothing the target
 * has to emulate.
 *
 * Short enough to type on camera (scripts/demo_shot.py --program sierpinski).
 */

#include <stdio.h>

int main(void) {
  for (int i = 0; i < 16; i++) {
    for (int s = 16 - i; s > 0; s--)
      putchar(' ');
    for (int k = 0; k <= i; k++)
      printf((i & k) == k ? "* " : "  ");
    putchar('\n');
  }
  return 0;
}
