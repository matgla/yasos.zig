/* Forced into yasc files for the C/C++ extension's IntelliSense only (the
 * extension's configuration provider passes it as forcedInclude; tcc never
 * sees it).  IntelliSense parses regular C, so the yasc words it cannot know
 * are erased here; tcc's own diagnostics (source "tcc") are the real check.
 *
 * Left as they are, because a macro cannot erase them without breaking
 * regular uses of the same word, or cannot touch them at all: `@min`/`@max`,
 * slices (`[]T`, `p[a:b]`), `owned(dealloc)` (`owned` is erased, the
 * parenthesis stays), `out`, `in`, `catch`, `error`, `!T`, `union(k)`, `ro`/`wo`/
 * `w1c`, methods in struct bodies, `module`/`import`/`export`.  The errors
 * IntelliSense gives for them are hidden by squiggles.js where tcc accepts
 * the line (`#pragma diag_suppress` cannot: they are not discretionary).  The headers
 * keep their yasc declarations under `#ifdef __YASC__`, which IntelliSense
 * does not get, so it reads their plain C declarations. */
#ifndef YASC_INTELLISENSE_H
#define YASC_INTELLISENSE_H

/* pointer qualifiers, after the `*` */
#define owned
#define view
#define maybe
#define writeonly
#define borrows(...)
#define takes(...)
#define when(...)

/* before a parameter's type */
#define drop
#define inout

/* expressions */
#define move(x) (x)
#define borrow(x) (x)
#define unsafe
#define try
/* `unreachable;`, `default: unreachable;`: still an expression that does not
   return, so `x ? a : unreachable` parses */
#define unreachable __builtin_unreachable()

/* statements: `defer free(p);` reads as `free(p);` */
#define defer
#define errdefer

#endif
