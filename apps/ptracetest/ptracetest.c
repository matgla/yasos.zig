/*
 Copyright (c) 2026 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

/* ptracetest: exercise the kernel's ptrace on copies of this program.
 *
 * Run with no arguments, it traces itself re-executed in a child mode and
 * prints one "ok"/"not ok" line per check, then PTRACE_TEST PASS or FAIL
 * (exit status 0 or 1).  The child is the same romfs binary, which a traced
 * exec loads into RAM: the breakpoint test plants UDF #1 in that copy, at the
 * offset `target` has in this (in-place) one.  tests/smoke/debug_test.py runs
 * it on QEMU; it runs on a board just as well.
 */

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures;
static int checks;

static void check(int ok, const char *what) {
  ++checks;
  if (!ok) ++failures;
  printf("%s %d - %s\n", ok ? "ok" : "not ok", checks, what);
}

__attribute__((noinline)) int target(int x) {
  return 2 * x;
}

static char self[256];

/* vfork a child running this program as `mode`, traced from its exec when
 * `traced`.  Returns its pid. */
static pid_t spawn_with_stdin(const char *mode, int traced, int stdin_fd) {
  char *args[3];
  pid_t pid;
  args[0] = "ptracetest";
  args[1] = (char *)mode;
  args[2] = NULL;
  pid = vfork();
  if (pid == 0) {
    if (stdin_fd >= 0 && dup2(stdin_fd, 0) < 0) _exit(125);
    if (traced && ptrace(PTRACE_TRACEME, 0, 0, 0) != 0) _exit(126);
    execv(self, args);
    _exit(127);
  }
  return pid;
}

static pid_t spawn(const char *mode, int traced) {
  return spawn_with_stdin(mode, traced, -1);
}

/* The load address of a process's own .text, from /proc/<pid>/maps: its first
 * line is the executable's. */
static uintptr_t text_base(pid_t pid) {
  char path[32], line[160], name[64], section[16];
  unsigned long address = 0, size = 0;
  FILE *f;
  if (pid) snprintf(path, sizeof(path), "/proc/%d/maps", (int)pid);
  else strcpy(path, "/proc/self/maps");
  f = fopen(path, "r");
  if (!f) return 0;
  while (fgets(line, sizeof(line), f)) {
    if (sscanf(line, "%63s %15s %lx %lx", name, section, &address, &size) == 4 && !strcmp(section, ".text")) break;
    address = 0;
  }
  fclose(f);
  return address;
}

/* Where `target`'s code is in this process.  A function pointer on YasOS is
 * the address of a per-process thunk (16 bytes: two literal loads, then the
 * callee's GOT base and its address) unless it already points into .text;
 * a debugger takes the address from the symbol table instead. */
static uintptr_t code_of(int (*fn)(int)) {
  uintptr_t p = (uintptr_t)fn & ~(uintptr_t)1;
  uintptr_t base = text_base(0);
  if (p >= base && p - base < 0x400000) return p;
  return *(const uint32_t *)(p + 12) & ~(uintptr_t)1;
}

static int stopped_with(int status, int signal) {
  return WIFSTOPPED(status) && WSTOPSIG(status) == signal;
}

static void test_breakpoint(void) {
  struct user_regs regs;
  int status = 0;
  long word, original;
  uintptr_t offset, bp, aligned;
  pid_t pid = spawn("child-bp", 1);

  check(pid > 0 && waitpid(pid, &status, 0) == pid && stopped_with(status, SIGTRAP), "stops with SIGTRAP at exec");
  check(ptrace(PTRACE_GETREGS, pid, 0, &regs) == 0 && regs.uregs[15] != 0, "GETREGS at the exec stop");

  /* The same code at the same offset in the child's RAM copy. */
  offset = code_of(target) - text_base(0);
  bp = text_base(pid) + offset;
  aligned = bp & ~(uintptr_t)3;
  check(text_base(pid) != text_base(0), "the traced exec runs from a copy");
  errno = 0;
  original = ptrace(PTRACE_PEEKTEXT, pid, (void *)aligned, 0);
  printf("# text at 0x%lx here, 0x%lx in the tracee; target at +0x%lx, word 0x%lx (errno %d)\n",
         (unsigned long)text_base(0), (unsigned long)text_base(pid), (unsigned long)offset, (unsigned long)original,
         errno);
  check(errno == 0 && original == *(const long *)(code_of(target) & ~(uintptr_t)3),
        "PEEKTEXT reads the tracee's copy of the code");

  word = original;
  if (bp & 2) word = (word & 0x0000ffffL) | ((long)YASOS_PTRACE_BREAKPOINT << 16);
  else word = (word & (long)0xffff0000) | YASOS_PTRACE_BREAKPOINT;
  check(ptrace(PTRACE_POKETEXT, pid, (void *)aligned, (void *)word) == 0, "POKETEXT plants a breakpoint");

  check(ptrace(PTRACE_CONT, pid, 0, 0) == 0, "CONT");
  check(waitpid(pid, &status, 0) == pid && stopped_with(status, SIGTRAP), "stops with SIGTRAP at the breakpoint");
  check(ptrace(PTRACE_GETREGS, pid, 0, &regs) == 0 && regs.uregs[15] == bp, "pc is the breakpoint");
  check(regs.uregs[0] == 42, "r0 holds the argument");
  errno = 0;
  check(ptrace(PTRACE_PEEKUSER, pid, (void *)(15 * 4), 0) == (long)bp && errno == 0, "PEEKUSER reads pc");

  /* Put the instruction back, change the argument, and let it finish. */
  check(ptrace(PTRACE_POKETEXT, pid, (void *)aligned, (void *)original) == 0, "POKETEXT restores the code");
  regs.uregs[0] = 7;
  check(ptrace(PTRACE_SETREGS, pid, 0, &regs) == 0, "SETREGS");
  check(ptrace(PTRACE_CONT, pid, 0, 0) == 0, "CONT past the breakpoint");
  check(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 14,
        "the changed argument reached the result");
}

static void test_fault_and_kill(void) {
  struct user_regs regs;
  struct user_vfp fp;
  int status = 0;
  pid_t pid = spawn("child-fault", 1);
  check(pid > 0 && waitpid(pid, &status, 0) == pid && stopped_with(status, SIGTRAP), "fault child stops at exec");
  check(ptrace(PTRACE_GETVFPREGS, pid, 0, &fp) == 0, "GETVFPREGS");
  check(ptrace(PTRACE_CONT, pid, 0, 0) == 0, "CONT into the fault");
  check(waitpid(pid, &status, 0) == pid && stopped_with(status, SIGILL), "an undefined instruction stops it with SIGILL");
  errno = 0;
  check(ptrace(PTRACE_GETREGS, pid, 0, &regs) == 0 &&
            (ptrace(PTRACE_PEEKTEXT, pid, (void *)(regs.uregs[15] & ~3UL), 0) >> ((regs.uregs[15] & 2) * 8) & 0xffff) ==
                0xde02,
        "pc is the faulting UDF #2");
  check(ptrace(PTRACE_KILL, pid, 0, 0) == 0, "KILL");
  check(waitpid(pid, &status, 0) == pid && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL,
        "the killed tracee reports SIGKILL");
}

static void test_attach_interrupt(void) {
  struct user_regs regs;
  int status = 0;
  pid_t pid = spawn("child-spin", 0);
  check(pid > 0 && ptrace(PTRACE_ATTACH, pid, 0, 0) == 0, "ATTACH to a running child");
  check(waitpid(pid, &status, 0) == pid && stopped_with(status, SIGSTOP), "it stops with SIGSTOP");
  check(ptrace(PTRACE_GETREGS, pid, 0, &regs) == 0, "GETREGS after ATTACH");
  check(ptrace(PTRACE_CONT, pid, 0, 0) == 0, "CONT");
  errno = 0;
  check(ptrace(PTRACE_PEEKDATA, pid, (void *)regs.uregs[13], 0) == -1 && errno == ESRCH,
        "a running tracee cannot be read (ESRCH)");
  check(ptrace(PTRACE_INTERRUPT, pid, 0, 0) == 0, "INTERRUPT");
  check(waitpid(pid, &status, 0) == pid && stopped_with(status, SIGSTOP), "it stops again");
  errno = 0;
  ptrace(PTRACE_PEEKDATA, pid, (void *)regs.uregs[13], 0);
  check(errno == 0, "PEEKDATA of its stack");
  errno = 0;
  check(ptrace(PTRACE_PEEKDATA, pid, (void *)0xE000ED00UL, 0) == -1 && errno == EIO, "kernel memory is EIO");
  check(ptrace(PTRACE_SINGLESTEP, pid, 0, 0) == -1 && errno == ENOSYS, "SINGLESTEP is ENOSYS");
  check(ptrace(PTRACE_KILL, pid, 0, 0) == 0, "KILL");
  check(waitpid(pid, &status, 0) == pid && WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL, "it reports SIGKILL");
  errno = 0;
  check(ptrace(PTRACE_ATTACH, 1, 0, 0) == -1 && errno == EPERM, "ATTACH to a non-descendant is EPERM");
}

static int killed_by(int status, int signal) {
  return WIFSIGNALED(status) && WTERMSIG(status) == signal;
}

/* Signals: no handlers, so a tracee stops with one and an untraced process
 * that does not ignore it ends; a blocked system call (sleep, a pipe read) is
 * cut short to get there. */
static void test_signals(void) {
  int status = 0, fds[2];
  pid_t pid = spawn("child-sleep", 1);
  check(pid > 0 && waitpid(pid, &status, 0) == pid && stopped_with(status, SIGTRAP), "sleeper stops at exec");
  check(ptrace(PTRACE_CONT, pid, 0, 0) == 0, "CONT into a long sleep");
  usleep(100000);
  check(ptrace(PTRACE_INTERRUPT, pid, 0, 0) == 0, "INTERRUPT a tracee asleep in nanosleep");
  check(waitpid(pid, &status, 0) == pid && stopped_with(status, SIGSTOP), "the sleep is cut short and it stops");
  ptrace(PTRACE_KILL, pid, 0, 0);
  waitpid(pid, &status, 0);

  pid = spawn("child-spin", 1);
  waitpid(pid, &status, 0);
  ptrace(PTRACE_CONT, pid, 0, 0);
  check(kill(pid, SIGINT) == 0, "kill SIGINT to a running tracee");
  check(waitpid(pid, &status, 0) == pid && stopped_with(status, SIGINT), "the tracee stops with SIGINT");
  check(ptrace(PTRACE_CONT, pid, 0, (void *)SIGINT) == 0, "CONT with the signal");
  check(waitpid(pid, &status, 0) == pid && killed_by(status, SIGINT), "and it ends by SIGINT");

  pid = spawn("child-spin", 0);
  usleep(50000);
  check(kill(pid, SIGTERM) == 0 && waitpid(pid, &status, 0) == pid && killed_by(status, SIGTERM),
        "SIGTERM ends a spinning process");

  pid = spawn("child-sleep", 0);
  usleep(100000);
  check(kill(pid, SIGINT) == 0 && waitpid(pid, &status, 0) == pid && killed_by(status, SIGINT),
        "SIGINT ends a process asleep");

  check(pipe(fds) == 0, "pipe");
  pid = spawn_with_stdin("child-read", 0, fds[0]);
  usleep(100000);
  check(kill(pid, SIGTERM) == 0 && waitpid(pid, &status, 0) == pid && killed_by(status, SIGTERM),
        "SIGTERM ends a process blocked reading a pipe");
  close(fds[0]);
  close(fds[1]);

  pid = spawn("child-ignore", 0);
  usleep(100000);
  check(kill(pid, SIGINT) == 0 && waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 5,
        "a process ignoring SIGINT runs on to its own exit");

  errno = 0;
  check(kill(1, SIGTERM) == -1 && errno == EPERM, "pid 1 takes no signals");
}

static void test_detach(void) {
  int status = 0;
  pid_t pid = spawn("child-exit", 1);
  check(pid > 0 && waitpid(pid, &status, 0) == pid && stopped_with(status, SIGTRAP), "stops at exec");
  check(ptrace(PTRACE_DETACH, pid, 0, 0) == 0, "DETACH");
  check(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 7, "it runs to its own exit");
}

int main(int argc, char **argv) {
  if (argc > 1) {
    volatile unsigned spins = 0;
    int (*volatile call)(int) = target;
    if (!strcmp(argv[1], "child-bp")) return call(42) & 0xff;
    if (!strcmp(argv[1], "child-fault")) {
      __asm__ volatile("udf #2");
      return 0;
    }
    if (!strcmp(argv[1], "child-spin"))
      for (;;) ++spins;
    if (!strcmp(argv[1], "child-exit")) return 7;
    if (!strcmp(argv[1], "child-sleep")) {
      sleep(30);
      return 0;
    }
    if (!strcmp(argv[1], "child-read")) {
      char c;
      return (int)read(0, &c, 1) + 50;
    }
    if (!strcmp(argv[1], "child-ignore")) {
      signal(SIGINT, SIG_IGN);
      usleep(400000);
      return 5;
    }
    return 100;
  }

  {
    ssize_t n = readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (n <= 0) strcpy(self, "/usr/bin/ptracetest");
    else self[n] = 0;
  }
  test_breakpoint();
  test_fault_and_kill();
  test_attach_interrupt();
  test_detach();
  test_signals();
  printf("PTRACE_TEST %s (%d of %d checks failed)\n", failures ? "FAIL" : "PASS", failures, checks);
  return failures ? 1 : 0;
}
