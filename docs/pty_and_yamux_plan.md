# PTY + yamux — plan

**Status (2026-08-12): planned, nothing implemented.** No code has been written.
Part 0 below is a spike that must run green before any of the rest is started,
because it tests an assumption the whole design rests on.

Three kernel pieces, then one small app: a **PTY** device, a **`poll()`**
syscall, and `apps/yamux`.

This plan **supersedes the kernel-side mux design in `docs/virtual_terminals.md`**
— see "Relationship to virtual_terminals.md" below, which records why that
design was examined and rejected rather than merely bypassed. That document
should be updated, not silently left in place, when this work lands.

> **Finding that shaped this plan: `nanosleep()` does not sleep.**
> `sys_nanosleep` → `time.sleep_ms` → `Process.sleep_for_us`
> (`source/kernel/process.zig`) is a **yield-spin**, not a scheduler deadline:
>
> ```zig
> const deadline = hal.time.get_time_us() +| us;
> while (true) {
>     const now = hal.time.get_time_us();
>     if (now >= deadline) return;
>     if (deadline - now >= tick_us) hal.irq.trigger(.pendsv);
> }
> ```
>
> The process stays `Ready` throughout — `reevaluate_state`
> (`process.zig:630-647`) only reports `Blocked` for `waiting_for` or
> `_blocked_by`, and neither is set here — so it is rescheduled, and burns a
> quantum, over and over until the deadline passes. There is **no deadline-based
> wake anywhere in the kernel**.
>
> Two consequences. First, the obvious "poll with `O_NONBLOCK` and
> `nanosleep(20ms)` between passes" design for yamux would not idle at all; it
> would sit permanently runnable, competing with every other process. That is
> why `poll()` is in this plan rather than filed as a later cleanup. Second, the
> loop used to spin on the *millisecond system tick*, so `sleep_for_us(500)`
> computed `500/1000 == 0` and returned immediately — **every sub-millisecond
> sleep in the tree was a no-op**. That part is **fixed** (2026-08-12): the loop
> waits on the microsecond wall clock, and spins the last tick out rather than
> yielding it, because a yield cannot resolve a sub-tick deadline. Regression
> test: `Process.ShouldSleepForSubMillisecondDelay`. The resolution is fixed;
> the *yield-spin* is not, and that is still what `wake_at` below is for.

## Context

yasos has one console: a single UART. Everything interactive — the shell, `vi`,
`textvaders`, a long `tcc` build — competes for it, and there is no way to leave
one running while doing something else. The goal is a tmux-like multiplexer:
several independent shell windows over that one UART, switched with a prefix
key.

The blocker is that a window needs to *be a terminal*. Today the only way for
one process to feed another's stdin is a pipe, and a pipe is not a tty:
`isatty()` is true only for `FileType.CharDevice`
(`source/kernel/interrupts/syscall_handlers.zig:312`), and toybox `sh` gates its
whole interactive path on it — `TT.options |= FLAG_i` requires `isatty(0)`
(`apps/toybox/toys/pending/sh.c:4973`), and the line editor `read_line_tty` is
only reached when `isatty(0)` (`apps/toybox/toys/pending/sh.c:4305`). On a pipe a
window would get no prompt, no line editing, and no full-screen apps.

So this lands in two parts: a **PTY character device in the kernel**, reached
through `/dev/ptmx` and `/dev/pts/N`, then a **small userspace app** on top of
it. The pty is what makes windows behave like terminals; the app is deliberately
thin.

### Relationship to `docs/virtual_terminals.md`

That document designs the mux *inside the kernel*: a `VtDriver` owning
`/dev/tty0`-`ttyN`, a `VtMux` singleton intercepting `Ctrl+Alt+N` in the UART
read path, per-VT process groups suspended and resumed on switch, and a `chvt`
command. Pseudoterminals are its §13.2 and tmux-like panes its §13.1, both filed
as *future extensions*.

This plan **does §13.2 first, with its exact device naming** (`/dev/ptmx` →
master, `/dev/pts/0` → slave, per that document's goal 6, "Linux-compatible
naming") and lets it subsume the rest: the kernel gets a generic PTY and **no
switching policy at all**, and the mux becomes an ordinary program.

**Two structural findings rule the VT design out**, and they are the reason this
is a replacement rather than a reordering:

1. **You could not switch away from a busy VT.** The RX interrupt
   (`on_uart_rx_irq` → `drain_rx`,
   `hal/source/raspberry/rp2350/source/uart.zig:154-176`) only moves bytes from
   the hardware FIFO into a 4096-byte HAL ring. **It never interprets them**, and
   nothing consumes that ring except `getc`/`read`/`flush` — that is, a process
   calling `read()`. So while VT0 runs a `tcc` build and does not read stdin,
   `Ctrl+Alt+2` accumulates in the ring unnoticed until the build finishes. That
   kills the central use case: leave a build running and go do something else.
   `chvt` does not rescue it — it can only be typed at a prompt, which is the
   same restriction with worse ergonomics.
2. **That cannot be fixed in the interrupt.** `source/kernel/sync/locks.zig:16-33`
   states the constraint outright: *"no filesystem or device I/O may ever be
   initiated from handler context"* — ranks put sleeping mutexes outside
   spinlocks, so waking a VT's blocked reader (which takes `proctable_lock`) from
   the RX handler is a rank inversion that panics. Scanning and routing input
   therefore needs a kernel thread owning the UART — at which point yamux has
   been written *inside* the kernel, with none of userspace's containment and all
   of the same complexity.

Three lesser points reinforce it:

- Switching, scrollback, key bindings and window lists are policy. In the VT
  shape they live in the kernel and cost kernel RAM permanently (its §6 budgets
  ~4.3 KB of ring buffers whether or not anyone uses a second terminal); as an
  app they cost nothing when yamux is not running. Its 512 B of output per VT is
  about six lines — not usable scrollback.
- A PTY is reusable — it is what a future `script(1)`, a serial-over-network
  shell, or an expect-style test harness needs. A VT mux is only ever a VT mux.
- Its §4.2, "an inactive VT's process group is suspended", is a scheduler
  feature this kernel does not have. A pty needs none of it: back-pressure on a
  full output ring blocks a background window's writer for free.

The VT design's one genuine advantage was needing no polling, since the kernel
routes bytes as they flow. Part 2 takes that advantage rather than the design
that carried it.

The unfinished stub `source/kernel/drivers/vt/vt_file.zig` (`read`/`write`
return 0, referenced only by a commented-out `initialize_virtual_terminals` at
`source/main.zig:429`) is dead — it appears in no `tests.zig`, so it is compiled
into no test binary, and its `!usize` returns do not even match the `IFile`
vtable's `isize`. Delete it as part of this work.

## Part 0 — spike first (blocks everything)

`apps/prun/main.c` states in its header that spawning `/bin/sh` from a `vfork()`ed
child HardFaults this kernel. yamux does exactly that, N times, so this must be
settled before anything is built.

The evidence says that comment is **stale**: HEAD (`2d2acc8`) fixed a vfork bug
where the child ran on the kernel's stack pointer 848 bytes below its caller's
frame, so it "branched through a garbage PLT descriptor and took a HardFault at
0xfffffffe" — precisely the fault prun described.

**Spike:** ~20 lines that `vfork()`, `dup2()` a pipe over fd 0/1/2 and
`execve("/bin/sh", {"sh", NULL}, envp)`, then write `echo hi\n` and read it back,
run under QEMU. If it works, proceed and correct prun's comment. If it does not,
the kernel spawn path is the first thing to fix and the rest of this plan waits
on it.

## Part 1 — kernel PTY

### 1a. The device: `source/kernel/fs/pty.zig`

Modelled directly on `source/kernel/fs/pipe.zig`, which already has every
mechanism this needs: a ring buffer, open-end counts that make EOF decidable,
and the `prepare_wait`/`wait`/`post` blocking idiom (`pipe.zig:151-179`) under a
`spin_irq` leaf lock.

A `Pty` is **two** of those rings plus a line discipline:

```
Pty {
    _input:   ring   // master writes -> slave reads
    _output:  ring   // slave writes  -> master reads
    _canon:   []u8   // line under assembly in canonical mode
    _termios: c.termios
    _winsize: c.struct_winsize   // defaults 24x80, as UartFile reports
    _index:   u8                 // its slot, i.e. the N in /dev/pts/N
    _locked:  bool = true        // cleared by TIOCSPTLCK; see 1c
    _masters, _slaves, _ends: u32
    _input_available, _input_space, _output_available, _output_space: u8
}
```

Capacity 1024 per direction (2 KiB of kernel heap per pair; `Pipe.capacity` is
4096, but a console line is short and there is one pair per window).

**Input path — `write_from_master`.** All input processing happens here, as on a
real tty, which keeps the slave's `read` a plain ring read:

- `ICRNL`/`IGNCR`/`INLCR` translation.
- `ICANON`: accumulate into `_canon`; `VERASE`/`VKILL` erase and, with `ECHOE`,
  echo `"\b \b"`; on `\n` (or `VEOL`) flush the whole line into `_input` and post
  `_input_available`. Nothing reaches the slave before a newline — that is the
  point of canonical mode.
- `!ICANON`: bytes go straight to `_input`.
- `ECHO`: append the byte to `_output` via the output path, so an echoed `\n`
  gets `ONLCR`. **Echo is best-effort and dropped when `_output` is full** — it
  must be, or a master write that echoes into a full output ring would block
  waiting for the only process that could drain it: itself.

**Output path — `write_from_slave`.** `OPOST|ONLCR` translates `\n` → `\r\n`,
then appends to `_output`. Not optional decoration: toybox restores cooked mode
before running each command (`apps/toybox/lib/tty.c:110-140`), so without `ONLCR`
every command's output stairsteps.

**Reads.** Slave reads `_input` honouring `VMIN` and `O_NONBLOCK`, EOF when
`_masters == 0` and empty. Master reads `_output` raw, EOF when `_slaves == 0`
and empty — that EOF is how yamux learns a window's shell exited. `VMIN=1`
blocking is the case toybox's `scan_key` depends on.

**Copy `Pipe`'s blocking, not `UartFile`'s.** `UartFile.read` does not block at
all — when the UART is not readable it `continue`s
(`source/kernel/drivers/uart/uart_file.zig:108-115`), busy-spinning through the
process's whole timeslice. Use `prepare_wait`/`wait`/`post` instead, and chunk
transfers at 512 bytes as `Pipe.chunk` does (`pipe.zig:76-81`) to bound how long
a `spin_irq` section masks interrupts, against a console that overruns in tens of
microseconds.

**Where this must differ from `UartFile` on purpose** — its behaviour is
UART-pragmatic, not POSIX, and copying it would propagate the bugs:

| | `UartFile` | PTY should |
|---|---|---|
| non-blocking read, no data | returns **0** (`uart_file.zig:110`) — indistinguishable from EOF | return **-1**, as `Pipe` does (`pipe.zig:198`) |
| `TCGETS` | fabricates the struct, dropping `c_iflag`, `c_cflag`, `c_cc[VINTR..VKILL]` (`uart_file.zig:362-384`) | store a real `c.termios` and hand it back verbatim, so `tcgetattr`→modify→`tcsetattr` round-trips |
| canonical | inferred from `c_oflag == 0` (`uart_file.zig:343-347`) | key off `c_lflag & ICANON`, and output processing off `c_oflag & OPOST` |
| `VMIN` | dead outside raw mode (`uart_file.zig:111`) | honoured whenever `!ICANON` |
| `ioctl(arg == NULL)` | -1 for every command (`uart_file.zig:335`) | reject only where an argument is required |

Keying raw off `ICANON` stays compatible with `libs/yasos_curses`, whose `raw()`
clears `ICANON|ECHO` *and* zeroes `c_oflag` (`libs/yasos_curses/curses.c:584-599`)
— both halves land correctly here.

**Canonical mode stays deliberately small.** `UartFile` carries an ESC/CSI state
machine for arrow keys and mid-line insertion (`uart_file.zig:167-278`); the PTY
does not need it, because every consumer wanting real line editing (toybox `sh`,
`vi`) switches to **raw** mode and edits itself. Canonical mode here is:
accumulate, `VERASE`/`VKILL`, echo, flush on newline.

Lifting `UartFile`'s discipline into something shared is **not in scope**: it is
written as re-entrant pulls from the device rather than a per-byte state machine,
so sharing means inverting it into `feed(byte) -> {consumed, erase,
line_complete}` and re-validating ~20 existing tests. Worth doing later; doing it
here puts a risky refactor of the live console on the critical path of a new
feature.

**Never take the console lock.** `console_acquire` panics on recursive
acquisition and is per-core (`uart_file.zig:52-67`); it serialises bytes onto the
one physical wire. PTY echo goes into a ring, not a wire.

### 1b. `PtyFile` (the two ends)

One `interface.DeriveFromBase(IFile, ...)` with an `_is_master` flag, exactly as
`PipeFile` uses `_writable` (`pipe.zig:288`).

- `filetype()` → `.CharDevice` on **both** ends. This is what makes
  `isatty(slave)` true, the entire reason the kernel work exists.
- `ioctl`: `TCGETS`, `TCSETS`/`TCSETSW`/`TCSETSF` (`TCSETSF` also flushes
  `_input` and `_canon` — toybox enters raw mode with `TCSAFLUSH`),
  `TIOCGWINSZ`/`TIOCSWINSZ` over the shared `_winsize`, `FIONREAD` for the
  caller's own side, `TIOCGPTN` and `TIOCSPTLCK` on the master, and
  `GetMemoryMappingStatus` → false.
- `fcntl`: `F_GETFL`/`F_SETFL` for `O_NONBLOCK`, copied from `pipe.zig:382` —
  including its `@bitCast` + `@truncate` decode; `UartFile`'s `@intCast` version
  can panic on a pointer-shaped value.
- `__clone`: bump the matching end count. Non-negotiable — this is the vfork
  fd-table copy, and getting it wrong reports EOF while the real peer is alive
  (`pipe.zig:310` documents the same trap). Omit it and the interface layer does
  a shallow memcpy of the struct.
- `delete`: drop the count, post the counterpart's tokens **outside the lock**,
  destroy the pty and clear its slot at zero ends (`pipe.zig:266-284` is the
  template).
- `seek`/`tell`/`truncate` → `IllegalSeek`/`-1`/`InvalidArgument`, as `PipeFile`.

### 1c. Reaching them: `/dev/ptmx` and `/dev/pts/N`

A fixed table of `pty_count = 8` slots (`?*Pty`) guarded by `pty_lock`. The slot
index *is* the N in `/dev/pts/N`, reported by `TIOCGPTN`.

**`/dev/ptmx` — a driver, no new syscall.** `open()` resolves through
`DriverFs.get` → `driver.interface.node()`
(`source/kernel/drivers/driverfs.zig:105`), and `node()` is already expected to
hand back a *fresh* object per call — `UartDriver.node()` returns
`self._node.clone()`. So a `PtmxDriver` whose `node()` allocates a new `Pty`,
claims a slot, and returns a **master** `PtyFile` node gives
open-with-side-effects for free, with no change to driverfs, the VFS, or the
syscall table.

Two consequences, both checked against the code:

- `stat("/dev/ptmx")` and `access()` also call `get()`, then `defer node.delete()`
  (`driverfs.zig:169`). So `ls -l /dev` creates and immediately destroys a pty
  per stat. Correct — provided destroy-on-last-end is right — and a good forcing
  function for it. Cover it with a test.
- `ls /dev` does **not**: `DriverFsIterator.next` returns the map key only and
  never calls `node()` (`source/kernel/drivers/driverfs_iterator.zig:38`).

**`/dev/pts/N` — a small filesystem.** `DriverFs.get` does a single flat map
lookup on the whole remaining path and never walks components, so a `"pts/0"` key
is not an option. Mount a `PtsFs` at `/dev/pts` instead; the VFS's
`find_longest_matching_point` then routes `/dev/pts/0` → `PtsFs.get("0")`.

Model it on procfs, which solves the identical problem — a directory whose
contents are live kernel objects: `source/kernel/process/procfs.zig`,
`source/kernel/process/procfs_directory.zig`, and especially `PidDirectory.get`
(`source/kernel/process/pid_directory.zig:98`), which **synthesizes** nodes on
demand instead of storing them. `PtsFs.get("N")` parses N, takes `pty_lock`, and
returns a *new slave end* on that slot's `Pty` — so multiple opens of the same
`/dev/pts/N` each get their own end sharing one pty, as on Linux. Synthesizing
avoids the add/remove API, the key-ownership problem and the rehash race that a
mutable registry would bring.

`mount_filesystem` requires the mountpoint to already resolve in the parent
(`source/kernel/fs/mount_points.zig:238-240`) — the same reason `build_rootfs.sh`
does `mkdir -p rootfs/proc`. So register a `"pts"` driver in driverfs whose
`node()` returns the **PtsFs root directory**, then mount `PtsFs` at `/dev/pts`
in `initialize_filesystem` (`source/main.zig:440`), right after `/dev` is mounted
at `source/main.zig:532`. One object serves both.

`TIOCSPTLCK` is real, not a stub: `_locked` starts true and `PtsFs.get` refuses a
locked slot, so `unlockpt()` means something and a caller that skips it gets a
clear error rather than silent divergence from POSIX.

### 1d. Supporting kernel edits

- **`check_ioctl_arg` must learn the new pointer ops.** The table at
  `source/kernel/interrupts/syscall_handlers.zig:787-791` is what validates user
  pointers per ioctl, and its own comment says an unlisted pointer op goes
  unvalidated. Add `TIOCSWINSZ` (read, `sizeof(winsize)`), `TIOCGPTN` (write,
  `sizeof(int)`), `TIOCSPTLCK` (read, `sizeof(int)`).
- **New lock rank `pty = 45`**, inserted in the `Rank` enum in
  `source/kernel/sync/locks.zig:120`, immediately after `pipe = 40` and before
  `proctable`. It must sit **below `proctable` (50)**: waking a waiter walks the
  process table, so `enter(.proctable)` would panic with "lock order violation"
  if a `.pty` lock were still held. One global `pty_lock` for all pairs and the
  slot table, per the reasoning at `pipe.zig:58-67` — same-rank nesting is itself
  a panic, so per-pty locks would make any master↔slave nesting fatal.
  - **Cap worth knowing:** `held` is a per-CPU `u16` bitmask, so 16 ranks is a
    hard limit, asserted by `Sync.Locks.RanksAreOrderedAndDense`. There are 14
    today; `.pty` makes 15, leaving one.
  - Do **not** add it to `migrating_ranks` — that set is the sleeping mutexes,
    and a `Ranked` spinlock's bit belongs to the core.
- **Wake outside the lock, always**: shape every read/write/close as
  `{ take pty_lock; mutate; decide who to wake } → drop → post(token)`, with
  `prepare_wait` called *under* the lock and `wait` after releasing it.
- **Delete the dead vt stub** (`source/kernel/drivers/vt/`) and the commented-out
  `initialize_virtual_terminals`.

### 1e. libc (`libs/libc`, a submodule — needs its own commit plus a bump here)

No syscall is added, so **`sys/syscall.h` and `YASOS_SYSCALL_COUNT` are
untouched** and no prebuilt binary's ABI moves. Everything composes over existing
`open`/`ioctl`:

| symbol | implementation |
|---|---|
| `posix_openpt(flags)` | `open("/dev/ptmx", flags)` |
| `grantpt(fd)` | return 0 — there is no permissions model to grant |
| `unlockpt(fd)` | `ioctl(fd, TIOCSPTLCK, &zero)` |
| `ptsname_r(fd, buf, len)` / `ptsname(fd)` | `ioctl(fd, TIOCGPTN, &n)` then format `/dev/pts/%d` |
| `openpty(am, as, name, termp, winp)` | the standard composition of the five above, then `open()` the slave; applies `termp`/`winp` via ioctl |

`libs/libc/pty.h` already exists and is **an empty 0-byte file** — it gets these
declarations; `pty.c` is new. The ioctl numbers are already defined: `TIOCGPTN`
and `TIOCSPTLCK` at `libs/libc/sys/ioctl.h:45-46`, `TIOCSWINSZ` at
`libs/libc/sys/ioctl.h:22`. New `.c` files are picked up by the wildcard in the
libc `Makefile`. Because the `name` argument is now backed by a path that
genuinely exists, `openpty` can carry the real glibc signature with no caveats.

## Part 2 — kernel `poll()`

Without this, yamux has no way to wait on the console and N pty masters at once:
`libs/libc/poll.c:25-28` is a `printf("TODO: Implement poll\n"); return -1;` stub
and neither `poll` nor `select` appears in the syscall enum. The fallback —
non-blocking reads with `nanosleep` between passes — does not work here, for the
reason in the status note above: `nanosleep` is a yield-spin that never leaves
the process `Ready`, so an "idle" yamux would compete for the CPU permanently.

`poll()` is also the piece that makes the kernel VT design's advantage available
without its architecture, and it is reusable by any future program that watches
more than one descriptor.

### 2a. Readiness: a new `IFile` method

Add `poll_mask(self) i16` to `source/kernel/fs/ifile.zig`, returning
`POLLIN`/`POLLOUT`/`POLLHUP` bits for what the file could do *right now*, without
blocking.

- **Default** (regular files, everything not overriding it): `POLLIN|POLLOUT` —
  a regular file is always ready, which is what POSIX says.
- `PtyFile`: readable when its side's ring is non-empty; `POLLHUP` when the
  counterpart count is zero. This is the same state `FIONREAD` and the EOF checks
  already compute, so it is a few lines over existing helpers.
- `PipeFile`: the same, over `_length` and `_readers`/`_writers`.
- `UartFile`: `POLLIN` when `uart.bytes_to_read() > 0`, always `POLLOUT`.

### 2b. Blocking: one shared activity token

Blocking on N descriptors does **not** need per-file waiter lists. `waiting_for`
is a single opaque token (`process.zig:186-189`) and the wake path is a scan
(`wake_all_blocked_on`), so a **single kernel-wide `io_activity` token** is
enough:

- every place that makes a pty, pipe or uart readable posts `io_activity` in
  addition to its own specific token;
- `poll()` re-checks every fd, and if none is ready, does `prepare_wait` on
  `io_activity` **under the same lock that guards the data it just inspected**,
  releases, waits, and re-checks.

Taking the wait decision under that lock is what makes the wake-up
unlose-able — the identical argument `pipe.zig:21-38` makes for its own rings.
It is a thundering herd in principle; with one or two pollers on this system that
is the right trade against a waiter list per file.

**A closing pty end must post it too**, or yamux would sleep through a window's
shell exiting. It already has to post its counterpart's token there
(`pipe.zig:266-284` is the shape); this is one more post on the same path.

### 2c. Timeouts

- `timeout < 0` (block forever) and `timeout == 0` (poll and return) need no new
  machinery and cover everything yamux does — a window's shell exiting is a pty
  EOF, which is an `io_activity` post, so yamux never needs a timer.
- `timeout > 0` does need a deadline wake, which **the kernel does not have**
  (see the status note). Add a `wake_at: ?u64` to `Process`, and check it where
  the scheduler already walks the process table to pick the next one rather than
  adding a second walk to systick. Waking from there is consistent with existing
  practice — PendSV is handler context and already takes `proctable_lock`, a
  `spin_irq` lock; the prohibition is on *sleeping* mutexes and device I/O, not
  on this.

That deadline primitive would also let `nanosleep` become a real sleep, which is
worth doing and is **deliberately not done here** — changing the timing of every
existing `nanosleep` caller does not belong in the same change as a new device.

### 2d. libc and the syscall

Unlike the pty, this *is* a new syscall, so it takes the full checklist:
`poll_context` and `sys_poll` appended to the enum in `libs/libc/sys/syscall.h`
(append only — renumbering breaks prebuilt binaries), `YASOS_SYSCALL_COUNT`
59 → 60 in `libs/libc/sys/syscall_ids.h` (a compile-time typedef ties the two
together), the real `poll()` replacing the stub in `libs/libc/poll.c`, the
dispatch arm and argument-size entry in
`source/kernel/interrupts/system_call.zig`, and the handler. Keep it **out** of
`is_fast_syscall` — it blocks.

`sys_poll` must `uaccess.check` the `pollfd` array for read *and* write (it
writes `revents` back), sized `n * sizeof(struct pollfd)`, with a sane cap on
`n`.

## Part 3 — `apps/yamux`

`apps/yamux/main.c` + `apps/yamux/Makefile` — copy `apps/prun/Makefile`
verbatim; it already builds both the `yaff` binary and the `.elf`. Do **not**
copy `apps/yasvi/Makefile`, which omits the `.elf` and so cannot be symbolicated
from a HardFault. Two one-line registrations in `build_rootfs.sh`:
`build_makefile yamux` in the app list at `build_rootfs.sh:671-688`, and
`rm -rf apps/yamux/build` in the `--clear` block at `build_rootfs.sh:174-201`.
There is no other registry — no Kconfig entry, no `build.zig` change.

```
yamux [-b SCROLLBACK] [-n MAXWINDOWS] [command ...]
```

**Raw ANSI, not `libs/yasos_curses`.** yasos_curses has no cell buffer, no window
clipping (`newwin` stores only `{x,y}`), a no-op `wrefresh`, and
`fsync(STDOUT_FILENO)` on every cursor move. It would cost a 19 KB `.so`
dependency for the three things worth having — the `raw()` termios incantation
(`libs/yasos_curses/curses.c:584-599`), the CPR size probe
(`curses.c:408-474`) and `endwin()`'s restore (`curses.c:382-393`). Lift those
~30 lines and drive ANSI directly.

**Console.** Save fd 0's termios, `cfmakeraw` + `tcsetattr(TCSAFLUSH)`, restore
on *every* exit path via `atexit` — there are no signals to catch, so a missed
path strands the user's console in raw mode. Note yasos_curses sets termios on
fd 0 **and** fd 1 because the UART keeps per-fd state; do the same. Get the size
from `TIOCGWINSZ`, falling back to the CPR probe then 80x24, and push it to each
pty with `TIOCSWINSZ`.

**Spawning a window.** `openpty()`, then the prun recipe (`apps/prun/main.c`),
whose two hard-won constraints apply verbatim: argv/envp must live in **static**
storage (malloc'd memory lands in the kernel heap and uaccess rejects it), and
`environ` must never be passed — `execve` with a local empty env. The child does
only `dup2(slave,0/1/2)`, `close(slave)`, `close(master)`, `execve`,
`_exit(127)`.

**Main loop.** Built on Part 2's `poll()`, so an idle yamux is genuinely
blocked rather than spinning:

```
poll({console, master[0..n]}, -1)   // blocks; no timeout needed
  console readable -> prefix state machine, else forward to active master
  master readable  -> append to that window's scrollback;
                      if active, write(1)
  master POLLHUP   -> that window's shell exited
waitpid(-1, WNOHANG) -> reap
```

Descriptors still get `O_NONBLOCK` — including the masters, since a blocking
master write into a wedged window would freeze the whole console, and a
`poll()`-reported readiness can be stale by the time the read runs. The infinite
timeout is safe because a shell exiting closes its slave end, which is a pty
`POLLHUP` and an `io_activity` post; there is no event yamux can miss by not
having a timer.

`docs/smp_plan.md` measured the per-syscall console path at 20-30 us, so this
also keeps the per-keystroke cost to one wake and one forward rather than a scan
of every window.

**Keys.** Prefix `Ctrl-A`, then: `c` new, `n`/`p` next/prev, `0`-`9` select, `x`
kill, `w` list, `q` quit, `Ctrl-A` literal, `?` help.

**Scrollback** (per window, default 2048 B, `-b`): a byte ring allocated when the
window is created — 4 windows is 8 KiB. On switch: `\033[2J\033[H\033[0m` then
replay. Replay **starts at the first `\n` in the ring**, so it never begins
mid-line or mid-escape-sequence; the leading partial line is dropped rather than
rendered as garbage.

**Known limits, to state in the header comment:** an inactive window's `\e[6n`
cursor query goes unanswered because its output is not forwarded — which is why
`TIOCSWINSZ` matters, it keeps toybox off the probe path
(`apps/toybox/lib/tty.c:65-71`); no status line, no splits, no detach/reattach;
and 8 ptys system-wide.

## Verification

1. **Host unit tests** in `pty.zig`, registered by adding
   `_ = @import("pty.zig");` to `source/kernel/fs/tests.zig:21` — a file in no
   `tests.zig` is never compiled into a test binary, which is exactly why the vt
   stub survived broken.

   ```
   zig build test --summary all
   zig build test -Dtest-filter=Pty     # while iterating
   ```

   Follow the `Pipe` pattern, not the `UartFile` one: build a real pair, unwrap
   with `ends.master.instance.file`, call through `.interface.read(...)`, and
   `defer …delete()` both ends — the runner installs a fresh GPA per test and
   **fails the run on any leak**.

   Cases: bytes carry each way; canonical mode delivers nothing until `\n`;
   `VERASE` erases and echoes `"\b \b"`; `ECHO` on/off; raw passthrough at
   `VMIN=1`; `ONLCR` on output; EOF in both directions; termios round-trip
   through `TCGETS`/`TCSETS` **without losing `c_iflag`/`c_cc`**;
   `TIOCGWINSZ`/`TIOCSWINSZ`; `TCSETSF` flushing pending input; `FIONREAD`;
   `TIOCGPTN` matching the slot; a locked slot refusing `PtsFs.get` until
   `TIOCSPTLCK`; `__clone` keeping the pty alive; echo **dropped** rather than
   blocking when `_output` is full; and open-then-immediately-close freeing the
   slot (the `stat /dev/ptmx` path).

   These terminate without hardware for a specific reason worth preserving:
   `prepare_wait` returns false when the process manager is not initialised
   (`pipe.zig:167-171`) and both paths treat that as "give up rather than park".
   **The PTY's blocking helpers need the same early-out or the host tests will
   hang.**

   For `poll()`, host tests cover the readiness half only — `poll_mask()` on a
   pty/pipe in each state (empty, has data, counterpart gone), and `timeout == 0`
   returning immediately with correct `revents`. The blocking half needs two
   processes and belongs in the smoke test, exactly as `pipe.zig:412-417`
   explains for its own rings.

2. **Smoke test** `tests/smoke/yamux_test.py`, modelled on
   `tests/smoke/vi_test.py` — whose governing rule (its header, lines 18-27) is
   *do not parse the full-screen app's screen*; drive it blind and verify side
   effects. Reuse its `_vi_feed` shape (`session.serial.write(...)`, flush,
   settle sleep, `session._drain_serial_buffer()`), since `write_command`'s echo
   check stops applying once an app owns the terminal.

   Sequence: `ls /dev/pts` before and after; start `yamux`; expect a prompt
   (which alone proves `isatty` and the interactive path); `echo` a marker;
   `Ctrl-A c`; echo a second marker; `Ctrl-A 0` and assert the first marker
   reappears **from scrollback**; `Ctrl-A q`; assert the console is usable and
   unmangled afterwards.

   **The test that matters most** is the one the whole architecture exists for,
   and the one the kernel-VT design could not have passed: start a long-running
   command in window 0 (a `tcc` compile, or `sleep`), switch away from it *while
   it is running*, run something in window 1, switch back and confirm the first
   finished. Add it as a separate case so a regression is unambiguous.

   A third, for `poll()` specifically: confirm an idle yamux is actually idle.
   With yamux sitting at a prompt in the background, a `prun`-driven workload
   should show no meaningful slowdown against the same workload with yamux not
   running — that is the difference between a blocked process and a spinning one,
   and `tests/smoke/prun_scaling_test.py` is the existing instrument for it.

   ```
   ./scripts/run_qemu_smoke.sh --rebuild-rootfs yamux_test.py
   ./scripts/run_qemu_smoke.sh --no-build yamux_test.py -n 0    # iterate, readable output
   ```

   The QEMU runner's default file list is hardcoded (`scripts/run_qemu_smoke.sh:175`)
   and will not pick up a new file, so always name it.

3. **Size**: report `ls -l rootfs/bin/yamux` and the kernel `.text` delta.
   Calibration from the current tree: `prun` 5.7 KB, `textvaders` 9.6 KB, `vi`
   58 KB — 10-25 KB is unremarkable. The rp2350 romfs region is 4 MiB
   (`hal/source/raspberry/rp2350/linker_script.ld:21`) and the image is at
   2.94 MiB, so there is ~1 MiB of headroom.

4. Full existing suites stay green — `tests/smoke/pipe_test.py` and
   `tests/smoke/vfork_test.py` in particular, since this reuses their machinery.

## Order of work

1. Part 0 spike — `vfork` + `execve("/bin/sh")`. Everything below assumes it.
2. `pty.zig` + the `.pty` rank + `check_ioctl_arg` entries, with unit tests.
   Kernel only, fully testable on the host before any device work.
3. `PtmxDriver` + `PtsFs` + the `main.zig` registration and mount.
4. `poll_mask()` on `IFile` and its four implementors, plus `sys_poll` with
   `timeout <= 0`. Independent of the pty and separately testable — a
   pipe-based `poll()` test needs none of parts 2-3.
5. The `wake_at` deadline, for `timeout > 0`. Deliberately last of the kernel
   work: it is the only piece that touches the scheduler, and nothing yamux does
   depends on it, so it can slip without blocking the app.
6. libc — `pty.h`/`pty.c`, the real `poll()`, the syscall enum and
   `YASOS_SYSCALL_COUNT` bump. One commit in the submodule, then bump it here.
7. `apps/yamux` + the two `build_rootfs.sh` lines.
8. Smoke tests (including the switch-away-from-a-busy-window case and the idle
   check), size report, delete the vt stub, update `docs/virtual_terminals.md`.
