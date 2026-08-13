# SMP — plan

> **Two things measured on hardware 2026-08-12, both owed a follow-up.**
>
> 1. **`CONFIG_PROCESS_SMP=n` panics deterministically on this tree.** Four
>    sequential tcc compiles driven through `prun -j1`: three complete, the
>    fourth dies with `kernel heap exhausted: _sbrk(+1412) heap_end=0x20012fe4
>    limit=0x20013000 used=53728B`. Identical on both attempts, always the fourth
>    job. The same four compiles issued as four shell commands complete fine on
>    the same boot, so it is the spawn path rather than the compiles, and the
>    direction is the odd part: SMP=n has *more* heap available than SMP=y (no
>    per-CPU statics) and the SMP=y build runs the same batch repeatedly without
>    trouble. Reads like per-spawn kernel-heap growth that only the single-core
>    build sits close enough to the 76 KiB limit to hit. **Not bisected against
>    pre-SMP history**, so "the SMP work caused it" is unproven — but the
>    single-core configuration is currently broken either way.
> 2. **SMP costs ~48% on the per-syscall console path.** Same tree, same test,
>    only this symbol differs: the shell's per-character command echo (a `read`
>    plus a `write` per character) goes **20.1 us/char at SMP=n to 29.7 us/char
>    at SMP=y**, which is ~14 s over a 4453-test smoke run. The pre-phase-7
>    measurement of the same slope was 19.4 us/char, i.e. the SMP=n number, so
>    this corroborates independently. It does not show up in the compile bucket
>    because a compile is 77% XIP miss stalls and a syscall tax hides inside
>    that; the echo path is nothing but syscalls, so it exposes it. See
>    docs/remote_smoke_speedup_plan.md, "Three more paths checked".
>
> Neither is a reason to hold phase 7 — but the second says the lock/entry cost
> is now measurable, and there is an instrument for it
> (`tests/smoke/prun_scaling_test.py`, the round-trip anatomy section).

**Status (2026-08-11):** **phases 0-5 are complete, and core 1 now boots on both
targets.** `CONFIG_PROCESS_SMP=y` on `mps3-an524` and on `pimoroni_pico_plus2`;
on each, core 1 boots, passes a two-core mutual-exclusion test and parks — see
[Core 1 on QEMU](#core-1-on-qemu-mps3-an524) and
[Core 1 on the RP2350](#core-1-on-the-rp2350). What is left of phase 6 is the
doorbell IPI and two diagnostic globals, none of which a parked core reaches.
Apart from those two sections the prose below is the phases 0-5 record.

Every structure the
inventory names as needing synchronization before a second core starts now has
it: the kernel heap, page pool, pid map, process table, mount tree, filesystem,
block device, loader tables and console, plus atomic refcounts throughout and a
seqlock for the clock. `block_context_switch` is gone -- all 37 sites classified
and converted, the alias deleted, a CI grep guarding it. Nine of the twelve
named locks exist; the three that do not are phase-6, -7 and -9 work by nature
(see below).

What stood between phases 0-5 and core 1 was therefore **phase 6 itself**, not
more of this — and on QEMU that step has now been taken.
This document is the design and the work breakdown. Its centre of gravity is
[the synchronization inventory](#the-synchronization-inventory) — the list of
every place in the tree that needs synchronization and the mechanism chosen for
each, because that list, not the core-1 bring-up, is the actual project.

| Phase | State |
|---|---|
| 0. Atomics + spinlocks (LDAEX/STLEX) | **done** — the ranked lock types carry the granule themselves |
| 1. Per-CPU state, `preempt_disable()` | **done for phases 0-5**; the rest are phase-6 or diagnostics — see below |
| 2. Atomic refcounts | **done** — `libs/oop` + all seven hand-rolled |
| 3. Split `block_context_switch` (37 sites) | **done** — 0 sites; the alias is deleted and grep-guarded |
| 4. Lock hierarchy + big kernel lock | **hierarchy done** — 9 locks + lockdep + audit; `rq`/`fd`/BKL deferred with reasons |
| 5. Non-reentrant libraries (FatFs, littlefs, SDIO) | **done for what is mounted** — FatFs, block device, loader |
| 6. Core 1 bring-up + doorbell IPI | **bring-up done on both targets** (mps3-an524 and rp2350); the doorbell IPI and two per-CPU diagnostics remain — see below |
| 7. SMP scheduler | not started |
| 8. Split the BKL | not started |
| 9. Threads (`clone`, pthreads, TLS) | not started |

### Core 1 on QEMU (mps3-an524)

Phase 6, on the QEMU leg only. **`CONFIG_PROCESS_SMP=y` on `mps3-an524`**, core 1
boots, runs a two-core mutual-exclusion test, and parks in an idle loop. The
rp2350 is deliberately untouched and stays `n`.

**The plan said QEMU could not do this, and that was an assumption rather than a
fact.** The AN524 is an **SSE-200**, not an IoTKit: `qemu-system-arm -machine
mps3-an524` is documented as "dual Cortex-M33" and `info cpus` lists both. The
[Testing](#testing) table is corrected accordingly. This matters beyond
convenience — it means the cross-core paths get exercised on every CI run,
including under `-n auto` where each xdist worker boots its own two-core guest,
rather than only on the rig that is already the flakiest part of CI.

**How core 1 starts.** The SSE-200 holds it at reset through the system control
block's `CPUWAIT` (secure alias `0x5002_1000`, `+0x118`), whose reset value is 2
— core 0 boots, core 1 waits. Clearing bit 1 starts it, and it resets through
`INITSVTOR1` (`+0x114`) rather than through the table core 0 booted from. So core
1 needs a vector table of its own; pointing it at `__vector_table` would re-enter
`_start`, which re-runs `crt_init` and re-zeroes a `.bss` core 0 is already
using. `__vector_table_core1` is therefore two words — initial MSP and
`_start_core1` — and `_start_core1` repoints VTOR at the shared table before
anything can raise an exception, so the cores share every handler, which is what
phase 7 needs. (128-byte aligned: `INITSVTOR1`'s VTOR field starts at bit 7.)

`coreid()` is a load from the per-core CPU_IDENTITY block at `0x4001_f000` —
each core sees its own copy, which is this board's answer to the rp2350's SIO
CPUID load. It was hardcoded to 0 before, along with `number_of_cores()`
returning 1 for a part that has two.

`kstack` is split so each core has an MSP of its own: MSP is banked per core, the
memory behind it is not. Core 0's `MSPLIM` is exactly core 1's stack top, so
neither can grow into the other and an attempt faults instead of corrupting.

**What core 1 does not do.** It does not schedule — no run queue, no entry in the
process table — so `irq_systick` refuses to pend PendSV on a core that does not
run the scheduler (`smp.core_schedules`, deleted in phase 7 along with
`scheduler_core`). It does not log either: core 0 reports the handshake, so the
boot log stays a single-writer stream. It parks in **WFI**, not a spin — under
emulation a spinning idle core burns a whole host CPU, which on a suite that runs
one QEMU per worker would halve the machine.

**The self-test is the point, not the boot message.** "Core 1 did not start" is
loud. "Core 1 started and its exclusives do not exclude" is silent, and is what
this phase exists to catch — the `ACTLR.EXTEXCLALL` hazard named above. It runs
in two stages, because the lock and the primitive under it fail differently:
both cores `fetchAdd` a shared atomic with no lock involved (a short total means
one core's `ldrex`/`strex` never reached the other), and then both take a real
`SpinLock` section carrying two signatures — a marker that catches *overlap*, and
a deliberately non-atomic counter read into a register, held across a delay and
written back, which catches *lost updates*.

**Nothing in it blocks, and that rule was learned the hard way.** Stage 2 used a
blocking `lock_irqsave` first, which made a self-test able to hang the boot it
verifies — and under QEMU's multi-threaded TCG it did, wedging about one smoke
run in five past the 15 s boot timeout. gdb on a stalled guest: both cores
online, the other core finished and idle, lock word **free**, and the spinning
core still in its retry loop 19 seconds later. A losing try-lock now skips its
turn, so sections are *counted* rather than predicted and the test is bounded by
its own loop counts however the cores are scheduled. Fourteen consecutive clean
suite runs, against roughly one-in-five before.

Two workarounds were tried and rejected on evidence, both worth recording
because both look reasonable:

- **A larger spin budget / a wall-clock timeout on the handshake.** The timeout
  was a real bug fix — an iteration budget measures the *host*, not the guest,
  and `hal.time.get_time_us()` runs from a free-running timer long before
  SysTick — but it did not touch the stall, which was inside the lock.
- **`-accel tcg,thread=single`.** It does remove the stall, and it silently
  guts the test: round-robin TCG never runs the cores at the same instant, so
  with the lock deliberately removed the suite still reported **pass**. It also
  drops a contended lock to ~140 sections a second. Do not reach for it.

**The detector was verified by breaking it**, which is the only way to tell a
test that passes from a test that cannot fail. Replacing the lock with a bare
PRIMASK mask: 1853 guarded increments against 2048 sections taken, an overlap
seen, verdict `fail`, three runs out of three. It doubles as proof that the two
cores genuinely run at the same time, since a lost update requires real overlap
— as does the section count itself, where about half the try-locks lose.

**`/proc/cpus`** is the surface, and it answers three different questions:

```
smp 1                          cpus 2                     online 2
selftest pass                  selftest_atomic_expected 8192
selftest_atomic_counted 8192   selftest_sections 1029
selftest_guarded 1029          selftest_overlaps 0        selftest_us 1393
cpu0_online 1                  cpu0_ticks 1268
cpu1_online 1                  cpu1_ticks 1281
```

`selftest_us` is reported rather than kept internal because the cost of this is
*contention*, and contention is the thing an emulator makes least
representative; it is the number to look at before changing an iteration count.

The tick counts are there because the online flag cannot answer liveness: a core
that came up and then wedged still reads back online forever. Two reads a moment
apart separate "started once" from "running now", and that is what
`tests/smoke/smp_test.py` asserts, along with the self-test verdict. It runs on
**both** QEMU boards rather than skipping on the single-core one — an505 must
report `smp 0`/`cpus 1`/`selftest skipped`, so `smp 0` silently appearing on the
an524 leg is a failure rather than a skip.

### Core 1 on the RP2350

Phase 6 on real silicon. **`CONFIG_PROCESS_SMP=y` on
`pimoroni_pico_plus2`**, core 1 boots, runs the same two-core
mutual-exclusion test, and parks. `/proc/cpus` from the rig:

```
smp 1        cpus 2        online 2       selftest pass
selftest_atomic_expected 8192   selftest_atomic_counted 8192
selftest_sections 1038          selftest_guarded 1038
selftest_overlaps 0             selftest_us 165
cpu0_online 1  cpu0_ticks 18    cpu1_online 1  cpu1_ticks 82
```

`selftest_us` is **165 against QEMU's 1393** — the one number in this document
where the emulator was off by an order of magnitude, and a reminder that the
contention figures above are emulator artefacts. `cpu1_ticks > cpu0_ticks` is
expected rather than alarming: `init()` leaves core 0's SysTick *disabled* until
the root process exists, while `init_secondary` leaves core 1's running.

**How core 1 starts, and why it is less work than the SSE-200.** There is no
`CPUWAIT` and no `INITSVTOR1`. Core 1 comes out of reset into the **bootrom**,
which sits in a receive loop on the inter-core FIFO and takes VTOR, SP and the
entry point *as messages* — the six-word sequence `{0, 0, 1, VTOR, SP, entry}`,
each word echoed back, a mismatch restarting the sequence from the beginning
(`hal/.../rp2350/source/cpu.zig` `start_core`). So **there is no second vector
table to build**: core 1 is handed core 0's live VTOR, which is the RAM vector
table `crt_init` relocated to, and the cores share every handler from the first
instruction. `__vector_table_core1`, which the QEMU board needs, has no rp2350
counterpart.

Every wait in that path is on one 100 ms deadline, so a core that never answers
costs the boot 100 ms once instead of hanging it. The kernel's own 2 s handshake
timeout sits outside it.

`_start_core1` (`startup.S`) therefore has almost nothing to do — the bootrom
already set MSP and VTOR. It sets `MSPLIM`, calls `crt_init_core1`, and enters
`kernel_secondary_core_entry`. It is deliberately not a second `_start`: .data,
.bss, the constructors, clocks, QMI and PSRAM are all already up and chip-wide.

**Stacks.** `core1_stack`, 4 KB at `0x2007D000`, taken off `process_ram` (396K →
392K) rather than out of `scratch`, so core 0's 16 KB is unchanged to the byte.
`__stack_top_core1__` is exactly `__stack_bottom__`, i.e. core 0's MSPLIM, so
either core overflowing faults on a limit instead of eating the other's stack —
a linker `ASSERT` holds that adjacency. 4 KB is **not** enough for the hardfault
maps dump (a 4 KB stack buffer on its own), so a core-1 fault hits MSPLIM partway
through it. Bounded and loud, and the right trade until phase 7 gives core 1
real work.

**`ACTLR.EXTEXCLALL` is set on both cores**, in `init_per_core_state()` called
from `crt_init` and `crt_init_core1`. Note the pico-sdk *also* sets it on core 0
via its own runtime initializer (`spinlock_set_extexclall`, visible in the
disassembly) — the explicit write removes the dependency on that initializer's
ordering and is the only thing that covers core 1, which runs no SDK per-core
init. Verified in the disassembly rather than assumed: `ldr`/`orr #0x20000000`/
`str` against `0xE000E008` in both.

**`sio.zig` was RP2040-shaped and is now RP2350-shaped.** Two things moved: GPIO
is interleaved low/high from `+0x14` (`GPIO_HI_OUT` at `+0x14`, `GPIO_OUT_SET` at
`+0x18`), and **there is no divider** — `+0x60`..`+0x7c` is reserved, not `DIV_*`.
What made this survivable, and what makes it a trap, is that both layouts have
exactly 32 words ahead of `INTERP0`: `cpuid` and `spinlocks` landed correctly and
the `@sizeOf` check passed. The asserts are now per-field `@offsetOf`.

**Two races that only exist on this part**, both found by walking core 1's path
rather than by a test:

- **`xip_stats.accumulate()` in `irq_systick`** is a seqlock *writer* with no
  writer-side exclusion — a single-writer assumption that a second core's SysTick
  breaks. It is now timekeeper-only, like the clock beside it. The QEMU boards
  publish no sampler, so their second core returns on the null check and can
  never reach it: this one was structurally invisible to the QEMU leg.
- **`FPCCR.LSPEN`** is banked per core, and only core 0 was clearing it.
  `init_secondary` now does too. Nothing a phase-6 core 1 runs can trip the
  unbalanced-`EXC_RETURN` bug that setting exists for, but phase 7 would.

**Still phase-6 work:** the doorbell IPI and the `hal.irq.Type` extension that
carries it, and `hardfault_callee` / `ctx_ring` becoming per-CPU. Neither is
reachable from a core that only idles, which is why core 1 parks today without
them. (`mpu.zig`'s `next_region`, listed here previously, is already a local.)

**Erratum RP2350-E2 is a constraint on the doorbell work, and the tree already
satisfies it.** The SDK's wording: "writes to new SIO registers above an offset
of +0x180 alias the spinlocks, causing spurious lock releases." The doorbells are
at exactly `+0x180`, so ringing one can release a SIO *hardware* spinlock. That
is harmless here only because this kernel does not use them — its locks are
LDAEX/STLEX exclusives and the sole write to `spinlocks` is the boot release loop
in `crt.zig`. Treat that as an invariant, not a coincidence.

**Not yet measured: the overclock.** The rig runs at 532 MHz and VREG margin
above 600 MHz is already known to be thin and ~80% intermittent, so single runs
lie. A second active core changes current draw and die temperature. The stability
sweep has *not* been re-run with core 1 live, and it should be before this is
trusted under load.

### Both cores scheduling

Phase 7. **`CONFIG_PROCESS_SMP=y` on both targets, and both cores now run
processes.** The evidence, from `/proc/cpus` on the QEMU an524 leg across a
workload with three concurrent jobs:

```
cpu0_scheduling 1   cpu0_switches 2 -> 8    cpu0_pid 6   cpu0_idle_pid 2
cpu1_scheduling 1   cpu1_switches 1 -> 5    cpu1_pid 3   cpu1_idle_pid 3
```

Core 1 performing four context switches under load is the whole milestone.
Note what it replaces: through phase 6 that counter would have read `1 -> 1`,
because core 1 booted, passed the exclusives self-test and sat in WFI.

**The claim is the scan, and the lock is the claim.** `RoundRobin.try_claim`
stores `Running` into the node it picks, inside the same `proctable_lock`
critical section that tested it for `Ready`. No CAS, deliberately, and the code
says so at the site: every caller arrives through `ProcessManager.schedule_next`,
which holds the lock across the whole walk, and a lock held over test-and-store
is strictly stronger than a CAS. A CAS there would also imply the surrounding
walk is safe unlocked, which it is not — it reads `node.next` while the other
core may be inserting.

**The release is deferred to after the context store, and that ordering is the
subtle half.** `store_and_switch_to_next_task` calls
`arch_store_registers_on_stack` — which reaches `update_stack_pointer` and writes
the outgoing stack pointer — *before* `switch_to_next_task`. So
`RoundRobin.update_current`, reached from `process_set_next_task`, is the first
moment at which there is a valid context to resume, and that is where
`release_from_core` publishes the process as `Ready` again. Releasing at pick
time instead would let the other core resume it from a stack pointer belonging
to the previous switch.

**`Running` had to become sticky.** `reevaluate_state` is called on *other*
processes by every waker in the tree, and it fell through to `Ready`. On one core
that was harmless because a woken process could not also be executing. On two it
is the same double-claim by another route, so `reevaluate_state` now refuses to
demote `Running`, and `release_from_core` is the single exception — issued by the
core that owns the claim, after the store. `Running -> Blocked` stays allowed: it
is always a process blocking itself.

**Every core has a real idle process**, held in `ProcessManager.idle[]` and
deliberately not in `processes`, so `ps`, `is_empty`, `has_live_child`,
`wake_all_blocked_on` and the other core's scan never see it. Created after the
root so the root keeps pid 1. Three things fall out of it: `core[]` is valid on
every core from the moment idle exists rather than `undefined` until first
switch; `process_set_next_task`'s "no tasks available" panic is unreachable; and
the reaper gets a thread context.

That last one also fixed a *single-core* pathology. A process blocked in
`waitpid` used to keep its core and spin on `hal.irq.trigger(.pendsv)`. On one
core that merely wasted the slice. On two it actively throttles the other core:
the spin re-enters `schedule_next` as fast as the core can issue it and every
pass takes `proctable_lock`. Blocked processes now switch to idle and the core
parks in WFI.

**The reaper left PendSV**, as phase 4 required. `reap_terminated` runs in the
idle process and at process creation, and skips any process still pointed at by
some core's cursor (`is_claimed_by_any_core`) — the exiting process is its own
core's `current` while that core is switching away from it, and freeing its stack
in that window is a use-after-free of the context the switch is about to store.

**The `scheduler_core` constant and `system_call.scheduler_running` were one
question asked twice**, and both answers were per-system where the question is
per-core. They are now a single `smp.scheduling_mask` bit per core, set when a
core takes its own first switch. This is load-bearing rather than tidy: a
secondary core enables its SysTick in `init_secondary()` while still on MSP with
no PSP of its own, so a PendSV taken there would store its context through an
unset stack pointer. Both `irq_systick` and `do_context_switch` refuse on that
basis.

#### The rig is the aggressive case, not the gentle one

Worth stating before the list, because it inverts the obvious assumption. QEMU
has no doorbell, so an idle core there only looks for work every 100 ms. **The
rp2350 does have one, so an idle core is interrupted the moment work appears** —
which makes the rig behave like the 1 ms poll configuration, not like the QEMU
default. Two bugs that were nearly unreachable on QEMU showed up in the first
minute of a rig suite run, as reruns:

- the vfork parent claim race below, and
- SDIO driven from both cores at once.

So: **a clean QEMU suite is not evidence for the rig.** Run both.

#### Twelve bugs the first two-core workload found

None of them was in the scheduler, and none is reachable on one core. That is
the pattern worth noting: the scheduler change was the easy part, and everything
that actually broke was **per-core state that should have been per-process**, or
**unlocked state that only one core used to reach**. Those two questions are the
ones to ask of any code this phase touches next.

**Per-core lock accounting breaks when processes migrate.** lockdep's held-rank
bitmask is `PerCpu(u16)`, which is right for every `Ranked` in the tree — they
are `spin_irq`, taken with interrupts masked, so a core cannot be switched while
holding one — and wrong for all four `RankedMutex`es. Blocking is what a sleeping
mutex is *for*, blocking means a context switch, and the holder may resume on the
other core. Two `sha256sum` jobs were enough:

```
lockdep: lock order violation: taking dev (rank 30) while holding ranks 0x10
lockdep: releasing dev (rank 30), which this core does not hold
```

Both are the same accounting error seen from the two ends: the core the holder
left keeps the bit, so the next process to take that lock there looks like an
order violation; the core it arrives on never had it, so the release looks
unmatched. `locks.migrating_ranks` now names the four sleeping-mutex bits, and
`RoundRobin.update_current` moves them onto the process being switched away from
and back off the one being switched to. This is the same hazard the plan
predicted for the BKL — "`RecursiveRanked` tracks ownership by *core*, so the
depth survives a switch while the process it belongs to does not" — arriving via
lockdep instead, because the BKL was never wired.

**Exception priorities are banked per core.** `initialize_context_switching` runs
on core 0, so core 1 came up with SVCall, SysTick and PendSV all at the reset
value of 0. The entire ordering argument — PendSV strictly lowest so it can never
preempt SysTick or SVCall and strand their ACTIVE bits — is a property of those
registers, and it simply did not hold on the core that had just started running
user code. Equal priorities happen not to preempt, which is why this reads as
working right up until something moves. `init_secondary` sets them now.

**The exit path held a preempt window across two sleeping mutexes.** `sys_exit`
disables preemption before `delete_process` — correctly, for the hand-off at the
tail of that function, where the process takes itself off the run queue and gives
the core away. But `clear_fds` (filesystem, rank 20) and `release_executable`
(loader, rank 8) were *inside* that window, and `RankedMutex` refuses to block
with preemption disabled — rightly, since the yield that would resume it could
never run. Uncontended on one core, so it stood; it panicked within minutes of
core 1 scheduling, when a `cat | cat` stage exited while the other core was
inside the loader:

```
KERNEL PANIC: sleeping mutex would block with preemption disabled
  modules.release_executable / ProcessManager.delete_process / sys_exit
```

Both calls moved to a preemptible cleanup phase at the head of `delete_process`,
before the window is retaken. They are ordinary teardown and the process is still
`Running` and still on the run queue there, so being preempted is no different
from being preempted anywhere else in a syscall.

**Three loader functions walk the module tables with no lock at all.**
`load_executable` and `release_executable` take `loader_lock`;
`restore_parent_writable_sections`, `save_parent_writable_sections` and
`get_executable_for_pid` do not. `vfork_snapshots` is a `HashMap` mutated by the
first two, and with two cores one shell exec'ing while another vforks is the
ordinary shape of running a command. An unsynchronised rehash under a concurrent
lookup is how a module name comes back empty:

```
[ERR][yasld] Can't find child module ''
[ERR][loader] loading '/tmp/null_envp' failed: DependencyNotFound
```

Measured rather than assumed, by stashing the change and re-running the same
command:

| build | rounds of `pipe_test` + `vfork_test` + `smp_test` | rounds with a failure |
|---|---|---|
| phase 6 baseline (core 1 parked) | 5 | **0** |
| phase 7, before the loader lock | 6 | **4** |
| phase 7, after locking one of the three | 8 | **1** |
| phase 7, after locking all three | 10 | **0** |
| phase 7, final (all nine fixes) | 10 | **0** |

`restore_parent_writable_sections` now takes the lock — both its callers
(`delete_process`'s cleanup phase and the head of `prepare_exec`) are
preemptible, which is what makes a rank-8 sleeping mutex legal there. The
baseline row is the one that matters for attribution: this flakiness is phase 7's
to own, not something that was already there.

**All three are locked now, and `vfork` was restructured to allow it.**
`save_parent_writable_sections` and `get_executable_for_pid` are called from
`vfork`, which held its preempt window across the whole function — so taking a
rank-8 sleeping mutex there would have panicked exactly as the exit path did.

The window could not simply move to the end either: **`wait_for_process` marks
the parent `Blocked`**, so from that call onwards a PendSV would switch the
parent out before it reached the hand-off, leaving the child created, unreleased
and unreachable. So the window now opens exactly at `wait_for_process`. Above it
is preemptible setup that touches nothing another core can see — the child is not
in `processes` yet — and below it is the hand-off. Snapshotting the parent's
writable sections earlier is sound because the requirement is only "before the
child runs", and the child does not run until `process_vfork_child`.

`get_executable_for_pid` needed splitting into a locked public accessor and an
`executable_for_pid_locked` helper, because `save_parent_writable_sections` calls
it and `RankedMutex` does not recurse.

With that, **ten rounds of ten, clean.**

**The MPU is banked per core, and core 1 had none.** `main.zig` calls
`arch.mpu.enable_kernel_protection()` once, on core 0. Through phase 6 that was
harmless because core 1 ran only kernel code; a core that schedules runs *user*
processes, so on the QEMU boards (`CONFIG_PROCESS_USE_MPU_KERNEL_PROTECTION=y`)
every unprivileged process that landed on core 1 had the run of the kernel heap
and stack. Core 1 now programs its own, after the self-test — the same position
core 0's call occupies relative to it.

This is safe with respect to the `ACTLR.EXTEXCLALL` hazard, and the reason is
worth stating rather than assuming: EXTEXCLALL stops helping once an *enabled MPU
region covers the address*, and `enable_kernel_protection` deliberately leaves
kernel RAM unmapped — that is the whole point of it. Every kernel lock word lives
there, so they stay uncovered and their exclusives keep reaching both cores.

Note also what this exposes about the self-test: it runs *before* either core
enables its MPU, so "cross-core exclusives work" has only ever been verified in
the MPU-off configuration. That remains true and is worth keeping in mind, though
the argument above says it should not matter for kernel locks.

**romfs read the device with a split seek/read.** `FileHeader.load` did
`seek(offset)` then `read(buffer)` on the **shared** device file with nothing
holding the two together. `FileReader` already knew better and took `dev_lock`
around its own pairs; `file_header.zig` and `file_system_header.zig` simply
never did. With two cores the other core's romfs read lands between them, this
read returns bytes from elsewhere in the image, and they are parsed as a header —
so the size and offset fields come back as garbage and the next read indexes off
the end of the device:

```
KERNEL PANIC: index out of bounds: index 1497450080, len 67108864
  RamFlash.read / FileHeader.load / RomFs.get_file_header / RomFs.get
```

This matters more than it looks: romfs *is* the rootfs, so every `open` and every
`exec` walks it. The lock has to be scoped to the pair rather than held across
the function, because the long-name path calls `FileReader.read_string`, which
takes the same lock — and `RankedMutex` does not recurse, so holding it across
that is a same-rank re-acquisition that lockdep panics on.

**`Ranked.lock_irqsave` set the rank bit before masking interrupts.** It called
`enter(rank)` and *then* `inner.lock_irqsave()`, which is what does the masking —
leaving a window with the bit set and interrupts still enabled. On one core that
window is harmless. With a second core running processes, a PendSV landing in it
migrates the caller, and the bit is per-core: the core it left keeps a bit nobody
holds, and the core it arrives on releases one it never took.

```
[lockdep] releasing pipe (rank 40), which this core does not hold
[lockdep] lock order violation: taking pipe (rank 40) while holding ranks 0x20
```

The pipe code was doing nothing wrong — it takes `pipe_lock` with `lock_irqsave`
and releases it before yielding, exactly as its comments promise. The defect was
one level down, in the lock type itself, and it applies to **every** `Ranked` in
the tree. Masking first closes it outright: from there to `unlock_irqrestore`'s
`leave` the caller cannot be preempted, so the bit cannot outlive its core. The
hierarchy is still checked before the acquire, which is what the original
ordering was reaching for.

**A lost wake-up in `waitpid`, and it is the textbook one.** The decision block
tested for an already-exited child and then blocked, guarded only by
`preempt_disable()` — which stops *this* core switching and says nothing about
the other core, where the child is exiting:

```
core 0 (parent)                 core 1 (child)
  take_exited_child -> null
                                  record_child_exit -> appends
                                  wake_from -> parent not blocked yet, a no-op
  block_on -> Blocked
  ...never woken; the wake already happened
```

The result is a shell parked forever on `hello & wait`. `proctable_lock` is now
held across the whole decision, and `delete_process` holds the same lock across
`record_child_exit`, the unblocks and the list move — condition-and-sleep under
one lock, make-condition-true-and-wake under the same one. There is no cheaper
answer. This needed `has_live_child_locked` / `get_process_for_pid_locked`, since
the public forms take the lock themselves and `Ranked` does not recurse.

**The vfork parent was published as `Ready` before it was claimed — and then the
other core was invited to take it.** `delete_process`'s hand-off path calls
`unblock_parent()` (parent becomes `Ready`), drops `proctable_lock`, calls
`kick_idle_core()`, and only then does `set_next(&parent.node)` claim it for this
core. A vfork parent is the one process that must never be resumed from its
stored context: the hand-off re-enters it through `_vfork_context` and rewrites
its stack, so the frame at its `stack_position` is stale. The other core resuming
it there reads the frame at the wrong offset:

```
HardFault: EXC_RETURN=0xFFFFFFE1 stacked_pc=0x2002AA98      (a user address)
           stacked r0=0x2002AA98 r1=0xFFFFFFED r2=0x2002AA98 psr=...000E
```

`bx r0` into user code from PendSV, with the EXC_RETURN one word out of place in
r1. **QEMU has no doorbell, so `kick_idle_core` was a no-op there and the window
was nearly unreachable; the rig hit it in the first minute.** The claim now
happens inside the same locked region as the unblock.

**SDIO was driven from both cores.** `MmcIo.read`/`write`/`init` guarded a whole
transfer with `arch.sync.save_and_disable_interrupts()`, which excludes this
core's handlers and nothing else. Two processes reading or writing files at once
interleaved two command sequences on one controller, and the card said so:
`DataCrc` on reads, `WriteFail` on writes, both after six retries. There is now
an `sdio` rank (35, below `dev`) held across each transfer — below `dev` so a
caller already holding it (FatFs, romfs) nests legally, while the raw `/dev/mmc`
path, which holds nothing, is still excluded. A single controller cannot
interleave two transfers, so file I/O genuinely serialises across cores; that is
the hardware's price, not a design choice.

**The console degraded to ungoverned writes whenever it was busy, including when
the other core held it.** `console_acquire` used a bare `try_lock_no_irq()` in
handler context and wrote regardless on failure. That was right by construction
on one core: the only possible holder was this core's thread mode or a
lower-priority handler, neither of which can run to release until the handler
returns, so waiting would hang and garbled output is the better failure. The same
test also catches "the *other* core holds it" — where that core is running and
will release, so writing anyway is not graceful degradation but plain corruption,
two cores emitting into one UART:

```
[ERR][mmc/sdio] 0x1003c142 (4, 0x4[ERR][E[m][mcc//sdio] 0x1003b90b (42791(...
```

The question is not "is it free" but "is it *mine*", so it now asks
`held_by_current()` — race-free here, since only this core can make it true and
nothing else on this core can run while we are in the handler. A panic or
HardFault on the core already holding the lock still writes straight through,
preserving "a garbled panic beats a hung panic". The cost is that a logging
handler may wait for the other core to finish a line, which is the same wait
thread context has always taken.

`lock_no_irq` also moved its rank bookkeeping to *after* the acquire, for the
same reason `lock_irqsave` masks before it: it cannot mask — not masking is its
entire purpose — so recording afterwards is what stops a migration stranding the
bit. It gives up the pre-acquire hierarchy check, which costs nothing at rank 95
with nothing above it.

**A secondary core's first switch had a window with no PSP.**
`process_set_next_task` marks the core as scheduling — which is what permits
PendSV on it — part-way through `switch_to_the_first_task`, before
`arm_load_registers_from_stack` sets PSP and before the CONTROL write. A SysTick
there finds a core that is nominally scheduling but still on MSP with no context
of its own, and if anything is runnable, PendSV stores through that unset PSP.
It surfaces later as a resume into nothing (`stacked_pc=0x00000000`, "branch to
NULL"). Core 0 has the identical window and has always been fine, because it
takes its first switch when the root process is the only process and
`schedule_next` has nothing to hand it. `enter_scheduler_on_secondary_core` now
masks interrupts across the sequence and `idle_process_entry` re-enables them,
which is exactly how the vfork hand-off closes its own equivalent window.

#### The doorbell IPI

`SCB.ICSR` is banked, so `hal.irq.trigger(.pendsv)` only ever pends on the
calling core, and an idle core would otherwise wait up to a full tick to notice
work that is runnable now. On a 1 ms tick that is most of the cost of a short job.

`SIO_IRQ_BELL` (IRQ 26) carries it on the rp2350. The registers were already
mapped; what is new is `ring_doorbell`/`clear_doorbell`/`enable_doorbell` on the
HAL cpu interface, an idle-core bitmask in `smp.zig` that says who is worth
ringing, and `kick_idle_core` calls on the paths that make a process runnable
(creation, `wake_all_blocked_on`, process exit).

Three things worth keeping straight:

- **The vector table is shared, the NVIC is banked.** Core 1 is handed core 0's
  live VTOR by the bootrom, so one `install_doorbell_handler` covers both cores,
  while `enable_doorbell` has to be issued by each core for itself.
- **The idle mask is a hint and is allowed to be stale in both directions.** A
  spurious doorbell costs an interrupt that finds nothing; a missed one costs a
  tick of latency, which is exactly what a board without a doorbell pays anyway.
  At most one core is rung — waking every idle core to race for one runnable
  process is a thundering herd whose losers each pay a lock acquisition.
- **Erratum RP2350-E2 still binds.** The doorbell write is at SIO `+0x180` and
  aliases the SIO hardware spinlocks, so it can spuriously release one. This is
  safe only because the kernel does not use them. That is an invariant to keep,
  not a coincidence, and it is now commented at both the register declaration and
  the ring site.

**The QEMU leg has no doorbell and must stay correct without one.** The SSE-200
has no equivalent, so `hal.cpu.ring_doorbell` returns false there and the an524
falls back to tick discovery — which means the CI leg exercises the *fallback*
path and the doorbell path only runs on the rig. `/proc/cpus` reports `doorbell`
so a latency figure says which of the two produced it.

#### Still open

- **`ArmProcess.vfork` still hands the child a raw PSP as its `stack_position`.**
  Fixed in practice by claiming the parent under the lock (above), so no path
  now reaches a vfork frame through PendSV — but the representation is still a
  trap for the next person, and giving vfork children a real initial frame (or a
  state the scheduler refuses) would remove the trap rather than avoid it.

  Historical note on the symptom, which is what made it findable:
  child's `stack_position` to the parent's raw **PSP** — it is meant to be entered
  only by the `process_vfork_child` assembly hand-off, never by the scheduler. If
  PendSV ever picks it, `arm_load_registers_from_stack` reads the hardware
  exception frame as though it were a software frame, so the LR slot yields a
  word of user data and `bx r0` branches into user code from handler mode:

  ```
  HardFault: EXC_RETURN=0xFFFFFFF1 stacked_pc=0x6602491C  (a user address)
             stacked r0=0x6602491C r2=0x6602491C psr=...000E   (exception 14, PendSV)
  ```

  The route to it was `delete_process` publishing the vfork parent as `Ready`
  and then *ringing the other core's doorbell* before claiming it — see the
  entry above. With that closed the symptom is gone, and what remains is the
  representation, not a live bug.

- **The idle core's 1 ms poll is written but commented out**, in
  `interrupts/systick.zig`. An idle core has no timeslice to protect, so looking
  for work every tick rather than every 100 ms is the obviously right behaviour,
  and on a board with no doorbell the period *is* the discovery mechanism. It is
  off only because of the vfork frame bug above.

  Keep it as the bug-finding knob it has proven to be: raising the rate
  multiplies how often processes migrate, and **it found five of the nine bugs
  above** — the unlocked loader tables, the unlocked romfs seek, the
  `enter(rank)`-before-masking window, the lost wake-up, and the first-switch
  window. Turn it on when hunting an SMP defect, run a handful of rounds of
  `pipe_test`/`vfork_test`/`smp_test`, and turn it back off.

- **The second core contributes little on a board without a doorbell**, and that
  is a consequence of the same period rather than a separate defect. An idle core
  gets one look for work every 100 ms, so anything shorter than that runs entirely
  on one core: four `sha256sum` jobs over a 219 KB binary at `-j2` finished in
  0.10 s with core 1 never taking any of it. `test_secondary_core_actually_runs_processes`
  had to grow a 1.6 MB workload and up to four attempts to be reliable, and that
  sampling difficulty *is* the finding. The rp2350 does not have this problem —
  the doorbell wakes an idle core the moment work appears — which makes measuring
  `prun -j2` on the rig the interesting comparison.
- **`hardfault_callee` is still a single shared buffer.** Unlike `ctx_ring`,
  which both cores write on every switch and which is now per-CPU, this is
  written only by the faulting core — so it corrupts only if both cores fault at
  once. Making it per-core means indexing by `coreid` inside the naked entry
  stub, which is board-specific (SIO on the rp2350, CPU_IDENTITY on the SSE-200)
  in a file that is generic `arm-m`, and that stub has already cost this project
  two wrong diagnoses. Not worth the risk for a double-fault-only diagnostic.
- **No per-core run queues.** One ready list under `proctable_lock`, so every
  switch on both cores serialises on one lock. At a ~1 ms tick that is not
  measurable; `rq_lock` (rank 60) stays reserved and unused, and work stealing is
  a later change to make once there is a measurement asking for it.
- **The 532 MHz stability sweep has not been re-run with core 1 executing.** It
  was already flagged as not done for a core that only idled; a core running user
  code changes current draw and die temperature considerably more. Single runs
  lie here (~80% intermittent), so this needs the full sweep.
- **`sleep_for_us` polls the clock while staying `Ready`**, so it round-robins
  normally rather than blocking — meaning it now competes for both cores.

### The sleeping mutex

`sync/mutex.zig` — `RankedMutex(rank)`. A contender blocks and yields through
`Process.block_on` instead of spinning, which is the whole point: this is the
lock for things held across filesystem and device I/O, where spinning in
`cpsid i` for milliseconds would blow the ~93 µs UART RX-FIFO budget. It
enforces two things rather than documenting them — **thread context only**
(`arch.sync.in_handler_mode()` panics otherwise, which is how "no filesystem or
device I/O from handler context" stops being a convention) and **not
recursive**.

It handles two cases worth naming, both found the hard way.

**Boot.** The kernel mounts filesystems in `main()` before any process is
scheduled, so `current_process()` is legitimately null. Boot is single-threaded
and therefore uncontended, which is why `held` and `owner` are separate fields.

**Shutdown, and where the handler-context rule really belongs.** The first
version rejected *any* acquire from handler context, and a full hardware smoke
run passed 4543/4561 tests and then panicked during teardown:

```
$ exit
[ERR][kernel] KERNEL PANIC: sleeping mutex acquired from an exception handler
```

`sys_stop_root_process` calls `switch_to_main_task`, which ends in
`pop {r0, pc}` — a plain return, **not** an exception return — so the kernel's
main task is resumed from *inside* the SVCall handler and the entire shutdown
sequence (unmount, flush the card) runs with IPSR non-zero. That is by design in
this kernel, not a bug in the shutdown path.

The rule was simply stated too broadly. What is forbidden from a handler is
**blocking** — it deschedules whatever the handler interrupted, and the handler
never returns. An *uncontended* acquire blocks nothing and is harmless. The
check now sits on the blocking path only, which is both more accurate and lets
shutdown work. A handler that interrupted the holder still trips the
already-held panic, which is the deadlock it would otherwise be.

### FatFs is serialised (phase 5, first half)

One `RankedMutex(.fs)` at every outer FatFs boundary —
`source/fs/fatfs/fs_lock.zig`. **This closes a hole that is open today, on one
core.** It is tempting to assume the existing `block_context_switch` windows
already cover FatFs; they do not. `sys_read` and `sys_write` release the window
*before* touching the file, so every FatFs read and write already runs
preemptible, and two processes doing file I/O can already interleave inside
`ff.c` and scribble over each other's `LfnBuf`. That it has not obviously broken
is a property of the workload — the shell is blocked in `waitpid` for almost the
whole run — not of the code.

Lockdep earned its keep immediately, catching two real re-entries the moment the
lock went in: `format` called `umount`/`mount` (fixed by splitting out
`*_locked` bodies), and `access` is a pure composition of `get`, `filetype` and
`delete` (fixed by not locking it at all — the sequence was never atomic and is
not now). Both would have been silent hangs without the check.

The rule that fell out: **an entry point that is a pure composition of other
locked entry points must not take the lock itself.**

### The device lock (phase 5, second half)

`source/kernel/drivers/dev_lock.zig`, a `RankedMutex(.dev)` at rank 30. What it
guards is not "the device" but the **seek position**, which lives in the device
file object and is shared by every handle to it: every caller does
`seek(offset); read(buffer)`, and two of those interleaved means the first read
returns the second one's data.

It **replaced** the FatFs disk wrapper's PRIMASK sections rather than adding to
them. Those kept the seek and the transfer together by masking interrupts for
the duration of a multi-sector SD command — correct exclusion, milliseconds
long, inside a budget that is ~93 µs. There are now zero
`save_and_disable_interrupts` calls left in `source/fs/fatfs/fatfs.zig`.

`romfs/file_reader.zig` takes it too, around each whole seek-then-read sequence
— including `read_string`'s loop, which keeps reading forward from one seek
until it finds a terminator.

One global instance rather than the table's `dev_lock[dev]`: it cannot deadlock
against itself through an ordering mistake between two devices, and on one core
it is no coarser than the mask it replaced. Split it when a second device stack
justifies the contention.

### The mount lock (phase 3(B), first subsystem)

`mount_points.zig`'s `mount_lock`, rank 10 — the outermost lock, and a
**sleeping** mutex rather than the spin rwlock this table originally sketched.
It has to be: rank 10 is taken before `fs` (20), which is itself sleeping, so a
spinlock there would violate "never take a sleeping mutex while holding a
spinlock" the moment it were held across a filesystem call. **The table below is
corrected accordingly.**

It makes the tree *walk* safe against a concurrent mount or umount. It does not
yet make the *result* safe — the VFS calls into `node.point.filesystem` after
the lookup returns and the lock is dropped, so a umount landing in that gap can
still free the mount point under an in-flight operation. Closing that needs a
reference on the returned point. Holding the lock across the filesystem call
instead is **not** an option: RamFs's tier spills back through
`kernel.fs.get_ivfs()` and would re-enter it.

lockdep again caught the nesting as it went in — `mount_filesystem` and `umount`
both look a point up before changing it — fixed with a `find_locked` body, the
same shape as FatFs's `*_locked` split.

### Still to do in phase 5

- **SDIO internals.** `dev_lock` covers the seek/transfer pair at the block
  layer. `g_sdio`, `g_sdio_timeout_dumps` and `aligned_buf[4096]` inside
  `sdio_rp2350.c` / `mmc_sdio.zig` are reached under it from FatFs and romfs,
  but `mmc_io.zig`'s own PRIMASK guards (`:84,:117,:159`) are still the only
  thing protecting the card state.
- **littlefs.** Still built without `LFS_THREADSAFE` and still unmounted; the
  config literal never sets `.lock`/`.unlock`, so enabling it today would
  null-deref. Wire it to a `RankedMutex(.fs)` when it is mounted.
- **`libs/zfat`'s `disks[FF_VOLUMES]`.** Every `FatFs` instance writes
  `disks[0]`, so a second FAT mount steals the first's volume. That is a
  refactor, not a lock, and it is a live single-core bug.

### The remaining blocker for phase 3(B) and 4-wiring

With FatFs serialised, the (B) sites can now begin to move -- but they still
cannot move *wholesale*, because the windows they hold cover more than FatFs.

The 37 `block_context_switch` sites are not, as the inventory assumed, mostly
small windows around table lookups. `sys_open`, `sys_unlink`, `sys_stat`,
`sys_getdents` and friends hold the window across *the whole handler*, VFS
lookup and SD card I/O included. They are today's de-facto big kernel lock,
implemented as "do not preempt at all", and that is precisely what makes FatFs
and SDIO safe today without either of them being reentrant.

So a (B) site cannot be converted to `Ranked(.fs)` as things stand:

- a **spinlock** there would hold `cpsid i` across milliseconds of card I/O,
  which blows the ~93 µs RX-FIFO budget `uart_driver.zig:51-59` documents — the
  regression risk the [Risks](#risks) section already names;
- **dropping** the window without putting a real lock in its place exposes
  FatFs (`FF_FS_REENTRANT 0`, `LfnBuf` shared by every directory walk) and the
  SDIO state machine to the reentrancy they have never had to survive.

Phase 5 has the same shape from the other side: `FF_FS_REENTRANT 1` needs
`ff_mutex_take`/`ff_mutex_give`, and FatFs holds that across disk I/O, so it
must be a lock that *sleeps* rather than one that spins with interrupts off.
`kernel.sync.Semaphore` cannot serve — it is a syscall wrapper and is unusable
from kernel context.

### The reaper: what it was actually needed for, and what is left

The inventory says the PendSV reaper "frees to the kernel heap". It does worse
than that, and the difference matters: `p.deinit()` calls `clear_fds()`, so
**reaping closes file descriptors from an exception handler** — a FatFs handle
goes through `FatFsFile.delete` and takes `fs_lock`, a sleeping mutex. That was
harmless while nothing locked, and became a latent panic the moment `fs_lock`
existed: a reap landing while another process was mid-FatFs-operation finds the
lock contended and has nowhere to block.

**Fixed without a thread.** `clear_fds` moved to `delete_process`, which runs in
the exiting process's own thread context and is where closing a process's files
belonged anyway. It is now idempotent, because `deinit` still calls it for the
paths that destroy a process without going through `delete_process`. With that
change **no filesystem or device lock is reachable from PendSV at all**, which
is the invariant the whole hierarchy rests on.

### The shutdown HardFault was not a synchronization bug

Recorded because it cost four hardware runs and two wrong diagnoses, and because
the tooling failure underneath it will otherwise recur.

`exit` intermittently HardFaulted the board after every test passed. The dump was
useless -- `r0 == r12`, `r1 == r3`, a nonsense PSR -- because
`hard_fault_main` read EXC_RETURN and chose MSP-vs-PSP with `mov r0, lr` /
`tst lr, #4` from inside the Zig body, *after* `file_log_disable()` and
`klog_force_enable()` had already clobbered `lr`. Both are now captured in the
naked stub and passed as arguments, and the two readers are deleted.

With a trustworthy dump the fault was `memcpy(dst, src=0xFFFFFFFF, len=471)` from
`vfmt.Out.bytes`, IPSR 14. The culprit:

```
kernel.log.err("Cannot start root process: {s}", .{@errorName(err)});
```

`switch_to_the_first_task` pushes a frame on MSP and `bx`es into the first task
without returning; `switch_to_main_task` pops it a whole system lifetime later to
resume `sys_start_root_process` mid-function. Naming the error there was safe
only if that resumed value was an error at all, and it was not.

My first reading of this blamed MSP drift, and that was wrong -- MSP is fine, and
guessing was the third wasted diagnosis in a row. The disassembly says it
outright. `spawn.root_process` materialises its `!void` success value into a
callee-saved register and returns it at the resume point:

```
1000cf48:  mov.w r0, #0                    ; the success value
1000cf58:  mov   r4, r0                    ; parked in r4
1000cfaa:  bl    switch_to_the_first_task   ; never returns here
1000cfae:  mov   r0, r4                    ; ...but the resume lands HERE
```

The hand-off saved `{r0, lr}` and restored `{r0, pc}` -- pc and sp correct,
r4-r11 belonging to the *shutdown* context. So a clean `exit` returned a foreign
word as an error, and `@errorName` indexed past its table. The out-of-line
`sys_start_root_process` is worse: it keeps its sret pointer in r4, so the resume
stored 8 bytes through a stale address. Which register is involved is not stable
-- a ReleaseFast rebuild moved `root_process`'s to r5 -- so the fix is the whole
callee-saved set, `push {r0, r4-r11, lr}` / `pop {r0, r4-r11, pc}` (r0 for the
8-byte alignment AAPCS wants).

Underneath that sat a second, independent bug on the same path: line 373 read
`.thumb_func:`, with a colon, which defines a label rather than invoking the
directive. `switch_to_main_task` was therefore emitted `NOTYPE` at an even
address. `pendsv_exit` reaches it with a local `b` and did not care, but the `bl`
from `sys_stop_root_process` crosses from flash into `.time_critical` in RAM
through a linker long thunk ending in `bx ip` -- a branch to ARM state on a core
that has none, i.e. INVSTATE UsageFault escalating to HardFault. Only one of the
two shutdown routes is thunked, which is the intermittency.

Five fixes, none of them synchronization:

- the fault handler captures its frame correctly;
- `vfmt` refuses to dereference an unreadable `{s}` and prints `<bad str>` -- a
  logger that faults destroys the evidence of the bug it was reporting, and here
  it was killing the fault handler's own postmortem;
- the first-task hand-off preserves r4-r11, so the resumed function finds the
  register state its compiler assumed;
- `.thumb_func` gets its directive back;
- `main` names the error again, now that it is real.

Run 4's unexplained "integer overflow" panic at shutdown was almost certainly the
register bug too: `main` resumes with foreign callee-saved registers as well, and
`detect_leaks` runs immediately after.

The lesson worth keeping is the one about instruments. Three diagnoses died
because the fault dump was lying, and the fourth only landed once I stopped
theorising and read the disassembly of the resume point. `<bad str>` in the log
was not the bug -- it was the guard working, and it is what made the real bug
readable.

### What is deliberately not done, and why

Everything remaining falls into one of three buckets. None of it blocks core 1.

**Belongs to a later phase by nature.**

- `rq_lock` (rank 60) — the scheduler's `current`/`next` TOCTOU is a redesign,
  not a lock placement: `RoundRobin` holds a single pair and tests `Ready`
  separately in time from the `Ready -> Running` store. That is phase 7's
  CAS-claim, and putting a lock around today's shape would only hide it.
- `fd_lock` (rank 55) — `_fds` is per-process and there is one thread per
  process, so two cores means two separate tables. It becomes shared exactly
  when phase 9 adds threads, which is where its lock belongs. The rank stays
  reserved and unused.
- **The BKL** — built (`sync.RecursiveSpinLock`) and taken nowhere. With
  `CONFIG_PROCESS_SMP=n` it can never be contended, so wiring it into every
  kernel entry buys nothing today and changes the syscall hot path. It goes in
  with core 1, which is the milestone it exists to serve.
- `hardfault_callee` and `ctx_ring` — genuinely per-CPU, but the first is
  written by a naked asm stub that would have to index by `coreid`, and both
  are only reachable from a second core that does not exist yet. Phase 6.

**Diagnostics whose SMP failure mode is a wrong number, not corruption.**
`perf_profile`'s ~35 counters (compiled out entirely unless
`CONFIG_INSTRUMENTATION_PERF_PROFILING`), `load_profile`, `benchmark.previous`.
They should become per-CPU and summed; none of them can corrupt anything.

**Pre-existing limitations that are not synchronization.**

- **`libs/zfat` was single-volume, and it failed silently. Fixed.** There were
  three single-instance points: `FF_VOLUMES` was 1 (the build never passed
  `-Dvolume-count`), there was one `global_fs`, and `disks[]` had one slot that
  every instance wrote as `disks[0]`. A second mount therefore did not fail --
  it *succeeded*, repointed `disks[0]` at the new device and remounted
  `global_fs` on it, after which the first mount point read and wrote the second
  one's device with no diagnostic. Nothing hit it only by luck of the board
  definitions: `fatdisk0` exists only on the QEMU boards and the RP2350 has only
  the SD card.

  Note this was never a *concurrency* bug, and it is not what makes FatFs safe
  on two cores -- `fs_lock` is, and it has to stay one lock for all volumes
  regardless, because `LfnBuf`, `DirBuf` and `CurrVol` are shared across volumes
  inside `ff.c`. Multi-volume support changes nothing about the SMP picture.

  Each `FatFs` now claims a drive number at `init` and returns it at `delete`,
  carries its own `FATFS`, writes `disks[volume]`, and addresses every
  path-based call through `volume_path` -- because FatFs resolves an unprefixed
  path against its *current* drive, which is exactly how the aliasing happened.
  `FF_VOLUMES` is 4 on both build paths, from one constant in `build.zig`.

  The host fs tests exercise the case directly: two instances over independent
  device stubs, and a file created through one is asserted absent through the
  other. Under the old code both lookups hit the same device.
- littlefs is built without `LFS_THREADSAFE` and is **not mounted**. Wire its
  `.lock`/`.unlock` to a `RankedMutex(.fs)` when it is.
- `mmc_io.zig` still masks interrupts across a card transfer (`:84,:117,:159`).
  Every path that reaches it from a filesystem holds `dev_lock` already, so the
  mask is redundant there; the raw `/dev/mmc` path does not, and giving it the
  same seek-then-transfer atomicity needs the VFS to express that pair. Worth
  doing, but it is a latency fix rather than a correctness one.

### The console lock excludes the other core, not this core's handlers

`console_lock` is the one lock in the table held **without** masking interrupts,
and that is deliberate rather than an oversight. The console is a blocking
per-byte UART: a hundred-byte line at 460800 baud is over two milliseconds, so
`spin_irq` here would blow the ~93 µs RX-FIFO budget by an order of magnitude —
the lock would create the very problem it sits next to.

So it excludes the other core, and same-core interrupt context does not block on
it: a handler takes it if free and writes anyway if not. That is exactly today's
behaviour (interleaved bytes) rather than a regression, and it is what the plan
already asks for on the panic path — a garbled panic beats a hung panic.

It cannot deadlock: a thread can never *find* it held by a handler on one core,
because handlers run to completion. Being the innermost rank, it cannot invert
against anything either, which is what lets any code log while holding anything.

### The last unbarriered seqlock

`process/xipstat_file.zig`'s sequence was a plain `+%=` on a `volatile u32`.
`volatile` stops the *compiler* reordering and says nothing to a second core, and
the sequence is the entire protocol. It is an `Atomic(u32)` with `seq_cst`
ordering now.

Its totals are three fields read together, which `Seq64` does not model, so the
protocol stays hand-rolled here and only its ordering is fixed. A multi-field
guard is the natural generalisation if a third user ever appears.

### The loader, and the third correction to the rank table

`loader_lock` is **rank 8, a sleeping mutex** — not the rank 40 `spin_irq` the
table first specified. Both parts of that were wrong for the same reason: the
loader reads the executable *through the VFS*, so holding it across a load takes
`mount` (10), `fs` (20) and `dev` (30) underneath. At rank 40 that is an
inversion on every exec, and a spinlock across milliseconds of card I/O blows
the ~93 µs console budget by two orders of magnitude.

It is held across the **whole load**, not just the tables, and that is the point.
`Loader.get_shared_data` is check-then-act across a lookup and an insert: two
contexts can both miss, both create the image, and one `put` overwrites the
other — leaking an image and leaving a `users` count that never reaches zero.
Closing that needs the lock held across miss → create → insert, and the create
*is* the load. Guarding only the tables would have looked like a fix and been
none.

**`prepare_exec` had to give up its window first.** It held preemption off from
its first line to its last, which spans the load — so a sleeping `loader_lock`
inside it would have been a block with preemption disabled, which is a hang and
which `RankedMutex` refuses outright. The window now starts where it is actually
category (C): at `reallocate_stack`, where the process's own stack is rewritten
and the core is handed to its parent. Everything above that is preemptible.

lockdep found the nesting immediately, as it has every time: `load_executable`
drops the previous image before installing the new one, so it called
`release_executable` from inside the lock. Same `*_locked` split as FatFs's
`format` and the mount tree's `umount`. That is now three subsystems where the
identical mistake was caught by the identical check.

### The system clock, and a seqlock to read it with

`systick.tick_counter` was the inventory's `AT + PC` entry and it needed both,
for reasons that pull in opposite directions:

- **SysTick is per-core hardware** (it is in the SCS), so core 1 gets its own
  interrupt. A shared counter incremented by both runs at twice wall-clock
  speed — and unlike most per-CPU state, a *clock* must not be summed across
  cores either. So exactly one core advances it (`timekeeper_core`), which also
  leaves it with a single writer. Every other core's SysTick still fires and
  still drives its own preemption, off a per-CPU `last_preempt`.
- **It is 64 bits on a machine with no `LDREXD`**, read concurrently by
  `sysinfo` (and, until it moved to the microsecond wall clock, by
  `sleep_for_us`). A plain two-halves read can catch the increment
  mid-carry: `0x0000_0000_FFFF_FFFF` becoming `0x0000_0001_0000_0000` reads as
  `0x0000_0001_FFFF_FFFF`, four billion ticks in the future.

Hence `sync/seqlock.zig`. `Seq64` stores the value as two `u32` halves accessed
atomically rather than as a plain `u64` field — a plain read can be reordered
around the sequence checks meant to bracket it, and `Atomic(u64)` is refused at
comptime anyway. Readers retry; the writer never waits, which is what makes it
usable from an interrupt handler.

`get_system_ticks()` returns a **value** now. It used to hand out a
`*const volatile u64` for callers to dereference at their leisure, which is
precisely the read a seqlock cannot protect: there is no way to retry a raw
dereference.

`process/xipstat_file.zig` still has the tree's hand-rolled seqlock, with a
plain `sequence +%=` and no barriers. It should move onto `Seq64`.

### A deadlock the sleeping mutex can hit *on one core*

Worth stating separately, because it is not an SMP hazard and it caught me out
after the FatFs lock had already shipped and passed a board run.

`sys_read` and `sys_write` release their `block_context_switch` window *before*
touching the file; `sys_open`, `sys_unlink`, `sys_stat`, `sys_getdents` hold
theirs *across* it. So one process can be parked holding `fs_lock` while
preemptible, and another can contend for it with preemption disabled. Blocking
then waits for a reschedule that `do_context_switch` refuses to perform — a hang,
not a livelock, and a narrow enough window that 4543 hardware tests did not hit
it.

`RankedMutex` now refuses to block when preemption is disabled, the same way it
refuses to block in a handler, and for the same reason: the *yield* is what is
illegal, not the acquire. An uncontended acquire from either context stays
legal, which is what keeps boot and shutdown working.

The real fix is phase 3(B) — those syscalls should hold a named lock rather than
refuse to be preempted. **This is the strongest argument for doing that
conversion**, ahead of adding any further named locks: every sleeping lock added
below a `block_context_switch` window inherits the same trap. `loader` would
have been the fourth, which is why it is not done yet.

### Phase 3(B) has started: `sys_open` is preemptible

`sys_open` is the first conversion and the pattern for the rest. Its window was
doing three jobs, each of which now has a named lock underneath it — kernel-heap
allocation (`kheap`), the VFS walk and filesystem work (`mount`, `fs`, `dev`),
and `get_current_process()` (per-CPU, and the caller *is* the current process).

The fourth candidate turned out not to need one at all: **`_fds` is per-process
and there is one thread per process**, so two cores means two separate fd
tables. It becomes shared when phase 9 adds threads, and that is where its lock
belongs — the `fd` rank stays reserved and unused until then. That is worth
knowing before converting the rest, because most of the remaining sites touch
the fd table and it is easy to assume it needs covering first.

To convert one of the others, check that list against what its window spans. The
ones holding a window across filesystem I/O were the same shape as `sys_open`
and are **done**: `sys_fstat`, `sys_isatty`, `sys_close`, `sys_unlink`,
`sys_stat`, `sys_lseek`, `sys_getdents`, `sys_access`, `sys_chdir`,
`sys_getcwd`, `sys_fcntl`. Twelve of the 37 sites are gone; 20 remain.

Deliberately **not** in that batch:

- **`sys_mmap` / `sys_munmap` / `sys_mremap`.** They reach
  `ProcessMemoryPool.tag_next_heap`, a one-shot flag whose own comment asserts
  "mmap serializes via block_context_switch and exec is single threaded". The
  flag is now read-and-cleared under `pagepool_lock`, so it cannot tear — but
  the *protocol* (a tag set by one caller must be consumed by that caller's next
  allocation) still assumes no interleaving, and that wants its own change.
- **`sys_exit` / `sys_kill` / `vfork` / `prepare_exec`**, whose windows are the
  hand-off pairs described above rather than data protection.
- **`sys_dup`**, which has history: a `dup2(fd, fd)` refcount use-after-free was
  found there, so it is worth converting on its own rather than in a batch.

**Second batch, done:** `sys_getpid`, `sys_prlimit`, `sys_ftruncate`, `sys_dup`,
`sys_read`, `sys_write`. Twenty-three of the 37 sites are gone; **14 remain**.

`sys_dup`'s window existed for a reason that had since expired -- its comment
justified it as guarding "the kernel heap, which newlib's allocator does not
guard". `__malloc_lock` is a ranked recursive spinlock now and the allocator
wrapper's accounting sits under it, so the heap guards itself. Worth checking
the *stated* reason for each remaining window before assuming it still holds.

`sys_read` and `sys_write` are the ones that mattered most. They took the window
for validation and the fd lookup and then released it explicitly *before* the
transfer, while every other file syscall held its window across the I/O. That
asymmetry is precisely what made `fs_lock` deadlockable on one core -- these two
could park holding it while preemptible, and a `sys_open` contending with
preemption disabled could never be rescheduled to get it. With both sides
preemptible the asymmetry is gone, along with six hand-written `unblock` calls
on their error paths.

A note on verifying these: the first QEMU run after this batch failed 14/14 with
the target crashing at boot, and it was **not** the conversion —
`[ERR][yasld] image needs fpu-sp+dcp ... this machine provides fpu-sp` — a
`rootfs.img` left over from an rp2350 build being refused by the mps3 kernel.
Pass `--rebuild-rootfs` after switching defconfigs, or the failure looks total
and means nothing.

### What still blocks `pagepool`

`schedule_next()` runs in PendSV and reaps the terminate list inline:
`p.deinit()` reaches `ProcessMemoryPool.release_pages_for`. That makes the page
pool lock impossible to place correctly today, in *both* directions:

- a **sleeping mutex** cannot block in a handler, and PendSV is one;
- a **`spin_irq` lock** — which is what the table below specifies — would hold
  interrupts off for the duration of a pool operation, and the pool's own source
  records `mmap costs 407 us a call`. Against the ~93 µs console budget that is
  a 4x blowout, and it would be a *regression*: `block_context_switch` masks
  interrupts only briefly to bump a counter, so mmap runs with interrupts on
  today.

**Resolved by option 2 below.** `allocate_pages` now reserves under the lock and
clears outside it, so `pagepool_lock` exists and is `spin_irq`. The two ways out
were:

1. **The `kreaper` thread** the plan calls for. It works, but it complicates
   shutdown: `schedule_next` returns `.ReturnToMain` when the process list is
   empty, and a permanent reaper process means it never is, so the kernel would
   no longer stop when the root process dies.
2. **Shorten the critical section instead.** The 407 µs is dominated by
   `memory.zero_pages` — the `perf.PoolPhase` split (scan/mark/book/**clear**)
   exists to measure exactly this. Once a run is marked used and recorded in the
   mapping list it belongs to the caller, so the clear can happen *outside* the
   lock. That leaves a bitmap scan and a hashmap insert under it —
   microseconds — and `spin_irq` becomes the right answer, from PendSV included.

Option 2 is smaller, removes a latency problem rather than moving it, and needs
no new scheduling entity. **The reaper thread is therefore no longer a
prerequisite for anything** -- it is an optimisation, and the plan should stop
listing it as a phase-4 blocker.

The same argument cleared `proctable_lock`, which was blocked only by sharing the
reaping walk, and it is now done: rank 50, `spin_irq`, held across
`schedule_next`'s reap *and* its pick (they are one decision about the table),
plus `get_process_for_pid`, `is_empty` and every `processes` / `terminate_list`
mutation. `delete_process` guards its mutation with a block rather than a
`defer`, because its vfork branch never returns.

The ordering that makes this work is worth stating: `proctable` (50) is outside
`pidmap` (70), `pagepool` (80) and `kheap` (90), so a reap can release a
process's pid, pages and kernel allocations with the table held -- and inside
`fs` (20) and `dev` (30), which is exactly why `clear_fds` had to move out of
`deinit` first.

`pidmap_lock` was not blocked by this and is done: `release_pid` is also called
from PendSV, but a bitset scan and a bit flip are microseconds, so `spin_irq` is
the right answer there and costs nothing.

**The next unit of work is the `kreaper` thread**, followed by `pagepool` and
`proctable`. After that, `dev`-rank locking for the SDIO internals, which is what the (B) sites still implicitly protect once
FatFs no longer needs them to. After that, the sites can be converted one
subsystem at a time, with `assert_held` at the head of each guarded function --
and each conversion wants a hardware smoke run, not just QEMU, because it
changes when a process can be descheduled inside a syscall.

The BKL is built (`sync.RecursiveSpinLock`) but deliberately not yet taken at
kernel entry: with `CONFIG_PROCESS_SMP=n` it can never be contended, so wiring
it in buys nothing today and changes the syscall hot path. It goes in with core
1 bring-up, which is the milestone it exists to serve.

### What landed

The primitives live in **`source/kernel/sync/`**, not in `source/arch/` as
originally sketched. Only the four things that genuinely differ per target sit
in the arch layer (`lock_free_bits`, `clear_exclusive`, `cpu_relax`,
`signal_event`, `owner_id`); the lock and the atomics themselves are one
implementation shared by the device, QEMU and the host. That is what makes the
host `std.Thread` race tests in [Testing](#testing) test the same code the M33
runs, which the plan asks for and three copies of a spinlock could not deliver.

- `sync/atomic.zig` — `Atomic(T)` over `std.atomic.Value`, refusing at comptime
  any width that would become an `__atomic_*` libcall. Pointers are exempted by
  construction so a 64-bit host build still compiles `Atomic(?*T)`.
- `sync/spinlock.zig` — `SpinLock` with `lock_irqsave`/`unlock_irqrestore`,
  `try_lock`, `assert_held`, and `Isolated(T)` for the reservation granule. The
  lock word holds an owner token, so a recursive acquisition panics with a name
  instead of hanging.
- `sync/placement.zig` — the PSRAM assertion, installed into `libs/oop`'s
  refcount through an injectable hook (`kernel.sync.init()`), so the standalone
  library gets the board's memory map without depending on the kernel.
- `sync/refcount.zig` — one implementation for the seven hand-rolled counters
  (ramfs data + directories, driverfs, procfs, mmc driver + partitions, and the
  mmc container-level `global_refcount`); `dynamic_loader/source/refcount.zig`
  is the same thing for yasld, which imports neither the kernel nor `libs/oop`.
  All of them had both defects: a non-atomic increment that can lose a
  reference, and a decrement whose zero-test was a separate read.
- `sync/locks.zig` — the rank table below as a Zig enum, `Ranked(rank)` with a
  per-CPU held-set that panics on a rank inversion, and the `RecursiveSpinLock`
  for the BKL.
- `sync/percpu.zig` — `PerCpu(T)`; `sync/preempt.zig` — the preempt counter,
  `need_resched`, and the deferred re-trigger.
- `scripts/verify_atomics.sh` — the disassembly gate, wired into the QEMU CI job.

### `CONFIG_PROCESS_SMP` — what one core still has to pay for

The knob is **not** `hal.cpu.number_of_cores() > 1`. The RP2350 reports two cores
and we park one, so deriving it from the hardware would buy cross-core
synchronization on a chip where nothing else is running. It defaults to `n` and
flips to `y` with core 1 bring-up in phase 6; `configs/host_defconfig` sets it
`y` so the host unit tests exercise the SMP path under real `std.Thread`
contention.

The split matters, because "one core" does not mean "no synchronization" — the
scheduler is preemptive, so a read-modify-write shared between thread and handler
context races on one core exactly as it does across two.

| Kept with SMP off | Dropped with SMP off |
|---|---|
| `lock_irqsave` / `unlock_irqrestore` — the mask *is* the exclusion | the `wfe`/`sev` wait-and-wake back-off |
| the atomic acquire and the `stl` release ordering | the SIO CPUID load for the owner token, and the bounds check on its `@intCast` |
| `Atomic(T)` and its lock-free width rule | the second per-CPU slot; `current_core()` folds to a comptime 0 |
| `assert_held`, recursion detection | — |

A contended `lock()` on one core cannot be a wait: whoever holds it cannot make
progress while we spin, because an interrupt handler runs to completion before we
get the CPU back. So it panics with that reason instead of hanging, which is
strictly better than the spin it replaces.

Measured on the rp2350 ReleaseSafe kernel: `sev`/`wfe` drop to **zero
occurrences**, and the acquire preamble goes from an SIO load plus a bounds check
plus a panic branch to a single `movs r1, #1`.

The two reserved-but-unreferenced `CONFIG_PROCESS_*_HW_SPINLOCK_NUMBER` knobs are
deleted, along with the SIO spinlock backend they named.

Deleted as planned: `hal/interface/atomic.zig` and all six backends,
`KernelMutex`, `enter_critical_section`/`leave_critical_section`, and the
dangling `bl unlock_pendsv_spinlock` in `armv6-m/context_switch.S`.
`KernelSemaphore` now takes a real lock where it used to call a spinlock backend
that released locks it had failed to take.

**Still deliberately deferred:** the boot-time SIO spinlock force-release loop
in `rp2350/startup/crt.zig` is now dead but was left in place — deleting it
changes hardware boot behaviour, and it costs nothing to keep until the doorbell
work in phase 6 has to touch it anyway.

### Phase 3's mechanism, and what is left of it

`block_context_switch` / `unblock_context_switch` are now deprecated aliases
over the per-core preempt counter, so the global `bool` + global `i32` are gone
and `do_context_switch` **records** a refused reschedule instead of dropping it.
That fixes the lost-SysTick timeslice bug on one core today.

**The release path is now strict.** Every release has an acquire it pairs with,
so `unblock_context_switch` panics on an unmatched one (Debug/ReleaseSafe;
clamps in ReleaseFast so a missed site is a test failure, not a bricked image).
Getting there meant fixing four sites that looked unpaired, and none of them
turned out to be a genuine asymmetry:

- **`waitpid`** leaked its window entirely when the pid was unknown or the child
  had already finished, and released once per iteration when it did wait.
- **`prepare_exec`** released on only two of its five exits — and released
  *twice* on the vfork hand-off, once itself and once through the assembly.
- **`delete_process`** released once per iteration of its tail loop; now once,
  closing the window `sys_exit` / `sys_kill` opened.
- **`process_syscall_unblock_context_switch`** (`context_switch.S:340`) was
  **unreachable**. `dispatch_syscall` sets `r0 = 0` before its `svc` — the svc
  immediate is not what the handler reads — userspace syscall numbers start at
  5, and nothing else issues an `svc` with `r0 = 1`. Deleted.

The two remaining assembly releases (`process_get_back_to_parent_vfork`,
`process_vfork_child`) are genuine halves of windows opened in `vfork` and
`prepare_exec`, which cannot use `defer` because they never return normally.

**Phase 3 is complete.** All 37 sites are classified and converted, the alias is
deleted from `kernel.process`, and `scripts/verify_no_block_context_switch.sh`
runs in CI so it cannot come back — the completion test this document asked for.

How the 37 landed:

- **(B) named data lock, window removed** — the file syscalls (`open`, `close`,
  `read`, `write`, `stat`, `fstat`, `unlink`, `lseek`, `getdents`, `access`,
  `chdir`, `getcwd`, `fcntl`, `ftruncate`, `dup`, `isatty`), the mmap trio, and
  `file_log.drain`, whose window was explicitly "so no process FS op can
  interleave (FatFs is not reentrant)" -- exactly `fs_lock`'s job now.
- **(B) moved onto a lock in place** — `create_process` and the process-table
  walks onto `proctable_lock`.
- **Redundant, deleted outright** — `get_current_process`, which wrapped a
  single per-CPU pointer load in two PRIMASK round-trips on one of the
  most-called functions in the kernel; and `sys_getpid` / `sys_prlimit`.
- **(C) PendSV window, kept but renamed** — `sys_exit`, `sys_kill`, `vfork`,
  `delete_process`, `arch_store_vfork_back_point`, `wait_for_process`. These
  were never data protection: they hold PendSV off across a hand-off that
  assembly completes, so they stay as `preempt_disable()` and simply stop
  pretending to be a lock.

Two things fell out that are worth carrying forward:

- **Check the window's stated reason before assuming it still holds.**
  `sys_dup`'s comment justified it as guarding "the kernel heap, which newlib's
  allocator does not guard"; `__malloc_lock` had since become a ranked recursive
  spinlock, so the heap guarded itself and the window was protecting a fact that
  had moved.
- **`tag_next_heap` is gone.** It was a one-shot flag a caller set immediately
  before allocating, and its own comment conceded the protocol only held because
  "mmap serializes via block_context_switch". It is an argument now
  (`allocate_pages_from`), so the handshake cannot be lost.

`assert_held` is now on the page pool's bitmap surgery (`mark_used`,
`mark_free`), which is the sharpest place for it: those two are called only from
inside `reserve_pages` and `free_pages`, so a future caller reaching them by
another route is exactly the mistake the assert exists to catch. Extending it to
the rest of the guarded structures is cheap and worth doing as each one is
touched.

**The reservation-granule item from phase 0 is closed too.** `Isolated` existed
but was applied to nothing, so every named lock shared a granule with its
neighbour. Rather than wrap each declaration, `Ranked`, `RecursiveRanked` and
`RankedMutex` are now granule-aligned themselves -- which also rounds their size
up to a multiple of it, so two locks declared next to each other cannot collide.
The bare `SpinLock` stays small on purpose: per-file and per-process locks would
pay 32 bytes each for a hazard they will never see.

Phases 0–5 change **no behaviour on one core**. That is deliberate: it is what
makes the dangerous part reviewable, and it means the first two thirds of this
work can land and be tested without a second core running at all.

---

## Why

The RP2350 has two Cortex-M33 cores. We use one. Half the compute in every board
we ship is idle, and the workloads that hurt most — `tcc` compiles, SD I/O,
console drain — are exactly the ones that would benefit.

The blocker is not bring-up. It is that **the kernel has no synchronization**,
and a great deal of code silently depends on that fact.

### What exists today

- **One real lock in the whole tree**: `__malloc_lock` / `__malloc_unlock`
  (`source/kernel/interrupts/system_stubs.zig:229-258`), a PRIMASK nesting
  counter. Its own comment (`:213-228`) explains it was added after free-list
  corruption from a SysTick→PendSV preemption inside `malloc`, and argues
  correctly that a blocking mutex is the wrong primitive there. It does not
  cross cores.
- **`block_context_switch()` is not a lock.** It is a per-core interrupt mask
  plus a global flag (`source/kernel/interrupts/system_call.zig:49-86`) that
  makes `do_context_switch` return `3` ("ignore"). **37 acquire sites across 7
  files use it as if it were mutual exclusion** — 86 references to the
  block/unblock pair, concentrated in `syscall_handlers.zig` (44 refs) and
  `process_manager.zig` (25). On a second core it provides exactly zero.
- **`KernelMutex` — the one primitive shaped like a lock — is never called.**
  `source/kernel/interrupts/kernel_mutex.zig:20-41`. Its only instance is a dead
  field: `process_manager.zig:132`.
- **`hal.atomic.Atomic(T)` is not usable as a building block.** The spinlock ID
  is `hash(@typeName(T)) % n` (`hal/interface/atomic.zig:9-23`), so every
  `Atomic(u32)` in the system — every semaphore counter — contends on one
  physical lock. On RP2350, `lock()` is a **try**-lock that returns `false` on
  contention (`hal/source/raspberry/rp2350/source/atomic.zig:35-40`) while
  `load`, `exchange` and `compare_exchange` **ignore that result and proceed
  unlocked**, then `unlock()` unconditionally releases a lock they may not own.
  Its only collision guard is a single hardcoded `u32`-vs-`u16` comparison
  (`:90-94`).
- **No LDREX/STREX, no `@atomicRmw`, no `@cmpxchg`, no `std.atomic`** anywhere in
  `source/` or `hal/`. The only `dmb` in the tree is in `source/arch/arm-m/sync.zig`.
- **No IPI.** `hal.irq.Type` is only `{systick, pendsv, supervisor_call}`
  (`hal/source/common/cores/arm/cortex-m/irq.zig:25-29`) and `trigger()` only
  pokes the core-local `SCB->ICSR`.
- `enter_critical_section` / `leave_critical_section` (`cortex-m/irq.zig:57-67`)
  are bare `cpsid i` / `cpsie i` — **not nesting-safe, and never called**. Dead API.
- `source/arch/armv6-m/context_switch.S:46` calls `bl unlock_pendsv_spinlock`,
  **an undefined symbol** — a fossil of an abandoned spinlock design. No
  defconfig builds armv6-m.

### What already leans toward SMP

Not nothing, which helps:

- `hal.cpu.number_of_cores()` returns **2** on RP2350 and `coreid()` reads SIO
  CPUID (`hal/source/raspberry/rp2350/source/cpu.zig:38-44`).
- `ProcessManager.core` is already `[hal.cpu.number_of_cores()]*ProcessType`
  (`process_manager.zig:131`), accessed as `core[coreid()]` at 12 call sites.
  But `core[1]` is never initialized — only `create_root_process` (`:254`)
  populates index `coreid()`.
- `Process.current_core` exists (`process.zig:153`, set at `:503`) but is
  **written and never read**.
- The SIO struct declares the inter-core FIFO (`sio.zig:59-62`) — unused.
- `Kconfig:76-82` reserves `CONFIG_PROCESS_HW_SPINLOCK_NUMBER` and
  `CONFIG_PROCESS_CONTEXT_SWITCH_HW_SPINLOCK_NUMBER` — referenced by zero lines
  of Zig.

There is exactly one deliberate lock-free protocol in the tree: the seqlock in
`source/kernel/process/xipstat_file.zig:57-120`, and even it uses a plain
non-atomic `sequence +%=` with no barriers.

---

## Decisions

| Decision | Choice |
|---|---|
| End state | **Full symmetric SMP** — either core runs any runnable process, IPI-driven reschedule |
| Primitives | **Exclusive-monitor (LDAEX/STLEX) spinlocks** in `source/arch/`; SIO hardware spinlocks only where genuinely required |
| Threads | **In scope** — `clone()` with a shared address space, per-thread `errno`, TLS, real pthreads |

---

## Hardware facts that shape the design

Both of these came out of the vendored pico-sdk, and each one invalidates an
otherwise-reasonable design. They belong up front.

### 1. On RP2350, exclusives are the sanctioned mechanism — SIO spinlocks are the fallback

`hal/libs/pico-sdk/src/rp2_common/hardware_sync_spin_lock/include/hardware/sync/spin_lock.h:13-17`:

```c
// PICO_CONFIG: PICO_USE_SW_SPIN_LOCKS, Use software implementation for spin locks,
//              type=bool, default=1 on RP2350 due to errata, group=hardware_sync
#ifndef PICO_USE_SW_SPIN_LOCKS
#if PICO_RP2350
#define PICO_USE_SW_SPIN_LOCKS 1
#endif
#endif
```

and `:113-130` implements that lock with `ldaexb` / `strexb` under
`__ARM_ARCH_8M_MAIN__`. **Raspberry Pi's own default on this chip is software
exclusives over the SIO hardware spinlocks**, because of the same errata
(RP2350-E2) that already forces us to blacklist 13 of the 32 SIO locks
(`hal/source/raspberry/rp2350/source/atomic.zig:26-29`).

This confirms the chosen primitive, and it confirms the RP2350 implements a
**global** exclusive monitor — a purely local monitor would make that software
spinlock incorrect between cores.

Note the exact idiom: `ldaexb`/`strexb`, i.e. **load-acquire**-exclusive, plus an
explicit acquire fence. Armv8-M Mainline has the acquire/release exclusive forms;
use them rather than bare `ldrex`/`strex` + `dmb`.

### 2. `ACTLR.EXTEXCLALL` is already on — and core 1 forgetting it fails silently

`hal/libs/pico-sdk/src/rp2_common/hardware_sync_spin_lock/sync_spin_lock.c:24-42`:

> Force use of global exclusive monitor for all exclusive load/stores: makes
> multicore exclusives work without adding MPU regions. For something more
> exotic, like having multicore exclusives in internal SRAM **and also
> single-core exclusives in external PSRAM (not covered by the global monitor on
> RP2350)** you must clear this and add your own Shareable regions.

**This is already running on core 0 today, by accident of the build.** That
function is registered via `PICO_RUNTIME_INIT_FUNC_PER_CORE`, which expands to a
`.preinit_array` entry; the rp2350 linker script `KEEP`s `.preinit_array`
(`hal/source/raspberry/rp2350/linker_script.ld:80-83`) and `crt_init()` calls
`__libc_init_array()` (`startup/crt.zig:186`), which runs it. Confirmed in the
shipped binary:

```
$ nm zig-out/bin/yasos_kernel | grep -i extexcl
10039860 T __pre_init_spinlock_set_extexclall
100029f9 t spinlock_set_extexclall
```

So cross-core exclusives will work on core 0 without touching `mpu.zig` at all.

**`ACTLR` is a per-core register in the PPB, and core 1 must set it in its own
bring-up path.** If it does not, every kernel spinlock silently degrades to a
local-monitor lock providing zero exclusion — no fault, no log line, presenting
as random memory corruption rather than as a lock bug. This is the single
easiest way to lose weeks on this project.

**Mitigation, and it is cheap:** after setting `ACTLR` in `crt_init_core1`, run a
short two-core LDREX/STREX mutual-exclusion self-test *before* starting the
scheduler. `ACTLR` is also not modelled in
`hal/source/common/arch/arm/armv8-m/registers.zig` and must be added.

**The MPU angle is moot on the SMP target today.** `mpu.zig:53` hardcodes
`SH[4:3] = 0b00` (Non-shareable), which is safe *only because* `EXTEXCLALL`
overrides shareability for exclusives — but note that
`CONFIG_PROCESS_USE_MPU_KERNEL_PROTECTION` is set **only in the two QEMU
defconfigs**, not in `pimoroni_pico_plus2_and_vga_defconfig` or
`mspc_defconfig`. `enable_kernel_protection()` does not execute on the RP2350 at
all right now. Still: correct the comment to record the `EXTEXCLALL` dependency,
because if anyone ever clears it (e.g. to allow exclusives in PSRAM), every
region carrying a lock word must become `SH = 0b11`.

One real latent bug there regardless: **`next_region` (`mpu.zig:70`) is a module
global and the MPU is per-core** — core 1's programming pass would continue from
core 0's index and program regions 5..9 on a part with 8. Make it a local.

**No lock or atomic may live in PSRAM.** This is an invariant, not a caveat:

- The **kernel heap is safe** — it is in `kernel_ram`, internal SRAM
  (`hal/source/raspberry/rp2350/linker_script.ld:153-160`).
- The **process memory pool's tier 1 is PSRAM at `0x11000000`**
  (`hal/source/raspberry/rp2350/source/memory.zig:47-52`,
  `source/kernel/memory/heap/process_memory_pool.zig:48`).

So any lock or atomic reachable from process-allocated memory is silently
broken — the exclusive succeeds locally and provides no cross-core guarantee.
This bites in two specific places:

- **`libs/oop` refcounts.** `__refcount` is `?*i32`
  (`libs/oop/src/interface.zig:461`) — a *heap pointer*, allocated in `clone()`
  (`:512`). Making it atomic requires auditing which allocator backs it for
  process-owned objects.
- **Userspace pthread mutexes** (phase 9), which land in the process heap and can
  therefore be in PSRAM.

Phase 0 must ship an assertion or allocator split that makes "this lock is in
SRAM" checkable rather than assumed.

### 3. Erratum RP2350-E2 is not what our code says it is — and it couples two decisions

`hal/source/raspberry/rp2350/source/atomic.zig:26-29` describes E2 as a set of
broken spinlocks needing a remap table. That is wrong.
`hal/libs/pico-sdk/src/rp2_common/hardware_sync/include/hardware/sync.h:41-42`:

> RP2350 Warning. Due to erratum RP2350-E2, **writes to new SIO registers above
> an offset of +0x180 alias the spinlocks, causing spurious lock releases.** This
> SDK by default uses atomic memory accesses to implement the
> `hardware_sync_spin_lock` API, as a workaround on RP2350 A2.

The registers at ≥ `+0x180` are **exactly the doorbells** (`DOORBELL_OUT_SET`
`0x180` … `DOORBELL_IN_CLR` `0x18c`, per
`hal/libs/pico-sdk/src/rp2350/hardware_regs/include/hardware/regs/sio.h:1936,1984`).

So the erratum reads: **using doorbells corrupts the SIO hardware spinlocks.**
That couples two decisions that look independent — you cannot keep
`hal/interface/atomic.zig` *and* use doorbells as the IPI. Since the SIO spinlock
backend is being deleted anyway (it releases locks it never acquired), this is
consistent, but it must be recorded so nobody reintroduces one half of it.

Note also that `bugfree_spinlocks = {5,6,7,10,11,18..31}` in `atomic.zig` is not
derived from E2 at all — it is near enough the complement of pico-sdk's
*reserved* IDs (`hardware/sync/spin_lock.h:22-76`: IRQ=9, TIMER=10,
HARDWARE_CLAIM=11, RAND=12, ATOMIC=13, OS1/OS2=14/15). The comment and the list
are both hazards; delete the backend.

Nothing else depends on SIO spinlocks: the pico-sdk C that *is* compiled already
resolves `spin_lock_blocking` to the **software** LDAEXB/STREXB variant, because
`PICO_USE_SW_SPIN_LOCKS` defaults to 1 on RP2350. `nm` confirms `_sw_spin_locks`
sits in kernel `.bss`. The only two consumers are `atomic.zig` and the boot
force-release loop at `crt.zig:250-253`; both go away.

### 4. The IPI should be a doorbell; `NVIC_STIR` cannot work

The RP2350 adds **doorbells** for cross-core interrupts — `SIO_IRQ_BELL = 26`
(`.../regs/intctrl.h:42`), rung with `sio_hw->doorbell_out_set`
(`pico_multicore/include/pico/multicore.h:344-360`; doorbells "are not available
on RP2040"). Level-held, idempotent, no queue, no data — exactly IPI semantics,
8 bits available. The receiver acknowledges via `DOORBELL_IN_CLR` (W1C).

The inter-core **FIFO** should be left for the core-1 launch handshake, and is
the fallback if the doorbell erratum turns out to be blocking on the rig's
stepping.

**`NVIC_STIR` is not an option**: the NVIC is a per-PE block, so STIR pends an
interrupt on the *writing* core only. Useful as a self-directed soft IRQ, useless
as an IPI. Say so in the header so nobody re-derives it.

**`hal/source/raspberry/rp2350/source/sio.zig` now carries the doorbell
registers**, and the struct audit this section called for was done first and
found more than the doorbells: the GPIO block followed **RP2040** ordering, and
the RP2040's `DIV_*` registers do not exist on this part at all. See
[Core 1 on the RP2350](#core-1-on-the-rp2350) for why `@sizeOf` could not catch
either. What remains here is `hal.irq.Type`, which must still grow beyond
`{systick, pendsv, supervisor_call}` to carry an IPI, and the per-core NVIC
enable that goes with it — the NVIC is a per-PE block, so each core has to enable
`SIO_IRQ_BELL` for itself.

---

## Phases

### Phase 0 — Primitives

New: `source/arch/arm-m/atomic.zig`, `source/arch/arm-m/spinlock.zig`.

Prefer **Zig's `@atomicLoad` / `@atomicStore` / `@atomicRmw` / `@cmpxchgStrong`**,
which lower to LDAEX/STLEX on `thumbv8m.main`, over hand-written assembly. Verify
the lowering by disassembly before building anything on it — this Zig is known to
mishandle *direct volatile field access* (the `uart.zig` idiom exists for that
reason), so "it compiled" is not evidence.

Ship:

- `SpinLock`: `lock()`, `try_lock()`, `unlock()`, with `wfe`/`sev` back-off.
  `arch.sync.wait_for_event()` already exists and is unused.
- **`spin_lock_irqsave()` / `spin_unlock_irqrestore()`** — this is the one that
  matters. Almost every structure in the inventory is touched from *both* handler
  and thread context, so a plain spinlock self-deadlocks the moment an interrupt
  lands on a core that holds it. `arch.sync.save_and_disable_interrupts()`
  (`source/arch/arm-m/sync.zig:51-66`) is already the correct nesting-safe
  PRIMASK helper to build on.
- Barriers: state where `dmb` / `dsb` / `isb` are actually required, rather than
  the current scatter of `memory_barrier_release()`/`_acquire()` that are both
  plain `dmb` (and a `data_synchronization_barrier` that emits a redundant
  `dsb; dmb`). Express acquire/release on a *single* location as `ldaex`/`stl`
  orderings, not as a separate `dmb`. There are no data caches for SRAM on
  RP2350 and the XIP cache is shared between cores, so **no cache maintenance is
  ever required**.
- Single-core implementations with the same API so the host and unit-test targets
  keep building: `source/arch/host/`, `source/arch/ut/`, qemu mps2/mps3. Note
  qemu mps2/mps3 are armv8-m — give them the *identical* exclusives path, just
  uncontended, so CI runs the same code as hardware. Make the **host** backend
  genuinely concurrent (`std.atomic`), because that is what makes the host race
  tests in [Testing](#testing) possible; `source/arch/ut/arch.zig` should point
  at it rather than at today's no-op stubs.

Three correctness traps that belong in the primitive itself:

- **Ban 64-bit atomics at comptime.** Cortex-M33 has no `LDREXD`, so a 64-bit
  `@atomicRmw` lowers to an `__atomic_*` libcall that is **not lock-free** —
  silently. Several counters in scope are `u64` (`tick_counter`, most of
  `perf_profile`); they must become per-CPU, not atomic. Add a CI gate that
  disassembles the armv8-m kernel and asserts `ldrex`/`strex` are present and
  **no `__atomic_*`/`__sync_*` libcall is linked**.
- **Pad and align every lock word to 32 bytes.** The global monitor's exclusive
  reservation granule is implementation-defined; if two lock words share a
  granule, core A's `strex` on lock X clears core B's reservation on lock Y.
  That presents as an unbounded-retry throughput cliff, not a hang — very hard to
  diagnose. *Verify the actual granule in the RP2350 datasheet.*
- **Add `clrex` to the context-switch store path** (`context_switch.S`). A thread
  preempted between its `ldrex` and `strex` must not resume with a live
  reservation. The architecture may already clear it on exception entry —
  *verify against the Armv8-M ARM* — but `clrex` is one cycle; do it
  unconditionally rather than rely on a guarantee nobody has checked.

Also in phase 0, because they block everything after it:

- **Fix `hal/source/host/host/source/cpu.zig:36-42`** — it reports
  `number_of_cores() == 4` with `coreid()` hardcoded to `1`.
- Decide the fate of `hal/interface/atomic.zig`. Recommendation: demote to
  boot-only use or delete it. Leaving a broken `compare_exchange` in the tree
  next to a correct one is a trap.
- Delete the dead `KernelMutex` and the non-nesting `enter_critical_section`, and
  the dangling `bl unlock_pendsv_spinlock` in `armv6-m/context_switch.S:46`.

### Phase 1 — Per-CPU state

Cortex-M has no per-core general-purpose register (no A-profile `TPIDRPRW`
equivalent), so per-CPU data is an array indexed by `coreid()`, which on RP2350
is a single SIO MMIO load. Introduce `percpu[coreid()]` and a per-CPU
`preempt_count`.

### Phase 2 — Atomic refcounts

`libs/oop/src/interface.zig:461-512` plus the seven hand-rolled counters. Include
the SRAM-placement audit from hardware fact 2(b).

### Phase 3 — Split `block_context_switch`

The crux. It currently conflates **three** different meanings, and every acquire
site has to be classified as one of them:

- **(A) "do not preempt me"** — protecting a *per-core* invariant. → per-CPU
  `preempt_disable()`.
- **(B) "nobody else may touch this shared structure"** — process table, pid map,
  page pool, loader tables, VFS. → a named data lock. This is the majority, and
  the only one of the three that is a lock at all.
- **(C) "PendSV must not fire in this instruction window"** — the assembly sites
  where an exception frame is being hand-built on a stack. → `preempt_disable()`
  plus a `need_resched` flag so the dropped PendSV is re-delivered.

**Do the mechanical rename first, as its own merge**, with
`block_context_switch` kept as a deprecated alias so nothing breaks. In that step
`do_context_switch` changes from *silently return 3* to *set `need_resched` and
return 3*, and `preempt_enable()` re-triggers PendSV on the way out.

**That fixes a live single-core bug for free:** today a SysTick landing inside a
block window is simply **lost**, so the process gets a free extra timeslice — a
fairness and latency defect that has nothing to do with SMP.

Also fix `system_call.zig:78-82` in that step. `unblock_context_switch`
currently clamps a negative counter back to zero and re-enables; that is not a
safety net, it is a bug concealer that has been silently absorbing every
unbalanced pair in the tree. Make it a debug panic — it will immediately surface
the two known-broken sites below, and possibly others.

Verification has to live in the code, not a review spreadsheet — three layers:

1. **No site keeps calling a generic "block".** When the last one is converted,
   delete the alias and let the compiler find stragglers; then add a CI grep
   guard so `block_context_switch` cannot come back.
2. **`assert_locked(&locks.X)`** at the head of every function that mutates a
   guarded structure (`allocate_pages`, `get_next_pid`,
   `find_longest_matching_point`, `get_shared_data`, …). This catches sites you
   *believed* a caller covered and it did not. Debug builds only.
3. **Lockdep** (phase 4), which turns the hierarchy from documentation into a
   runtime invariant. Run the whole smoke suite in that build.

Two sites are already broken and should be fixed while passing through:

- `waitpid` (`process_manager.zig:583-612`) blocks at `:584` and **never unblocks
  on the success path** (`:610-611`).
- `prepare_exec` (`:456-569`) blocks at `:457` with no `defer`, unblocking
  manually at `:521` and `:565` — leaked on some error paths.

### Phase 4 — Lock hierarchy + BKL

Acquire in **increasing rank**, release in reverse, enforced at runtime by a
lockdep-style per-CPU `held_lock_ranks` bitmask that panics on a violation.

| rank | name | kind | IRQ-safe | leaf | guards |
|---:|---|---|:-:|:-:|---|
| 5 | `bkl` | recursive spin | yes | no | *transitional only*, deleted in phase 8 |
| 10 | `mount_lock` | **sleeping mutex** | no | no | the `MountPoints` tree — see above for why not a spin rwlock |
| 20 | `fs_lock[fs]` | sleeping mutex | no | no | per-filesystem; FatFs, littlefs, romfs, ramfs, procfs, driverfs |
| 30 | `dev_lock[dev]` | sleeping mutex | no | yes | device seek/DMA state, `g_sdio`, `aligned_buf`, the FatFs line cache |
| 8 | `loader_lock` | **sleeping mutex** | no | no | `modules.zig` + `loader.zig` tables **and the load itself** — see below for why not rank 40 |
| 50 | `proctable_lock` | spin_irq | yes | no | process table, parent/child, wait lists, `Semaphore.counter` |
| 55 | `p->fd_lock` | spin_irq | yes | yes | per-process `_fds` |
| 60 | `rq_lock[cpu]` | spin_irq | yes | no | per-core runqueue, `Thread.state` transitions |
| 70 | `pidmap_lock` | spin_irq | yes | yes | `_pid_map` |
| 80 | `pagepool_lock` | spin_irq | yes | yes | `ProcessMemoryPool` |
| 90 | `kheap_lock` | spin_irq | yes | yes | newlib free list + `malloc.zig` accounting + `_sbrk` |
| 95 | `console_lock` | spin, **not** irqsave | no | yes | `stdout.zig`, UART TX, `file_log` ring — see below |

**The counter-intuitive part is that sleeping mutexes are *outer* and spinlocks
are *inner*.** That encodes the rule that matters most:

> **Never take a sleeping mutex while holding any spinlock.**

Because ranks run mutexes-before-spinlocks, lockdep enforces it for free. The
consequence is that **no filesystem or device I/O may ever be initiated from
handler context**. Two sites violate this today and are prerequisites:

- `process_manager.zig:180-184` — the terminate-list reaper runs *in PendSV* and
  frees to the kernel heap. Move it to a `kreaper` thread woken via `try_wake`.
- `source/kernel/file_log.zig` — its drain phase must be thread-context only.

`console_lock` being the innermost leaf is what lets you log from inside
`kheap_lock` or `rq_lock`. Panic and HardFault paths use `try_lock` and print
regardless — a garbled panic beats a hung panic. Correspondingly the allocator
must never log at a rank ≥ its own; `malloc.zig` does today, so audit it.

Cross-core migration needs two `rq_lock`s: use a `double_rq_lock(a, b)` that
always takes the lower `coreid` first, and special-case it in lockdep as the one
permitted same-rank acquisition.

**Then add the BKL, and do not skip it.** One recursive spinlock at every kernel
entry (SVC both paths, PendSV, SysTick, device IRQs). With it in place, core 1
can be launched in phase 6 and *the entire existing smoke suite runs on two
cores* while FatFs, SDIO, the loader and the mount tree remain trivially safe.
Then peel one subsystem out from under it per PR in phase 8. Converting every
subsystem *and* bringing up core 1 in one merge is how this project fails. Type
it `RecursiveSpinLock` so it stays greppable and deletable.

> **Revised, 2026-08-10.** The type exists (`sync.RecursiveRanked`, rank 5) and
> is taken nowhere, deliberately. The reasoning above was written when *nothing*
> was locked: its whole promise is that core 1 can launch while "FatFs, SDIO, the
> loader and the mount tree remain trivially safe". All four now have real locks,
> as do the process table, pid map, page pool, kernel heap and console. Phase 8 —
> "peel one subsystem out from under the BKL" — has effectively already happened,
> subsystem by subsystem, which is why the failure mode this paragraph warns
> about (converting everything *and* bringing up core 1 in one merge) no longer
> applies.
>
> Wiring it now would also be wrong in a specific way rather than merely
> unnecessary. A BKL has to be **held across the context switch** and released by
> whoever resumes; `RecursiveRanked` tracks ownership by *core*, so the depth
> survives a switch while the process it belongs to does not. Getting that right
> needs the same hand-off design as the preempt windows in `vfork` and
> `prepare_exec` — which is phase 6/7 work, next to the core-1 bring-up it exists
> to serve. A BKL taken at the entries that return normally but not at PendSV
> would look like protection and provide none, which is worse than no BKL.
>
> What it still has to offer is a net for what is *not* individually locked: the
> perf counters, `ctx_ring`, `hardfault_callee`, and the scheduler's
> `current`/`next` TOCTOU. All four are phase 6/7 items already. So: keep the
> type, decide in phase 6 whether the net is worth its hand-off, and note that
> "no BKL at all" is now a defensible answer where it was not before.

**Audit result (the allocator/console rank question above):** it passes by
construction. `kheap` is 90 and `console` is 95, so the allocator's sixteen log
calls acquire in *increasing* rank and are legal. The inversion to look for is
the other direction — console → allocator — and the console write path formats
into a stack buffer; `vfmt`'s allocating variants take an explicit allocator and
are not on it. lockdep has run live through the host suite, 14 QEMU smoke tests
and 1503 ir_tests without firing.

### Phase 5 — Non-reentrant libraries

FatFs, littlefs, SDIO, and the shared device seek positions. See the inventory.
This is the last phase that is single-core-testable end to end.

### Phase 6 — Core 1 bring-up

> **Bring-up done on both targets, 2026-08-11.** `CONFIG_PROCESS_SMP=y` on
> `mps3-an524` and on `pimoroni_pico_plus2`; on each, core 1 boots, proves the
> locks work across cores, and parks. What landed is described under
> [Core 1 on QEMU](#core-1-on-qemu-mps3-an524) — including the correction that
> **QEMU is not a single-core vehicle after all**, which changes the
> [Testing](#testing) table's verdict — and under
> [Core 1 on the RP2350](#core-1-on-the-rp2350). Still open in this phase: the
> doorbell IPI, and `hardfault_callee` / `ctx_ring` becoming per-CPU.

Launch sequence, second vector table / VTOR, second stack, `ACTLR.EXTEXCLALL` and
MPU on core 1, doorbell IPI and the SIO register additions.

**Second SysTick.** The SysTick hardware is per-core on Cortex-M (it is in the
SCS), so core 1 needs its own `init()`. The shared counter
(`source/kernel/interrupts/systick.zig:29-30`) would otherwise be
double-incremented — and it is already a non-atomic 64-bit RMW on a 32-bit core,
handed out by pointer to `Process.sleep_for_us`.

Write the bring-up in Zig against the existing `crt.zig` rather than enabling the
vendored `multicore.c`: that file is available but unbuilt, and pulling it in
drags along `pico_runtime_init`, its own spinlock claim allocator, and the FIFO
handshake.

End state for this phase: **core 1 boots and parks in an idle loop**, core 0
behaviour unchanged. That is a real, shippable, testable milestone.

### Phase 7 — SMP scheduler

> **Done, 2026-08-11: both cores schedule.** See
> [Both cores scheduling](#both-cores-scheduling) for what landed, the two bugs
> the first two-core workload found, and what is deliberately still open.

Per-core run queues. The critical correctness property is that a process is
**claimed exactly once**, via a CAS on `Process.state`.

Today's scheduler cannot do this. `RoundRobin` holds a single `current`/`next`
pair (`round_robin.zig:32-33`), and the `Ready` test (`:50`, `:64`, `:88`) is
separated in time from the `Ready → Running` store in `update_current()`
(`:147`) — a textbook TOCTOU that hands the same node to both cores.

Also: `schedule_next()` **frees memory from PendSV handler context**
(`process_manager.zig:180-184` — `terminate_list.remove()`, `release_pid()`,
`p.deinit()` → `_kernel_allocator.free`). Move reaping off the switch path.

### Phase 8 — Split the BKL

Retire the coarse lock subsystem by subsystem, measuring throughput against
phase 7 each time.

### Phase 9 — Threads

- Split `Process` into process and thread (today it is both).
- **Per-thread `errno`.** `libs/libc/errno.c:42` is a bare `int errno;` with **no
  `__errno()` accessor and no `_reent`**. It is safe today only because
  `.data`/`.bss`/`.got` are per-process (the loader's `LoadedUniqueData`,
  `dynamic_loader/source/module.zig:118-165`) and there is one thread per
  process. Adding threads breaks it immediately.
- TLS under the FDPIC / R9 loader model.
- fd-table and per-process-heap locking.
- A real `libs/pthread` — `pthread.c` is currently a **0-byte file**; the library
  exists only so `-lpthread` links.

---

## The synchronization inventory

Every site that needs synchronization, by subsystem, with the mechanism chosen.

Mechanism key: **PC** per-CPU · **SL** spinlock (named) · **AT** atomic ·
**SEQ** seqlock · **RCU** RCU / epoch · **RF** refactor to per-thread or
per-process · **LIB** library configuration change

### Scheduler and process

| Site | Hazard | Mech |
|---|---|---|
| `system_call.zig:49,50` `context_switch_enabled`, `counter` | per-core mask used as a lock at 37 sites | PC + SL |
| `system_call.zig:59` `scheduler_running` | first-switch ordering flag | PC |
| `system_call.zig:321` dispatch, `:266-277` `write_result` | **dereferences user pointers directly, no copy-in/copy-out.** Another thread of the same process can mutate the arg struct after validation — a TOCTOU. This is a security issue *today*, and becomes exploitable the moment threads exist | RF (copy args to kernel stack, copy results back) |
| `process_manager.zig:638` `instance` | the entire process world; read unlocked from PendSV, HardFault, SVC and thread mode | SL |
| `process_manager.zig:126` `processes` | intrusive `DoublyLinkedList` run queue, O(n) walk | SL (runqueue) |
| `round_robin.zig:32-33` `current`/`next` | single-valued; hands the same node to both cores | PC + AT |
| `round_robin.zig:147` `state = Running` | TOCTOU against the `Ready` test at `:50,:64,:88` | AT (CAS) |
| `process_manager.zig:130` `_pid_map` | non-atomic `findFirstSet` + `unset` (`:212-230`) | SL |
| `process_manager.zig:180-184` `deinit()` in PendSV | frees to the shared heap from handler context | reaper |
| `process_manager.zig:131` `core[]` | asm hooks read it unlocked — comments at `:679-681`, `:712-714` say so | PC |
| `process.zig:175-176` `_blocked_by`, `_blocks` | heap-allocated intrusive lists mutated with **no** lock (`:461-501`), incl. from `delete_process` | SL |
| `process.zig:153` `current_core` | written, never read | RF |
| `process_manager.zig:312-361` `vfork` | multi-step table + scheduler + loader mutation; success path bypasses defers | SL |
| `process_manager.zig:456-569` `prepare_exec` | as above; also resets global perf and pool counters | SL |
| `process_manager.zig:583-612` `waitpid` | blocks and never unblocks on success | fix + SL |
| `process_manager.zig:264-310` `delete_process` | ends in an unbounded `unblock / barrier / trigger(.pendsv)` spin | SL |
| `process.zig:429-443` `reevaluate_state` | RMW on `state` from both thread and handler context | AT |
| `process_manager.zig:732-733` `ctx_ring`, `ctx_seq` | comment at `:721` already asserts "one core" | PC |
| `systick.zig:29-30` `tick_counter`, `last_time` | non-atomic 64-bit RMW; per-core SysTick would double-count | AT + PC |
| `perf_profile.zig:88` `perf_svc_entry_cycles` | written **from assembly** on every SVC (`context_switch.S:269-274`) | PC |
| `syscall_handlers.zig:103` `main_process_stack_pointer_before_scheduler_started` | boot handoff | PC |
| `syscall_handlers.zig:44` `kernel_allocator` | init-once | — |
| `armv8-m/mpu.zig:70` `next_region` | MPU programming cursor, per-core MPU | PC |
| `arm-m/irq_handlers.zig:152` `hardfault_callee` | fault stub scratch, written by naked asm | PC |
| `arm-m/irq_handlers.zig:297-298` handler function pointers | init-once | — |

### Memory

| Site | Hazard | Mech |
|---|---|---|
| `system_stubs.zig:229-258` `__malloc_lock` | PRIMASK only; **the kernel heap *is* newlib malloc**, called from SVC and loader context | SL |
| `malloc.zig:41-61` accounting (`memory_in_use`, `counter`, 9 `bucket_*`) | plain RMW, **not** covered by `__malloc_lock` | SL/AT |
| `malloc.zig:338` `tracker` | global intrusive leak-tracker list, spliced on every alloc/free | SL |
| `malloc.zig:150,198` `free_list_fault_reported`, `get_current_pid_fn` | check-then-set / hook | AT |
| `system_stubs.zig:160` `heap_end` | `_sbrk` plain unlocked RMW (`:170-191`) | SL |
| `process_memory_pool.zig` `page_bitmap`, `used_pages`, `peak_used`, `first_free_hint`, `memory_map` | one shared pool for all processes; **no entry point takes any lock** | SL |
| `process_memory_pool.zig:160` `tag_next_heap` | global one-shot flag whose comment asserts "mmap serializes via block_context_switch and exec is single threaded" | PC/RF |
| `process_page_allocator.zig:54` `page_cache_enabled` | global feature flag | AT |
| `main.zig:150-152` `tmp_memory_pool`, `tmp_page_allocator`, `tmp_tier` | `/tmp` arena, counters read from `/proc/meminfo` | SL |
| `tmp_memory_pool.zig:30,37` `page_bitmap`, `peak_pages` | bitmap set + compare-write, no locking | SL |

### VFS and filesystems

| Site | Hazard | Mech |
|---|---|---|
| `vfs.zig:371-372` `vfs_instance`, `vfs_object` | singletons handed to every syscall | SL/AT |
| `mount_points.zig:107-156` vs `:207-225` | `find_longest_matching_point` walks the tree on the **hottest kernel path** while `umount` `destroy()`s nodes under it. No refcount, no generation counter | RCU |
| `mount_points.zig:173-205` `mount_filesystem` | `appendChild` while readers traverse | RCU/SL |
| `libs/oop/src/interface.zig:461-512` `__refcount` | **backbone of every `IFile`/`IDirectory`/`IFileSystem` lifetime**: `r.* += 1` / `-= 1` then `if == 0 destroy`. Note `?*i32` is a heap pointer — the PSRAM constraint applies | AT + placement |
| `ramfs_data.zig:69`, `ramfs_directory.zig:30`, `driverfs.zig:53`, `procfs_directory.zig:31`, `mmc_driver.zig:71`, `module.zig:49`, `loader.zig:109` | seven hand-rolled `i16`/`i32` refcounts, all plain RMW | AT |
| `mmc_driver.zig:72` `global_refcount` | container-level static shared by **all** `MmcDriver` instances | AT |
| `buffered_file.zig:31,46-55` `_position`, `_end` | shared offset across `dup`/`fork` | SL (per-file) |
| **FatFs** `ff.c:464,465,468,520` `FatFs[1]`, `Fsid`, `CurrVol`, `LfnBuf[256]` | built `FF_FS_REENTRANT 0`, `FF_FS_LOCK 0`, `FF_USE_LFN 1`. ffconf documents this LFN mode as **"Always NOT thread-safe"**; `LfnBuf` is written by every name comparison in every directory walk | LIB + SL |
| `ffsystem.c:38-130` `ff_cre_syncobj`, `ff_req_grant` | the hooks exist but are the **unmodified upstream Win32 examples** (`CreateMutex`, `WaitForSingleObject`) and are compiled out | LIB |
| `source/fs/fatfs/fatfs.zig:51,52` `global_fs`, `workspace_buffer` | one `FATFS` and one mkfs scratch buffer for the system | SL/RF |
| `libs/zfat/src/fatfs.zig:9` `disks[FF_VOLUMES]` | every `FatFs` instance writes the same `disks[0]` slot — a second FAT mount steals the first's volume | RF |
| `source/fs/fatfs/fatfs.zig:283-555` DiskWrapper | 16 KiB line cache, LRU `clock`, write-combining buffer, `sectors_on_disk`. `line_for` (`:526-555`) does a device read while the line is marked empty. Guarded only by PRIMASK around the raw transfer (`:504,515,617`), documented at `:499-502` as covering only the seek+transfer | SL |
| littlefs | built **without** `LFS_THREADSAFE`; the config literal (`littlefs.zig:133-146`) never sets `.lock`/`.unlock`, so enabling it today would null-deref. Currently unmounted | LIB |
| `romfs/file_reader.zig:47-103` | seek-then-read on a shared device `IFile` with no guard; two romfs walks interleave | SL (device) |
| `ramfs_data.zig:41` `inode_counter` | shared counter (currently never incremented — every file gets inode 1) | AT |

### Drivers

| Site | Hazard | Mech |
|---|---|---|
| `hal/.../rp2350/source/uart.zig:55` `rx_buffer` + `ring_buffer.zig:22-25,47-75` | plain non-volatile `head`/`tail`/`dropped`. Producer is the RX ISR **and** an inline drain called from inside `Uart.write`'s `cpsid i` window (`:183-203`); consumers are any core | AT (SPSC) |
| `uart.zig:64-65` `stats`, `last_irq_us` | `+%=` from IRQ; `get_rx_stats` snapshots by struct copy → torn read | SEQ/AT |
| `uart.zig:56` `is_initialized` | check-then-set | AT |
| `uart_file.zig:107-192` canonical-mode line editor | multi-byte read/write sequences with no exclusion; two readers interleave escape sequences | SL |
| `sdio_rp2350.c:53` `g_sdio`, `:117` `g_sdio_timeout_dumps` | PIO+DMA state machine in C. `mmc_sdio.zig:404-418` masks IRQs around the poll loop with a comment that `rp2350_sdio_dma_irq()` reentrancy overwrites `blocks_checksumed` — **a second core defeats that protection entirely** | SL |
| `mmc_sdio.zig:385` `aligned_buf[4096]` | one static DMA bounce buffer for the whole system | SL |
| `mmc_io.zig:66-71` card state (`_card_type`, `_size`, `_initialized`, `_rca`) | shared by all partitions and FS layers; PRIMASK-guarded only (`:84,117,159`) | SL |
| `mmc_file.zig:34` `_current_block`, `mmc_partition_file.zig:35` `_current_position`, `flash_file.zig:43` `_current_address` | shared device **seek positions**, driven concurrently by FatFs *and* romfs | SL (device) |
| `driverfs.zig:48-53` `_container` | registry read on every `/dev/...` lookup; appended during boot with nothing enforcing read-only-after-boot | RCU |
| `xip.zig:68-74` `sample_and_clear()` | read-then-write-0 on shared hardware counters; two callers race to zero them | SL/AT |
| `flash.zig:43-52` | `write`/`erase` are **no-ops today**, so the XIP-erase-while-executing hazard is not live — it becomes live if they are implemented | deferred |
| `crt.zig:194` `ram_vector_table`, `:351-352` measured clocks | one vector table; core 1 needs its own or a shared-with-care one | PC |

### Dynamic loader and modules

| Site | Hazard | Mech |
|---|---|---|
| `loader.zig:133-147` `get_shared_data` | **check-then-act**: both cores miss, both create, one `put` overwrites → leaked image and a `users` count that never reaches 0 | SL |
| `loader.zig:167-182` `unload_module` | `users -= 1; if 0 destroy + remove`; a concurrent `get_shared_data` resurrects a freed pointer | AT + SL |
| `loader.zig:822` `loader_object`, `:55` `emit_load_map` | singletons | SL |
| `modules.zig:41` `resolver_cache` | `StringHashMap` insert on every spawn rehashes under another core's lookup | SL |
| `modules.zig:178,179,529` `modules_list`, `libraries_list`, `vfork_snapshots` | single global pid-keyed maps mutated from exec/exit | SL |
| `modules.zig:438-447` `dump_fault_maps` | reads `modules_list` from **HardFault context** with a 4 KiB stack frame | try-lock |
| `modules.zig:61` `last_executable_load_us` | written by loader, read by `process_manager.zig:485` | AT |
| `module.zig:49` `ThunkHolderData.refcount`, `:172-176` `allocate_thunks` | non-atomic refcount plus check-then-create | AT |
| `load_profile.zig:31,46` `time_us_hook`, `phase_us` | global accumulator array | PC |

### libc and threads (phase 9)

| Site | Hazard | Mech |
|---|---|---|
| `libs/libc/errno.c:42` `int errno;` | no `__errno`, no `_reent`; safe only while there is one thread per process | RF |
| `libs/pthread/pthread.c` | **0-byte file** | implement |
| `process.zig:169` `_fds` | per-process today; **shared the moment threads exist**; `fork` copies it while the parent may run on the other core | SL |
| per-process malloc | per-process today; shared under threads, and **must not hold locks in PSRAM** | SL + placement |

### Logging and instrumentation

| Site | Hazard | Mech |
|---|---|---|
| `file_log.zig:62-80` ring, `head`, `count`, `appending`, `draining` | non-atomic check-then-set re-entrancy guards; the header (`:26-42`) documents that SDIO and FatFs are non-reentrant and SD I/O must never nest | AT + SL |
| `stdout.zig:26-35` (6 globals) | `drain_sink` reads callbacks and context unlocked; `klog_force_enable` is called from HardFault | SL |
| `perf_profile.zig:61-410` (~35 counters) | plain `+=` / `+%=` from SVC handler, pool allocator and FS code. `:496-500` already notes "the syscall counters are system-wide — concurrent processes would mix" | PC + sum |
| `xipstat_file.zig:51-120` | the tree's only seqlock, but with plain non-atomic `sequence +%=` and no barriers; correct against preemption on one core, **not** across cores | SEQ (fix) |
| `uartstat_file.zig:46` `provider` | global hook | AT |
| `benchmark.zig:21` `previous` | RMW in `timestamp()` | PC |

---

## Testing

This is the weakest part of the plan and the honest answer is uncomfortable.

| Vehicle | Verdict |
|---|---|
| QEMU mps2-an505 | **Single-core.** The AN505 is an IoTKit part with one M33, so this leg stays `CONFIG_PROCESS_SMP=n` and is what keeps the single-core path honest |
| **QEMU mps3-an524** | **A real SMP vehicle, and this was wrong before.** The AN524 is an **SSE-200**, which QEMU models with **two** Cortex-M33s (`-machine mps3-an524` → `info cpus` lists both) — the claim that no QEMU board could test SMP was an assumption about the machine, never checked against it. Core 1 boots here today; see [Core 1 on QEMU](#core-1-on-qemu-mps3-an524) |
| Renode | **Dead scaffolding.** `renode/run_raspberry_pico.resc` already drives `sysbus.cpu0` *and* `sysbus.cpu1` with two GDB servers — but it `path add`s `libs/hal/renode/Renode_RP2040`, **which does not exist**, and nothing in `build.zig`, `.github/workflows/` or `tests/` references Renode. It also targets RP2040 = armv6-m, which has **no exclusives**, so it could not validate phase 0 even if revived. A dual-M33 RP2350 `.repl` is a genuine option but is its own project — cost it, don't assume it |
| Remote RP2350 rig | The **only** true SMP vehicle, and already the flakiest part of CI |
| **Host `zig build test`** | **The recommended primary vehicle for phases 0–5, 7 logic and 8** |

The host route is stronger than it looks and should carry the bulk of
verification. Two hooks already exist:

- `hal/source/ut_stub/cpu.zig:19-29` exposes a **settable `_coreid`** via
  `set_coreid()` — exactly what is needed to exercise per-CPU code.
- `hal/source/host/host/source/atomic.zig:23-40` already backs atomics with
  `std.Thread.Mutex`.

So the run queue, the per-CPU array, the refcounts, the `Ready → Running` CAS
claim and the lock-order assertions can all be tested under **genuine
`std.Thread` contention with ThreadSanitizer** before any RP2350 code exists.
**The design should therefore keep these structures free of arch dependencies so
they stay host-testable** — that constraint is worth real effort.

Blockers to fix first: `source/arch/host/process.zig` is `fork()`-based and
partly dead (`HostProcess.create` at `:55-68` returns `.pid` while the struct
field is `child_pid` — it would not compile if instantiated), and
`hal/source/host/host/source/cpu.zig:36-42` reports 4 cores with `coreid()`
pinned to 1.

---

## Risks

**The 3 Mbaud console budget.** `uart_driver.zig:51-59` documents a ~93 µs
RX-FIFO overrun window that every `cpsid i` section must fit inside, and names
FatFs, MMC/SDIO and `__malloc_lock` as the sections that have to fit. Spinlocks
held with interrupts disabled — plus cross-core spin time — eat directly into
that budget. This is a measurable regression risk on a path that is already
known to drop bytes, and it should be measured per phase, not at the end.

**PSRAM placement is silent when wrong.** A lock in PSRAM does not fail loudly;
the exclusive just succeeds locally. Without an assertion this will be found by
a corruption bug months later.

**`prepare_exec` and `vfork` are already fragile.** Both do multi-step mutation
of the process table, the scheduler, the memory pool and the loader tables, with
non-returning success paths that bypass `defer`. They will be the hardest sites
in phase 3 and the most likely source of phase-7 bugs.

## Not in scope

- **Don't skip the BKL milestone.** It is the single decision that makes this
  tractable.
- **Don't attempt RCU.** At two cores it does not pay for its quiescent-state
  machinery; a rwlock plus a generation counter on the mount tree is sufficient
  and far easier to get right.
- **Don't make FatFs concurrent.** Serialize it behind one mutex, permanently.
- **Don't use 64-bit atomics** (no `LDREXD` on M33 → a non-lock-free libcall).
- **Don't run the dynamic loader concurrently** in v1 — `loader_lock`, and pin
  `execve` to core 0.
- **Don't put the console behind a sleeping mutex** — panic must be able to print.
- **RISC-V / Hazard3.** No first-party code exists; the only RISC-V artifacts are
  unbuilt vendored pico-sdk files.
- **RP2040 / armv6-m.** No exclusives, and no defconfig builds it. The dangling
  `unlock_pendsv_spinlock` there should simply be deleted.
- **Flash write/erase.** They are no-ops today (`flash.zig:43-52`); implementing
  them would add the XIP-erase-while-the-other-core-executes hazard on top of
  everything here.
- **Reviving Renode** as part of this work. Evaluate separately.
