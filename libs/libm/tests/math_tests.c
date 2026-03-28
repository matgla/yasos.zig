// Copyright (c) 2025 Mateusz Stadnik <matgla@live.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#include "utest.h"

#include <math.h>

// Helper to verify exact values (for integer results)
#define ASSERT_DOUBLE_EQ(actual, expected) ASSERT_EQ((actual), (expected))

UTEST(math_tests, sin_basic) {
  EXPECT_NEAR(sin(0.0), 0.0, 1e-10);
  EXPECT_NEAR(sin(M_PI / 2.0), 1.0, 1e-10);
  EXPECT_NEAR(sin(M_PI), 0.0, 1e-10);
  EXPECT_NEAR(sin(-M_PI / 2.0), -1.0, 1e-10);
  EXPECT_NEAR(sin(0.12), 0.119712, 1e-5);
}

UTEST(math_tests, cos_basic) {
  EXPECT_NEAR(cos(0.0), 1.0, 1e-10);
  EXPECT_NEAR(cos(M_PI / 2.0), 0.0, 1e-10);
  EXPECT_NEAR(cos(M_PI), -1.0, 1e-10);
  EXPECT_NEAR(cos(0.12), 0.992809, 1e-5);
}

UTEST(math_tests, tan_basic) {
  EXPECT_NEAR(tan(0.0), 0.0, 1e-10);
  EXPECT_NEAR(tan(0.12), 0.120579, 1e-5);
  // tan(PI/4) = 1
  EXPECT_NEAR(tan(M_PI / 4.0), 1.0, 1e-5);
}

UTEST(math_tests, asin_basic) {
  EXPECT_NEAR(asin(0.0), 0.0, 1e-10);
  EXPECT_NEAR(asin(1.0), M_PI / 2.0, 1e-10);
  EXPECT_NEAR(asin(-1.0), -M_PI / 2.0, 1e-10);
  EXPECT_NEAR(asin(0.12), 0.120290, 1e-5);
}

UTEST(math_tests, acos_basic) {
  EXPECT_NEAR(acos(0.0), M_PI / 2.0, 1e-10);
  EXPECT_NEAR(acos(1.0), 0.0, 1e-10);
  EXPECT_NEAR(acos(-1.0), M_PI, 1e-10);
  EXPECT_NEAR(acos(0.12), 1.450506, 1e-5);
}

UTEST(math_tests, atan_basic) {
  EXPECT_NEAR(atan(0.0), 0.0, 1e-10);
  EXPECT_NEAR(atan(1.0), M_PI / 4.0, 1e-10);
  EXPECT_NEAR(atan(-1.0), -M_PI / 4.0, 1e-10);
  EXPECT_NEAR(atan(0.12), 0.119429, 1e-5);
}

UTEST(math_tests, sinh_basic) {
  EXPECT_NEAR(sinh(0.0), 0.0, 1e-10);
  EXPECT_NEAR(sinh(0.12), 0.120288, 1e-5);
}

UTEST(math_tests, cosh_basic) {
  EXPECT_NEAR(cosh(0.0), 1.0, 1e-10);
  EXPECT_NEAR(cosh(0.12), 1.007209, 1e-5);
}

UTEST(math_tests, tanh_basic) {
  EXPECT_NEAR(tanh(0.0), 0.0, 1e-10);
  EXPECT_NEAR(tanh(0.12), 0.119427, 1e-5);
  EXPECT_NEAR(tanh(20.0), 1.0, 1e-10);
  EXPECT_NEAR(tanh(-20.0), -1.0, 1e-10);
}

UTEST(math_tests, exp_basic) {
  EXPECT_NEAR(exp(0.0), 1.0, 1e-10);
  EXPECT_NEAR(exp(0.12), 1.127497, 1e-5);
  EXPECT_NEAR(exp(1.0), M_E, 1e-10);
}

UTEST(math_tests, fabs_basic) {
  EXPECT_EQ(fabs(-0.12), 0.12);
  EXPECT_EQ(fabs(0.12), 0.12);
  EXPECT_EQ(fabs(0.0), 0.0);
  EXPECT_EQ(fabs(-5.5), 5.5);
}

UTEST(math_tests, log_basic) {
  EXPECT_NEAR(log(1.0), 0.0, 1e-10);
  EXPECT_NEAR(log(M_E), 1.0, 1e-10);
  EXPECT_NEAR(log(0.12), -2.120264, 1e-5);
}

UTEST(math_tests, log10_basic) {
  EXPECT_NEAR(log10(1.0), 0.0, 1e-10);
  EXPECT_NEAR(log10(10.0), 1.0, 1e-10);
  EXPECT_NEAR(log10(100.0), 2.0, 1e-10);
  EXPECT_NEAR(log10(0.12), -0.920819, 1e-5);
}

UTEST(math_tests, pow_basic) {
  EXPECT_NEAR(pow(2.0, 3.0), 8.0, 1e-10);
  EXPECT_NEAR(pow(0.12, 0.12), 0.775357, 1e-5);
  EXPECT_NEAR(pow(2.0, 0.0), 1.0, 1e-10);
  EXPECT_NEAR(pow(0.0, 2.0), 0.0, 1e-10);
  EXPECT_NEAR(pow(1.0, 100.0), 1.0, 1e-10);
}

UTEST(math_tests, sqrt_basic) {
  EXPECT_NEAR(sqrt(0.0), 0.0, 1e-10);
  EXPECT_NEAR(sqrt(1.0), 1.0, 1e-10);
  EXPECT_NEAR(sqrt(4.0), 2.0, 1e-10);
  EXPECT_NEAR(sqrt(9.0), 3.0, 1e-10);
  EXPECT_NEAR(sqrt(0.12), 0.346410, 1e-5);
}

UTEST(math_tests, round_basic) {
  EXPECT_EQ(round(12.34), 12.0);
  EXPECT_EQ(round(12.5), 13.0);
  EXPECT_EQ(round(12.6), 13.0);
  EXPECT_EQ(round(-12.34), -12.0);
  EXPECT_EQ(round(-12.5), -13.0);
  EXPECT_EQ(round(-12.6), -13.0);
}

UTEST(math_tests, ceil_basic) {
  EXPECT_EQ(ceil(12.34), 13.0);
  EXPECT_EQ(ceil(12.0), 12.0);
  EXPECT_EQ(ceil(-12.34), -12.0);
  EXPECT_EQ(ceil(-12.0), -12.0);
}

UTEST(math_tests, floor_basic) {
  EXPECT_EQ(floor(12.34), 12.0);
  EXPECT_EQ(floor(12.0), 12.0);
  EXPECT_EQ(floor(-12.34), -13.0);
  EXPECT_EQ(floor(-12.0), -12.0);
}

UTEST(math_tests, ldexp_basic) {
  EXPECT_EQ(ldexp(1.0, 0), 1.0);
  EXPECT_EQ(ldexp(1.0, 1), 2.0);
  EXPECT_EQ(ldexp(1.0, 2), 4.0);
  EXPECT_EQ(ldexp(1.0, -1), 0.5);
  EXPECT_EQ(ldexp(0.0, 10), 0.0);
}

// Test float variants
UTEST(math_tests, float_variants) {
  EXPECT_NEAR(sinf(0.12f), 0.119712f, 1e-5f);
  EXPECT_NEAR(cosf(0.12f), 0.992809f, 1e-5f);
  EXPECT_NEAR(tanf(0.12f), 0.120579f, 1e-5f);
  EXPECT_NEAR(sqrtf(0.12f), 0.346410f, 1e-5f);
  EXPECT_NEAR(expf(0.12f), 1.127497f, 1e-5f);
  EXPECT_EQ(fabsf(-0.12f), 0.12f);
}

// Test long double variants
UTEST(math_tests, long_double_variants) {
  EXPECT_NEAR(sinl(0.12L), 0.119712L, 1e-5L);
  EXPECT_NEAR(cosl(0.12L), 0.992809L, 1e-5L);
  EXPECT_NEAR(tanl(0.12L), 0.120579L, 1e-5L);
  EXPECT_NEAR(sqrtl(0.12L), 0.346410L, 1e-5L);
  EXPECT_NEAR(expl(0.12L), 1.127497L, 1e-5L);
  EXPECT_EQ(fabsl(-0.12L), 0.12L);
}

// Test the exact values expected by 24_math_library.c test
UTEST(math_tests, tcc_math_library_test_values) {
  // These are the exact values expected by the TCC test
  EXPECT_NEAR(sin(0.12), 0.119712, 1e-5);
  EXPECT_NEAR(cos(0.12), 0.992809, 1e-5);
  EXPECT_NEAR(tan(0.12), 0.120579, 1e-5);
  EXPECT_NEAR(asin(0.12), 0.120290, 1e-5);
  EXPECT_NEAR(acos(0.12), 1.450506, 1e-5);
  EXPECT_NEAR(atan(0.12), 0.119429, 1e-5);
  EXPECT_NEAR(sinh(0.12), 0.120288, 1e-5);
  EXPECT_NEAR(cosh(0.12), 1.007209, 1e-5);
  EXPECT_NEAR(tanh(0.12), 0.119427, 1e-5);
  EXPECT_NEAR(exp(0.12), 1.127497, 1e-5);
  EXPECT_EQ(fabs(-0.12), 0.12);
  EXPECT_NEAR(log(0.12), -2.120264, 1e-5);
  EXPECT_NEAR(log10(0.12), -0.920819, 1e-5);
  EXPECT_NEAR(pow(0.12, 0.12), 0.775357, 1e-5);
  EXPECT_NEAR(sqrt(0.12), 0.346410, 1e-5);
  EXPECT_EQ(round(12.34), 12.0);
  EXPECT_EQ(ceil(12.34), 13.0);
  EXPECT_EQ(floor(12.34), 12.0);
}
