# ydb: the plan, step by step, by video part

ydb is a debugger for YasOS programs. It runs on the board, it is written on
the board (in yasvi, over the console), and it is written in C, built on the
board by the board's own tcc. This file is the order of work: what each video
part ends with, and the steps that get there. Each step is one typist take.

- The ptrace contract, the debug-data format and the address rules are in
  `docs/ydb_plan.md` (sections 1-3). Read that before writing a step; this
  file does not repeat it.
- What the kernel gives ydb today: `docs/debugging.md`.
- Every ptrace request, tested: `apps/ptracetest/ptracetest.c`.
- The video script: ScriptForge project `ydb-part1-a-debugger-on-the-board`
  (part 1). Later parts get their own projects.

## Ground rules

1. **Written on the board.** Edited with yasvi, built with `make` and tcc on
   the board, run on the Pico Plus 2 (and on QEMU for the smoke tests). The PC
   keeps the git checkout: `scripts/target_sync.py push|pull` (or
   `scripts/qemu_mount.py` on QEMU) moves `apps/ydb` back and forth.
2. **Every step is a snapshot.** Write the code first (on the board, or here),
   commit each step, tag it `ydb/p<N>-s<M>`. A take types the diff from the
   previous tag to this one. Retakes replay the same diff, so the code on
   screen never drifts from the code in git.
3. **Shared, not copied.** The YAFF layout comes from the compiler's own
   header (`-I../../libs/tinycc/source/obj`, `tccyaff.h`), the Thumb decoder
   from `apps/yaffdump/thumb.c` (compiled in from there, as yaffdump's
   Makefile does with its own files). ptrace from libc `<sys/ptrace.h>`.
4. **Small.** Fixed buffers, `malloc` only where a size is not known before
   reading the file. No `printf` of huge tables; ydb itself is built `-g` so
   it can be inspected with its own tools.
5. **Read debug data on demand.** Never load a whole section. `fseek`, read a
   window, parse, forget. A `-g` tcc has megabytes of DWARF.
6. **Tests run on the board.** `make CC=tcc test` builds `build/ydb_tests`
   with libc's test framework and runs it there (see "Tests" below). No host
   build: the ptrace half can only run on YasOS, and the parsers are checked
   against programs the board's tcc just compiled.

## Build

`Makefile` modelled on `apps/yaffdump/Makefile`: `CC ?= armv8m-tcc` for the
image, `make CC=tcc` on the board.

On the board (what the video shows):

```sh
cd /root/ydb
make CC=tcc            # tcc -g -c src/*.c, then link build/ydb
make CC=tcc test       # build the targets and build/ydb_tests, run them
build/ydb targets/hello
```

or, before the Makefile exists (P1/S0):

```sh
tcc -g -I../../libs/tinycc/source/obj -o build/ydb src/main.c
```

Check in P1/S0, and write the answers here:

- `make` on the board: `/usr/bin/make` is in the image (apps/make); confirm
  it runs a two-file build, else `build.sh`.
- The include path to `tccyaff.h` on the board: the tree pushed by
  `target_sync.py` has to carry `libs/tinycc/source/obj/tccyaff.h` (or copy
  the one header into `apps/ydb/include/` at push time -- not by hand).
- Build time of P1/S5's ydb on the board (for the script).

## Test programs

`apps/ydb/targets/`, plain C built on the board with `tcc -g`:

| file | for |
|---|---|
| `hello.c` | exits 0; the P1 target |
| `count.c` | a loop calling a function, prints i; breakpoints, stepping |
| `crash.c` | NULL store in a function three calls deep; crash report, backtrace |
| `vars.c` | globals and locals of int, char*, struct, array; print |
| `fact.c` | recursion; bt, up/down, finish |
| `wait.c` | blocks in `read(0)` then loops; Ctrl-C, attach |

## Tests

The framework is sheredom's `utest.h`, the one libc's tests use
(`libs/libc/tests/utest.h`, one header, public domain). It works on YasOS as
it is (checked 2026-11-18 on QEMU with both the cross and the board's own
tcc): tests register through constructors, `UTEST_F` fixtures, failures with
file:line, exit status 1 on any failure, `--filter=suite.name`, and a 3-test
file built with `-g` is 53 KB.

- **Build it with `-D__STRICT_ANSI__`.** Without it, utest takes its Linux
  path and calls `timespec_get` / `TIME_UTC`, which YasOS libc doesn't have
  (compile error). With it, timings come from `clock()`. Adding
  `timespec_get` to libc would remove the flag. That's a small libc change,
  not needed for ydb.
- Include it from `libs/libc/tests/` (`-I../../libs/libc/tests`). The tree
  pushed to the board has to carry it, like `tccyaff.h`.
- Layout: `tests/test_<module>.c`, one `UTEST_MAIN()` in `tests/main.c`,
  linked with every `src/*.c` except `main.c` into `build/ydb_tests`.
  `make test` builds `targets/*` with `tcc -g` first, then runs the tests.
- **Expected values come from the target sources, not hand-copied numbers.**
  The targets mark lines with comments (`/* @loop */`), and a test finds the
  marker's line number by reading the `.c` file. A line test then asks:
  does `count.c:@loop` map to an address, and does that address map back to
  the same line? Symbols are checked the same way: `inc` exists, it's in
  `.text`, and `main` calls it (a `BL` to it found by `thumb_decode`). Edits to
  a target don't break the tests.
- **ptrace tests drive the real targets**, the way `apps/ptracetest` does:
  launch `targets/hello`, expect the exec stop, plant a breakpoint, expect
  SIGTRAP at the right pc, continue, expect `exited 0`. Each test kills its
  tracee in teardown (`UTEST_F_TEARDOWN`), so a failed test doesn't leave a
  stopped process behind.
- The tests can be part of the takes ("the test first, it fails, then the
  code") where that reads well on camera. Otherwise they're written off
  camera at each step's tag, and the take only shows `make test` passing.
- QEMU CI: `tests/smoke/ydb_test.py` runs `make test` on the image's ydb tree,
  plus a few `ydb -x CMDS` scripts for the command line.

| part | tests added |
|---|---|
| P1 | launch -> exec stop; GETREGS pc is outside the program; CONT -> exit 0; `crash` -> SIGSEGV stop, CONT with the signal -> killed by 11; breakpoint at `main` -> SIGTRAP with pc == address, restore, exit 0 |
| P2 | YAFF header and section table of a target; symbol <-> address round trip for every function of `count`; maps rules (code and data); breakpoint by name; step-over of a non-branch; crash report names `store`; line table round trip on every marker; `directory` substitution |
| P3 | successors of each branch kind (a target with one function per kind, made with inline asm); `stepi` lands on a successor; `next` visits the marked lines of the loop in order; `step` enters `inc`; `finish` returns to the marker after the call |
| P4 | `print` of each global in `vars` against the values the source sets; `bt` depth and function names in `fact` at depth 5; `info locals` / `print n` in every frame; `<optimized out>` outside a location list's range |
| P5 | `PTRACE_INTERRUPT` stops `wait` inside `read` (SIGSTOP), and CONT resumes it; `attach` / `detach` of a descendant leaves no breakpoints in it. Ctrl-C on the console is checked by the smoke test, which can type ^C |

## Overview

| part | video | ends with (the payoff on screen) | milestone (`docs/ydb_plan.md` 5) |
|---|---|---|---|
| P1 | Why, and how ptrace works | a hand-placed breakpoint hit at `main` | ptrace loop |
| P2 | Names and lines | `break count.c:12`, stop shows the source line; crash shows `crash.c:7 in store()` | M0 + M1 |
| P3 | Stepping without single-step | `next` / `step` / `finish` through `count.c` | M2 |
| P4 | Variables and the stack | `bt` in `fact.c`, `print` of locals and a struct | M3 + M4 |
| P5 | A real bug | Ctrl-C, `attach`; ydb finds a bug in a YasOS program | M5 + finale |

P2 is large; split it into "names" and "lines" if the take time passes
~12 minutes of footage.

---

## P1 -- why, and how ptrace works

Script: `ydb-part1-a-debugger-on-the-board` (why on the board, the MCU
constraints, why C, how a debugger works, ptrace inside the YasOS kernel,
then these steps). Kernel side needed: done (debug support commit
`54bf32a9a7`).

### P1/S0 -- the skeleton (`p1-s0-skeleton.take`)

- `src/main.c`: usage line, `argv[1]` is the program. `targets/hello.c`.
- Build with the one tcc line above; run `build/ydb` (usage) and
  `tcc -g -o targets/hello targets/hello.c`.
- Done when: both build on the board; build time noted here. Short take,
  mostly to show the edit-build-run loop once.

### P1/S1 -- start a program stopped (`p1-s1-launch.take`)

- `vfork`; child: `ptrace(PTRACE_TRACEME, 0, 0, 0)`, `execv`, `_exit(127)`.
  Parent: `waitpid`, decode the status: `stopped: SIGTRAP (exec)`.
- vfork: the child runs on the parent's stack until exec, so it calls only
  those three functions (as `ptracetest.c` does).
- A `ptrace` error helper: request name + `strerror(errno)` (the table in
  `docs/ydb_plan.md` 3.8).
- Run `build/ydb targets/hello`.
- Done when: the stop prints and `ps` shows the stopped child. Then
  `PTRACE_KILL` so nothing is left behind.

### P1/S2 -- registers (`p1-s2-regs.take`)

- `PTRACE_GETREGS` into `struct user_regs`, print `pc sp lr xpsr`.
- Show that pc is not in the program: it is the kernel's `call_main`
  trampoline (flash address, `0x1...`). Do not disassemble there.
- Done when: the registers print and pc is in flash.

### P1/S3 -- continue to the end (`p1-s3-continue.take`)

- `PTRACE_CONT` with signal 0, `waitpid`, `WIFEXITED` -> `exited 0`,
  `WIFSIGNALED` -> `killed by N`. One status-printing function shared with
  S1.
- Run on `hello` (exit 0) and `crash` (stops with SIGSEGV: print signal + pc,
  then `CONT` with the signal -> `killed by 11`).
- Done when: both outcomes print. This is the first real tracer.

### P1/S4 -- a breakpoint by hand (`p1-s4-breakpoint.take`)

- `ydb -b ADDR PROG`: at the exec stop, `PEEKTEXT` the word at `addr & ~3`,
  swap `0xde01` into the right half, `POKETEXT`, `CONT`. At the SIGTRAP stop:
  print pc, put the halfword back, `CONT` -> `exited 0`. (Code: `insert()` in
  `docs/ydb_plan.md` 3.3.)
- The address by hand, on camera: `yaffdump -f targets/hello` for `main`'s
  link offset (Thumb bit off), and `/proc/<pid>/maps` of the stopped child
  for `.text`'s base. Either ydb prints the child's pid and the maps file is
  read from a second console, or `-b` takes an offset into `.text` and ydb
  reads the maps line itself (simpler on camera; decide when writing).
- After the hit, pc equals the breakpoint address; resuming without
  restoring the halfword would fault again (show it once if it reads well).
- Done when: hit at `main`, then a clean exit. This is the cold open of P1.

---

## P2 -- names and lines

M0 + M1. ydb gets a command loop and reads the program's own debug data.

### P2/S1 -- the YAFF header and the YDBG blob (`p2-s1-yaff.take`)

- `src/debuginfo.c`: read `YaffHeader` (`tccyaff.h`, `yaff_version == 6`),
  `debug_offset` / `debug_length`; read `YaffDebugHeader` and the section
  table (`Elf32_Shdr`-shaped); find a section by name.
- `.yaff_debuglink`: open the named file next to the program, then
  `/usr/lib/debug/`; compare `image_crc`.
- `ydb -s PROG` lists the sections (like `yaffdump -f`).
- Test: the section table of `targets/count` has `.symtab` and the DWARF sections.

### P2/S2 -- symbols (`p2-s2-symtab.take`)

- `src/symbols.c`: walk `.symtab` with a small read window; name -> link
  address, address -> name+offset (keep the function symbols sorted in an
  array if they fit; otherwise scan).
- Function symbols carry the Thumb bit: clear it for code addresses.

### P2/S3 -- run-time addresses (`p2-s3-maps.take`)

- `src/maps.c`: parse `/proc/<pid>/maps`; link <-> run rules from
  `docs/ydb_plan.md` 2 ("Link-time to run-time addresses").
- Replaces P1's hand arithmetic: `-b main` works.

### P2/S4 -- the command loop (`p2-s4-cli.take`)

- `src/cli.c`: a line reader on fd 0 (backspace, Enter; raw mode only in
  P5), commands `run`, `break SYM`, `continue`, `info registers`,
  `x/Nx ADDR`, `x/Ni ADDR` (disassembly through `apps/yaffdump/thumb.c`),
  `kill`, `quit`; `-x FILE` reads commands from a file (the smoke tests use
  it).
- `src/target.c`: the ptrace layer from P1 moved here: launch, wait, regs,
  a word cache for PEEK, the breakpoint table. The Makefile appears here.

### P2/S5 -- continuing from a breakpoint (`p2-s5-stepover.take`)

- Continuing needs the breakpoint out of the way for one instruction, and
  there is no single-step (P3 does it properly). For now: remove it, plant a
  temporary one at pc + the instruction's size (`thumb_decode`), `CONT`,
  restore. Only correct when the instruction is not a branch; refuse
  otherwise ("can't step over a branch yet") -- the P3 hook.
- `count.c` with `break inc`: hits once per loop iteration.

### P2/S6 -- crash report (`p2-s6-crash.take`)

- A fault stop prints the signal, `pc -> function+offset`, the faulting
  instruction (`x/i $pc`) and the registers. `crash.c`:
  `SIGSEGV at store+0x6: str r1, [r0, #0]`.
- Smoke test `tests/smoke/ydb_test.py` (QEMU): break/continue/crash by
  command file.

### P2/S7 -- line tables (`p2-s7-lines.take`)

- `src/dwarf_line.c`: DWARF 5 line-program header (formats, directory and
  file tables with `DW_FORM_line_strp`), the state machine, `is_stmt` rows.
  `.debug_aranges` to find the CU of an address without walking
  `.debug_info`.
- address -> file:line; file:line -> first `is_stmt` address.
- Test: every `/* @marker */` line of the targets round-trips. (While
  writing it, a one-off check on the PC against `yaff_debug_to_elf.py` +
  `arm-none-eabi-readelf --debug-dump=decodedline` is still a good idea.)

### P2/S8 -- source on screen (`p2-s8-list.take`)

- `break file.c:N`, `list`, `info line`; every stop prints
  `count.c:12  x = inc(x);`.
- Paths: `DW_AT_comp_dir` is where it was compiled -- a host path for the
  rootfs programs, a board path for the test programs. `directory DIR`
  command for a substitution.
- Crash report gains the line: `SIGSEGV in store () at crash.c:7`.
- Done when: the P2 payoff runs from a command file and by hand.

---

## P3 -- stepping without single-step

M2. Software stepping (`docs/ydb_plan.md` 3.4).

### P3/S1 -- successors (`p3-s1-successors.take`)

- `src/thumb_step.c`, on top of `thumb_decode` (it gives size, branch
  target and IT state already): the successors of the instruction at pc --
  `B`, `B<cond>`, `BL`, `BLX imm`, `BX`/`BLX Rm`, `MOV pc`, `POP {pc}`,
  `LDM sp!` with pc, `LDR pc`, `CBZ`/`CBNZ`, `TBB`/`TBH` (PEEK the table),
  IT blocks (plant after the block too). Registers from GETREGS, memory from
  the word cache.
- What `thumb.c` doesn't give (register targets, the condition, TBB/TBH
  table base) is decoded here; test on a target with one function per branch kind, with known
  answers.

### P3/S2 -- stepi (`p3-s2-stepi.take`)

- `stepi` / `si`: temporary breakpoints at all successors, `CONT`, take them
  out. P2/S5's step-over now handles branches. `display/i $pc` makes it
  readable.

### P3/S3 -- next, step, finish (`p3-s3-next.take`)

- `next`: temporary breakpoints at every `is_stmt` address of the current
  function other than the current line's, plus the return address (lr at
  entry; P4 makes it right everywhere). `step`: plus the `BL` target if it is
  in the program's own code; a call into a shared library is stepped over
  (flash). `finish`: return address.
- Never plant inside an IT block (a skipped UDF is silent).
- Done when: `next` walks the loop in `count.c`, `step` enters `inc`,
  `finish` returns.

---

## P4 -- variables and the stack

M3 + M4.

### P4/S1 -- DIEs (`p4-s1-info.take`)

- `src/dwarf_info.c`: `.debug_abbrev` (one CU's abbrevs in a table), DIE
  walk of the CU from `.debug_aranges`; subprograms, variables, base /
  pointer / struct / array / typedef types.

### P4/S2 -- print a global (`p4-s2-print.take`)

- `src/print.c`: value by type; `print g_count`, `print g_name` (char* ->
  string via PEEK), `print g_point` (struct), `print $r0`, `set var`,
  `display`.

### P4/S3 -- unwinding (`p4-s3-frame.take`)

- `src/frame.c`: `.debug_frame` CIE/FDE (ops listed in `docs/ydb_plan.md`
  2), CFA and saved registers; `bt` in `fact.c`; `up`/`down`; `finish` from
  anywhere (return address from the CFI).

### P4/S4 -- locals (`p4-s4-locals.take`)

- Expression evaluator: `DW_OP_addr`, `DW_OP_fbreg`, `DW_OP_breg*`,
  `DW_OP_reg*`, `DW_OP_piece`; frame base `breg13`/`breg7`; `.debug_loclists`
  by pc, empty = `<optimized out>`. `info locals`, `print n` in each frame.
- Done when: the P4 payoff (`bt` + locals at depth 5 of `fact`).

---

## P5 -- a real bug

M5 + the finale.

### P5/S1 -- Ctrl-C (`p5-s1-ctrlc.take`)

- While the program runs, ydb blocks in `waitpid`: ^C reaches the tracee
  (SIGINT stop), even inside a blocking read. At ydb's prompt: raw mode
  (`cfmakeraw`) so ^C is a byte; `signal(SIGINT, SIG_IGN)` in between.
  `continue` after a SIGINT stop drops the signal.
- `wait.c`: Ctrl-C in the read, Ctrl-C in the loop.

### P5/S2 -- attach (`p5-s2-attach.take`)

- `attach PID` for a descendant (a program ydb started and detached, or one
  started in the background from a `shell` command). `detach` takes all
  breakpoints out first.

### P5/S3 -- the bug

- Pick a real, unfixed bug in a YasOS userland program (built on the board
  with `-g`), and find it with ydb on camera. Keep a list here of candidates
  as they turn up while writing P2-P4.
- Possible extra: ydb debugging ydb (a second ydb, built `-g`, tracing the
  first one while it traces `count`).

---

## Open questions

- K2 `PTRACE_SINGLESTEP` (MON_STEP on the board) would make P3 shorter on
  the board only; the software stepper stays for QEMU. Not needed.
- K3 hardware breakpoints for code in flash (libc), board only. Sketch, not
  verified on the chip:
  - Cortex-M33 FPB comparators (count from `FP_CTRL.NUM_CODE`); with no probe
    halting the core and `DEMCR.MON_EN` set, a match raises DebugMonitor
    (today `irq_debugmonitor` panics). Without MON_EN it escalates to
    HardFault with `HFSR.DEBUGEVT`, which `fault_signal` already reports as
    SIGTRAP.
  - The comparators are per core and match every process running that
    address (libc is shared): they are per-tracee state, loaded when the
    tracee is switched in and cleared when it is switched out.
  - Stepping off one: disable it and use another comparator at the
    successors (P3's stepper), or `DEMCR.MON_STEP` -- the same DebugMonitor
    handler gives K2 single-step on the board.
  - ptrace: Linux ARM's `PTRACE_GETHBPREGS`/`SETHBPREGS`; ydb `hbreak`, and
    `break` in flash falls back to it. DWT comparators give `watch` the same
    way.
  - Check: which security state the kernel runs in (`DEMCR.SDME`), an attached
    OpenOCD (halting debug wins over the monitor), QEMU not modelling FPB or
    DebugMonitor (QEMU fallback: a private RAM copy of the libraries for a
    traced process, at their text size in RAM).
  - Candidate for its own part (P6: breakpoints in flash, watchpoints).
- Where ydb lives in the image: `/usr/bin/ydb` in the romfs once P2 works
  (`build_rootfs.sh`, cross tcc, like yaffdump); the board build stays the
  one the video shows.
