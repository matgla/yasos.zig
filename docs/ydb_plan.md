# ydb -- a debugger on the board: plan and ptrace guide

ydb is a small debugger that runs on YasOS itself, driving the kernel's
ptrace. This document has three parts: what the kernel and toolchain give it
today (and what is missing), how to use ptrace from ydb with working code, and
a milestone plan.

Status of the pieces it builds on (2026-11-17): `docs/debugging.md`. The
ptrace contract is in libc `sys/ptrace.h`; `apps/ptracetest/ptracetest.c` is a
complete, tested example of every request (37 checks, passing on QEMU and the
Pico Plus 2).

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
  libraries), board only.
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
libc's `utest.h`. The step-by-step plan, by video part, is `apps/ydb/plan.md`.

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

Each one usable on its own (the video parts in `apps/ydb/plan.md`), each
with a smoke test (`tests/smoke/`, ydb driven by a command file, e.g.
`ydb -x cmds prog`):

| | Commands | Needs |
|---|---|---|
| M0 | `run [args]`, `break <symbol>`, `continue`, `info registers`, `x/<n>x <addr>`, `kill`, `quit`; crash report (signal, pc -> symbol+offset) | symtab, 3.1-3.3, 3.5-3.6 |
| M1 | `break file:line`, `list`, `info line`, stop location as file:line | line tables |
| M2 | `stepi`, `next`, `step`, `finish` (from the entry), step-over of breakpoints | 3.4 |
| M3 | `print <global>` with types, `print $r0`, `set var`, `display` | `.debug_info`, types |
| M4 | `bt`, `up`/`down`, locals, `finish` anywhere | `.debug_frame`, location lists |
| M5 | Ctrl-C (SIGINT stop), `attach` to a descendant | 3.7 |

Test programs: compile them on the board (`tcc -g`) or with the cross, and
check against `yaff_debug_to_elf.py` + `arm-none-eabi-readelf` on the host.
`apps/ptracetest` is the reference for the ptrace calls.
