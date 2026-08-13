# Syscall path cost — measured

**Status (2026-08-09):** measured on the RP2350 rig at 532 MHz. Two cheap fixes
landed and are measured below. **The headline is a negative result: the syscall
*path* is ~1% of syscall time and well under 1% of a program's runtime, so it is
not where the time is.** The handlers are — see
[Where the time actually is](#where-the-time-actually-is).

| Change | State |
|---|---|
| Profiling build fixed (it did not compile) | done, prerequisite for everything below |
| Report whether the cycle counter is live (`cyc=on/off`) | done |
| Rank `top=` by call count when cycles are unavailable | done |
| `syscallbench` + `syscall_profile_test.py`: round-trip cost from the caller | done, new instrument |
| ARMv8-M syscall/context-switch stub into RAM (`.time_critical`) | done, **dispatch 0.11 ms -> 0.02 ms per compile** |
| Fast-path table read inlined into the stub | done, included in the above |
| ~~Re-enable lazy FP stacking~~ | **rejected, measured tax is zero** |
| ~~Widen the fast-syscall set~~ | **rejected, negligible payoff at real deadlock risk** |

## How to reproduce

Cycle counts need real hardware. QEMU's Cortex-M models never advance
DWT_CYCCNT, and model neither exception-entry cost, nor pipeline flushes, nor
XIP/PSRAM latency — which is precisely what this path is made of. The kernel now
says so itself rather than printing a silent `us=0`:

    [ERR][tprof] syscyc pid=2 cyc=off

```bash
# Round-trip cost from the caller, plus the kernel's own per-syscall table.
scripts/remote_smoke_tui.py --profile --pytest-args \
    "tests/smoke/syscall_profile_test.py -m measure -s"

# What share of a real program's life is syscalls, and how much of that is path.
scripts/remote_smoke_tui.py --profile --pytest-args \
    "tests/smoke/io_profile_test.py -m measure -s"
```

## The two paths

A syscall enters `irq_svcall` (`source/arch/armv8-m/context_switch.S`) and takes
one of two routes. A "fast" syscall (`is_fast_syscall`, currently seven trivial
getters) is dispatched in handler mode and exception-returns straight to the
user. Everything else takes a trampoline: the stub builds a *simulated*
exception frame, exception-returns into thread mode to run the handler where it
can block and be rescheduled, then comes back through a second `svc`.

|  | fast | trampoline |
|---|---|---|
| exception entries / returns | 1 / 1 | 2 / 2 |
| `ISB` pipeline flushes | 0 | 6 |
| `CONTROL` writes | 0 | 2 |

## What it costs

RP2350, `clk_sys` 532 MHz, profiling build. Per call, loop overhead removed,
minimum of seven trials (`apps/syscallbench`):

| arm | before | after | note |
|---|---|---|---|
| `getpid` (fast) | 718 ns | **668 ns** | 1 exception entry + return |
| `close(-1)` (trampoline) | 916 ns | **867 ns** | same handler work as getpid |
| `lseek` (trampoline) | 1408 ns | **1360 ns** | a real handler body |
| derived: trampoline | 198 ns | 199 ns | the second entry + return |
| derived: `lseek` handler body | 492 ns | 493 ns | not addressable by dispatch |

The trampoline costs **198 ns**, and that figure is corroborated from the other
side: the kernel's own window (SVC stamp -> end of handler) grows by 98 ns
between `getpid` and `close(-1)`, and the userspace round trip grows by 198 ns,
so the missing 100 ns is the return half — exactly the part the kernel profiler
structurally cannot see, which is why `syscallbench` exists.

## Where the time actually is

`io_profile_test.py`, same rig, `tcc -O0 hello.c`:

    spawn 33.88ms = loader 4.36ms (12.9%) + run 29.52ms
      syscalls 10.98ms (37.2% of run) over 169 calls, dispatch 0.02ms

Syscalls are **37% of the compile**, and the path is **0.2% of the syscalls**.
The rest is handler bodies:

| syscall | calls | total | per call |
|---|---|---|---|
| `write` | 16 | 3.32 ms | 208 us |
| `open` | 9 | 3.17 ms | 196 us (of which **86% is the VFS walk**) |
| `close` | 9 | 2.62 ms | 291 us |

Which is the same conclusion `docs/vfs_lookup_cache_plan.md` reached from the
other direction, and where the remaining work belongs. A syscall that spends
196 us finding a file does not care about 200 ns of dispatch.

## What landed, and what it bought

**The stub now runs from RAM.** The Zig half of the path already carried
`linksection(".time_critical")` and linked at `0x2000xxxx`; `context_switch.S`
declared no section, so it sat in `.text` at `0x1000xxxx` and every syscall
crossed flash -> RAM -> flash on the way in and again on the way out, with the
SVCall vector itself pointing into XIP flash. On the QEMU boards
`.time_critical` is deliberately kept in flash (a >1 GB PREL31 distance in
`.ARM.exidx`), so this is a no-op there and takes effect only on rp2040/rp2350.

**The fast-path decision is inlined.** It was an exported Zig function, so the
stub paid a call — push/pop of a frame pointer and link register around three
instructions of lookup — and *both* paths paid it, the trampoline included,
before it had been decided they were slow. It is now a bounds check and one
`ldrb` against `syscall_fast_table`. The bound lives in `sys/syscall_ids.h` as
`YASOS_SYSCALL_COUNT` because the assembler cannot read a C enum;
`sys/syscall.h` fails to compile if the two drift.

The measured effect splits in an instructive way:

| | microbenchmark | `tcc` compile |
|---|---|---|
| dispatch, before | 651 ns/call | 0.11 ms / 169 calls |
| dispatch, after | 118 ns/call | **0.02 ms / 169 calls** |
| round trip, before/after | 718 -> 668 ns | — |

The tight benchmark loop improved by 50 ns a call; the real workload's dispatch
fell by 5.5x. The difference is the XIP cache: a loop calling `getpid` 20 000
times keeps the stub hot in it, and a compiler making scattered syscalls does
not. **The microbenchmark understates this fix, and a workload measurement was
needed to see it** — worth remembering before trusting a microbenchmark about
anything fetch-bound.

In absolute terms it is still 0.09 ms off a 29.5 ms compile: 0.3%.

## Two things deliberately not done

**Lazy FP stacking stays off.** `disable_lazy_fp_stacking`
(`source/arch/arm-m/process.zig`) turns off FPCCR.LSPEN because the trampoline
breaks the `EXC_RETURN.FType` pairing lazy stacking relies on, so every
exception entry from FP context eagerly stacks s0-s15 + FPSCR — four times per
trampoline syscall. That is a real cost on paper and the obvious thing to go
after. It measures **zero**:

    fp_tax_fast_ns=-16   fp_tax_slow_ns=-15

i.e. below noise, in both the one-transition and the two-transition case, which
agree with each other. The M33 evidently absorbs the extra 18 words behind the
stalls it is already taking on entry. Re-enabling it would mean reworking the
exact code path behind a documented family of intermittent crashes (dijkstra,
`370_ptr_struct_copy_inline`, `bug_struct_slot_reuse`, `ieee/pr50310`) for no
measurable gain.

> A caution for anyone re-measuring this: the first version of the benchmark
> used `double`, which on this target compiles to DCP/softfloat and never sets
> `CONTROL.FPCA`, so it dutifully reported a tax of -13 ns while exercising no
> FP stacking at all. The FPU here is single-precision (`fpv5-sp-d16` /
> `rp2350`); the arms use `float`, and the emitted `vmul.f32`/`vadd.f32` were
> checked in the disassembly.

**The fast-syscall set stays at seven.** Moving a syscall onto the fast path
saves it 198 ns. `isatty`, `getcwd`, `sysinfo`, `prlimit` and `klog_ctl` are
short and non-blocking enough to qualify, and together they are a handful of
calls per program — microseconds. Against that, a fast syscall runs at SVCall
priority with SysTick and PendSV masked, so one misjudgement about whether a
handler can block or do IO is a deadlock rather than a slowdown. Anything worth
moving (`read`, `write`, `open`, `lseek` on FAT) is exactly what must not move.
