/**
 * math.c
 *
 * Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
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

#include <math.h>
#include <stddef.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifndef M_E
#define M_E 2.71828182845904523536
#endif

// Forward declarations for internal helpers
static double _exp_positive(double x);
static double _sqrt_newton(double x);

// ============================================================================
// Basic operations (no dependencies)
// ============================================================================

double fabs(double x) {
  return (x < 0) ? -x : x;
}

double ldexp(double x, int exp) {
  // Load exponent: multiply x by 2^exp
  // Handle special cases
  if (x == 0.0 || exp == 0)
    return x;
  
  // Use exponent manipulation for correct IEEE 754 behavior
  // ldexp(x, n) = x * 2^n
  
  // Split exp into manageable chunks to avoid overflow
  while (exp > 0) {
    int step = (exp > 1023) ? 1023 : exp;
    x *= (double)(1L << step);
    exp -= step;
  }
  while (exp < 0) {
    int step = (exp < -1023) ? -1023 : exp;
    x /= (double)(1L << (-step));
    exp -= step;
  }
  return x;
}

// ============================================================================
// sqrt - needed by other functions
// ============================================================================

static double _sqrt_newton(double x) {
  if (x < 0.0) return -1e308;  // Error for negative input
  if (x == 0.0) return 0.0;
  
  // Newton-Raphson method
  double guess = x;
  double prev;
  
  // Initial guess
  if (x > 1.0) {
    guess = x / 2.0;
  } else {
    guess = 1.0;
  }
  
  // Iterate until convergence
  for (int i = 0; i < 100; i++) {
    prev = guess;
    guess = (guess + x / guess) / 2.0;
    if (fabs(guess - prev) < 1e-15) break;
  }
  
  return guess;
}

double sqrt(double x) {
  return _sqrt_newton(x);
}

// ============================================================================
// Trigonometric functions
// ============================================================================

double sin(double x) {
  // Reduce x to [-PI, PI] range for better accuracy
  while (x > M_PI) x -= 2 * M_PI;
  while (x < -M_PI) x += 2 * M_PI;
  
  // Taylor series: sin(x) = x - x^3/3! + x^5/5! - x^7/7! + ...
  double term = x;
  double sum = term;
  int n = 1;

  while (fabs(term) > 1e-15) {
    term *= -x * x / ((2 * n) * (2 * n + 1));
    sum += term;
    n++;
  }
  return sum;
}

double cos(double x) {
  // Reduce x to [-PI, PI] range for better accuracy
  while (x > M_PI) x -= 2 * M_PI;
  while (x < -M_PI) x += 2 * M_PI;
  
  // Taylor series: cos(x) = 1 - x^2/2! + x^4/4! - x^6/6! + ...
  double term = 1.0;
  double sum = term;
  int n = 1;

  while (fabs(term) > 1e-15) {
    term *= -x * x / ((2 * n - 1) * (2 * n));
    sum += term;
    n++;
  }
  return sum;
}

double tan(double x) {
  // tan(x) = sin(x) / cos(x)
  double c = cos(x);
  // Handle cases where cos(x) is close to zero
  if (fabs(c) < 1e-15) {
    // Return a large value to approximate infinity
    return (c < 0) ? -1e308 : 1e308;
  }
  return sin(x) / c;
}

// ============================================================================
// exp - needed by other functions
// ============================================================================

static double _exp_positive(double x) {
  // Split x into integer and fractional parts: e^x = e^n * e^f
  int n = (int)x;
  double f = x - n;
  
  // e^n using repeated multiplication
  double en = 1.0;
  double e = M_E;
  int exp_n = n;
  while (exp_n > 0) {
    if (exp_n & 1) en *= e;
    e *= e;
    exp_n >>= 1;
  }
  
  // e^f using Taylor series for fractional part
  double term = 1.0;
  double sum = term;
  int i = 1;

  while (fabs(term) > 1e-15) {
    term *= f / i;
    sum += term;
    i++;
    if (i > 100) break;
  }
  
  return en * sum;
}

double exp(double x) {
  // Handle special cases
  if (x == 0.0) return 1.0;
  if (x > 709.0) return 1e308;  // Overflow
  if (x < -709.0) return 0.0;   // Underflow
  
  // For negative x, use e^(-x) = 1/e^x
  if (x < 0) {
    return 1.0 / _exp_positive(-x);
  }
  
  return _exp_positive(x);
}

// ============================================================================
// Inverse trigonometric functions
// ============================================================================

double asin(double x) {
  // Domain check: asin is only defined for [-1, 1]
  if (x < -1.0) x = -1.0;
  if (x > 1.0) x = 1.0;
  
  // For x close to 1 or -1, use the identity for better accuracy
  if (fabs(x) > 0.5) {
    double sign = (x < 0) ? -1.0 : 1.0;
    double abs_x = fabs(x);
    // Use complementary angle formula for better accuracy near 1
    // asin(x) = PI/2 - 2*asin(sqrt((1-x)/2))
    double y = _sqrt_newton((1.0 - abs_x) / 2.0);
    // Recursively compute asin for smaller value
    double result = M_PI / 2.0 - 2.0 * asin(y);
    return sign * result;
  }
  
  // Taylor series: asin(x) = x + (1/2)(x^3/3) + (1*3)/(2*4)(x^5/5) + ...
  double term = x;
  double sum = term;
  int n = 1;
  double coeff = 1.0;

  while (fabs(term) > 1e-15) {
    coeff *= (2.0 * n - 1) / (2.0 * n);
    // Compute x^(2n+1) iteratively
    term = coeff;
    double power = x;
    for (int i = 0; i < 2 * n; i++) power *= x;
    term = coeff * power / (2 * n + 1);
    sum += term;
    n++;
    if (n > 100) break; // Safety limit
  }
  return sum;
}

double acos(double x) {
  // Domain check
  if (x < -1.0) x = -1.0;
  if (x > 1.0) x = 1.0;
  
  // acos(x) = PI/2 - asin(x)
  return M_PI / 2.0 - asin(x);
}

double atan(double x) {
  // atan(x) = asin(x / sqrt(1 + x^2))
  // But for better accuracy, use Taylor series for small |x|
  
  if (fabs(x) > 1.0) {
    // For large |x|, use atan(x) = PI/2 - atan(1/x) for x > 0
    // or atan(x) = -PI/2 - atan(1/x) for x < 0
    double sign = (x < 0) ? -1.0 : 1.0;
    return sign * M_PI / 2.0 - atan(1.0 / x);
  }
  
  // Taylor series: atan(x) = x - x^3/3 + x^5/5 - x^7/7 + ...
  double term = x;
  double sum = term;
  double x2 = x * x;
  int n = 1;

  while (fabs(term) > 1e-15) {
    term *= -x2;
    sum += term / (2 * n + 1);
    n++;
    if (n > 100) break; // Safety limit
  }
  return sum;
}

// ============================================================================
// Hyperbolic functions
// ============================================================================

double sinh(double x) {
  // sinh(x) = (e^x - e^(-x)) / 2
  // For small x, use Taylor series to avoid catastrophic cancellation
  if (fabs(x) < 0.5) {
    double term = x;
    double sum = term;
    double x2 = x * x;
    int n = 1;

    while (fabs(term) > 1e-15) {
      term *= x2 / ((2 * n) * (2 * n + 1));
      sum += term;
      n++;
    }
    return sum;
  }
  
  double ex = exp(x);
  double e_neg_x = exp(-x);
  return (ex - e_neg_x) / 2.0;
}

double cosh(double x) {
  // cosh(x) = (e^x + e^(-x)) / 2
  double ex = exp(x);
  double e_neg_x = 1.0 / ex;  // e^(-x) = 1/e^x
  return (ex + e_neg_x) / 2.0;
}

double tanh(double x) {
  // tanh(x) = sinh(x) / cosh(x) = (e^x - e^(-x)) / (e^x + e^(-x))
  // For large |x|, return +/- 1
  if (x > 20.0) return 1.0;
  if (x < -20.0) return -1.0;
  
  double ex = exp(2.0 * x);
  return (ex - 1.0) / (ex + 1.0);
}

// ============================================================================
// Logarithmic functions
// ============================================================================

double log(double x) {
  // Domain check: log is only defined for x > 0
  if (x <= 0.0) return -1e308;  // Return large negative (error)
  
  // Use the identity: log(x) = log(m * 2^e) = log(m) + e * log(2)
  // where m is in [1, 2) and e is the exponent
  
  int exp = 0;
  double m = x;
  
  // Normalize to [1, 2)
  while (m >= 2.0) { m /= 2.0; exp++; }
  while (m < 1.0) { m *= 2.0; exp--; }
  
  // log(m) using Taylor series around 1
  // log(1 + y) = y - y^2/2 + y^3/3 - y^4/4 + ...
  double y = m - 1.0;
  double term = y;
  double sum = term;
  int n = 2;

  while (fabs(term) > 1e-15) {
    term *= -y;
    sum += term / n;
    n++;
    if (n > 100) break;
  }
  
  // log(2) = 0.6931471805599453
  return sum + exp * 0.6931471805599453;
}

double log10(double x) {
  // log10(x) = log(x) / log(10)
  return log(x) / 2.302585092994046;
}

// ============================================================================
// Power functions
// ============================================================================

double pow(double base, double exponent) {
  // Handle special cases
  if (exponent == 0.0) return 1.0;
  if (base == 0.0) return 0.0;
  if (base == 1.0) return 1.0;
  if (exponent == 1.0) return base;
  
  // Integer exponent optimization
  int int_exp = (int)exponent;
  if (exponent == int_exp) {
    double result = 1.0;
    double b = base;
    int e = int_exp;
    if (e < 0) {
      e = -e;
      b = 1.0 / b;
    }
    while (e > 0) {
      if (e & 1) result *= b;
      b *= b;
      e >>= 1;
    }
    return result;
  }
  
  // For general case: x^y = e^(y * log(x))
  return exp(exponent * log(base));
}

// ============================================================================
// Rounding functions
// ============================================================================

double round(double x) {
  if (x >= 0.0) {
    return (double)(long)(x + 0.5);
  } else {
    return (double)(long)(x - 0.5);
  }
}

double ceil(double x) {
  long int_part = (long)x;
  if (x > 0 && x != (double)int_part) {
    int_part++;
  }
  return (double)int_part;
}

double floor(double x) {
  long int_part = (long)x;
  if (x < 0 && x != (double)int_part) {
    int_part--;
  }
  return (double)int_part;
}

// ============================================================================
// Float variants (cast to double and back)
// ============================================================================

float sinf(float x) {
  return (float)sin((double)x);
}

float cosf(float x) {
  return (float)cos((double)x);
}

float tanf(float x) {
  return (float)tan((double)x);
}

float asinf(float x) {
  return (float)asin((double)x);
}

float acosf(float x) {
  return (float)acos((double)x);
}

float atanf(float x) {
  return (float)atan((double)x);
}

float sinhf(float x) {
  return (float)sinh((double)x);
}

float coshf(float x) {
  return (float)cosh((double)x);
}

float tanhf(float x) {
  return (float)tanh((double)x);
}

float expf(float x) {
  return (float)exp((double)x);
}

float logf(float x) {
  return (float)log((double)x);
}

float log10f(float x) {
  return (float)log10((double)x);
}

float powf(float base, float exponent) {
  return (float)pow((double)base, (double)exponent);
}

float sqrtf(float x) {
  return (float)sqrt((double)x);
}

float roundf(float x) {
  return (float)round((double)x);
}

float ceilf(float x) {
  return (float)ceil((double)x);
}

float floorf(float x) {
  return (float)floor((double)x);
}

float fabsf(float x) {
  return (x < 0) ? -x : x;
}

float ldexpf(float x, int exp) {
  return (float)ldexp((double)x, exp);
}

// ============================================================================
// Long double variants (cast to double and back)
// ============================================================================

long double sinl(long double x) {
  return (long double)sin((double)x);
}

long double cosl(long double x) {
  return (long double)cos((double)x);
}

long double tanl(long double x) {
  return (long double)tan((double)x);
}

long double asinl(long double x) {
  return (long double)asin((double)x);
}

long double acosl(long double x) {
  return (long double)acos((double)x);
}

long double atanl(long double x) {
  return (long double)atan((double)x);
}

long double sinhl(long double x) {
  return (long double)sinh((double)x);
}

long double coshl(long double x) {
  return (long double)cosh((double)x);
}

long double tanhl(long double x) {
  return (long double)tanh((double)x);
}

long double expl(long double x) {
  return (long double)exp((double)x);
}

long double logl(long double x) {
  return (long double)log((double)x);
}

long double log10l(long double x) {
  return (long double)log10((double)x);
}

long double powl(long double base, long double exponent) {
  return (long double)pow((double)base, (double)exponent);
}

long double sqrtl(long double x) {
  return (long double)sqrt((double)x);
}

long double roundl(long double x) {
  return (long double)round((double)x);
}

long double ceill(long double x) {
  return (long double)ceil((double)x);
}

long double floorl(long double x) {
  return (long double)floor((double)x);
}

long double fabsl(long double x) {
  return (x < 0) ? -x : x;
}

long double ldexpl(long double x, int exp) {
  return (long double)ldexp((double)x, exp);
}
