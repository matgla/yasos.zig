"""
 A program linked with --hot-text runs part of its code from a copy in RAM
 (libs/tinycc/docs/hot_text.md): every way in and out of that block has to work
 from the copy as it does from the image.  The device's own tcc is linked this
 way, so the whole suite relies on it too; this is the short version, on the
 device's linker.
 """

from .conftest import session_key

SOURCE = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int counter;
static const char *const names[] = {"zero", "one", "two"};
int cold_add(int a, int b) { counter++; return a + b; }
int hot_leaf(int a) { return a * 3 + 1; }
int hot_calls_cold(int a) { return cold_add(a, hot_leaf(a)); }
int cold_calls_hot(int a) { return hot_calls_cold(a) + 1; }
int hot_tail(int a) { return cold_add(a, 7); }
int hot_switch(int a) {
  switch (a) { case 0: return 10; case 1: return 21; case 2: return 32; case 3: return 43; case 4: return 54; case 5: return 65; default: return -1; }
}
const char *hot_str(int a) { return names[a]; }
unsigned long long hot_big(unsigned long long x) { return x * 0x123456789ULL + 0xABCDEF012345ULL; }
double hot_fp(double d) { return d * 2.5 + 1.0; }
char *hot_import(const char *s) { char *p = malloc(strlen(s) + 1); strcpy(p, s); return p; }
typedef int (*fn_t)(int);
fn_t table[] = {hot_leaf, cold_calls_hot, hot_switch};
int hot_indirect(fn_t f, int a) { return f(a); }
int cold_indirect(fn_t f, int a) { return f(a); }
int main(void) {
  printf("%d %d %d %d\n", hot_leaf(4), hot_calls_cold(2), cold_calls_hot(3), hot_tail(5));
  for (int i = 0; i < 7; i++) printf("%d ", hot_switch(i));
  printf("\n%s %s %llu %.2f\n", hot_str(1), hot_str(2), hot_big(99), hot_fp(4.0));
  char *p = hot_import("copied"); printf("%s\n", p); free(p);
  printf("%d %d %d\n", hot_indirect(table[0], 5), cold_indirect(table[1], 6), table[2](3));
  printf("%d %d %d\n", table[0] == hot_leaf, (fn_t)hot_leaf == table[0], counter);
  return 0;
}
"""

HOT = "hot_leaf hot_calls_cold hot_tail hot_switch hot_str hot_big hot_fp hot_import hot_indirect".split()

EXPECTED = ["13 9 14 12", "10 21 32 43 54 65 -1", "one two 189384751590720 11.00", "copied", "16 26 43", "1 1 4"]


def run(session, command, timeout=60):
    session.write_command(command)
    return session.wait_for_prompt(timeout=timeout)


def write_lines(session, path, lines):
    run(session, f": > {path}")
    for line in lines:
        assert "'" not in line
        run(session, f"echo '{line}' >> {path}")


def output_of(session, program):
    text = run(session, f"{program}; echo RC=$?")
    assert "RC=0" in text, text
    return text


def test_hot_text_program_behaves_as_linked_plainly(request):
    session = request.node.stash[session_key]
    write_lines(session, "/tmp/hot.c", SOURCE.splitlines())
    write_lines(session, "/tmp/hot.txt", HOT)
    flags = "-O1 -ffunction-sections"
    assert "error" not in run(session, f"tcc {flags} /tmp/hot.c -o /tmp/plain")
    assert "error" not in run(session, f"tcc {flags} -Wl,--hot-text=/tmp/hot.txt /tmp/hot.c -o /tmp/hotp")
    for program in ("/tmp/plain", "/tmp/hotp", "/tmp/hotp"):  # twice: a second load of one image
        text = output_of(session, program)
        for line in EXPECTED:
            assert line in text, f"{program}: {line!r} not in {text!r}"
    run(session, "rm -f /tmp/hot.c /tmp/hot.txt /tmp/plain /tmp/hotp")
