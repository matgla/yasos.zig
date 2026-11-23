# yasc syntax for VSCode

Highlights tinycc's **yasc** dialect of C in ordinary `.c`/`.h` files
(the tutorial: `libs/tinycc/examples/yasc/README.md`):

- ownership: `owned`, `view`, `maybe` (after a `*`), `out`, `drop` (before a
  parameter's type)
- `defer`, `errdefer`
- errors: `error Set { A, B = ENOENT };`, `error.NAME`, `error Set e`, `!T`
  return types, `try f()`, `f() catch X`, `catch |e| { ... }`,
  `error_name()`, `error_from()`
- `move(p)`, `borrow(p)`
- modules: `module a.b;`, `import a.b;`, `export DECL`

It is a grammar injection into VSCode's built-in C grammar (`source.c`), so
the language stays `c` and the C/C++ extension's IntelliSense keeps working.

- yasc is tcc's default dialect (`-ccompat` is regular C), so the words are
  highlighted in every C file, with or without `#pragma yasc`.
- tcc takes these words as keywords only where its parser expects them and as
  names everywhere else (`out->len`, `s.view`, `drop(x)`, `int error;`,
  `goto out;`). Without a parser the grammar goes by the neighbours: `owned`
  must follow a `*`, `out` must be followed by a type name, `catch` must follow
  the end of an expression, `error.` must be followed by a capitalised name,
  `module` must start a line, `!` must be followed by a type, and none of them
  follows `.` or `->`. Over ~960 regular C files of this tree (tinycc, libc,
  the kernel, make) that marks 3 words. yasvi uses the same rules
  (`apps/yasvi/filetypes/c.c`).
- Scopes: `storage.modifier.yasc.c` (qualifiers, coloured like `const`),
  `keyword.control.{defer,try,catch,import}.yasc.c`,
  `storage.type.error.yasc.c`, `entity.name.type.error.yasc.c` (a set's
  name), `constant.other.error.yasc.c` (an error's name),
  `variable.parameter.capture.yasc.c` (`|e|`),
  `storage.modifier.errunion.yasc.c` (`!`), `support.function.yasc.c`,
  `entity.name.namespace.yasc.c` (a module's name),
  `storage.modifier.export.yasc.c`.

```bash
./install.sh                # build yasc-syntax.vsix and `code --install-extension` it
./install.sh --package-only # just the .vsix
node test/run.js            # tokenize test snippets with VSCode's own engine
```
