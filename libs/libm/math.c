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

double ldexp(double x, int exp) {
  if (x == 0.0)
    return 0.0;
  if (exp < -1022)
    return 0.0;
  if (exp > 1023)
    return x * (1 << exp);
  return x * (1 << exp);
}

double fabs(double x) {
  return (x < 0) ? -x : x;
}
double sin(double x) {
  // Simple sine approximation using Taylor series
  double term = x; // First term is x
  double sum = term;
  int n = 1;

  while (fabs(term) > 1e-10) { // Continue until the term is small enough
    term *= -x * x / ((2 * n) * (2 * n + 1)); // Calculate next term
    sum += term;                              // Add to sum
    n++;
  }
  return sum;
}

float sinf(float x) {
  // Simple sine approximation using Taylor series
  float term = x; // First term is x
  float sum = term;
  int n = 1;

  while (fabs(term) > 1e-6f) { // Continue until the term is small enough
    term *= -x * x / ((2 * n) * (2 * n + 1)); // Calculate next term
    sum += term;                              // Add to sum
    n++;
  }
  return sum;
}

long double sinl(long double x) {
  // Simple sine approximation using Taylor series
  long double term = x; // First term is x
  long double sum = term;
  int n = 1;

  while (fabsl(term) > 1e-10L) { // Continue until the term is small enough
    term *= -x * x / ((2 * n) * (2 * n + 1)); // Calculate next term
    sum += term;                              // Add to sum
    n++;
  }
  return sum;
}

long double fabsl(long double x) {
  return (x < 0) ? -x : x;
}