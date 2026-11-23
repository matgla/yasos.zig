# ydb -- a debugger on the board

ydb is a debugger for YasOS programs. It runs on the board, driving the
kernel's ptrace. It is written on the board (in yasvi, over the console), in
C, and built there by the board's own tcc.

This document has two halves:

- **Reference** (sections 1-5): what the kernel and toolchain give ydb today
  and what is missing, the debug data and the address rules, how to use
  ptrace (with working code), the source layout and the milestones.
- **The plan** (sections 6-10, then parts P1-P5): the order of work by video
  part, what each part ends with and the steps that get there. Each step is
  one typist take. Read the reference before writing a step; the steps do
  not repeat it.

Other sources:

- What the kernel gives ydb today (2026-11-17): `docs/debugging.md`.
- The ptrace contract: libc `sys/ptrace.h`. `apps/ptracetest/ptracetest.c`
  is a complete, tested example of every request (37 checks, passing on QEMU
  and the Pico Plus 2).
- The video script: ScriptForge project `ydb-part1-a-debugger-on-the-board`
  (part 1). Later parts get their own projects.

# Reference

## 1. What ydb can rely on

| Need | Provided by | State |
|---|---|---|
| Start a program stopped before its first instruction | `PTRACE_TRACEME` + `execv` -> SIGTRAP stop | works |
| Breakpoints in the program's own code | `POKETEXT` of `UDF #1` (0xde01) -> SIGTRAP, pc = breakpoint | works (the traced exec runs from a RAM copy) |
| Registers r0-r15, xPSR | `GETREGS`/`SETREGS`, `PEEKUSER`/`POKEUSER` | works |
| FP registers s0-s31, FPSCR | `GETVFPREGS`/`SETVFPREGS` | works (zeros if no FP context) |
| Memory | `PEEKDATA`/`POKEDATA`, one word per call | works |
| Crash reporting | a fault stops the tracee: SIGILL/SIGSEGV/SIGBUS/SIGFPE | works |
| Interrupt a running program | `PTRACE_INTERRUPT` -> SIGSTOP; Ctrl-C on the console -> SIGINT stop | works, also in a blocking system call (it returns EINTR) |
| Kill / detach | `PTRACE_KILL`, `PTRACE_DETACH`, `kill(2)` | works |
| Load addresses of the program | `/proc/<pid>/maps` | works, `.rodata` line for shared rodata |
| Symbols, line tables, types | the YDBG blob of a `-g` image, or its `strip -f` file | works (DWARF 5) |
| Single instruction step | -- | `PTRACE_SINGLESTEP` is ENOSYS: ydb steps with breakpoints (section 3.4) |
| Unwinding, locals on the stack | `.debug_frame` CFI, frame base `DW_OP_breg13`/`breg7` + offset | works |
| Variables in registers | `.debug_loclists` (DWARF 5 location lists) | works: valid only over their live range, empty location = optimised out |
| Breakpoints in shared libraries (libc.so ...) | -- | not possible: their code runs from flash (K3) |

### Gaps

Closed (2026-11-17): T1 (tinycc `.debug_frame`, frame base), T2 (location
lists, no stale locations), K1 (`.rodata` in maps), K4 (EINTR), Ctrl-C.
Still open, none of them blocking a milestone:

- **K2 (kernel, optional): `PTRACE_SINGLESTEP`.** On the board the debug
  monitor's MON_STEP can do it; QEMU does not model it. Software stepping in
  ydb (3.4) works everywhere, so this is an optimisation.
- **K3 (kernel, later): FPB hardware breakpoints** for code in flash (shared
  libraries), board only. Sketch under "Open questions" at the end.
- **Signal handlers.** There are none: a handler a program installs is
  recorded and keeps the signal from ending it, never called.

## 2. Debug information

### Finding it

1. Read the `YaffHeader` (`libs/tinycc/source/obj/tccyaff.h`; build ydb with
   `-I../../libs/tinycc/source/obj` like `apps/yaffdump`). `yaff_version` must
   be 6.
2. `debug_offset == 0`: no debug data (not linked with `-g`, or stripped bare).
   Symbols only from the image's export table, no lines.
3. Otherwise read the `YaffDebugHeader` there. If its only section is
   `.yaff_debuglink` (type `YAFF_SHT_DEBUGLINK`), the data is in a separate
   file: its name is the section's contents. Look next to the program first,
   then `/usr/lib/debug/`. Accept it only if both blobs carry the same
   `image_crc`.
4. The section table is `Elf32_Shdr`-shaped (`YaffDebugSection`); offsets are
   from the start of the blob. Read sections on demand with `fseek`/`fread`: a
   `-g` tcc has megabytes of DWARF, and the board has no room to hold it.

`libs/tinycc/scripts/yaff_debug_to_elf.py` is a compact reference reader, and
it turns the data into an ELF so `arm-none-eabi-readelf --debug-dump` shows
what ydb should find.

### What is in it

- `.text .plt .rodata .data .bss .got` as `SHT_NOBITS` entries: link
  addresses and sizes of the image's regions.
- `.symtab` + `.strtab`: every symbol, statics included, `st_value` a link
  address (functions carry the Thumb bit), `st_shndx` an index into the blob's
  section table.
- DWARF 5: `.debug_info`, `.debug_abbrev`, `.debug_line`, `.debug_str`,
  `.debug_line_str`, `.debug_aranges` (use it to find the CU for an address
  without parsing all of `.debug_info`), `.debug_frame`, `.debug_loclists`.
- `.debug_frame`: CIE version 1, code alignment 2, data alignment -4, return
  address r14, initial rule CFA = r13 + 0; one FDE per function. The ops are
  advance_loc*, def_cfa(_offset/_register), offset, restore,
  remember/restore_state.
- Frame base (`DW_AT_frame_base`): `DW_OP_breg13 <top>` (sp after the
  prologue + the locals' size) or `DW_OP_breg7 <top>` in a function with a
  frame pointer. `DW_OP_fbreg` offsets are from that. In a frame one up, use
  the sp/r7 the unwinder recovers for it.
- `DW_AT_location` is `exprloc` (`DW_OP_addr`, `DW_OP_fbreg`, `DW_OP_reg*`,
  register pieces) or, for a variable in a register, `sec_offset` into
  `.debug_loclists`: entries `DW_LLE_start_length` (address, uleb length,
  counted expression) and `DW_LLE_end_of_list`. A pc in no entry, or an empty
  expression, means optimised out.
- Paths: `DW_AT_comp_dir`/file names are those of the machine that compiled
  it -- a host path for the rootfs, a board path for code built on the board.
  ydb needs a `directory` / path-substitution setting.

### Link-time to run-time addresses

Link addresses are module offsets: `.text` starts at 0. `/proc/<pid>/maps`
gives one line per region, executable first, then its libraries:

```
toybox .text 0x603a1ac0 0x3bf50
toybox .plt 0x603dda10 0x1960
toybox .data 0x7000b000 0x830
toybox .bss 0x7000b830 0x1090
toybox .got 0x7000c8c0 0x132
libc.so .text ...
```

- code (`.text`, `.plt`): `run = maps[.text] + link`
- data: with `rodata = ` the `.rodata` link address from the blob and `C =`
  the header's `const_rodata_length`, `off = link - rodata`.
  - `off < C`: shared rodata in flash: `run = maps[.rodata] + off`.
  - otherwise `run = maps[.data] + (off - C)`. This one rule covers `.rodata`
    (its per-process part), `.data`, `.bss` and `.got`: the loader lays them
    out at the linker's distances (`tcc_yaff_data_region_offset`,
    `Module.resolve_data_offset`).

Reverse (pc -> function/line): `link = pc - maps[.text]`.

**Function pointers are not code addresses.** A function pointer on YasOS
points at a per-process yasld thunk (16 bytes: two literal loads, then the
callee's GOT base and its address at +12). Take code addresses from the
symbol table.

## 3. Using ptrace

```c
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <errno.h>
#include <signal.h>
```

Requests use Linux's numbers and layouts. `struct user_regs`: `uregs[0..12]`
r0-r12, `[13]` sp, `[14]` lr, `[15]` pc (bit 0 clear), `[16]` xPSR, `[17]` 0.
Every request but TRACEME/ATTACH needs a tracee of the caller, and all but
CONT/DETACH/KILL/INTERRUPT need it **stopped**: ESRCH otherwise.

### 3.1 Starting a program

```c
pid_t pid = vfork();
if (pid == 0) {
  ptrace(PTRACE_TRACEME, 0, 0, 0);
  execv(path, argv);
  _exit(127);
}
int status;
waitpid(pid, &status, 0);            /* WIFSTOPPED, WSTOPSIG == SIGTRAP */
```

The stop is before the program's first instruction. pc is the kernel's
`call_main` trampoline (in kernel flash), not your `_start` -- do not
disassemble or step there; set breakpoints and `PTRACE_CONT`. The traced exec
loaded the executable into RAM, so its code can take breakpoints; its shared
libraries still run from flash.

The program reads and writes the console itself; Ctrl-C reaches it through
the kernel (section 3.7).

`PTRACE_ATTACH` works only on a descendant of ydb -- in practice, programs ydb
started. It stops the target with SIGSTOP.

### 3.2 Waiting and reading the status

Every stop is reported once, by `waitpid`:

| status | meaning |
|---|---|
| `WIFSTOPPED`, `WSTOPSIG == SIGTRAP`, pc is one of ydb's breakpoints | breakpoint hit |
| `WIFSTOPPED`, `SIGTRAP`, pc not a breakpoint | the exec stop (first stop only) |
| `WIFSTOPPED`, `SIGILL` / `SIGSEGV` / `SIGBUS` / `SIGFPE` | the program faulted; pc is the faulting instruction |
| `WIFSTOPPED`, `SIGSTOP` | after `PTRACE_ATTACH` or `PTRACE_INTERRUPT` |
| `WIFSTOPPED`, `SIGINT` (or another signal) | Ctrl-C on the console, or `kill()`: the tracee stops instead of dying; `CONT` with 0 drops the signal, with the signal ends the program |
| `WIFEXITED`, `WEXITSTATUS` | the program exited |
| `WIFSIGNALED`, `WTERMSIG` | killed: `PTRACE_KILL` (SIGKILL), or a signal passed to CONT |

While the program runs, block in `waitpid(pid, ...)`: Ctrl-C reaches the
program through the kernel (3.7). `waitpid(pid, &status, WNOHANG)` returns 0
while it still runs, for when ydb has something else to do.

### 3.3 Breakpoints

POKE writes a whole aligned word, so a 16-bit breakpoint is a
read-modify-write of one halfword:

```c
#define BKPT 0xde01                           /* YASOS_PTRACE_BREAKPOINT */

struct breakpoint { uintptr_t addr; uint16_t saved; int inserted; };

static int insert(pid_t pid, struct breakpoint *b) {
  uintptr_t w = b->addr & ~3u;
  int hi = (b->addr & 2) != 0;
  errno = 0;
  long word = ptrace(PTRACE_PEEKTEXT, pid, (void *)w, 0);
  if (errno) return -1;
  b->saved = hi ? (uint16_t)(word >> 16) : (uint16_t)word;
  word = hi ? (word & 0x0000ffff) | ((long)BKPT << 16)
            : (word & (long)0xffff0000) | BKPT;
  if (ptrace(PTRACE_POKETEXT, pid, (void *)w, (void *)word)) return -1;
  b->inserted = 1;
  return 0;
}
/* remove(): the same with b->saved in place of BKPT. */
```

- 16 bits are enough even over a 32-bit instruction: execution never gets
  past the first halfword.
- `POKETEXT` on flash fails with EIO: a breakpoint in a shared library
  cannot be set (K3). Say so instead of pretending.
- **Not inside an IT block.** An instruction in an IT block whose condition
  fails does not execute, and neither does a breakpoint in its place: it is
  skipped silently. Breakpoints on a line's first address are practically
  never in one. When stepping (3.4), plant at the instruction after the block.
- When a breakpoint is hit, pc is its address -- the UDF did not execute.
- Before `CONT` with breakpoints in place you have to get the current one out
  of the way: 3.4.

### 3.4 Stepping without PTRACE_SINGLESTEP

ydb steps in software: decode the instruction at pc, find where it can go
next, plant temporary breakpoints there, `CONT`, take them out at the stop.

**Successors** of the instruction at pc (Thumb-2; tcc uses a modest subset):

- not a branch: pc + 2 or pc + 4 (bits [15:11] of the first halfword are
  `0b11101`, `0b11110` or `0b11111` for a 32-bit instruction)
- `B`, `B<cond>` (16 and 32 bit): target and, if conditional, the next one
- `BL`, `BLX` imm: target (step into) -- for "next", the next one only
- `BX Rm`, `BLX Rm`, `MOV pc, Rm`: the register (from GETREGS), bit 0 cleared
- `POP {.., pc}`, `LDM sp!, {.., pc}`: the word at sp + 4 x (registers below pc)
- `LDR pc, [..]`: the word it loads (PEEK)
- `CBZ`/`CBNZ`: target and next
- `TBB`/`TBH`: read the table entry (PEEK), pc + 4 + 2 x entry
- in an IT block: the instruction after the block too

`apps/yaffdump/thumb.c` decodes Thumb-2 already; its branch decoding is the
place to start.

**Stepping over a breakpoint** (to continue from one):

1. remove the breakpoint at pc,
2. plant temporary breakpoints at the successors,
3. `CONT`, wait for the stop (it is at one of them),
4. remove the temporaries, put the original breakpoint back,
5. `CONT` again if the user asked to continue.

**Source stepping:**

- `next`: temporary breakpoints at every line-table address of the current
  function (`is_stmt` rows) other than the current line's, plus the return
  address; `CONT`. The return address: lr at the function's first
  instruction, the CFI's saved lr (CFA - 4 after the push) anywhere else.
- `step`: the same, plus the target of a `BL` at the stop -- if that is in the
  program's own code. A call into a shared library is stepped over (no
  breakpoints in flash).
- `finish`: a breakpoint at the return address (as for `next`).

### 3.5 Registers

```c
struct user_regs r;
ptrace(PTRACE_GETREGS, pid, 0, &r);
printf("pc %08lx  sp %08lx  lr %08lx\n", r.uregs[15], r.uregs[13], r.uregs[14]);
r.uregs[0] = 7;
ptrace(PTRACE_SETREGS, pid, 0, &r);           /* the next CONT sees r0 = 7 */
```

- Writing pc: the Thumb state is kept, bit 0 dropped. A moved pc leaves any
  IT block.
- Of xPSR only the flags (N Z C V Q, GE) are writable.
- Writing sp moves the stopped frame there (for calling a function in the
  tracee later). It has to stay inside the tracee's stack.
- `PEEKUSER`/`POKEUSER` with a byte offset (`15 * 4` is pc) do one register.
- `GETVFPREGS` gives `struct user_vfp`: `fpregs[i]` is d_i = s(2i) | s(2i+1) << 32
  for i < 16, then `fpscr`. A process that never used the FPU reads zeros, and
  `SETVFPREGS` on it fails with EIO.

### 3.6 Memory

```c
errno = 0;
long word = ptrace(PTRACE_PEEKDATA, pid, (void *)addr, 0);
if (word == -1 && errno) { /* EIO: not the tracee's memory; ESRCH: not stopped */ }
ptrace(PTRACE_POKEDATA, pid, (void *)addr, (void *)new_word);
```

- One word per call; read a range as aligned words and cut out the bytes.
  Cache what was read while the tracee stays stopped.
- PEEK reads the tracee's own pages (its RAM code copy, data, heap, stack)
  and the read-only image in flash (shared libraries, shared rodata). POKE
  writes only its pages.
- Clear `errno` first: a word of -1 is valid data.

### 3.7 Running, interrupting, ending

```c
ptrace(PTRACE_CONT, pid, 0, 0);               /* data must be 0, see below */
ptrace(PTRACE_INTERRUPT, pid, 0, 0);          /* -> SIGSTOP stop */
ptrace(PTRACE_KILL, pid, 0, 0);               /* -> WIFSIGNALED, SIGKILL */
ptrace(PTRACE_DETACH, pid, 0, 0);             /* runs on, untraced */
```

- **A non-zero `data` in CONT/DETACH kills the tracee with that signal**:
  there are no signal handlers to deliver it to. So after a fault stop, `CONT`
  with 0 re-executes the faulting instruction; to let the program die as it
  would have, `CONT` with the signal (`WTERMSIG` reports it).
- Take every breakpoint out before `DETACH`: an untraced process that hits
  `UDF #1` is killed.
- If ydb exits, its tracees are detached and resume -- with whatever
  breakpoints are still in them. Remove them (or `PTRACE_KILL`) first.
- **Ctrl-C.** The console's ISIG turns ^C into SIGINT for the foreground
  program: from the root shell down the chain of processes waiting in
  `waitpid` for one process, the one at the end. With ydb waiting in
  `waitpid` for its tracee, that is the tracee, which stops with SIGINT and
  ydb sees `WSTOPSIG == SIGINT` -- even when the program is blocked reading
  the console (the read returns EINTR). So: let the program use the console
  itself, and while it runs, block in `waitpid`. At ydb's own prompt put the
  terminal in raw mode (`cfmakeraw` clears ISIG), where ^C is the byte 0x03
  and nothing is signalled -- and ignore SIGINT (`signal(SIGINT, SIG_IGN)`)
  for the moments in between, so a ^C then does not end ydb.

### 3.8 Errors

| errno | from | means |
|---|---|---|
| ESRCH | any per-tracee request | not your tracee, gone, or not stopped (for requests that need it stopped) |
| EIO | PEEK/POKE | address not in the tracee's memory; POKE into flash |
| EIO | SETREGS | new sp outside its stack |
| EIO | SETVFPREGS | no FP context to write |
| EPERM | ATTACH | not a descendant, already traced, or a kernel process |
| EPERM | TRACEME | already traced |
| ENOSYS | SINGLESTEP | not implemented: 3.4 |
| EFAULT | GETREGS etc. | ydb's own buffer pointer is bad |
| EINTR | read, write, nanosleep, poll, waitpid | a signal for the caller arrived (in ydb: a ^C while not in raw mode, if it does not ignore SIGINT) |

## 4. Structure

ydb is written in C, on the board, built with the board's tcc (the cross tcc
builds it for the image, like `apps/yaffdump`), and tested on the board with
libc's `utest.h` (section 9). The step-by-step order is the second half
of this document.

The split, in `apps/ydb/src/`:

- `target.c` -- the ptrace layer: launch, wait/decode status, regs, memory
  (word cache), the breakpoint table (insert/remove/step-over), kill/detach.
- `maps.c` -- `/proc/<pid>/maps`, link <-> run-time addresses (section 2,
  "Link-time to run-time addresses").
- `debuginfo.c` -- YaffHeader, YDBG blob, debuglink + `image_crc`, section
  reader by name (on-demand `fread`).
- `symbols.c` -- `.symtab`: name -> address, address -> name+offset.
- `dwarf_line.c` -- DWARF 5 line programs: address <-> file:line, a
  function's statement addresses.
- `dwarf_info.c` -- abbrevs, DIE walking for CUs found via `.debug_aranges`;
  subprograms, variables, types; a small expression evaluator (`DW_OP_addr`,
  `DW_OP_reg*`, `DW_OP_fbreg`, `DW_OP_breg*`, `DW_OP_piece`), and
  `.debug_loclists` lookup by pc.
- `thumb_step.c` -- successors of an instruction (3.4), sharing
  `apps/yaffdump/thumb.c`.
- `frame.c` -- CFA and unwinding from `.debug_frame`.
- `print.c` -- values by DWARF type.
- `cli.c` -- commands, the console loop with Ctrl-C (3.7).

## 5. Milestones

Each one usable on its own (the video parts, section 10), each with a
smoke test (`tests/smoke/`, ydb driven by a command file, e.g.
`ydb -x cmds prog`):

| | Commands | Needs |
|---|---|---|
| M0 | `run [args]`, `break <symbol>`, `continue`, `info registers`, `x/<n>x <addr>`, `kill`, `quit`; crash report (signal, pc -> symbol+offset) | symtab, 3.1-3.3, 3.5-3.6 |
| M1 | `break file:line`, `list`, `info line`, stop location as file:line | line tables |
| M2 | `stepi`, `next`, `step`, `finish` (from the entry), step-over of breakpoints | 3.4 |
| M3 | `print <global>` with types, `print $r0`, `set var`, `display` | `.debug_info`, types |
| M4 | `bt`, `up`/`down`, locals, `finish` anywhere | `.debug_frame`, location lists |
| M5 | Ctrl-C (SIGINT stop), `attach` to a descendant | 3.7 |

# The plan

## 6. Ground rules

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

## 7. Build

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

## 8. Test programs

`apps/ydb/targets/`, plain C built on the board with `tcc -g`:

| file | for |
|---|---|
| `hello.c` | exits 0; the P1 target |
| `count.c` | a loop calling a function, prints i; breakpoints, stepping |
| `crash.c` | NULL store in a function three calls deep; crash report, backtrace |
| `vars.c` | globals and locals of int, char*, struct, array; print |
| `fact.c` | recursion; bt, up/down, finish |
| `wait.c` | blocks in `read(0)` then loops; Ctrl-C, attach |

Compile them on the board (`tcc -g`) or with the cross; while writing a
parser, check against `yaff_debug_to_elf.py` + `arm-none-eabi-readelf` on
the host. `apps/ptracetest` is the reference for the ptrace calls.

## 9. Tests

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

## 10. Overview of the parts

| part | video | ends with (the payoff on screen) | milestone (section 5) |
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
  section 3.8).
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
  section 3.3.)
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
  section 2 ("Link-time to run-time addresses").
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

M2. Software stepping (section 3.4).

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

- `src/frame.c`: `.debug_frame` CIE/FDE (ops listed in section 2), CFA and saved registers; `bt` in `fact.c`; `up`/`down`; `finish` from
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
