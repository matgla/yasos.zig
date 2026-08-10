# SMP — plan

**Status (2026-08-10):** nothing implemented. This document is the design and
the work breakdown. Its centre of gravity is
[the synchronization inventory](#the-synchronization-inventory) — the list of
every place in the tree that needs synchronization and the mechanism chosen for
each, because that list, not the core-1 bring-up, is the actual project.

| Phase | State |
|---|---|
| 0. Atomics + spinlocks (LDAEX/STLEX) | not started |
| 1. Per-CPU state, `preempt_disable()` | not started |
| 2. Atomic refcounts | not started |
| 3. Split `block_context_switch` (37 sites) | not started |
| 4. Lock hierarchy + big kernel lock | not started |
| 5. Non-reentrant libraries (FatFs, littlefs, SDIO) | not started |
| 6. Core 1 bring-up + doorbell IPI | not started |
| 7. SMP scheduler | not started |
| 8. Split the BKL | not started |
| 9. Threads (`clone`, pthreads, TLS) | not started |

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

**`hal/source/raspberry/rp2350/source/sio.zig` has no doorbell registers** and
must gain them — but **audit the whole struct first**: its GPIO fields from
`+0x14` follow **RP2040** ordering (`gpio_out_set` at `+0x14`), whereas RP2350 has
`GPIO_HI_OUT` at `+0x14` and `GPIO_OUT_SET` at `+0x18` (`regs/sio.h:113,133,188`).
Latent today because only `cpuid` and `spinlocks` are read, but not something to
build doorbell offsets on top of. `hal.irq.Type` must also grow beyond
`{systick, pendsv, supervisor_call}` to carry an IPI.

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
| 10 | `mount_lock` | rwlock (spin) | no | no | the `MountPoints` tree |
| 20 | `fs_lock[fs]` | sleeping mutex | no | no | per-filesystem; FatFs, littlefs, romfs, ramfs, procfs, driverfs |
| 30 | `dev_lock[dev]` | sleeping mutex | no | yes | device seek/DMA state, `g_sdio`, `aligned_buf`, the FatFs line cache |
| 40 | `loader_lock` | spin_irq | yes | no | `modules.zig` + `loader.zig` tables |
| 50 | `proctable_lock` | spin_irq | yes | no | process table, parent/child, wait lists, `Semaphore.counter` |
| 55 | `p->fd_lock` | spin_irq | yes | yes | per-process `_fds` |
| 60 | `rq_lock[cpu]` | spin_irq | yes | no | per-core runqueue, `Thread.state` transitions |
| 70 | `pidmap_lock` | spin_irq | yes | yes | `_pid_map` |
| 80 | `pagepool_lock` | spin_irq | yes | yes | `ProcessMemoryPool` |
| 90 | `kheap_lock` | spin_irq | yes | yes | newlib free list + `malloc.zig` accounting + `_sbrk` |
| 95 | `console_lock` | spin_irq | yes | yes | `stdout.zig`, UART TX, `file_log` ring |

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
it `RecursiveSpinLock` so it stays greppable and deletable — it is the only
recursive lock in the system.

### Phase 5 — Non-reentrant libraries

FatFs, littlefs, SDIO, and the shared device seek positions. See the inventory.
This is the last phase that is single-core-testable end to end.

### Phase 6 — Core 1 bring-up

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
| QEMU mps2-an505 / mps3-an524 | **Single-core** (`number_of_cores()` returns 1). Cannot test SMP at all. Every defconfig except `host` targets these or the RP2350 |
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
