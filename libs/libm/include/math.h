/**
 * math.h
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

#pragma once

#include <limits.h>

#ifndef FP_ILOGB0
#define FP_ILOGB0 (-INT_MAX)
#endif

#ifndef FP_ILOGBNAN
#define FP_ILOGBNAN INT_MAX
#endif

// Trigonometric functions
double sin(double x);
double cos(double x);
double tan(double x);
double asin(double x);
double acos(double x);
double atan(double x);

// Hyperbolic functions
double sinh(double x);
double cosh(double x);
double tanh(double x);

// Exponential and logarithmic functions
double exp(double x);
double log(double x);
double log10(double x);
int ilogb(double x);

// Power functions
double pow(double base, double exponent);
double sqrt(double x);
double ldexp(double x, int exp);

// Rounding functions
double round(double x);
double ceil(double x);
double floor(double x);

// Absolute value
double fabs(double x);

// Float variants
float sinf(float x);
float cosf(float x);
float tanf(float x);
float asinf(float x);
float acosf(float x);
float atanf(float x);
float sinhf(float x);
float coshf(float x);
float tanhf(float x);
float expf(float x);
float logf(float x);
float log10f(float x);
int ilogbf(float x);
float powf(float base, float exponent);
float sqrtf(float x);
float roundf(float x);
float ceilf(float x);
float floorf(float x);
float fabsf(float x);
float ldexpf(float x, int exp);

// Long double variants
long double sinl(long double x);
long double cosl(long double x);
long double tanl(long double x);
long double asinl(long double x);
long double acosl(long double x);
long double atanl(long double x);
long double sinhl(long double x);
long double coshl(long double x);
long double tanhl(long double x);
long double expl(long double x);
long double logl(long double x);
long double log10l(long double x);
int ilogbl(long double x);
long double powl(long double base, long double exponent);
long double sqrtl(long double x);
long double roundl(long double x);
long double ceill(long double x);
long double floorl(long double x);
long double fabsl(long double x);
long double ldexpl(long double x, int exp);

// Mathematical constants (if not already defined)
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#ifndef M_E
#define M_E 2.71828182845904523536
#endif
