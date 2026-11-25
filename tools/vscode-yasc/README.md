# yasc for VSCode

Highlights tinycc's **yasc** dialect of C in ordinary `.c`/`.h` files
(the tutorial: `libs/tinycc/examples/yasc/README.md`):

- ownership: `owned`, `view`, `maybe` (after a `*`, and in a parameter
  array's brackets: `char * view argv[owned]`), `in`, `inout`, `out`, `drop`
  (before a parameter's type; a view parameter's target is read-only unless
  it says `inout` or `out`). `readonly` is no yasc word any more (it was
  `const T * view`): a name, as in C
- `defer`, `errdefer`, `unreachable` (`unreachable;`, `default: unreachable;`,
  `f() catch unreachable`)
- errors: `error Set { A, B = ENOENT };`, `error.NAME`, `error Set e`, `!T`
  return types, `try f()`, `f() catch X`, `catch |e| { ... }`,
  `error_name()`, `error_from()`
- `move(p)`, `borrow(p)`
- slices: `[]T`, `[:0]T`, `[][]T` before a type (`[:0]char s = path[0:len:0];`,
  `static []const char names`, parameters), and the `:` of `x[a:b]`, `x[a:]`,
  `x[:b]`, `x[a:b:0]`
- lifetimes: `owned(fclose)`, `borrows(x)` / `borrows(static)`, `takes(p)`
  (after a `*` or another qualifier), int handles (`int owned(close) maybe
  fd`, `int view fd`), owned objects (`regex_t owned(regfree) re`),
  `struct tokenizer borrows(text) { ... }`, an out parameter's target
  (`out char * borrows(s) * view maybe end`)
- `unsafe { ... }`, `unsafe(expr)`
- tagged unions: `union(k) { long i when(V_INT); ... } u;`
- register fields: `uint32_t irq:1 w1c;`, `volatile uint32_t id ro;`, `... wo;`
- modules: `module a.b;`, `import a.b;`, `export DECL`
- C23 / GNU words VSCode's C grammar does not know: `constexpr`, `nullptr`,
  `typeof`, `typeof_unqual`, `__typeof__`, `alignof`, `__auto_type`

It is a grammar injection into VSCode's built-in C grammar (`source.c`), so
the language stays `c` and the C/C++ extension's IntelliSense keeps working.

- yasc is tcc's default dialect (`-ccompat` is regular C), so the words are
  highlighted in every C file, with or without `#pragma yasc`.
- tcc takes these words as keywords only where its parser expects them and as
  names everywhere else (`out->len`, `s.view`, `drop(x)`, `int error;`,
  `goto out;`). Without a parser the grammar goes by the neighbours: `owned`
  must follow a `*`, `out` / `inout` / `in` must be followed by a type name
  (`FILE *in` stays a name), `catch` must follow
  the end of an expression, `error.` must be followed by a capitalised name,
  `module` must start a line, `unreachable` must stand alone (first on its
  line, after `;` `{` `}` `:` `)`, `else` or `catch`, and before `;` `,` `)`
  or `}`: `int unreachable;` and `unreachable()` stay names),
  `!` must be followed by a type, `when(` must
  follow a member's name, `ro`/`wo`/`w1c` must follow a member's declarator
  (`int ro;`, `struct s ro;`, `return ro;` stay names), `owned(...)` /
  `borrows(...)` after a type must be followed by the declaration, and none of
  them follows `.` or `->`. Over 888 regular C files of this tree (tinycc's
  sources, libc, apps) that marks 3 words, all from the older rules. yasvi uses the same rules
  (`apps/yasvi/filetypes/c.c`).
- Scopes: `storage.modifier.yasc.c` (qualifiers, coloured like `const`),
  `keyword.control.{defer,try,catch,unreachable,import}.yasc.c`,
  `storage.type.error.yasc.c`, `entity.name.type.error.yasc.c` (a set's
  name), `constant.other.error.yasc.c` (an error's name),
  `variable.parameter.capture.yasc.c` (`|e|`),
  `storage.modifier.errunion.yasc.c` (`!`), `support.function.yasc.c`,
  `entity.name.namespace.yasc.c` (a module's name),
  `storage.modifier.export.yasc.c`, `keyword.control.unsafe.yasc.c`,
  `storage.modifier.when.yasc.c`, `storage.modifier.register.yasc.c`,
  `storage.modifier.slice.yasc.c` (`[]`, `[:0]`), `keyword.operator.slice.yasc.c`
  (a slice's `:`).
- A slice prefix is a `[]` / `[:0]` before a type name that does not follow a
  name, `)`, `]` or a quote (that is `int a[] __attribute__((x))`), except a
  storage-class word (`static []char s`). A slice's `:` is one inside a single
  pair of brackets with no `?` or quote there (`a[c ? 1 : 2]`, `case '[': ...
  ']'`) and not `::` (`[[gnu::unused]]`). Over the 7957 C files of the tree
  (submodules included): libgen.c's slices and libgen.h's `char path[maybe
  :0]`, nothing else.
- Oniguruma trap: a lookaround nested inside a variable-length lookbehind
  makes the scanner report an empty match at column 0 of every line, and
  VSCode then drops the whole injection without a message. `test/run.js`
  fails on any rule that matches an empty string.

## Diagnostics and IntelliSense

The C/C++ extension's IntelliSense parses regular C, so on its own it marks
yasc as errors (`invalid storage class for a parameter` at `* view maybe`).
The extension fixes that in two parts:

- **tcc's diagnostics** (source `tcc`): each yasc `.c` file goes through
  `libs/tinycc/bin/armv8m-tcc -fsyntax-only -fmax-errors=0` exactly as
  `scripts/safe_mode_ratchet.py` runs it (the safe default: yasc, `-Wall`,
  `-Wlifetime`; `-I` the file's directory, the counted directory and its
  `include/`, plus the directory's `flags`), on open, on save and while typing
  (the unsaved text goes to tcc on stdin after `#line 1 "<file>"`). tcc gives
  no columns: a message that names `'x'` underlines `x`, others the line. A
  `note:` is attached to the message before it; a message from a header shows
  at the `#include` that leads to it. Headers are not checked alone (the
  `sys/yasc/*.h` fragments do not compile alone).
- **IntelliSense for yasc files**: a configuration provider for the C/C++
  extension gives yasc files tcc's include paths (`armv8m-tcc -vv`: the
  rootfs headers) and macros (`-dM`, without `__YASC__`, so headers show their
  plain C declarations) and forces `intellisense/yasc_intellisense.h`, which
  erases the yasc words a macro can (`owned`, `view`, `maybe`,
  `borrows(...)`, `takes(...)`, `drop`, `move()`, `borrow()`, `unsafe`, `try`,
  `defer`, `errdefer`). Other C files keep the C/C++ extension's own
  configuration. It needs
  `"C_Cpp.default.configurationProvider": "yasos.yasc-syntax"` in the
  workspace settings (the extension offers to set it once).
- **IntelliSense errors only where tcc agrees**: what no macro can erase --
  `@min(a, b)`/`@max` ('unrecognized token' at the `@`), slices (`[]const
  char s`, `p[0:n]`, then every `s` is 'undefined'), `owned(dealloc)`,
  `out`, `catch`, `error`, `!T`, `union(k)`, methods, modules -- IntelliSense
  marks as errors, and EDG's `#pragma diag_suppress` cannot silence them. In
  a yasc `.c` file that tcc checks, a C/C++ error stays only on a line where
  tcc reports an error too; IntelliSense's warnings and hints stay -- except
  its "never used" hints (EDG 177/550/869) for a name that appears on a line
  whose error is hidden: `size_t len; ... []char s = path[0:len];` is a use
  IntelliSense could not read -- headers and other files are left alone
  (`yasc.intellisense.hideErrors`). It wraps
  the extension host's shared `DiagnosticCollection` class to see the C/C++
  extension's `C/C++: IntelliSense` collection (`squiggles.js`): VSCode has
  no API for it.

Yasc files: the directories in `scripts/safe_mode_ratchet.json`
(`yasc.ratchetConfig`), the globs in `yasc.files` (default
`libs/tinycc/examples/yasc/**`) and any `.c` file with `#pragma yasc`.
Settings: `yasc.compiler`, `yasc.extraArgs`, `yasc.diagnostics.enable`,
`yasc.diagnostics.onType`, `yasc.diagnostics.delay`,
`yasc.intellisense.enable`, `yasc.intellisense.hideErrors`,
`yasc.intellisense.standard` (default `gnu17`:
IntelliSense's C23 mode calls a self-referencing struct a redeclaration);
command `yasc: Check this file with tcc`;
log in the `yasc` output channel. The cross has to exist (`./build_rootfs.sh`).

```bash
./install.sh                # build yasc-syntax.vsix and `code --install-extension` it
./install.sh --package-only # just the .vsix
node test/run.js            # tokenize test snippets with VSCode's own engine
node test/diag.js           # message parsing, which files are yasc, one real tcc check
```
