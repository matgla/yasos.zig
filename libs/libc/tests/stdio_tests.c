#include "minunit.h"

static int foo = 0;
static int bar = 0;
static double dbar = 0.1;
static const char *foostring = "Thisstring";

void test_setup(void) {
  foo = 7;
  bar = 4;
}

void test_teardown(void) {
  /* Nothing */
}

MU_TEST(test_scanf) {
  int integer = 0;
  scanf("%d", &integer);
  mu_assert_int_eq(integer, 123);
}

MU_TEST_SUITE(test_suite) {
  MU_SUITE_CONFIGURE(&test_setup, &test_teardown);

  MU_RUN_TEST(test_scanf);
}

int main(int argc, char *argv[]) {
  MU_RUN_SUITE(test_suite);
  MU_REPORT();
  return MU_EXIT_CODE;
}
