# Debugging programs on YasOS

What exists so far, toward a debugger on the board (and a gdbserver for a PC):

| Piece | Where |
|---|---|
| `tcc -g` debug data inside the YAFF image (YAFF v6) | `libs/tinycc/source/obj/tccyaff.{h,c}` |
| `strip`, `strip -f FILE` (debug data to a separate file) | `apps/strip`, `man strip` |
| `yaffdump -f` shows a program's debug data or its link | `apps/yaffdump` |
| `ptrace(2)`: stops, breakpoints, registers, memory, ATTACH/INTERRUPT/KILL/DETACH | kernel `sys_ptrace` + `ProcessManager.ptrace_*`, libc `sys/ptrace.h` |
| a traced exec loads the program into RAM | `load_executable_node(.., in_ram)` |
| `ptracetest`: the on-device ptrace test | `apps/ptracetest`, `tests/smoke/debug_test.py` |
| YAFF debug data -> ELF debug file for gdb/readelf on the PC | `libs/tinycc/scripts/yaff_debug_to_elf.py` |

Signals (minimal: no handlers) and Ctrl-C: see "Signals" below.

Not there yet: single-step (`ENOSYS`; a debugger steps with breakpoints),
breakpoints in code that stays in flash (shared libraries -- needs the FPB),
watchpoints, a gdbserver, and the debugger itself.

## Debug data

A `-g` link appends a `YDBG` blob to the image, after everything the loader
reads: `YaffHeader.debug_offset` / `debug_length`. The loader never reads it --
a RAM copy of the image stops at `debug_offset` -- so a `-g` program runs as it
is and costs only file space. The blob holds DWARF (`.debug_*`), the full
symbol table (statics too; the image keeps only exports) and the image's
region map, with `Elf32_Shdr`-shaped section headers. The format is documented
at `YaffDebugHeader` in `tccyaff.h`.

Addresses in it are link-time module offsets (`.text` at 0). At run time the
code sits at the image's code base and the data region at the process's data
base; `/proc/<pid>/maps` gives both.

```sh
tcc -g -o prog prog.c
strip -f prog.debug prog     # prog keeps a .yaff_debuglink naming prog.debug
yaffdump -f prog             # -> prog.debug
```

`strip -f` writes the image's CRC-32 into both files, so a debugger can tell
a stale debug file from the right one.

On the PC:

```sh
libs/tinycc/scripts/yaff_debug_to_elf.py prog.debug prog.elf
arm-none-eabi-readelf --debug-dump=decodedline prog.elf
```

## Code in RAM

Programs in the romfs run in place from flash (XIP), where a breakpoint cannot
be written. A process that called `ptrace(PTRACE_TRACEME, 0, 0, 0)` (in a
vfork child, before execve) has its next exec copy the image into RAM instead:
a private copy, kept out of the loader's shared-text cache. Its shared
libraries (`libc.so`, ...) still run in place -- breaking inside them will need
the FPB hardware breakpoints, or a RAM path for libraries.

## ptrace

`sys/ptrace.h` has the requests, with Linux's numbers and register layouts
(`struct user_regs`, `struct user_vfp`). In short:

- `PTRACE_TRACEME` (the parent traces the caller) and `PTRACE_ATTACH` (only a
  descendant of the caller). A tracee stops, and its tracer's `waitpid`
  reports `WIFSTOPPED` with `SIGTRAP` at exec and at a breakpoint, `SIGILL`,
  `SIGSEGV`, `SIGBUS` or `SIGFPE` at a fault (instead of being killed), and
  `SIGSTOP` after ATTACH or `PTRACE_INTERRUPT`.
- The breakpoint is `UDF #1` (`0xde01`, `YASOS_PTRACE_BREAKPOINT`); pc points at
  it. Plant it with `PTRACE_POKETEXT`, put the instruction back before `CONT`.
  Take code addresses from the symbol table plus the tracee's `.text` base
  (`/proc/<pid>/maps`): a function pointer on YasOS is the address of a
  per-process yasld thunk (two literal loads, then the callee's GOT base and
  its address at +12), not of the code.
- `GETREGS`/`SETREGS`, `PEEKUSER`/`POKEUSER`, `GETVFPREGS`/`SETVFPREGS`,
  `PEEKTEXT`/`PEEKDATA` (the tracee's pages and the read-only image),
  `POKETEXT`/`POKEDATA` (its pages only), `CONT`, `DETACH`, `KILL`.
- Minimal signals: a signal passed to `CONT`/`DETACH` kills the tracee with
  it, `KILL` is `SIGKILL`, and the exit reports `WIFSIGNALED`.

How a stop works: the stop is decided where the process's context is not
stored yet -- the HardFault handler (`ptrace_trap`), exec (`finish_exec`), a
syscall return (`syscall_return_ptrace_check`) -- and only marked pending; the
context switch stores the registers, and `Process.settle_ptrace_stop` (from
`release_from_core`) then makes the stop visible and wakes the tracer. The
registers a tracer reads are the stored exception frame
(`HardwareProcess.read_user_registers`). A stop asked from outside is taken
when the tracee is switched out in user code, or when its system call
returns; a tracee blocked in a system call stops only once that call returns.

When the tracer exits, its tracees are detached and resume. A tracer that is
not the parent still gets the tracee's exit through `waitpid`.

## Signals

There are no signal handlers. What exists:

- `kill(pid, sig)` for SIGHUP, SIGINT, SIGQUIT, SIGKILL, SIGUSR1/2, SIGPIPE,
  SIGALRM, SIGTERM (0 checks the pid): a traced process stops with the signal
  (its tracer decides); otherwise the process ends -- resumed at `_exit`, its
  exit `WIFSIGNALED` -- unless it ignores the signal or installed a handler
  (`sigaction` reaches the kernel: SIG_IGN stays across exec, a handler is
  recorded, never called, and reset by exec). SIGKILL always ends it. pid 1
  and kernel processes take none.
- Ctrl-C: while the console's termios has ISIG (the default; raw mode clears
  it), the UART's receive path hands ^C to the kernel, which sends SIGINT to
  the foreground program: from the root shell down the chain of processes
  waiting in `waitpid` for one process, the one at the end. The QEMU boards'
  UART has no receive interrupt; the tick polls it.
- A process blocked in the console read, a pipe, `nanosleep`, `poll` or
  `waitpid` on a child is cut short (EINTR), so a signal reaches it.
- toysh: an interactive shell ignores SIGINT; the programs it starts get the
  default (apps/toybox, `sh_exec_vfork`).
