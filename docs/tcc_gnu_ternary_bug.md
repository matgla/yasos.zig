# TCC Bug: GNU `?:` Ternary Extension Miscompiled

## Summary

TCC silently miscompiles the GNU C `?:` (Elvis operator) extension, producing incorrect code without any error or warning.

## The GNU Extension

GCC supports an omitted middle operand in the ternary operator:

```c
x = a ?: b;  // equivalent to: x = a ? a : b;
```

This is defined in [GCC docs](https://gcc.gnu.org/onlinepubs/gcc/Conditionals.html) — if `a` is truthy, return `a`; otherwise return `b`. The key behavior is that `a` is evaluated only once.

## Observed Behavior in TCC

```c
char *tt = NULL;
char *destname = tt ?: toys.optargs[--toys.optc];
// Expected: destname = toys.optargs[--toys.optc]  (since tt is NULL)
// Actual:   destname = toys.optargs[0]  (picks wrong element / doesn't decrement)
```

With `argv = {"test.txt", "t.txt"}` and `optc=2`:
- **Expected**: `--optc` → `optc=1`, `destname = optargs[1]` → `"t.txt"`
- **Actual**: `destname = "test.txt"` (source file instead of destination)

## Impact

This caused `cp src dst` to treat the **source** as the destination, making every copy fail with:

```
cp: 'test.txt' is 'test.txt'
```

## Prevalence in Toybox

Toybox uses `?:` extensively (~50+ instances across the codebase). Grep pattern:

```
grep -rn '? :' apps/toybox/ --include='*.c'
```

## Workaround

Replace all `?:` with explicit ternary:

```c
// Before (GNU extension):
*destname = tt ?: toys.optargs[--toys.optc];

// After (standard C):
*destname = tt ? tt : toys.optargs[--toys.optc];
```

**Note**: The workaround evaluates `a` twice, which matters if `a` has side effects. None of the toybox usages have side effects in the first operand.

## Fix Needed

TCC should either:
1. **Correctly implement** the GNU `?:` extension, or
2. **Emit an error/warning** when encountering it, rather than silently miscompiling
