/*
 * dltest.c -- dlopen/dlsym/dlclose/dlerror checks, POSIX corner cases.
 *
 * Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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
 *
 * Prints one "ok"/"not ok" line per check, then DL_TEST PASS or FAIL.
 * tests/smoke/dl_test.py runs it.  Checks marked (YasOS) are what this
 * system promises where POSIX leaves the choice to the implementation.
 *
 * Order matters: the checks that crashed an earlier kernel (a function from
 * dlsym run with the caller's r9, a forged handle given to dlclose) come
 * last, so a crash there still leaves every line before it.
 */

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#define LIB "/usr/lib/libdltest.so"
#define LIB_NAME "libdltest.so"

static int checks;
static int failures;

static void check(int ok, const char *what) {
  ++checks;
  if (!ok)
    ++failures;
  printf("%s %d - %s\n", ok ? "ok" : "not ok", checks, what);
  fflush(stdout);
}

/* dlerror() after a failure: a message, not empty; NEEDLE in it when given.
   It is read once, so the next dlerror() must say nothing. */
static void check_error(const char *what, const char *needle) {
  const char *msg = dlerror();
  char line[160];
  if (msg)
    printf("# dlerror: %s\n", msg);
  snprintf(line, sizeof line, "%s: dlerror() gives a message", what);
  check(msg != NULL && msg[0] != '\0', line);
  if (needle) {
    snprintf(line, sizeof line, "%s: the message names '%s' (YasOS)", what, needle);
    check(msg != NULL && strstr(msg, needle) != NULL, line);
  }
  snprintf(line, sizeof line, "%s: dlerror() is cleared once read", what);
  check(dlerror() == NULL, line);
}

typedef int (*int_fn)(void);
typedef size_t (*strlen_fn)(const char *);

int main(void) {
  /* ---- dlerror before anything ---- */
  check(dlerror() == NULL, "dlerror() is null before any dl call");

  /* ---- a library, by path ---- */
  void *h = dlopen(LIB, RTLD_NOW);
  check(h != NULL, "dlopen(" LIB ", RTLD_NOW)");
  if (!h) {
    printf("# dlerror: %s\n", dlerror() ? "set" : "null");
    printf("DL_TEST FAIL (no library)\n");
    return 1;
  }
  check(dlerror() == NULL, "dlerror() is null after a dlopen that worked");

  int_fn answer = (int_fn)dlsym(h, "dltest_answer");
  check(answer != NULL, "dlsym(h, \"dltest_answer\")");
  check(answer != NULL && answer() == 42, "the function from dlsym runs");
  check(dlerror() == NULL, "dlerror() is null after a dlsym that worked");

  int *counter = (int *)dlsym(h, "dltest_counter");
  check(counter != NULL && *counter == 5, "dlsym gives a data symbol's address");
  if (counter)
    *counter = 7;

  /* The portable test for a dlsym result: clear, look up, ask. */
  (void)dlerror();
  void *again = dlsym(h, "dltest_answer");
  check(again != NULL && dlerror() == NULL, "clear, dlsym, dlerror() == null: found");

  /* ---- a symbol that is not there ---- */
  check(dlsym(h, "dltest_missing") == NULL, "dlsym of a missing symbol is null");
  check_error("missing symbol", "dltest_missing");

  /* ---- one copy, counted ---- */
  void *h2 = dlopen(LIB, RTLD_LAZY);
  check(h2 == h, "dlopen of the same library again gives the same handle");
  int *counter2 = h2 ? (int *)dlsym(h2, "dltest_counter") : NULL;
  check(counter2 == counter && counter2 && *counter2 == 7, "both handles see one copy of the data");
  check(h2 && dlclose(h2) == 0, "dlclose of the second reference");
  answer = (int_fn)dlsym(h, "dltest_answer");
  check(answer != NULL && answer() == 42, "the library stays open while a reference is left");

  void *byname = dlopen(LIB_NAME, RTLD_NOW);
  check(byname == h, "dlopen by bare name finds it in /usr/lib (YasOS)");
  if (byname)
    check(dlclose(byname) == 0, "dlclose of the bare-name reference");

  check(dlclose(h) == 0, "dlclose of the last reference");
  check(dlerror() == NULL, "dlerror() is null after a dlclose that worked");

  /* ---- dlopen failures ---- */
  check(dlopen("/nonexistent/libnope.so", RTLD_NOW) == NULL, "dlopen of a missing file is null");
  check_error("missing file", "/nonexistent/libnope.so");

  check(dlopen("libnope.so", RTLD_NOW) == NULL, "dlopen of a missing bare name is null");
  check_error("missing bare name", "libnope.so");

  check(dlopen("/usr/hello_world.c", RTLD_NOW) == NULL, "dlopen of a file that is not an object is null");
  check_error("not an object", "/usr/hello_world.c");

  check(dlopen("/lib", RTLD_NOW) == NULL, "dlopen of a directory is null");
  check_error("directory", "/lib");

  check(dlopen(LIB, 0) == NULL, "dlopen with neither RTLD_LAZY nor RTLD_NOW is null");
  check_error("mode 0", NULL);

  check(dlopen(LIB, RTLD_GLOBAL) == NULL, "dlopen with RTLD_GLOBAL alone is null");
  check_error("mode RTLD_GLOBAL", NULL);

  /* The last error is the one reported. */
  (void)dlopen("/nonexistent/first.so", RTLD_NOW);
  (void)dlsym(dlopen(NULL, RTLD_NOW), "dltest_second_missing");
  check_error("two failures", "dltest_second_missing");

  /* ---- errno: never set to 0 ---- */
  errno = EDOM;
  h = dlopen(LIB, RTLD_NOW);
  if (h) {
    (void)dlsym(h, "dltest_answer");
    dlclose(h);
  }
  check(errno != 0, "a dl call that worked does not set errno to 0");

  /* ---- the program's global symbols ---- */
  void *self = dlopen(NULL, RTLD_NOW);
  check(self != NULL, "dlopen(NULL) gives the global handle");
  strlen_fn len = self ? (strlen_fn)dlsym(self, "strlen") : NULL;
  check(len != NULL && len("abc") == 3, "dlsym(global, \"strlen\") finds libc's");
  len = (strlen_fn)dlsym(RTLD_DEFAULT, "strlen");
  check(len != NULL && len("abcd") == 4, "dlsym(RTLD_DEFAULT, \"strlen\") (YasOS: RTLD_DEFAULT is null)");

  h = dlopen(LIB, RTLD_NOW | RTLD_LOCAL);
  check(h != NULL, "dlopen RTLD_LOCAL");
  check(self && dlsym(self, "dltest_answer") == NULL, "an RTLD_LOCAL library is not in the global handle");
  (void)dlerror();
  h2 = dlopen(LIB, RTLD_NOW | RTLD_GLOBAL);
  check(h2 == h, "dlopen RTLD_GLOBAL of an open library gives the same handle");
  answer = self ? (int_fn)dlsym(self, "dltest_answer") : NULL;
  check(answer != NULL && answer() == 42, "an RTLD_GLOBAL library is in the global handle");
  if (h2)
    dlclose(h2);
  if (h)
    dlclose(h);
  check(self && dlclose(self) == 0, "dlclose of the global handle");

  /* ---- a function that uses its library's globals (r9 / GOT) ---- */
  h = dlopen(LIB, RTLD_NOW);
  int_fn bump = h ? (int_fn)dlsym(h, "dltest_bump") : NULL;
  check(bump != NULL, "dlsym(h, \"dltest_bump\")");
  if (bump) {
    /* Exact values, tied to the data symbol's address: run with the
       program's GOT, the function reads and writes some other memory just as
       steadily, so "one more than last time" alone would pass. */
    counter = (int *)dlsym(h, "dltest_counter");
    int base = counter ? *counter : -1000;
    int first = bump();
    if (counter)
      *counter = 100;
    int second = bump();
    check(counter != NULL && first == base + 1 && second == 102,
          "a function from dlsym reads and writes its library's globals");
  }
  if (h)
    dlclose(h);

  /* ---- handles that are not open ---- */
  int local = 0;
  check(dlsym(&local, "dltest_answer") == NULL, "dlsym with a handle that is not open is null");
  check_error("dlsym bad handle", NULL);
  check(dlclose(NULL) != 0, "dlclose(NULL) fails");
  check_error("dlclose(NULL)", NULL);
  check(dlclose(&local) != 0, "dlclose of a handle that is not open fails");
  check_error("dlclose bad handle", NULL);

  if (failures)
    printf("DL_TEST FAIL %d of %d\n", failures, checks);
  else
    printf("DL_TEST PASS %d\n", checks);
  return failures ? 1 : 0;
}
