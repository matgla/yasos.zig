/* Force-included ahead of zig.c when compiling the Zig compiler for YasOS.
 *
 * zig.h picks its compiler flavour by macro: __GNUC__ wins over __TINYC__, and
 * tcc defines __GNUC__ 4 for the YasOS target. On the zig_gcc path zig.h then
 * asks __has_attribute(aligned) etc., which tcc answers "no" to, and alignment
 * silently becomes unavailable. Undefining __GNUC__ moves zig.h onto its
 * zig_tinyc path, which asserts the attributes tcc really does support.
 *
 * The system headers zig.h pulls in are included FIRST, while __GNUC__ is still
 * defined, so they keep their GNU spellings (__builtin_va_list and friends). */
#include <stdarg.h>
#include <stddef.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <float.h>
#include <string.h>
#include <math.h>

#undef __GNUC__
#undef __GNUC_MINOR__
#undef __GNUC_PATCHLEVEL__
