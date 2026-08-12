# Remote smoke suite speedup plan (RP2350)

Goal: cut the wall time of a full `scripts/remote_smoke_tui.py` run (4531 tests, one RP2350 board) from the measured **54:20** toward ~30 min, by attacking harness overhead, kernel/libc memory paths, tcc allocation behavior, and kernel hot paths — measurement-first. The 2026-08-03 run measured **31:44**, so that target is effectively met; the 2026-08-03 extension (items 1.6-1.7, 2.9, Phases 5-6) aims the same method at what remains: the low-20s of minutes on one board, ~17 min with a second board, and ~10 min for the kernel-dev loop where tcc has not changed.

## Context

The suspicion going in was tcc compile performance and PSRAM-resident memory operations (heap spills to PSRAM, which is shared with flash on the QMI bus but cached). Analysis of a real full run shows the time actually splits three ways — on-target compile (66%), harness serial overhead (32%), and negligible test execution — so the plan attacks all of them, ordered by expected payoff per risk, with a measurement phase first because host profiling has misled before (5% host vs 44% target for vrp).

Decisions locked in:
- Scope: **all phases**, including the -O1/-O2 optimizer track (Phase 4).
- PSRAM 109→133 MHz restore: **approved** (validated by boot rxdelay calibration + POST + full suite run).
- Hybrid /tmp: user-specified design — small files (≤64 KB default) RAM-backed with a total arena budget, larger files spill to SD; motivated by prior experience that an unbounded SRAM RamFs starved code/heap and was a net loss.
- Kernel hot-path tuning (context switch, syscall path, hot code placement) included as Phase 2.7.
- 2026-08-03 extension: Phases 5-6 and items 1.6-1.7, 2.9 added (a clock-ladder item and a PCH item were added and closed the same day — their tombstones are 1.5 and 2.8). One rule is locked with them: **no caching or batching mode (5.3, 6.1, 6.2) ever becomes a default or serves as a baseline** — validation runs stay one-shot, cache-off.

Baseline source: 2026-07-30 run (`run_logs.txt` + `.cache/remote_smoke_logs/mateusz_192.168.0.113/tcc_timing_report.json`).

## Status

- [ ] Phase 0 — measurement & attribution (**now the highest-value item**: every remaining estimate was sized against a wall-time budget the 2026-08-03 run has invalidated); **items 7-8 added and answered 2026-08-03 — the compile is memory-bound, not core-bound, and the SD write path costs ~1.2 ms per sector**; see [Measured: Phase 0.7/0.8](#measured-phase-0708-2026-08-03)
- [ ] Phase 1 — **1.1, 1.3, 1.4 shipped and measured jointly**; 1.2 batching outstanding and needs re-sizing; 1.6-1.7 added 2026-08-03 (echo, pipelining); 1.5 clock ladder closed — 618 is this board's stable max
- [ ] Phase 2 — **2.2 and 2.6 shipped and measured jointly**; 2.1 tried and reverted; 2.3-2.5, 2.7 outstanding; 2.9 CMD25 write path built and bench-measured 2026-08-03 (0.41 → 3.5 MiB/s; full-suite run still owed); 2.8 PCH closed — measured worse than parsing
- [ ] Phase 3 — tcc -O0 allocation reduction
- [ ] Phase 4 — -O1/-O2 optimizer memory work
- [ ] Phase 5 — fetch-side + spawn-cost levers (added 2026-08-03). 0.1 sized the per-compile floor at 85.8 ms (~380 s/run) which 5.2/5.3 attack, and 0.7 sized the miss stream which 5.1 attacks. **5.1 FIRST DELIVERY 2026-08-06: `.text` −551 KiB (−22.2%), mechanical throughout — no pass merge; the mechanical seam is now exhausted and the rejected remainder is tabulated so it is not re-proposed. Speed dividend and a timed hardware run both still owed.** **5.5 SHIPPED 2026-08-04: the tcc-init half of the floor was the builtin alias declarations, now built programmatically; with the loader fixes the floor is 85.8 → 25.8 ms and the resident-compiler case (5.3) is much weaker**
- [ ] Phase 6 — suite-level levers: compile cache, changed-only runs, second board, core1 (added 2026-08-03; all opt-in). **Test-level concurrency on one board is CLOSED, measured 2026-08-12: two concurrent compiles are 0.61x, and the cause is the shared 16 KiB XIP cache, so no ordering or memory budget rescues it. 6.3 (a second board) is untouched by this — it adds a second cache with the second core.**

**Measured 2026-08-12: device-side concurrency is a 0.61x regression on
compiles, and it is the XIP cache** — not the scheduler and not memory. The
control arm settles it: a RAM-resident ALU loop gets **1.64x** from the second
core, while two tcc instances take 44% more cache misses for the same work and
lose almost exactly that much wall time. Quartering the compile's heap changes
nothing, which rules out the PSRAM-spill explanation and with it the
memory-aware co-scheduling such a feature would have needed. See
[Measured: device-side concurrency is closed](#measured-device-side-concurrency-is-closed-2026-08-12-the-xip-contention-round).

**Measured 2026-08-06: tcc `.text` 2,541,400 → 1,977,152 B (−551 KiB, −22.2%)**
— the footprint round, the first real delivery against item 5.1. This is the
*other* multiplier on the miss term: 5.4 cut what a miss costs, this cuts how
many there are. Three changes to the ARM backend and the headers, plus one
miscompile the third of them exposed. Two of the three shrink **every program
tcc compiles**, not just the compiler — `gcc_execute/strlen-5` emits 11 R9
stores where it used to emit 635 — so the execute step and the loader get
paid too. **Wall time on the rig is still owed**; the run confirmed the
firmware boots and works, but no timing was captured, so nothing in the table
below moves yet. See
[Measured: the footprint round](#measured-the-footprint-round-2026-08-06).

**Measured 2026-08-06: 636.60 s (10:36), compile bucket 557.6 → 489.3 s
(−12.2%)** — the transaction round: what a *miss* costs rather than how many
there are (item 5.4, both halves). The flash's chip-select deselect time was
sized from the datasheet's erase/program row instead of its read row, and every
XIP miss was still clocking out an opcode the part did not need. Getting the
second half required root-causing a PIO autopull race that had been breaking SD
bring-up for two rounds under the description "any codegen change breaks the
card". See
[Measured: 10:36](#measured-1036-2026-08-06-the-transaction-round--54-taken-in-full).

**Measured 2026-08-05: 1043.2 s (17:23), compile bucket 895.0 → 868.0 s
(−3.0%)** — the -O0 codegen dry-walk round, and the first corpus-wide *phase*
profile of the compile body (previous rounds profiled the floor and the tail
only). See [Measured: 17:23](#measured-1723-2026-08-05-the-dry-walk-round-and-the-first-body-profile).

**Measured 2026-08-04 (fourth run of the day): 1244.5 s (20:44)** — the
`try_demote_scratch_conflict` operand-decode cache, worth 0.4 s on the #1 test
and sub-noise on the run. The step before it, the tail round (20:47), carried
the ra_build_intervals quadratic fix and the -O0 rehearsal-walk default, on top
of the floor round (22:57) and the loader fixes (25:09): **−61.8% against the
3260 s (54:20) baseline.** Same pass set throughout (4466 passed / 79 skipped).
See [Measured: 20:44](#measured-2044-2026-08-04-the-1-test-round) and
[Measured: 20:47](#measured-2047-2026-08-04-the-tail-round).

Record A/B timings per phase in the table at the bottom as they land.

## Measured wall-time budget

Baseline is the 2026-07-30 run. The 2026-08-03 column is a full hardware run
(4466 passed, 72 skipped) of 1.1 + 1.3 + 1.4 + 2.2 + 2.6 together — see
[Measured: 2026-08-03](#measured-2026-08-03) for the per-phase caveat.

| Bucket | 2026-07-30 | 2026-08-03 | Δ |
|---|---|---|---|
| On-target tcc compile | 2166 s (66%) | 1493.9 s (78%) | **−672 s, −31%** |
| Harness/serial overhead | ~1050 s (32%) | 387.7 s (20%) | **−662 s, −63%** |
| On-target execution | 42 s (1.3%) | 23.0 s (1.2%) | −19 s, −45% |
| Flash/reboots | ~0 | ~0 | — |
| **Wall** | **3260 s (54:20)** | **1904.6 s (31:44)** | **−1355 s, −41.6%** |

Compile distribution over the same corpus:

| | 2026-07-30 | 2026-08-03 |
|---|---|---|
| p50 | 397 ms | **222.9 ms** |
| p90 | 638 ms | **467.2 ms** |
| p99 | 2431 ms | **2150.6 ms** |
| mean | — | 335.8 ms |
| max | — | 22.6 s (`gcc_compile/limits-fnargs`) |
| top-100 share of compile | 17% | **21.5%** (321.1 s) |

The body of the distribution moved much further than the tail — p50 −44% against
p99 −11.5% — so the tail is now a larger share of what is left (17% → 21.5%).
That is the shape that says the remaining compile time is concentrated: the 100
slowest tests are 2.2% of the corpus and 21.5% of its compile seconds. Harness
overhead per test is down from ~0.23 s to ~0.087 s.

## Verified structural facts (2026-07-30)

- Remote suite runs **-O0 only** (`DEFAULT_CONFIG["smoke_tcc_opt_level"]`, `scripts/remote_smoke_tui.py:191`). *(Superseded: the remote runner now defaults to the full `-O0 -O1 -O2` matrix, so a default run is roughly three times the work measured here. `--smoke-tcc-opt-levels -O0` reproduces the numbers below.)* At -O0 the flat opt pipeline is dce-only (`libs/tinycc/source/opt/engine/pipeline_table.c:260-266`), **but** the backend still builds CFG+dominators+SSA+rename+SSA-DCE (`libs/tinycc/ir/regalloc.c:4890-4955`) plus regalloc (~45-50 mallocs/function) and codegen dry-run scratch on every function.
- tcc `.text`/`.rodata` (2.4 MiB) executes **XIP in place from flash** (`dynamic_loader/source/module.zig:94-109`); flash XIP already at its 133 MHz max. Per exec: ~15 KB data copy, 43.7 KB bss memset, 2,312 B GOT copy + 289-entry rewrite, ~2,200 relocations — order of a few ms (Phase 0 confirms on hardware). *(Originally recorded here as "bss memset redundant — pool pre-zeroes". It is not: see 2.1 below. The pool does clear its pages, but `std.mem.Allocator` overwrites every allocation with `undefined` on the way out.)*
- **`/tmp` was a symlink to `/root/tmp` on the SD card** (RamFs /tmp had been removed to reclaim SRAM). Every compile wrote its output to SD; every execute read it back fully into RAM (`source/kernel/modules.zig:242-246`). Phase 2.6 replaces this with a mounted hybrid filesystem.
- Harness: pytest runs on the remote Pi; per-test round trips = prompt nudge + `cd /` (`tests/smoke/framework/session.py:206-223`), `cd /tmp`, device `sha256sum` (zmodem almost never fires; sources persist on SD), timed compile, timed execute, `rm -f`. Crash detection is stream-based (`session.py:120-130`) and **survives command batching**.
- Kernel: every mmap page eagerly zeroed (`process_memory_pool.zig`, still true and load-bearing — pages are recycled between processes); ~~O(pages) restart scan + 2 full-bitmap `count()` per alloc~~ **fixed by 2.2**; ~~loader double-zeros .bss~~ **not actually redundant, see 2.1**; libc `MSETMAX=2048` sends every ≥2 KiB alloc through a raw mmap syscall; `mk_pool` recycles pools without re-zeroing (`libs/libc/malloc.c:165-197`) which forces `tcc_mallocz` to always memset (documented HardFault). Memory zeroed up to 3×.
- PSRAM at 109 MHz in `config/target/.config` vs 133 MHz board default (`hal/boards/pimoroni_pico_plus2/KConfig:56-64`); clkdiv 6→5 = +20% bandwidth. rxdelay auto-calibration + whole-array POST exist (`hal/source/raspberry/rp2350/source/external_memory.zig`).
- Profiling seams already wired: `--profile` → `YASOS_TCC_PROFILE=1` → tcc `-bench` + `perf_dump_print` + syscall cycle table (`scripts/remote_smoke_tui.py:1615-1617`, `tests/smoke/profiling.py`); PASS_TIME harness (`libs/tinycc/source/opt/engine/pass_timing.c`); kernel loader timing behind `CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING` (currently off, `config/target/.config:103`).

## Phase 0 — Measurement (no functional changes)

Attribute the 397 ms median compile into {tcc-internal, spawn+load, SD/syscall, serial} and the 0.23 s/test overhead into {sha256, setup round trips, rm}.

1. Full suite run with `--profile` → per-test `wall_compile_ms` vs `internal_compile_ms` + aggregated syscall cycle table. **First cut taken 2026-08-03 without needing that build** — a ladder of bracketed windows that each add one layer puts the pre-source floor at 85.8 ms; see [0.1, first cut](#01-first-cut--86-ms-of-every-compile-happens-before-tcc-reads-the-source). Still owed from this item: the split of that floor into spawn / module load / tcc init (that is item 2's `loader_ms`), and the SD share 0.8 handed over.
2. **Regex fixed, and the run finally taken (2026-08-03). `loader_ms` is ~48 ms per spawn and does not scale with module size.** `LOADER_TIMING_RE` had matched only the file-only `yasld-bench` line, never perf.trace's `load kind=` mirror — the one that actually reaches the serial console — so `loader_ms` read 0.00 for all 4449 tests of the earlier run. *A zero column is worse than a missing one: it reads as "the loader costs nothing" rather than "never measured", and that is how it went unnoticed across two runs.* With the regex fixed and a `CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y` build flashed, the column is populated and the answer is in [0.2 below](#02--the-loader-costs-48-ms-per-spawn-and-it-does-not-care-how-big-the-module-is).
3. **Implemented (2026-08-03).** `CaseTiming` carries `hash_ms`/`setup_ms`/`cleanup_ms`, accumulated around `get_remote_hash`, the prompt resync + `cd`/`mkdir`, and the output `rm`; the report prints a harness line and a per-test breakdown, and the JSON carries the fields. Attribution goes through a module-level current-case + `record(field)` context manager rather than threading a `timing` argument through the upload helpers; `Session` times its own `_prepare_target` so `framework/` keeps no dependency on the suite package.

   First numbers, QEMU only and therefore a shape rather than a size (3 tests, and the first test's setup includes a QEMU relaunch): **hash 5.7 ms/test, cleanup 13.9 ms/test, setup 341 ms/test.** If that ordering survives on hardware it says Phase 1.1 took the hash cost and what remains is per-test session setup — which is 1.2's *second* half (drop the `cd /` + nudge), not its compound-command half.
4. Tail: top-20 slowest tests with `YASOS_TCC_ENV_PREFIX="TCC_PASS_TIMING=1 "` (`tests/smoke/tcc_suite_test.py:1284`) → PASS_TIME rows.
5. **Corpus-wide host profiling of tcc itself** (x86 cross `armv8m-tcc` runs the identical opt/codegen code; gprof workflow incl. its mcount call-bias caveat):
   - **Time profile over ALL tests**: sweep the full corpus (torture compile+execute, tests2, ir_tests) at -O0 (matches smoke config) and -O2 (tail/self-host track), `GMON_OUT_PREFIX` accumulation + summed `gprof`, cross-checked with `perf record` (no mcount bias). Deliverable: ranked per-function aggregate across the whole corpus + per-test worst-N list, saved under `.cache/tcc_host_profile/`.
   - **Data-access profile**: valgrind **DHAT** on representative worst tests → per-allocation-site bytes, block counts, access density (ranks the malloc/memset traffic that becomes PSRAM cost on target); valgrind **cachegrind** for D-refs/D-miss per function (host cache misses ≈ candidate PSRAM-hot data structures). Complemented by in-tcc allocation-volume counters (Phase 3.3) which run on both host and target.
   - Caveat: host ranks *volume*, not target cost — confirm top candidates on-target via PASS_TIME/`-bench` before optimizing (host profiling lied before: 5% host vs 44% target for vrp).
6. **Kernel hot-path microbenchmarks**: null-syscall round-trip, context-switch (PendSV with the new FP/DCP save-restore), and one mmap+zero cycle, measured on target (`source/kernel/benchmark.zig` timestamp helper; syscall cycle table via `tests/smoke/profiling.py`). Also verify where kernel `.text` executes from (XIP flash vs SRAM) — hot handlers running XIP contend on the QMI bus with the PSRAM data they touch.
7. **XIP fetch-bound vs core-bound split for compile — DONE (2026-08-03). Answer: memory-bound.** tcc executes 2.17 MiB of `.text` through the RP2350's 16 KiB XIP cache; whether the 78% compile bucket waits on the core or on QMI fetches decides all of Phase 5. Both measurements the item asked for were built and taken — (a) the RP2350 does keep the RP2040's counters (`XIP_CTR_HIT` at `XIP_CTRL_BASE`+0x0c, `XIP_CTR_ACC` at +0x10, both 32-bit **saturating**, write-any-value-to-clear), now drained on the system tick and served as `/proc/xip`; (b) the 618-vs-532 clock A/B, which 532 turns out to reach exactly (VCO 1596, postdiv 3/1, SCK 133.00). Numbers and the derived split in [Measured: Phase 0.7/0.8](#measured-phase-0708-2026-08-03).
8. **SD throughput floor — DONE (2026-08-03). Answer: reads are fine, writes cost ~1.2 ms per sector.** The MMC path already negotiates a 4-bit wide bus + high-speed and reads with CMD18 multi-block (`source/kernel/drivers/mmc/mmc_io.zig:500`, `:618`), so the cheap wins looked taken — but only on the read side. `sdio_write` (`:647-689`) issues one CMD24 plus a busy-wait **per 512-byte sector** and CMD25 appears nowhere in the tree, which the measurement confirms from the outside: write throughput is flat at ~0.4 MiB/s no matter how large the request. Numbers in [Measured: Phase 0.7/0.8](#measured-phase-0708-2026-08-03). Still owed for the 2.9 decision: the SD share of a *compile*, which is item 1's syscall cycle table, not this benchmark.

Exit criterion: numeric decomposition tables + a ranked corpus-wide tcc bottleneck report (time + data-access) + kernel hot-path cycle numbers + ~~the XIP fetch/core split~~ (done, item 7) + ~~the SD floor~~ (done, item 8); the (est.) figures below get replaced.

### Two bugs the manifest work surfaced (both fixed; neither is manifest-specific)

**zmodem could not sustain a bulk transfer — the kernel UART ring was smaller than a sub-packet.** Reported as `crc mismatch len=<short of 1024>` on ~25-35% of sub-packets across the 2026-07-31/08-02/08-03 runs; small sources survived on retries, a 511 KiB file never did.

The first diagnosis was that `rx_byte()` did one `read()` syscall per byte, and it was half right: at 921600 baud a byte lands every 10.9 µs, which is about what a `read()` costs, so the receiver ran at roughly line rate with no margin. But the 2048-byte userspace read buffer that was supposed to fix it did not, and the reason is that `VMIN = 1` raw mode returns **as soon as the ring is drained** (`source/kernel/drivers/uart/uart_file.zig:86-93`) — asking for 2048 bytes gets 1 or 2 back whenever the reader is anywhere near keeping up, so the syscall was still being paid per byte or two.

The next guess was the 512-byte kernel ring (`RingBuffer(u8, 512)`, `hal/source/raspberry/rp2350/source/uart.zig`), sized for a shell command line rather than for a 1 KiB sub-packet. It was raised to 4096 and **that did not fix it either** — the 2026-08-03 08:14 run came back with the same failures at the same magnitudes. That result is what identified the real layer, because ring overflow is arithmetically impossible at 4096: the sender is strictly lockstep, waiting for a ZACK after every 1024-byte chunk (`tests/smoke/framework/file_transfer.py`, `_recv_ack_or_zrpos`) and the receiver only ACKs after its SD write, so at most ~1030 bytes are ever in flight. The bytes never reach the ring.

The suspicion then moved to the 32-byte PL011 FIFO, since `UART_UARTIFLS` resets to 1/2 (interrupt at 16 bytes ≈ **174 µs of headroom at 921600 baud**) while the kernel masks interrupts with `cpsid i` for far longer in several places — FatFs disk read/write (`source/fs/fatfs/fatfs.zig:243`/`:254`), the MMC/SDIO layer below it, `__malloc_lock` on every malloc/free (`source/kernel/interrupts/system_stubs.zig:239`), parts of the scheduler. Rather than act on that, it was measured.

**Measured answer: the target loses nothing.** `on_uart_rx_irq` had been clearing UART errors by writing `icr = 0`, which clears nothing at all (ICR is a different register, and write-1-to-clear; FE/PE/BE/OE clear by writing UARTRSR/UARTECR), so overruns had been invisible for as long as this has been happening. With that fixed and counters added, every failing sub-packet on the 2026-08-03 08:40 run reported `ovr=0 drop=0` while `rx` climbed normally: no FIFO overrun, no ring overflow. **The bytes never arrived.**

**Resolved (2026-08-03): the bytes are lost on the link, before the target ever sees them.** Host-side byte accounting (`_LinkAccounting` in `file_transfer.py`) compares what the host has written against the cumulative `rx=` the target prints on every failure. Both counters are cumulative from different origins, so the first failure sets a baseline and the rest report drift. It climbs monotonically — +32, +64, +96, +128, +176, +224, +272, +304, +336, +368, +400 — and each increment is exactly that failure's deficit (`736 - len`, i.e. 32 or 48). The host writes N bytes and the target's interrupt receives N − deficit.

Combined with `ovr=0 drop=0 full=0` and no framing errors, the target is fully exonerated: this is not overrun, not ring overflow, not the tty layer, and not a zmodem bug. The bytes never reach the RP2350's RX pin, so the fault is in the Pi → USB → Debug Probe → UART path. **Nothing in this repository can fix it**; the remedies are rig-level (lower the console baud from 921600, update or replace the debug probe firmware, or move the console onto a dedicated USB-serial adapter and leave the probe for SWD only).

Two clues that fit and are worth recording: the failure rate tracked *round trips* rather than bytes, and each round trip has exactly one turnaround where the probe is forwarding both directions at once; and the deficits never scaled with burst size (1024 → 736 raw changed nothing).

The wrong turns below are kept because each one was disproved by a measurement that is still in the tree.

**A false negative, and the instrument was at fault.** `overruns` was counted from the copy of OE in UARTDR while UARTRSR was read and cleared one line later — but overrun is a FIFO-level status, and UARTRSR is where it is defined to appear; the UARTDR copy is not tied to a character the way FE/PE/BE are. So the ISR destroyed the evidence immediately after failing to read it, and reported a confident zero. Corrected: OE is counted from UARTRSR, checked both before and after the drain loop (the FIFO can overrun *while* it is being drained), alongside a `fifo_full`-on-entry counter that detects the same lateness without depending on the overrun flag at all, and a framing-error count to tell a corrupted line from a merely congested one. **Awaiting a re-measurement; treat the conclusion below as unproven.**

**Disproved: burst size is not the driver.** Sizing sub-packets by encoded length (below) shrank the chunk from 1024 to 736 raw bytes, and the deficits did not move — still 32/48/64/80, the same absolute values as before. A loss that is independent of how much is sent is not a buffer being overrun by an oversized write. Two further clues from that run: the failure rate per *sub-packet* held roughly constant while sub-packets got smaller, so failures track round trips rather than bytes; and one failure arrived at full length (`len=736`) with a bad CRC, which is corruption rather than truncation.

**Superseded theory — the host-to-target link drops whatever one burst pushes past its buffer.** Between the Pi's tty, the USB-CDC pipe and the debug probe that bridges it to the UART pin, a write is buffered and drained at line rate; the host hands over a whole sub-packet at USB speed and the tail past the buffer is lost. The deficits date the buffer at ~1024 encoded bytes, and their variance (30-80) is explained by ZDLE escaping: a 1024-byte raw chunk of C source encodes to 1054-1104 wire bytes depending on how many control characters it holds, and precisely the excess went missing.

**Kept, but not a fix:** the sender sizes sub-packets by their *encoded* length rather than raw payload — `_chunk_end_within_wire_budget` walks the payload charging two bytes for anything ZDLE escapes and one otherwise, capped by `WIRE_BURST_BUDGET` (768, comfortably under the inferred ~1024 rather than at its edge) less a 32-byte allowance for the ZDATA header, terminator and CRC that ride in the same burst. Sizing by raw bytes cannot work, because the overshoot is content-dependent. It bounds bursts predictably and is worth keeping for that, but it did not change the failure rate, and it costs ~39% more round trips — revisit the budget once the real cause is known. Covered by `tests/test_zmodem_batch.py`, which asserts no chunk of any payload — ordinary source, every byte value, all-escaped, ESCCTL control bytes — ever encodes past the budget.

Kept from the hunt, none of it the fix but all of it worth having:
- ring 512 → 4096, and `RingBuffer.push` drops the newest byte and counts it instead of discarding the oldest — and no longer logs from the RX interrupt, where the log went out over the same UART and `Uart.write` drains the RX FIFO inline while waiting for TX space, so an overflow could recurse straight back into `push`;
- the UART error clear is fixed, and the ISR counts FIFO overruns, ring drops, bytes received, and the longest interrupt-masked window seen at a loss;
- **`/proc/uart`** (`source/kernel/process/uartstat_file.zig`, registered in `procfs.zig`, fed from `main.zig` via a provider function so procfs stays HAL-free and host-testable). `rz` reads it itself and appends the counters to every `RZDBG` failure line — reporting once at the end of a batch was useless, because a 4546-file batch runs for tens of minutes and gets interrupted first;
- `receive_file_body` closed `fd` on three error paths that its caller also closes, and re-sent ZFIN on one of them; fd handling is now solely the caller's.

Still open from this: the kernel's `cpsid i` windows really are longer than the FIFO can cover, so bulk RX has no margin even though it is not what broke here. Belongs in Phase 2.7 — `/proc/uart`'s `max_overrun_gap_us` now measures it directly.

**The harness hung forever on a faulting target instead of reporting it.** `_read_until` and `_wait_for_echo` push their silence deadline back on every byte received and only hand the text to `_record_serial_output` — the crash-marker scan — once the loop ends. A faulted target dumps diagnostics without pause, so the deadline never expired, the markers were never scanned, `Session.target_crashed` was never set, and nothing was written to the log: the run showed "no new output, 2m36s in flight" indefinitely. Both readers now flush complete lines to the log every 256 bytes and stop when the crash flag goes up, turning the hang into a normal crash failure plus reset. Covered by `tests/test_smoke_session.py` (5 cases, all of which hang-then-fail without the fix).

**Still open — the device fault itself.** `echo <digest> > /root/ci/sources/.smoke_manifest_id` is followed by a precise bus fault (`CFSR=0x00008200`, `BFAR=MMFAR=0x00589004`, `pid=1`, `stacked_pc=0x100013E2`, `r2=r3=0x00589000`) at a non-existent address. Reproduced twice at the same test, because the every-32-sources flush lands on `129_scopes.c` deterministically. Shell output redirection creating a new file is a path the rest of the suite never exercises — note both manifest filenames begin with a dot, which is an awkward case for FAT 8.3 short-name generation. Needs decoding against the symbol ELFs (`scripts/collect_decode_bundle.sh`).

## Phase 1 — Quick wins (harness + config)

**1.1 Per-session source manifest (est. −270…450 s, low risk) — SHIPPED; in the 2026-08-03 run, not isolated.** Replaces ~4500 per-test device `sha256sum`s with two serial round trips per session.

Shipped shape. The suite knows its whole corpus up front, so it does not learn the device's state one test at a time — it **prebuilds the map on the host and establishes it in one exchange**:

- `_corpus_source_hashes()` hashes every source every collected case could upload — sources, support files and scanned `#include` dependencies, keyed by remote path so the -O0/-O1/-O2 and tagged variants share one entry. Measured: **4545 files, 0.22 s** on the dev box;
- getting the *first* map has four modes. **Default: push** (2026-08-03) — upload whatever the device is not already witnessed to hold, in one batched zmodem session, and seed from what was just written. `YASOS_SMOKE_SOURCE_MANIFEST_PUSH=0` asks for the old default back: the tests verify their own sources as they reach them exactly as before, and each is banked, so one full run leaves a complete map. `YASOS_SMOKE_SOURCE_MANIFEST_TRUST=1` seeds the whole prebuilt corpus at once with no device work. `YASOS_SMOKE_SOURCE_MANIFEST_CHECK=1` sends the map over (511 KiB, zmodem, `/root/ci/sources/.smoke_manifest`) and has the device confirm it with one `sha256sum -c` — verbose rather than `-s` so a disagreeing source costs only itself and the per-line verdicts keep the read alive (~195 KiB back). Asking for TRUST or CHECK stands the default push down; an explicit `..._PUSH=` setting wins over both;
- **the corpus check is opt-in because sending it was measured to be worse than what it replaces.** On the 2026-07-31 rig the device's `rz` took CRC retries on nearly every subpacket; two runs (06:49, 07:03) each burned minutes in that transfer at the start, before any test compiled. It also fires on *every* run that has no map, not once. Both it and the upload now print progress (`send_file` grew an `on_progress` callback; the check reports `device checked N/4545`) — the runner invokes pytest with `-s`, so plain prints reach the operator;
- **push: establish the corpus instead of interrogating it (2026-08-02).** Measured, the check had the economics backwards — the map of hashes it uploads is **511 KiB**, while the entire corpus it describes is **4.13 MiB across 4546 files** (median 344 B), and after receiving the map the device still has to read and hash all 4.13 MiB off the SD card and send ~195 KiB of verdicts back. Sending the sources costs 8× the map and answers the question completely, so `--seed-source-manifest push` uploads every source the device is not already witnessed to hold, then seeds from what it just wrote. With a valid map + token it pushes only the diff, so a branch that adds 40 tests costs 40 files rather than a re-check; with no token it pushes everything, which is also the only bootstrap that works on a fresh SD card or on QEMU, where a check can only report that nothing is there. **Promoted to the default on 2026-08-03**, because the lazy path it replaced only ever banked a map when a run *reached the end*: every interrupted run — and every `-k`/`--rerun-failed` run, which never touches most of the corpus — handed the next one the same 4546 per-source round trips, and the rig's map sat at 20 entries for days. The known cost of making it unconditional: the corpus is every *collected* case, not the filtered selection, so the first `-k`-filtered run against an unwitnessed device still sends all 4.13 MiB — paid once, since it leaves a full map and token behind. Implementation: **batch zmodem** — `rz --zmodem --batch` takes any number of files in one session, each named by its own ZFILE header (missing directories created on the fly), because the per-file cost was never the ~1 KiB of data but the rz spawn, handshake and shell round trip around it. An older `rz` on the target reads `--batch` as a filename and answers the first ZEOF with ZFIN, which the sender reports as a protocol error and falls back from, rather than hanging. The push reports a bar plus counts, throughput and ETA (`pushing [####----] 1908/4526 sources 1600/4211 KiB 68 KiB/s eta 0:38`), paced by the clock rather than by a file count — the corpus runs from empty files to 400 KiB ones, so "every N files" alternates bursts with silence. It redraws in place on a terminal and prints ordinary lines when piped, which is the case that matters: the remote runner gives pytest no tty, and a log full of carriage returns is one unreadable line. Interval: `YASOS_SMOKE_SOURCE_MANIFEST_PROGRESS_INTERVAL` (2 s). Covered by `tests/test_zmodem_batch.py`, which compiles the actual receiver C for the host and drives it over pipes with the actual host sender (nested directories, binary payloads that exercise ZDLE escaping, empty files, truncation of a longer stale copy, and the single-file path that now shares the same body helper);
- **the bootstrap modes are selectable from the runner**: `scripts/remote_smoke_tui.py --seed-source-manifest {push,lazy,check,trust,off}` (runtime-only, never written to the settings cache), with `push` now what a plain run does and `lazy` the opt-out. Until this existed they could only be picked with an environment variable set where pytest runs — the *remote* Pi — and the generated remote script forwarded no such variable, so in practice every run took the lazy path and no run ever reached the end to leave a complete map (2026-08-02: the map on the rig held 20 entries); that is what the default change fixes. `check` and `trust` export `..._PUSH=0` alongside their own flag, so selecting them still means what it says. The check path now also prints its elapsed time — that is the number this phase still owes;
- everything the device confirmed seeds `Session.confirmed_uploads`, is saved to `.cache/smoke_source_manifest.json` (`.cache/` is excluded from the remote-runner rsync, so it persists on the Pi; suffixed per pytest-xdist worker, since each worker drives its own QEMU), and a witness token = sha256 **of that map** is left at `/root/ci/sources/.smoke_manifest_id`;
- **steady state is one `cat`**: if the host map still covers the corpus and the device still holds the matching token, the whole map is seeded and no test hashes anything. The corpus check only runs again on a cold start or when the map has fallen more than `SOURCE_MANIFEST_RECHECK_THRESHOLD` (1024) sources behind — below that, letting the per-test path verify the stragglers is cheaper than a re-check, and the next flush folds them in;
- a stale map entry is harmless: `upload_testcase` compares against the *current* local hash, so a changed source misses the fast path and is verified and re-uploaded as before;
- the map is cumulative and rewritten every 32 newly verified sources, plus once at `pytest_sessionfinish`. The periodic write is the one that matters: interrupting `remote_smoke_tui.py` kills the ssh session and pytest never reaches its shutdown path (observed on the 2026-07-31 06:26 run — killed after ~40 s, banked 64 entries with a matching token; the first attempt used a 512 interval and a last-test-teardown hook and banked nothing);
- `reset_target()` now bumps `Session.confirmed_uploads_generation`, which re-triggers the seed — a mid-run reboot no longer costs a full re-verification storm on hardware, where `/root/ci` survives on the SD card;
- self-heal: a tcc `file '...' not found` naming a source the map vouches for drops the map and the confirmed set, so the rerun re-hashes and re-uploads. A missing include the upload scan never discovered is deliberately *not* blamed on the manifest.
- `YASOS_SMOKE_SOURCE_MANIFEST=0` disables it; the bootstrap defaults to push, and `..._PUSH=0` / `..._TRUST=1` / `..._CHECK=1` pick another mode (or `--seed-source-manifest` on the runner); `..._FLUSH_EVERY`, `..._RECHECK_THRESHOLD` and `..._CHECK_TIMEOUT` tune the rest.

Touches `tests/smoke/tcc_suite_test.py` (manifest block + `upload_test_sources` + `compile_testcase`), `tests/smoke/framework/session.py` (generation counter), `tests/smoke/conftest.py` (final flush). Host tests: 19 new cases in `tests/test_tcc_suite_harness.py` (corpus prebuild + partial device confirmation, trust mode, recheck threshold in both directions, token seed / stale / missing, re-seed after reset, flush thresholds, end-of-session recording, round trip, self-heal both ways). Still to verify on hardware: how long `sha256sum -c` over 4545 files actually takes on the device, then that the run after it opens with one `cat` and no per-test `sha256sum` at an identical pass/fail set.

**1.2 Round-trip batching — NEEDS RE-SIZING BEFORE IT IS BUILT (was: est. −250…400 s, low-medium risk).** The estimate was derived from a harness budget of 1050 s that the 2026-08-03 run put at 388 s, most of which is not per-test round trips at all (boot, collection, flash checks). The Phase 0.3 instrumentation now splits it; the first QEMU numbers say hash is ~6 ms/test and setup ~341 ms/test, which if it holds on hardware means the compound-command half of this item is chasing a cost that Phase 1.1 already removed, and the `cd /` + nudge half is the whole win. **Get one instrumented hardware run before writing any of it.** The design as originally specified:

One compound command per test: `cd /tmp && rm -f <bin>; tcc … -o <bin>; c=$?; echo __COMPILE_STATUS__:$c; if [ $c -eq 0 ] && <not compile_only>; then <bin> <args>; echo __EXIT_STATUS__:$?; rm -f <bin>; fi`. Split compile_ms/execute_ms by timestamping marker arrival via the streaming reader (`session.py:417-475`). Drop per-test `cd /` + nudge when the previous test ended cleanly (class-level flag; any anomaly → full recovery path). Keep `_resync_prompt_for_rerun` + crash-marker machinery untouched. Guard `expected_compile_failure`/`compile_only` with shell conditionals. Canary: longest generated command line through toybox sh first. Verify: tests2 subset diffed against baseline, then full run.

**1.3 PSRAM 109→133 MHz — SHIPPED (est. −50…150 s, config-only).** `CONFIG_CONFIG_PSRAM_MAX_FREQUENCY_HZ=133000000` in the board defconfig. Ran clean through a full 4466-test suite at 133 MHz with boot rxdelay calibration and the whole-array POST passing, so the timing margin holds on this board. Revert the single line on any later instability.

**1.4 Demote per-spawn info-level UART logs — SHIPPED (est. −20…40 s, likely more); in the 2026-08-03 run, not isolated.** Only two scopes actually reached the console: `std_options` pinned `.yasld` and `.loader` to info while everything else sits at the global `.err`, so `release_pages_for`'s four lines (`process_memory_pool.zig`) and `Process.deinit`'s four (`process.zig`) were already compiled out — those are demoted for consistency, and one eager `get_used_size()` computed purely to feed a dead log is gone.

The two that cost real time: `loaded '...' .text=.. .data=.. .got=..` (`dynamic_loader/source/loader.zig`), once **per module** — so three or four times per spawn — and `release_executable`'s two lines (`source/kernel/modules.zig`), twice per spawn. `Uart.write` busy-waits for TX space, so at 460800 baud that is on the order of 10-15 ms of blocking serial per spawn, on roughly 9000 spawns (compile + execute per test). Both are now off by default and both remain available: the load map is behind a runtime toggle the kernel sets from `perf.enabled` (`yasld.set_load_map_logging`), and the kernel-heap counters go out through `perf.trace`. Neither loses a diagnostic — a fault already dumps the module map (`dump_fault_maps`) and /proc/&lt;pid&gt;/maps serves it on demand. The `.loader` scope override in `std_options` is dropped with them.

**1.5 Core clock: the 618→798 ladder — TRIED, CLOSED (2026-08-03). 618 MHz is this board's stable max.** `a1101c0` raised the ceiling to 800 and landed the defconfig at 798 (after the 31:44 run was measured), but the points above 618 did not survive stability testing, so the board stays at 618 and **every number in this plan is, and remains, a 618 MHz number** — which keeps all Δs in this document comparable. The KConfig ceiling and its divider-ladder comments stay for other boards/parts. The estimated −110…−340 s this would have bought comes off the single-board outlook; what it leaves behind is the safe downward clock A/B in Phase 0.7, which extracts the fetch/core split this item would have needed anyway, without exceeding 618.

**Postscript (2026-08-03): the estimate this item was built on was wrong anyway.** 0.7's A/B measured a 13.9% core-clock *cut* costing 1% of wall, so the symmetric gain from a clock *rise* was never going to be −110…−340 s — core MHz is close to free money in both directions on this workload. Had 636 or 798 been stable, they would have bought a few seconds, not minutes, and 678 would still have lost 9% of SCK for nothing. The clock ladder is closed twice over: once because the board will not run above 618, and once because it would not have mattered much if it did.

**1.6 Suppress shell echo during harness sessions (added 2026-08-03; est. −10…−30 s; prerequisite for 1.7).** Every command byte the harness sends comes back as echo plus prompt redraw, and `_wait_for_echo` exists to wait for it — the echo is doing flow-control duty, so this is not just `stty -echo`: command receipt has to be confirmed by the command's own first marker instead. Worth a little on its own (both directions cross the probe that the zmodem hunt showed misbehaving under concurrent bidirectional load), but its real role is clearing the way for 1.7, where echo would interleave with the previous test's output and make the stream unparseable.

**1.7 Pipelined command streaming (added 2026-08-03; the stronger successor to 1.2; same gate — do not build before the 0.3 hardware split exists).** Batching (1.2) shrinks the number of round trips; pipelining removes the waiting for them: keep the next test's compound command already written to the wire while the current test runs, and let the 4096-byte kernel RX ring (sized in the zmodem hunt) hold it until the shell reads. The streaming reader already timestamps markers as they arrive (`session.py:417-475`), so per-test attribution survives unchanged. The ceiling is whatever share of the 388 s harness bucket is per-test turnaround — exactly the number 0.3 now measures, which is why it gates both this and 1.2. Recovery: any crash marker or timeout discards the in-flight queue, resyncs the prompt, and replays the queued tests on the lockstep path — the existing machinery plus one "discard in-flight" step. Two risks, each with an instrument already pointed at it: toybox sh line limits (1.2's longest-command canary), and the probe's bidirectional byte-dropping — believed gone at 460800 baud, but pipelining recreates precisely the both-directions-at-once pattern that triggered it, so every session ends by reconciling `/proc/uart` `rx` against host bytes written, and any deficit drops the session to lockstep.

Cumulative after Phase 1: **~2300-2600 s (38-43 min)**.

## Phase 2 — Kernel/libc memory path + hot paths (QEMU-gated; sized by Phase 0)

**2.1 Remove double .bss zero — TRIED, REVERTED. The premise is false.** The plan said the loader's `@memset(self.bss, 0)` (`dynamic_loader/source/module.zig:153`) is redundant because `process_memory_pool.allocate_pages` already clears every page it hands out. It does — but the loader does not receive those pages directly. It receives them through `std.mem.Allocator`, and `Allocator.allocBytesWithAlignment` ends with `@memset(byte_ptr[0..byte_count], undefined)` (`std/mem/Allocator.zig:284`), which in a safety-enabled build writes **0xAA over the pool's zeros**. Skipping the loader's memset boots toybox with a 0xAA-filled .bss and hardfaults immediately (`BFAR=0xAAAAAAB2`, `r0=r1=0xAAAAAAAA`, pid=1) — caught by `run_qemu_smoke.sh`, which builds ReleaseSafe.

The guarantee therefore reaches only callers of `allocate_pages` directly, which is the mmap path, not anything downstream of the `Allocator` interface. It could be salvaged by gating on `!std.debug.runtime_safety`, but then the shipping ReleaseSmall build takes a path QEMU never exercises — for a saving worth roughly 2-5 s of the 3260 s baseline (44 KiB per tcc spawn), which does not buy that risk. The trap is now recorded at the `@memset` in `allocate_pages`. Reconsider only as part of giving the loader a page-granular allocation path that bypasses `std.mem.Allocator` entirely.

**2.2 Pool free-slot hint + incremental used-count — SHIPPED; in the 2026-08-03 run, not isolated.** Three costs per `allocate_pages`, and a tcc compile makes hundreds of them (libc routes every alloc ≥ MSETMAX straight to mmap):

- the free-slot scan restarted at page 0 every time, re-walking the whole prefix held by the resident shell and libraries. Each region now carries a `first_free_hint` and scans from there. It is a *lower bound* only — `mark_free` lowers it, the scan raises it — so allocation still returns exactly the slot a scan from zero would have returned. **Deliberately not the next-fit cursor the plan called for**: next-fit stops reusing a just-freed block, which is both a fragmentation risk on a 300 KB region and the property four existing tests assert. The hint gets the same win with no behaviour change.
- `page_bitmap.count()` — a popcount over the whole bitmap — ran **twice per allocation** just to update `peak_used`, and again on every `get_used_size`/`used_pages`. Replaced by a `used_pages` total maintained in `mark_used`/`mark_free`, which count only real transitions so a double-free (`free_pages` will clear a range it never allocated) cannot skew it away from the bitmap.
- a region with too few free pages in total was still scanned end-to-end before failing over to the next tier. Now rejected in O(1), which is the common case once fast SRAM fills.

The scan itself also stopped retesting a candidate window one page at a time: a used page at offset k rules out every start below k+1, so the next candidate resumes there. Covered by 3 new unit tests (counter-vs-popcount after every mutating path including a double free, the hint's lower-bound invariant, and first-fit reuse across a hole too small for the request); 290 host tests + QEMU smoke green.

**2.3 Known-zero page tracking (medium risk).** Per-page known-zero bit; `allocate_pages` memsets only dirty pages; lazy re-zero (idle or at free). Explicitly NOT reintroducing slow-default tiering. Add a debug-mode audit sampling pages before handout (the prior HardFault class was exactly stale-nonzero memory).

**2.4 mk_pool re-zero → tcc_mallocz skip-memset (strict order).** Step 1: `mk_pool` zeroes recycled pool bodies (`libs/libc/malloc.c:171-179`) making "malloc returns zeroed" a true invariant (cover the vfork-restore path). Step 2 (after soak): drop the `tcc_mallocz` memset on yasos-native, re-running the exact past failure (self-host -O2 builtin-bitops-1). Gate: object-diff + full -O0/-O2 device runs.

**2.5 MSETMAX/MSETLEN tuning experiment** — informed by Phase 0's mmap counts; keep only if it measurably wins.

**2.6 Hybrid tiered /tmp — SHIPPED; in the 2026-08-03 run, not isolated.**
Small files stay in RAM, big ones go to SD. Shipped shape:

- **Placement is a dedicated linker region, not the process pool.** `temp_ram` (128 KB on the rp2350, carved out of `process_ram`, which drops 428→300 KB; 64 KB on mps2, 512 KB on mps3) reaches the kernel as a fourth `MemoryInfo` entry with a new `Owner.Temp`, which both MPU programmers and `process_memory_pool` already skip — so a compile's process image can never eat it and unprivileged code cannot reach it. Drawing arena pages from the process pool instead was considered and dropped: the arena would then compete with exactly the allocations it is meant to accelerate. **The trim alone costs ~2 min** on the full suite (33:40 measured with `process_ram` at 300 KB and no tmpfs), which is the debt the tmpfs has to pay back.
- **Tiering lives in `RamFsData`, not in a new filesystem.** A body is either a `std.ArrayListAligned` in the arena or a file on a backing filesystem, behind `len/read_at/write_at/resize`; `RamFs` gained `init_tiered(allocator, *Tier)` and everything else — the tree, directory listings, hard links, `dupe` — is unchanged. Because the union sits under the refcounted body rather than under the handle, a spill is instantly visible to every open handle and every hard link, and directory listings never need merging.
- **Three spill triggers** (`source/fs/ramfs/ramfs_tier.zig`): the write crosses `CONFIG_TMPFS_MAX_FILE_SIZE` (64 KB), free arena space is under `CONFIG_TMPFS_ARENA_RESERVE` (8 KB — without it the arena fills with bodies until there is no room left to *name* the next file and /tmp starts answering ENOMEM), or an arena allocation has already failed. Bodies land in `CONFIG_TMPFS_SPILL_DIRECTORY` (`/root/tmp`) as `yNNNNNNN.tmp` — 8.3-clean, since FAT short-name generation for dotted names is the path that produced the manifest bus fault above. Ids restart at 1 each boot and a spill truncates what it finds, so a reset leaves a bounded number of stale bodies rather than unbounded growth.
- **`/tmp` is now a real empty directory in the romfs** (`build_rootfs.sh`), not a symlink to `/root/tmp`. It has to be: `MountPoints.mount_filesystem` verifies the mount point exists in the parent filesystem, and `RomFs.get` resolves a symlink *inside the romfs*, where `/root/tmp` does not exist — mounting over the symlink fails with `NoEntry`. **This means the rootfs image must be rebuilt** before the tmpfs does anything; `remote_smoke_tui.py` hashes `build_rootfs.sh` so its normal flow picks it up.
- Arena growth is by whole 256-byte pages rather than the ArrayList's doubling: doubling a body that is already half the arena fails outright, while page-granular growth extends in place whenever the pages above are free, so an append-only writer normally pays no copy. Untiered RamFs instances (the QEMU `/root` fallback, on the kernel heap) keep doubling.
- A board with no Temp region still mounts /tmp, with the per-file limit pinned to zero: every body spills on its first write, which is exactly what the symlink did. `/proc/meminfo` picks the arena up through the existing `root.get_tmp_memory_usage()` hook.

Covered by 8 host unit tests (`source/fs/ramfs/ramfs.zig`, RamFs-backed spill target): threshold spill including the bytes written before it, arena-exhaustion spill over a real `TmpMemoryPool`, the metadata reserve, a handle opened before the spill reading correctly after it, truncate/seek on a spilled body, body removal on unlink, and symlink bodies never spilling. QEMU smoke (shell/cd/ls/ps/tcc) green.

Still owed: an isolated A/B against a no-tmpfs build — the 2026-08-03 run measured it alongside 1.3, 1.4 and 2.2 — and a decision on the 128 KB / 64 KB split. Note the unresolved provenance of the 33:40 comparison run recorded under [Measured: 2026-08-03](#measured-2026-08-03); it decides whether the tmpfs has repaid the `process_ram` trim or merely broken even.

**2.7 Kernel hot-path tuning (sized by Phase 0 microbenchmarks).**
General YasOS performance work that every compile/exec pays for:
- **Hot kernel code placement in SRAM**: if kernel `.text` is XIP from flash (verify in `hal/source/raspberry/rp2350/linker_script.ld`), move the hottest routines — PendSV/SVC entry + context switch (`source/arch/armv8-m/context_switch.S`, `source/arch/arm-m/process.zig`), syscall dispatch (`source/kernel/interrupts/syscall_handlers.zig`), and the pool page-zeroing memset (`process_memory_pool.zig:244`) — into a RAM-function section, so instruction fetches stop contending on the QMI bus with the PSRAM/flash data they operate on. Kernel RAM budget is tight (76 KB) — move only what the microbenchmarks justify.
- **Lazy FP context save/restore**: with hardware FP enabled, check whether PendSV saves/restores FP + DCP state unconditionally; use ARMv8-M lazy FP stacking (FPCCR.LSPEN / CONTROL.FPCA) so integer-only switches don't pay the FP-state cost. Coordinate with the in-flight FP changes on branch `virtualTerminal` (`source/arch/arm-m/process.zig`, `source/arch/armv8-m/context_switch.S` currently modified).
- **Syscall dispatch trim**: shave per-syscall fixed work in the SVC path (dispatch table, argument marshaling, logging/accounting on the hot path) guided by the null-syscall number.
- **Scheduler tick**: check tick frequency and per-tick work during a long compile; reduce rate or work if measurable.
Verify: QEMU smoke green + full HW run; microbenchmarks re-run to confirm each cycle-count win; the zmodem/nPRIV regression class (privilege state across context switch) explicitly re-tested since PendSV is being touched.

**2.8 Precompiled headers for the corpus — TRIED, CLOSED (2026-08-03): PCH loading measured *worse* than parsing.** The machinery exists end-to-end (`build_rootfs.sh --with-pch`, `:668-704` — stdio/stdlib/string in both predefine variants plus the `auto.index` the on-device loader picks up silently) and the item guessed that enabling it would cheapen header-heavy compiles. Measured, the premise is backwards: loading a PCH costs more than the direct parse — the corpus's headers are small, well-structured parses that tcc gets through faster than it can deserialize the cached form. The flash-saving reason it ships disabled was never the whole story. The machinery stays in the tree, off, for a future header set that measures differently; do not re-propose for this corpus.

**2.9 SD path tuning — CMD25 write parity BUILT AND MEASURED (2026-08-03): sequential writes 0.41 → 3.5 MiB/s at 32 KiB calls, and the gating question is answered: ~90% of the 1.33 ms was per-command turnaround.** The floor measurement (0.8) said sequential write sat at ~0.4 MiB/s **regardless of request size** (~1.2 ms per 512-byte sector) against reads at up to 8.2 MiB/s, because `sdio_write` issued one CMD24 plus a full program busy-wait per sector while CMD25 appeared nowhere in the tree. Built, on the same card in one session (sdbench `-s 1024 /root/ci`, old firmware then new):

| `write()` size | before | after | per op |
| --- | --- | --- | --- |
| 512 B | 373 KiB/s | 376 KiB/s | 1328 µs (unchanged — single sectors keep CMD24) |
| 4 KiB | 406 KiB/s | **2139 KiB/s** | 1869 µs |
| 32 KiB | 412 KiB/s | **3514 KiB/s** | 9105 µs |
| reads, scattered 1-sector writes | — | — | unchanged, as they should be |

The shape of those numbers is the answer to the gating question: a streamed sector inside a CMD25 run costs **~120–140 µs — write/read parity** (the read side measures 104–126 µs) — and what remains per *request* is a fixed ~1.3 ms (CMD25 + CMD12 + the final program flush), which is why 4 KiB calls gain 5.3× and 32 KiB calls 8.5×. The old per-sector 1.33 ms was ~90% recoverable command turnaround; the card's own program time pipelines behind the transfer exactly as the class rating promises. A 64 KB tmpfs spill drops from ~160 ms to ~18 ms.

Implementation (`source/kernel/drivers/mmc/mmc_io.zig` `sdio_write`, `hal/.../mmc/mmc_sdio.zig` `write_sdio_data`): multi-sector requests go out as chunked CMD25 + CMD12 (≤128 blocks, single sectors keep CMD24); a failed chunk retries whole from its first block, which is safe because it rewrites the same bytes to the same sectors, and `retransmissions` now resets after every good chunk like the read path always did (the old write loop accumulated them, so any 7 transient errors across one long write were a permanent failure). The HAL drives the stream **one block per critical section**: the C driver parks in `SDIO_TX_DONE` between blocks and the next `tx_start` continues without PIO reinit, the card just waits for the next start token, so the cpsid window shrinks from transfer-length (milliseconds — longer than the 32-byte UART FIFO covers, the 2.7 exposure) to ~50–100 µs per block — and the same per-block loop removes the old single-block limit on bounced buffers, so PSRAM/user memory streams through the SRAM bounce too. Worth knowing: FatFs's `write_through` critical section was already being broken one block in by the HAL's unconditional `cpsie` — real FS serialization comes from the layer above, and always did.

Verified: sdbench A/B above; a 443 KiB `cp` reads back sha256-identical; two smoke compiles (compile → .o write → execute) green on the new firmware. Still owed: a full suite run before this is trusted, and the original question of how much *suite wall time* it buys — the win is gated on `write()` granularity (a 512 B-buffered writer still lands on the CMD24 path), so the beneficiaries are the 2.6 spill path, `cp`/zmodem-scale writes, and anything with a ≥4 KiB stdio buffer; the SD share of an ordinary compile (item 0.1's syscall cycle table) still bounds the rest. Not built from the candidate list: FatFs multi-sector granularity (nothing to build — it already passes runs through intact), SDIO PIO clock, and read-side per-block cpsid windows — the RX stream's clock gating between `rx_start` calls needs understanding first.

**Guarded since 2026-08-06** by `tests/smoke/sd_write_perf_test.py`, an ordinary (non-`measure`) smoke test, so this cannot silently revert: nothing else in the suite notices a filesystem that is correct and 8x too slow. It runs `sdbench` once (~7 s, skipped on the QEMU boards, whose /root is RAM-backed) and asserts both loose absolute floors and — the part that actually pins CMD25 — the *speedup ratio* between a 32 KiB write and a 512-byte one, which is card-independent because both run on the same silicon seconds apart. The regression shows up there as 9.3x collapsing to 1.1x. Floors are set from four back-to-back runs; the tuning notes, including the one run where the card's garbage collection cost the single-sector pass 37%, are in that file's docstring.

**Conditional (decided by Phase 0 data):** the per-module precompiled relocation program formerly listed here is promoted to **Phase 5.2**, still gated on the same `loader_ms` number.

Cumulative after Phase 2 (incl. hybrid /tmp + hot-path tuning): **~1900-2300 s (32-38 min)**.

## Phase 3 — tcc -O0 allocation reduction (output-neutral)

- **3.1** Fuse the 5 duplicate `vreg_to_iv` builds (`libs/tinycc/ir/regalloc.c:1039/1099/1174/1240/1301`) into one shared build.
- **3.2** Reuse codegen dry-run scratch (`libs/tinycc/ir/codegen.c:2359-2589`, 5 O(n) mallocz/function) via grow-only persistent buffers (ctx pattern: `source/opt/engine/ctx.c:66-110`).
- **3.3** Add allocation-volume instrumentation (count/bytes/memset-bytes per pass) to `pass_timing.c`, then port the hottest -O0 sites to `small_sequence`/`dynamic_bitset` per the cap-measurement methodology (`libs/tinycc/docs/plans/memory_abstraction_port.md:487-517`).

Gate per change: object-diff across gcc torture at all -O levels, `make test-golden-ir`, metrics gate, device run. Cumulative: **~1800-2200 s (30-37 min)**.

## Phase 4 — -O1/-O2 track (helps -O2 torture runs + self-host, not the default -O0 suite)

- sccp `edge_exec = tcc_mallocz(nb*nb)` (≤100 KB × ≤5 iter/function) → sparse/per-block successor bitsets (`libs/tinycc/source/opt/ssa/scalar/sccp.c:1941`); per-flood-seed `visited` memset (`:431`) → touched-list (neg_chain pattern).
- `ra_coalesce_graph` 4 full-universe bit-matrices (~40 KB zeroed/function, `ir/regalloc.c:3845-3852`) → densification already used at `:3665-3671`.
- `switch_collapse` per-table-entry memsets (`source/opt/flat/scalar/switch_collapse.c:90/:97`) → generation stamping (known_bits pattern).
- Shared CFG for the 7 loop passes that each rebuild it (~15 allocs + O(nb²) `df_seen` each), via ctx caches.
- Continue `libs/tinycc/docs/plans/opt_pass_dedup_and_perf.md` Phases 2-6.

Same output-neutrality gates as Phase 3. Keep out of default-suite estimates; measure via `--smoke-tcc-opt-level=-O2 --with-gcc-torture` runs and self-host build time.

## Phase 5 — Fetch-side and spawn-cost levers (added 2026-08-03; sized by 0.7 + loader_ms)

Phases 2-4 attack allocation volume; this phase attacks the other side of the 78% compile bucket — instruction fetches through the QMI bus, and the fixed cost every one of the ~9000 spawns pays before tcc runs a line of its own work.

**5.1 tcc code size as a speed lever — FIRST DELIVERY 2026-08-06: `.text` 2,541,400 → 1,977,152 B (−551 KiB, −22.2%), and none of it needed the optimizer merge this item assumed.** Four mechanical defects (R9 GOT-base spills hoisted, a zero addend, and two rounds of header helpers that tcc never inlined but duplicated up to 179 times) plus the inline narrow-return-slot miscompile the last of them exposed. Two of the four shrink every program tcc compiles, so the execute step and loader benefit too. The speed dividend is **not yet measured** — the obligation this item set itself, to re-run the 0.7 capture at each size milestone, is outstanding, and so is a timed hardware run. The remaining mechanical patterns were each measured and rejected with a reason; see [Measured: the footprint round](#measured-the-footprint-round-2026-08-06) for that table so they do not get re-proposed. What is left on this axis is codegen quality (~1.48× gcc -O2), which is a project. **The pre-2026-08-06 text follows, including its 2.17 MiB figure — which was itself six weeks stale, the real number having drifted to 2.42 MiB unnoticed.** 2.17 MiB of `.text` executes through a 16 KiB XIP cache, so every point of hit rate is QMI bandwidth handed back to the PSRAM data traffic Phases 3-4 are busy reducing. The item was written with an escape hatch — "if 0.7 says compile is core-bound, this item evaporates" — and 0.7 said the opposite as loudly as it could: a 13.9% core-clock cut cost 1% of wall, and roughly 65% of a compile is stalled on cache misses. The size-reduction track already has a sized analysis (R9 GOT-base spills ~311 KiB of `.text`, the legacy+SSA optimizer merge, 1.48× vs gcc -O2) motivated by self-host; it now has a second and probably larger motivation, and one obligation: re-run the 0.7 capture at each size milestone so the speed dividend is measured rather than presumed. Note what the 98.71% hit rate does *not* mean — at ~38 M accesses per compile, the remaining 1.29% is still 495 k misses, so the lever is the miss *count*. The sweep sharpens this from an inference to a measurement: the miss rate holds within ±9% across a 148x range of compile durations, which is what a 2.17 MiB instruction footprint against a 16 KiB cache looks like, and it barely moves when the data working set grows by orders of magnitude. **Code footprint is the term.** The 311 KiB of R9 GOT-base spills alone is 14% of `.text`, and every KiB of it is competing for the same 16 KiB.

**5.2 Loader prelink cache — gate passed by an order of magnitude, and the item is bigger than it was written to be (2026-08-03).** It was to wait for `loader_ms ≥ ~5 ms/exec`. Measured: **~48 ms/spawn**, ~10x the gate. Three things 0.2 changes about the design:

- **This is not a tcc item.** `cat` pays 48.9 ms of loader before it prints a byte. Across the suite's ~9,000 spawns it is ~400 s of a 1,905 s run, and it taxes the harness's own round trips and every test's execute step as much as it taxes compiles.
- **The cost is not proportional to the image** — tcc is 11x toybox and loads *faster* — so the win is not in copying or clearing less. At ~22 us (≈13,500 cycles) per relocation the per-relocation work is itself the target, and at ~139,000 cache misses per load it is scattered lookups rather than streaming.
- Therefore the cached form should be **a flat, sequentially-streamed list of (offset, kind, value)** with symbol resolution already collapsed into it — the point is to replace scattered per-symbol lookups with one linear pass, not to parse the same structures faster.

Original sizing follows. Per exec today: ~15 KB data copy, 43.7 KB bss memset, 2,312 B GOT copy + 289-entry rewrite, ~2,200 parsed relocations (`dynamic_loader/source/module.zig`). First load of a module version flattens parse+hash-lookup into a stored list of (offset, kind, addend) triples; every later spawn replays the triples against its own base instead of parsing. At ~9,000 spawns the break-even is ~5 ms/exec of measured loader time (~45 s over the run) — below that the cache is complexity for nothing, which is why the 0.2 instrumented run must come first.

**5.3 Resident compiler / batch tcc — the largest single lever, now with a number on it, and still the most dangerous.** 0.1 has done the split this item was waiting for: **85.8 ms of every compile is paid before tcc reads the source**, ~380 s across the run, and a resident compiler is the only item here that recovers all of it rather than a part. Everything the item says about the danger stands unchanged — it is still opt-in or nothing, still needs bit-identical output across the whole corpus, and the one-shot path still stays forever. Original text follows. Every compile pays process create + eager page zeroing, module load, and tcc's own init — predefines, include-path setup, cold malloc pools; `mk_pool` recycling only helps *within* a process — and then throws it all away. A resident tcc consuming argv jobs from a FIFO amortizes all of it across the corpus. The danger is structural, not incidental: the suite exists to catch tcc regressions, a crash inside a batch takes the server and the per-test attribution with it, and state bleeding between jobs in one address space can both mask and invent miscompiles. So the shape, if 0.1 justifies building it at all: **batch-of-N between checkpoints** — any anomaly re-runs the window one-shot to re-attribute; mandatory gate = batched output bit-identical to one-shot output across the whole corpus; the one-shot path is kept forever and remains the only mode validation runs use. Ships opt-in or not at all.

**5.4 Flash transaction overhead — SHIPPED 2026-08-06, both halves: −20 cycles/miss for the CS-deselect time and −32 for the opcode, together −68.3 s of compile and −77.3 s of wall. See [Measured: 10:36](#measured-1036-2026-08-06-the-transaction-round--54-taken-in-full). The item's own caveat — that `cooldown` may already amortise the opcode — was measured and is real for *sequential* accesses only, which is not what a compile's misses are. The unblocking work was not on the flash side at all: it was a PIO autopull race in the SDIO command path. Original text follows.** (added 2026-08-03, off the back of 0.7; NOT attempted, and deliberately so). 0.7 leaves compile time as `misses x ~345 ns`. 5.1 and Phases 3-4 attack the count; this attacks the price. What a miss buys today, from `computeQmiConfig()` (`hal/source/raspberry/rp2350/startup/crt.zig:435-453`): an 0xEB quad-I/O read with a single-lane 8-bit command prefix, 24-bit quad address, an 8-bit quad suffix, and a 4-clock dummy — already a good configuration, so the dummy count and the read opcode are *not* where anything is left.

The prefix is. The suffix is programmed to `0xFF`, which is precisely the mode byte that keeps the part *out* of continuous-read mode, so the QMI re-sends the 8-bit opcode on every transaction. Switching the mode byte to the continuous-read pattern and dropping `PREFIX_LEN` to zero is what the pico-sdk's own boot2 does, and it saves 8 SCK clocks out of roughly 28-36 — call it up to 22% of a miss, which at 65% of compile would be ~14% of the bucket.

Two reasons it is written down rather than done:

- **The size of the win is genuinely unknown, and could be near zero.** The `cooldown` and `pagebreak` fields exist so the QMI can hold a transaction open across consecutive accesses, so a sequential run of misses may already pay the opcode once rather than per line. Only the discontinuous misses are charged, and nothing here has measured what fraction those are. Measure that fraction *first* — it is the difference between a 14% win and nothing.
- **It is a change to the bus the CPU fetches instructions from**, and getting the QMI and the flash out of step means garbage instructions rather than a wrong answer. It also has to survive everything that can knock the part out of continuous-read mode: the bootrom flash helpers, `ROM_FUNC_FLASH_FLUSH_CACHE`, and the flash-writing driver (`hal/source/raspberry/rp2350/source/flash.zig`).

The safety pattern already exists in the tree and should be reused rather than reinvented: `overclock_calibrate_flash_rxdelay` (`startup/overclock.c:184-249`) programs candidate flash timings from RAM, CRCs a known region through the **uncached** window at `0x14000000`, and keeps only what verifies. A continuous-read switch validated the same way is self-checking at boot and falls back to today's configuration on any mismatch. Recovery if it still goes wrong: `remote_smoke_tui.py --rescue`.

**5.5 Stop re-parsing the predefines every compile — SHIPPED 2026-08-04, in a different shape than written (−23 ms/compile measured, ~102 s/run; floor 48.9 → 25.8 ms).** The sizing below survived but the attribution did not: the cost was the ~60 builtin alias *declarations* (XIP-cache thrash between macro expander and declaration parser), not the macro defines — option (b) was built, measured as a wash, and reverted; what shipped is programmatic prototype construction (`tccgen_predef_protos`) plus word-wise libc `memset`/`memcpy`/`memmove` found along the way. See [0.1, third cut](#01-third-cut-2026-08-04--the-second-cut-was-right-about-the-where-and-wrong-about-the-what-floor-now-258-ms). Original item text follows, kept as the record of what the second cut believed. Every compile lexes and `#define`s the same ~17.4 KB of constant predefine text; the A/B says 95% of its 32.7 ms is proportional to that text, so not doing it per compile recovers nearly all of it. Options, cheapest first: (a) **pre-evaluate the dead `#if` branches at build time** for the fixed target — partial, the live lines still get lexed and defined each compile; (b) **build-time pre-tokenization** — generate the predef macro table as static data (names + token streams) and `define_push` without running the char-level lexer — recovers the lexing but still pays interning and `Sym` churn per compile; (c) **lazy predefines** — keep a static name→definition table and materialize a predef macro only on first lookup, the shape the lazy builtin-token interner in `tccpp_new` already uses — an empty compile then defines nothing and a typical TU a handful, so this recovers nearly all of it. All three keep one-shot process isolation, so none carries 5.3's cross-job state-bleed hazard; but (b)/(c) are surgery on macro lookup (`#ifdef`/`defined()` must see unmaterialized predefs, `#undef` of one must stick, `-dM` must list them), so the gate is the usual one: bit-identical output across the whole corpus against the parsing build. If this lands, 5.3 is left recovering only the ~15 ms that remain — which may retire the most dangerous item in the plan for good.

## Phase 6 — Suite-level levers (added 2026-08-03; change what a run does, not how fast the target is; all opt-in)

These do not make the target faster; they make a *run* cheaper by not repeating work whose inputs did not change, or by adding hardware. They all carry the stale-phantom risk class, so the locked rule applies doubly here: nothing in this phase is ever a correctness or timing baseline.

**6.1 Device-side compile cache (est.: a kernel-dev run drops from ~32 to ~10 min).** Key = (tcc binary digest, cflags, source + include-closure hashes) — the 1.1 manifest already computes the closure; outputs live on SD under `/root/ci/objcache/<key>`. On a hit the compile step becomes a copy (or execute runs the cached binary in place) while execute still exercises kernel, loader and syscalls — which is the entire point of a kernel-iteration run, where tcc has not changed and 78% of wall is spent re-proving it. Gates, in order: a **determinism check** (double-compile across the corpus on device, byte-identical, done once) before first use; the timing report marks cached runs non-comparable — a `compile_ms` that measured a `cp` must never land in a baseline table; the flag prints loudly in the report header; tcc-validation runs never see it. Invalidation is the tcc digest in the key; `rm -rf /root/ci/objcache` is the hammer.

**6.2 Changed-only selection (pure harness bookkeeping on top of 6.1's key).** Extend the key with the firmware digest, and a test whose triple matched the last green run can be skipped entirely — a JSON of triple→verdict beside the existing manifest cache. Dev-loop tool with the same phantom risk; the report states how many tests were skipped and why, and full runs remain the only gate that counts.

**6.3 Second board (rig work; est. 1904 s → ~1000-1100 s).** The per-board state already isolates: manifests are per-worker suffixed, `/root/ci` is per-SD-card, crash recovery is per-session. Needed: runner support for a second serial device + probe with its own uhubctl port mapping in the recovery ladder, and a **duration-aware split** — `tcc_timing_report.json` has per-test wall, and a longest-first greedy partition keeps the 321 s top-100 tail from serializing one shard, which a naive count split would. Near-linear until tail-bound (the single 22.6 s `limits-fnargs` sets the floor of the slowest shard). Second use once it exists: run the -O2/torture configuration on board B *concurrently* with the default -O0 suite on board A — two configurations per calendar slot instead of one.

**6.4 The idle second core (horizon; the only kernel-work item here).** *Superseded in part: core1 is no longer idle — SMP phases 0-7 landed and both cores schedule. What this item proposed is still unbuilt, but read [the XIP-contention round](#measured-device-side-concurrency-is-closed-2026-08-12-the-xip-contention-round) first: running a second **compile** on core1 is measured at 0.61x, and (a) below drives PSRAM traffic through the same QMI the compile is already saturating, so it needs measuring against that instrument before it is built. The paragraph below is the 2026-08-03 framing.* Nothing in the tree references core1 today. Full SMP is a project, not a plan item, but two bounded core1 duties pay into this plan without a scheduler rewrite: (a) **background page re-zeroing** — 2.3 wants pages zeroed off the allocation path, and a core1 work queue does exactly that while preserving the pages-are-recycled invariant, turning the mmap-path memset into a queue pop (verify PSRAM cache coherency between the cores before core1 touches cached PSRAM windows); (b) **console TX draining**, so `Uart.write`'s busy-wait leaves the compile path entirely (1.4 removed the routine spawn logging; this removes the cost of whatever remains). Order (a) first — it has a measured cost attached. Both need the SIO spinlock story told first; neither is worth starting before Phases 3-4 have eaten the cheaper compile wins.

## Verification (end-to-end)

1. After each phase: full `scripts/remote_smoke_tui.py` run; compare pass/fail set + `tcc_timing_report.json` against the 2026-07-30 baseline (goal: identical results, lower wall).
2. Kernel/libc changes: `run_qemu_smoke.sh` green before touching hardware; always rebuild+reflash before trusting a failure (stale-firmware phantoms).
3. tcc changes: object-diff protocol (bit-identical .o across torture corpus at -O0/-O1/-O2), `make test-golden-ir`, metrics gate.
4. PSRAM 133 MHz: boot POST + rxdelay window + one full suite; on instability revert the single config line.
5. Final: back-to-back timed full runs (old vs new) recorded here.
6. Any clock change (618 is the validated stable max; the 0.7 A/B runs *below* it): instability on this board is ~80% intermittent and **single runs lie** — ≥5 consecutive clean full runs (or the 76-test reduced repro, looped) before a timing at a new clock is recorded anywhere in this document, and every recorded run states its clock.
7. Caching/batching modes (5.3, 6.1, 6.2): never a correctness or timing baseline; validation runs are one-shot, cache-off. 6.1's determinism gate (corpus-wide double-compile, byte-identical) precedes its first use.

## Measured: 2026-08-03

**1904.60 s (31:44), 4466 passed / 72 skipped, same pass set as the baseline.**
Against the 2026-07-30 baseline of 3260 s that is **−1355 s (−41.6%)**, and it
lands at the bottom edge of the Phase 2 estimate while Phase 2 is only half
implemented.

Firmware in this run, verified against the synced tree on the rig rather than
assumed: **1.1** (source manifest), **1.3** (PSRAM 133 MHz), **1.4** (log
demotion), **2.2** (pool hint + counter), **2.6** (hybrid /tmp). Not present:
2.1 (reverted, see above), 1.2, 2.3-2.5, 2.7, Phases 3-4.

| Run | Wall | Δ vs previous | Contents |
|---|---|---|---|
| 2026-07-30 | 3260 s (54:20) | — | baseline |
| earlier 2026-08-03 (`timing_full_ram.txt`) | 2020.9 s (33:40) | −1239 s | no tmpfs; `process_ram` trimmed (**see caveat**) |
| 2026-08-03 17:44 | **1904.6 s (31:44)** | **−116.3 s (−5.8%)** | + 1.3, 1.4, 2.2, 2.6 |

The one clean like-for-like inside that last step is the `gcc_execute` category,
identical at 1799 tests in both runs:

| | 33:40 run | 31:44 run | Δ |
|---|---|---|---|
| compile | 722.46 s | 681.86 s | −40.6 s |
| execute | 19.05 s | 15.63 s | −3.4 s, −18% |
| total | 741.52 s | 697.49 s | **−44.0 s, −5.9%** |
| avg/test | 412.2 ms | 387.7 ms | −24.5 ms |

**Attribution is unresolved and this run cannot resolve it.** Four changes landed
together by explicit decision (implement-then-measure), so the −116 s is a joint
figure. Two of them are cheap to isolate if the number matters: 1.3 is one
defconfig line, and 1.4 is a runtime toggle. 2.2 and 2.6 would each need their
own run.

**Caveat on the 33:40 comparison — the provenance of `timing_full_ram.txt` is
not established.** The Phase 2.6 notes above describe 33:40 as the *trimmed*
`process_ram` (300 KB) configuration, and say the trim alone cost ~2 min, which
would put the untrimmed run near 31:40. The file's own name says "full ram",
which reads as the opposite (428 KB, untrimmed). The two readings tell different
stories: on the first, the tmpfs stack bought 116 s on top of paying back the
trim; on the second, it has roughly broken even against a configuration that
never gave up the SRAM. Resolve before treating either as settled — the earlier
run's logs are gone (each run clears `logs/`), so this needs a deliberate A/B,
not archaeology.

### What this says about the remaining work

- **Harness overhead is no longer the second-biggest bucket** — 1050 s → 388 s,
  now 20% of wall. Phase 1.2 (round-trip batching, est. −250…400 s) was sized
  against the 1050 s figure and cannot still be worth that; whatever remains of
  the per-test round trips is inside 388 s total, most of which is not round
  trips at all (boot, collection, flash checks). Re-size it against a measured
  `setup_ms`/`cleanup_ms` split (Phase 0 item 3) before building it.
- **Compile is now 78% of wall** and the tail carries a growing share of it
  (21.5% in 100 tests). That points at Phase 3/4 and at the tail specifically —
  `gcc_compile/limits-fnargs` alone is 22.6 s, `ir_tests/mibench_rijndael.c` is
  18.7 s, and the top 6 are 82 s between them.
- **Phase 0 is still owed** and is now the highest-value item, because every
  remaining estimate in this plan was sized against a budget that no longer
  holds. *(Items 7 and 8 have since been taken — see
  [Measured: Phase 0.7/0.8](#measured-phase-0708-2026-08-03). Items 1-6 remain
  owed, and item 1 in particular now carries the question 0.8 handed it: what
  share of a compile is SD wait.)*
- **Everything measured so far is miss-bound at the same rate**, and the sweep
  reduces it to a single law: `wall ~= misses x 345 ns`. It holds for compiles
  spanning 148x in duration, and it holds for the fixed cost of starting one.
  That re-weights the whole remaining plan: it reinforces Phases 3-4 and 5.1,
  retires core clock as a lever in both directions, and adds 5.4 — the only
  other multiplier there is, what a miss costs.
- **But the largest single lever is the per-compile floor, not the compile.**
  0.1 puts ~380 s of the run — a quarter of the compile bucket — in process
  spawn, module load and tcc init, before a byte of source is read. **5.1 is no
  longer the top of the list; it is second**, and its own sizing (how much of the
  *remaining* ~140 ms of a median compile answers to code footprint) is still
  open.
- **And within that floor, the loader was the half that was plainly wrong —
  now fixed, in two rounds, and it was the biggest win in the plan.** The symbol
  hash table was parsed and never attached, so every lookup linear-scanned; and
  once attached it only helped hits, while resolution is built out of misses.
  Together: a spawn went 48.5 → 7.5 ms, the compile floor 85.8 → 48.9 ms, and
  the suite 31:44 → 25:09. **Neither round touched tcc.**
- **The floor has now inverted, and that is the live question.** Of the 48.9 ms
  before tcc reads a byte, only ~7.5 ms is spawn and load — **~41 ms is tcc's
  own initialisation**, ~184 s or 12% of the run. Nothing targets it except 5.3,
  the most dangerous item here. Ask what tcc does for 41 ms at startup before
  reaching for a resident compiler.

## Measured: Phase 0.7/0.8 (2026-08-03)

Both instruments are in the tree and opt-in. `/proc/xip` serves XIP cache totals
(`source/kernel/process/xipstat_file.zig`, fed from `hal/source/raspberry/rp2350/source/xip.zig`
through a provider hook so procfs stays HAL-free); `sdbench` (`apps/sdbench`) is
a userspace storage benchmark; `tests/smoke/measure_test.py` drives both and is
skipped unless selected with `-m measure`, so a suite run neither pays for it nor
can be failed by it:

```
scripts/remote_smoke_tui.py --pytest-args "tests/smoke/measure_test.py -m measure -s"
```

The counters saturate rather than wrap, so they are drained on the 1 kHz system
tick into 64-bit totals — a read-at-the-ends design would silently truncate any
window longer than about seven seconds, which is exactly the tail compiles this
plan cares most about.

### 0.7 — the compile is memory-bound, and it is not close

Same workload (`tcc /usr/hello_world.c`), five repeats, median wall:

| | 618 MHz (÷5, SCK 123.6) | 532 MHz (÷4, SCK 133.0) | Δ |
|---|---|---|---|
| median compile wall | 167.4 ms | 169.2 ms | **+0.96%** |
| XIP accesses / compile | 38.33 M | 38.30 M | −0.1% |
| XIP misses / compile | 494.7 k | 496.8 k | +0.4% |
| hit rate | 98.71% | 98.70% | — |
| **XIP accesses / second** | **228.6 M** | **226.2 M** | **−1.1%** |

Dropping the core 13.9% cost **1%** of wall time. Pure core-boundedness predicts
+16.2%. By this item's own decision rule, that is the fetch-bound answer.

The instrument carries its own control, which is what makes the result
trustworthy rather than merely surprising: the same two runs also measured a
second, genuinely core-bound workload — the shell sitting idle at its prompt,
which spins entirely inside the cache at a 99.99% hit rate. Its access rate
scaled at 0.865 against the clock ratio of 0.861, i.e. exactly with the core.
The compile's did not move at all. One instrument, two workloads, opposite
behaviour, in the same pair of runs.

**Derived split, stated as derived.** Modelling wall as `core_cycles/f_core +
misses x t_miss` and assuming `t_miss` scales as 1/SCK, the two equations solve
to **t_miss = 221 ns** (27 SCK clocks at 123.6 MHz, which is the right order for
an 0xEB quad read with its command, address and dummy cycles) and, at 618 MHz:

| | ms | share |
|---|---|---|
| core execution | 58 | 35% |
| stalled on XIP cache misses | 109 | 65% |
| **total** | **167** | |

Treat the 65/35 as an estimate — it rests on the 1/SCK assumption — while the
+0.96% and the flat access rate above are measurements. Both point the same way.

One caveat stays attached to every number here: the counters cover the whole XIP
window. Flash instruction fetches and PSRAM data accesses land in one pair of
registers with no way to separate them, so a hit rate read off them is not the
instruction stream's alone. That ambiguity is what the sweep below was built to
work around, since it decides which of 5.1 and Phases 3-4 is the lever.

### 0.7, continued — compile time is miss count times a constant

The same instrument, run over compiles spanning **148x in duration**, all at
618 MHz. The last four are `-c`, since most of the corpus is fragments with no
`main` and linking them would measure the error path:

| source | wall | misses | miss/s | hit rate | ns of wall per miss |
|---|---|---|---|---|---|
| `tests2/00_assignment.c` | 149 ms | 430 k | 2.89 M | 98.83% | 347 |
| `/usr/hello_world.c` | 168 ms | 494 k | 2.95 M | 98.71% | 339 |
| `ir_tests/219_fuzz_strd_spill` | 1.42 s | 4.51 M | 3.18 M | 96.67% | 315 |
| `ir_tests/mibench_rijndael.c` | 12.39 s | 34.3 M | 2.77 M | 97.16% | 361 |
| `gcc_torture/limits-fnargs.c` | 22.08 s | 58.7 M | 2.66 M | 96.79% | 376 |
| *(idle shell, for contrast)* | 1.00 s | 65 k | 0.065 M | 99.99% | — |

**Wall time per miss is 315-376 ns across the whole range, and the miss rate
never leaves a ±9% band.** Compile time is, to a good approximation, *miss count
times ~345 ns*. The idle shell misses 45x less often, so this is a property of
executing tcc and not of the machine being switched on.

That the rate holds while the *working set* grows by orders of magnitude is the
answer the sweep was built to get. tcc's 2.17 MiB of `.text` dwarfs a 16 KiB
cache by 136x, so its instruction stream misses at a rate set by its own
footprint no matter what it is compiling; the data it chews on rides along. The
hit rate does sag from 98.8% to 96.8% on the large compiles, which says data
genuinely competes for the cache once there is enough of it — but it moves the
rate hardly at all.

**Miss count is a property of the program, not of the hardware.** The clock A/B
proves it from the other side: raising SCK 7.6% changed the miss count by
+0.42%, i.e. not at all. So there are exactly two multipliers on the compile
bucket, and this plan should be read as a search for them:

- **the miss count**, which answers to tcc's code footprint (5.1) and, more
  weakly, to its allocation traffic (Phases 3-4);
- **the ~345 ns each miss costs**, which answers to flash transaction overhead
  and SCK (5.4 below, and the reason 1.3's PSRAM bump worked).

The 532 MHz firmware existed only for this experiment. The board is back at 618,
and the restored kernel is bit-identical to the one built before it.

### 0.1, first cut — 86 ms of every compile happens before tcc reads the source

The sweep's smallest row (149 ms for a near-trivial source) looked like it was
mostly floor rather than work, so the harness now walks up to the floor one
layer at a time. Each row adds exactly one thing to the row above it, which
makes the arithmetic between them the attribution. Median of 5, 618 MHz, sources
in RAM-backed `/tmp` so nothing here is paying for an SD read:

| window | wall | what it adds | misses |
|---|---|---|---|
| `cd /` | 1.5 ms | harness round trip, no process spawned | *(see caveat)* |
| `ls /tmp` | 48.5 ms | + spawning and loading one large multicall module | 131 k |
| `tcc -c` empty source | **85.8 ms** | + spawning and loading tcc, and tcc's own init | 245 k |
| `tcc -c` `#include <stdio.h>` | 86.0 ms | + parsing a real header | 248 k |
| `tcc -c` trivial `main()` | 87.0 ms | + generating code | 251 k |

**An empty source costs 85.8 ms.** Parsing `stdio.h` costs **0.2 ms** and
generating code for a trivial `main` costs **1.0 ms**. Against a corpus p50 of
~223 ms that floor is ~38% of a median compile, and across ~4,450 compiles it is
roughly **380 s — a quarter of the 1,494 s compile bucket and a fifth of the
whole run** — spent on process creation, module load and compiler init, then
thrown away.

Two things fall out of this immediately:

- **It re-explains 2.8.** Precompiled headers were closed because loading a PCH
  measured worse than parsing; the reason is now visible rather than inferred.
  Parsing `stdio.h` costs 0.2 ms. There was never anything there to cache.
- **The floor is itself miss-bound, at the same exchange rate as everything
  else.** 245 k misses x ~345 ns = 84.6 ms, which is essentially all of the
  85.8 ms. So this is not a different bottleneck bolted onto the compile — it is
  the *same* one, being paid by the loader and by tcc's init instead of by the
  optimizer. That is worth knowing before anyone tries to fix it by making the
  loader cleverer: the win comes from touching less, not from doing less.

### 0.2 — the loader costs ~48 ms per spawn, and it does not care how big the module is

The `CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y` build was made and run, so
`loader_ms` finally has values in it rather than the zeros item 0.2 was written
about. Median module-load time, per executable, over one ladder run:

| module | median load | image size |
|---|---|---|
| `/bin/sh` | 49.79 ms | 237 KiB (toybox) |
| `/bin/rm` | 48.90 ms | 237 KiB (toybox) |
| `/bin/cat` | 48.87 ms | 237 KiB (toybox) |
| `/bin/ls` | 48.84 ms | 237 KiB (toybox) |
| **`/bin/tcc`** | **45.35 ms** | **2.53 MiB** |

**tcc is 11x the size of toybox and loads faster.** Load time is essentially
independent of the image, which rules out everything proportional to it — the
.data copy, the .bss memset, per-byte anything. At ~2,200 relocations per load
that is ~22 us, or about **13,500 CPU cycles, per relocation**, which is three
orders of magnitude more than applying one should cost. The load is also
miss-heavy in the way that implies: ~48 ms at the 345 ns exchange rate is
~139,000 cache misses, i.e. scattered pointer-chasing rather than streaming.

So the 85.8 ms floor splits roughly:

| layer | cost | share |
|---|---|---|
| harness round trip | ~1.5 ms | 2% |
| process spawn + module load | ~45 ms | 52% |
| tcc's own init (predefines, include paths, cold pools) | ~37 ms | 43% |
| compiling an empty file | ~1 ms | 1% |

**The consequence is much bigger than tcc.** Every process spawn on this system
pays it: `cat` takes 48.9 ms to load before it prints a byte, and the suite
spawns on the order of 9,000 processes between compiles, executes and the
harness's own `rm`/`cat` round trips — call it **~400 s of the 1,905 s run**.
5.2 was written as a tcc-spawn optimisation; it is actually a system-wide one,
and that is a much stronger case than the item currently makes.

*Caveat on the numbers.* These were taken on the profiling build, whose own
serial tracing inflates wall time — the same ladder read 107.7 ms for the floor
against 85.8 ms without it. The `us=` values are computed before their trace is
emitted, but traces fired inside a load window would still land in it, so treat
~48 ms as an upper bound. The cross-check from the ordinary build agrees closely:
`ls /tmp` costs 48.5 ms end to end there, which caps its load at ~45 ms.

### FIXED (2026-08-03) — the loader was never using the hash table it parsed

The size-independence was the clue that solved it. Cost that ignores the image
but tracks `imports x exports-in-search-path` is a lookup problem, and that is
exactly what it was: **every YAFF image carries an ELF-style symbol hash table,
`Parser` has always parsed it into `imported_symbols_hash_table` /
`exported_symbols_hash_table`, and nothing ever read those fields.** The symbol
tables were built as struct literals without `.hashtable`, so it defaulted to
null, so `element_by_name` always took its "fallback to linear search" branch —
a `strlen`-strided walk over variable-length records in XIP flash, once per
imported relocation, over the module's own exports first and then every
dependency's. `YaffHashTable.lookup` was dead code.

It also explains the inversion. toybox's libc lookups sit behind a 190+184-record
guaranteed-miss prefix (its own exports, then libm) while tcc's dependency path
opens with two 19-export stubs — so toybox does ~146,000 record visits per load
against tcc's ~114,000, and the 11x-smaller module is the slower one.

Attaching the table (`dynamic_loader/source/parser.zig`,
`dynamic_loader/source/item_table.zig`) is measured on the same ladder:

| window | before | after | Δ |
|---|---|---|---|
| `ls /tmp` | 48.5 ms | **36.4 ms** | **−25%** |
| `tcc -c` empty source | 85.8 ms | **71.8 ms** | **−16.3%** |

At ~9,000 spawns a run that is order **100 s off a 1,905 s run**, pending a full
run to confirm. It costs nothing at the margins: the lookup confirms the name
before returning, so it can only fail to find a symbol and never return a wrong
one, and on a miss it falls through to the old linear scan — so attaching the
table cannot turn a working image into a broken one.

**A correction to the model, and it matters.** The obvious reading of "~139,000
misses per load" was that the scan thrashed the 16 KiB cache. It did not. XIP
*accesses* for the `ls` window fell 37% (29.8 M → 18.6 M) while misses stayed
flat — the symbol tables fit in cache, and the scan was cache-resident byte-loop
work. So `wall ≈ misses x 345 ns` holds for *compiling*, which is what 0.7
measured it on, but it is not a law of the machine: this bucket was
compute-bound, and reasoning from miss counts alone would have picked the wrong
fix. Check accesses as well as misses before assuming which one a cost is made
of.

### FIXED, round two (2026-08-03) — the fix above was only half a fix

Attaching the hash table accelerated **hits only**, and symbol resolution is
built out of *misses*. `Module.find_symbol` asks each module in turn whether it
owns a name, so an import misses the importer's own table by definition, then
misses every dependency listed before the one that exports it — for toybox, 190
own exports plus all 184 of libm walked before reaching libc, 238 times per
spawn. The safety fallback that round one added fired on exactly that path, so
the common case still paid the full strided walk.

Three changes, all in the same shape as the original bug — work computed and
thrown away:

- **A hash miss is now authoritative.** The table covers exactly this module's
  symbols, so "not in the table" means "not in this module", which is an answer
  rather than a failure. An incomplete table would now fail a load loudly and
  immediately instead of being silently masked.
- **A dead `find_symbol(module, "__start_data")` probe is gone.** Its only
  consumer was a log body that compiles out at the pinned `.yasld` level; the
  call did not, and since the symbol is absent it walked every export table in
  the tree — ~900 strided entries per module load — to discard the answer.
- **`print_header`/`parser.print()` are gated on the comptime log level.** Their
  log bodies vanish, but their loops are driven by `ItemTable.iter()`, which
  calls `size()` — a full strlen-strided walk — to find its end pointer, and the
  trip count is a pointer chase LLVM cannot prove finite.

| window | original | round one | round two | total Δ |
|---|---|---|---|---|
| `ls /tmp` | 48.5 ms | 36.4 ms | **7.5 ms** | **−85%** |
| `tcc -c` empty source | 85.8 ms | 71.8 ms | **48.9 ms** | **−43%** |

XIP accesses for the `ls` window fell from 29.8 M to 2.69 M, −91%. Validated on
hardware with 17 smoke tests including `vi_test` — the deepest resolution path in
the tree (`vi` → `libncurses` → `libc`, `libm`), and the case most exposed by
trusting a miss.

### The loader is now ~2.3-3.2 ms per spawn, and that bounds what is left in it

Per-phase accounting (`dynamic_loader/source/load_profile.zig`, a hook the
kernel fills with a clock) puts the remaining load at **2.287 ms for `/bin/cat`
and 3.155 ms for `/bin/tcc`**, split:

| phase | `/bin/cat` | `/bin/tcc` |
|---|---|---|
| `symbol_relocations` | **1.399 ms (61%)** | **1.293 ms (41%)** |
| `children` | 0.328 | 0.433 |
| `process_data_copy` | 0.204 | 0.553 |
| `parse` | 0.132 | 0.123 |
| `data_relocations` | 0.129 | 0.429 |
| `process_data_alloc` | 0.074 | 0.139 |

**Against ~9,000 spawns the entire remaining loader budget is ~21-29 s of a
1509 s run — about 1.6%.** Symbol relocation is 41-61% of that, so the best case
for any further loader work is well under 1% of the run. The two big wins here
are taken; this is the point to stop and go after the compile bucket instead.

**A trap worth not re-entering.** The first split this produced blamed the page
allocator for ~3 ms of a 7.4 ms `cat` load, which is absurd for a 16 KB
allocation. The cause was `process_page_allocator`'s own `ldralloc` trace: it
fires per allocation and each line busy-waits on the console UART, so it was not
observing the allocator's cost, it *was* the cost. It now sits behind
`perf.trace_allocations`, off even when profiling is on. Two thirds of the
"7.4/10.5 ms" loader figures reported at 0.2 were the profiler measuring itself
— **on this target a trace on a hot path is never free, and per-spawn timings
taken on a profiling build should be treated as upper bounds until confirmed
against a shipping one.**

**Still open in the loader**, ranked, now known to be worth <1% of the run
between them: `ItemTable.size()`
re-derives the exported table's base by walking, when
`header.exported_symbols_offset` already carries it (one of three offsets the
toolchain writes and the loader reads only inside compiled-out logging);
`import_child_modules` creates a `Module` per dependency *edge*, so `vi` loads
libc twice — two GOTs, i.e. two copies of libc's writable globals in one
process, which is a latent correctness bug as much as a cost; and
`process_page_allocator.would_exceed_limit` calls an O(live-allocations) walk on
every allocation, dormant only because every shipped image declares
`heap_size == 0xFFFFFFFF`. The first image with a real heap limit makes tcc
quadratic.

**Caveat on short windows.** The counters are drained on the 1 kHz tick, so a
window of a few milliseconds carries up to a tick of lag at each end and its
*counter* columns are unreliable — the `cd /` row reports an impossible 15.98
accesses per cycle for exactly this reason. Wall times are unaffected. Read
counter figures only from windows of tens of milliseconds and up.

### 0.8 — reads stream, writes do not

`sdbench -s 1024 /root/ci`, i.e. 1 MiB per pass against the SD card the suite
actually uses:

| pass | block size | throughput | per 512-byte sector |
|---|---|---|---|
| sequential read | 512 B | 4.86 MiB/s | 102 us |
| sequential read | 4 KiB | 5.32 MiB/s | 94 us |
| sequential read | 32 KiB | 8.19 MiB/s | 61 us |
| sequential write | 512 B | 0.37 MiB/s | 1335 us |
| sequential write | 4 KiB | 0.41 MiB/s | 1220 us |
| sequential write | 32 KiB | 0.41 MiB/s | 1229 us |
| random read | 512 B | 0.54 MiB/s | 927 us |
| random write | 512 B | 0.36 MiB/s | 1376 us |

**Write throughput does not improve with request size** — 0.37, 0.41, 0.41 MiB/s
across a 64x range of block sizes, at a flat ~1.2 ms per sector. That is the
signature of a per-sector command loop, and it matches the code exactly:
`sdio_write` issues CMD24 plus a busy-wait for every 512 bytes while `sdio_read`
streams up to 128 blocks per CMD18. Reads get 1.7x from batching alone
(102 us → 61 us per sector); writes get nothing because nothing batches them.

What this does **not** settle is how much CMD25 would recover. The ~1.2 ms is
per-command turnaround *plus* the card's own program time, and this benchmark
cannot separate them; if most of it is program time, multi-block pipelines it but
does not remove it. The read side proves the bus can carry 8 MiB/s, so the
ceiling is there — the question is only how much of the gap is reachable. Measure
that before building 2.9, not after.

For the suite specifically, 2.6 already keeps compile outputs under 64 KB in RAM,
so an ordinary compile writes nothing here. The number that matters is what a
tmpfs *spill* costs: at 0.4 MiB/s, spilling a 64 KB file is ~160 ms — about one
whole median compile. That reframes the 2.6 threshold as a throughput decision
rather than a memory one.

## Measured: 28:56 (2026-08-03, loader hash-table fix)

**1736.21 s (28:56), 4466 passed / 75 skipped.** Against the 1904.6 s run
immediately before it, **−168.4 s (−8.8%)** from one change: attaching the symbol
hash table the loader was already parsing. Same pass set; the three extra skips
are the opt-in instruments.

| Bucket | 31:44 run | 28:56 run | Δ |
|---|---|---|---|
| On-target compile | 1493.9 s | 1433.9 s | −60.0 s |
| Harness overhead | 387.7 s | 201.8 s | **−185.9 s, −48%** |
| On-target execute | 23.0 s | 19.4 s | −3.6 s |
| **Wall** | **1904.6 s** | **1736.2 s** | **−168.4 s** |

The split is itself informative: **the fix bought more in the harness bucket than
in the compile bucket**, because the harness spawns processes too and a spawn got
~12 ms cheaper. That is the "this is not a tcc optimisation" point from 0.2,
confirmed at suite scale.

## Measured: 17:23 (2026-08-05, the dry-walk round and the first body profile)

**1043.2 s (17:23), 4466 passed / 83 skipped.** Compile bucket **895.0 → 868.0 s
(−27.0 s, −3.0%)**; wall −26.9 s. The change is one term in the codegen
dry-run gate, and it is broad-based rather than tail-driven: **90.9% of the
4,123 comparable tests got faster**, median −0.34%, p90 −0.0% (i.e. even the
90th percentile is not slower), and the ten biggest movers account for only
34% of the delta. Largest regression anywhere is +34 ms on `strlen-5` (+0.4%).

### The instrument had to be fixed before it could answer this

Three defects, all of which biased exactly the measurement this round needed:

- **`bench_*_time` accumulators were milliseconds, truncated per call.** The
  four `func-*` seams are charged once per *function*, so any source made of
  small functions lost most of its time to rounding — the corpus is mostly such
  sources. Now µs.
- **Per-item `# bench` rows were printed inside the window they measure**
  (~4 lines per function; at 460800 baud a dozen functions cost more console
  time than the compile). Now behind `TCC_BENCH_VERBOSE=1`; the totals always
  print.
- **The syscall snapshot was taken *after* the bench tables printed**, so it
  counted the dump's own serial traffic: `write` read as 61% of syscall time.
  Snapshot moved before the tables.

Honesty check on the fixed instrument: `95_bitfields` measures 5,610 ms under
`-bench` against 5,621 ms in the clean run.

### Where the 895 s compile bucket actually goes

`--profile` over all 4,449 compiles, attributed from the init stamps (which are
not inflated by the dump — the `bench prints` row carries that cost) and the
`PASS_TIME` rows recovered from the per-test serial transcripts:

| item | total | share of bucket |
|---|---|---|
| `cg:dry` — discovery codegen walk, emits no bytes | 132.5 s | 14.8% |
| `cg:emit` — the real codegen walk | 126.8 s | 14.2% |
| `func-body` — frontend / IR build | 117.2 s | 13.1% |
| outside `main()` (spawn, loader, libc init, exit, serial) | ~97 s | 10.8% |
| all 19 regalloc passes combined | ~76 s | 8.5% |
| `predef macros` | 75.5 s | 8.4% |
| `preprocess setup` | 59.0 s | 6.6% |
| `source open` | 58.2 s | 6.5% |
| `output` (link + write) | 49.0 s | 5.5% |

798.4 s (89%) is inside tcc's `main()`. Two corrections to standing beliefs
fall out of this:

- **The per-compile floor is ~75 ms, not 24.9 ms.** ~53 ms of in-main fixed
  work (everything except `parse+codegen`) plus ~22 ms outside main, ~333 s and
  **37% of the bucket**. `test_tcc_init_breakdown`'s 24.9 ms is a warm,
  repeated, `/tmp`-local compile and understates the real floor ~3×. The
  smallest-source cohort in the clean run agrees: n=1083 under 200 B, median
  86.4 ms, p10 74.9 ms.
- **Syscalls are 147.6 s (18.5% of in-main) and `mmap` alone is 82.0 s** —
  34.2 calls per compile. See the next section.

### The fix: the forward-branch term in the dry-run gate

`cg:dry` ran on 8,971 of 12,594 functions and cost **14.8 ms per call against
`cg:emit`'s 10.1 ms** — the walk that writes nothing was *more* expensive than
the one that emits code, because the gate left it running only on the complex
functions. What kept it alive was one term, `!has_forward_branch`
(`ir/codegen.c`), and any `if`/`while`/`for`/`&&` is a forward branch.

That gate was justified in-comment by a host measurement — *"no measurable
compile-time saving (the dry passes emit no bytes)"*. True on the host, wrong
here: the device is XIP-miss-bound, so a walk that emits nothing still pays the
whole instruction-fetch stream. **This is the third time in this plan that a
host measurement has pointed the opposite way from the device** (see 0.4 and
the `try_demote_scratch_conflict` round); the rule from the 20:44 round —
price a lever on the device, not with host instruction counts — now has a
counter-example that cost real time to find.

At -O0 only, that term no longer forces the walk. Every scratch-related
demotion is untouched, so the skip path's invariants (no surprise LR push, an
exactly-sized scratch area) still hold; the cost is that branches keep their
32-bit encoding. `TCC_KEEP_FWD_DRY=1` forces the old behaviour, so one firmware
carries both arms — and `--tcc-env-prefix` was added to `remote_smoke_tui.py`
to drive that remotely (deliberately not persisted into the cached config, so
an A/B arm cannot silently taint a later baseline).

**Priced both ways before shipping:**

| | value |
|---|---|
| object size, 3,988-file corpus @ -O0 | +17,210 B of `.text`, **+0.33%** |
| objects that change at all | 128 of 3,988 |
| `cg:dry` invocations | 53.6% → 48.3% of functions (−10%) |
| compile bucket | **−27.0 s (−3.0%)** |

Note the reach is small — only ~10% fewer dry walks — yet it bought 3.0%. The
functions that newly skip are not the cheap ones the call-count ratio suggests.
Cost is well under the +2.63% accepted for the rehearsal walk, and -O1/-O2
(rootfs, self-host) are unchanged.

### What is left in the dry walk, and the next lever

The remaining 48.3% is blocked by the *scratch* demotions, not the branch term:
FP ops, 64-bit operands, div/mod, block copy, inline asm, indexed memory,
switch tables, calls with stack-passed args, incoming stack params, frames
over 124 bytes. Removing those needs either a conservative analytic scratch
estimate (costs frame bytes) or restructuring so the emit walk backpatches the
prologue once the real scratch depth is known — a compiler project, not a gate
change. Ceiling on it: ~120 s.

**Bigger and better-conditioned: `mmap` at 82.0 s.** The cost model is tight —
**537 µs per call, nearly flat in size** (p10 466, p90 637; 486 µs for
allocations under 8 K against 617 µs for 8-16 K), so the lever is the *count*,
not the bytes. And **0.96 mmaps happen per ≥2 KiB allocation**: 151,008 mmaps
against 158,119 large allocations averaging exactly 8.0 KiB.

The cause is in `libs/libc/malloc.c`: `MSETMAX` is 2048, so every allocation
≥2 KiB bypasses the bump pool for a direct `mmap`. The existing `large_cache`
catches little of it — it is **exact-size match**, 8 slots, 128 KiB, and tcc's
sizes come from doubling `realloc`s that rarely match; only 10.8 of the 34.2
mmaps per compile are freed back at all. Top sites, per compile: `tccpp.c:205`
(56.7 KiB), `tccgen.c:1456` (48.0), `arm-thumb-gen.c:14966` (44.1),
`libtcc.c:708` (34.8, one 8 KiB `BufferedFile` per file opened, in stack
discipline and trivially poolable).

Two fixes, increasing in value and risk:

1. **Best-fit instead of exact-fit in `large_cache`** — reuse a mapping that is
   large enough with bounded waste, recording the true mapped size in the
   header so `munmap` still frees the right run. Contained, but reaches only
   the ~1/3 of mmaps that are ever freed.
2. **Geometric pool growth** — first pool stays 4 KiB so light applets keep
   today's footprint, later pools grow 8/16/32/64 KiB with `MSETMAX` tracking
   the current pool size. Reaches all 34 mmaps per compile, because an 8 KiB
   allocation stops being "large". This is a load-bearing allocator on a
   memory-constrained device and trades footprint for speed — the same class of
   call as the rehearsal walk, so it wants a deliberate decision, not a patch.

### One bug found and not fixed

The compact syscall dump's folded `other=` bucket wraps
(`other=1/4294967322` ≈ 2³²), which aggregated to 4.27 million seconds across
the run. It corrupts only the folded tail entry — the named rows above are
sound — but the underlying counter looks like a 32-bit overflow in the
kernel-side accumulation, which sits inside the in-flight `perf_profile.zig`
work and was left alone.

## Measured: 20:44 (2026-08-04, the #1-test round)

**1244.5 s (20:44), 4466 passed / 79 skipped.** −3.4 s on the step. The change
is one cache in `try_demote_scratch_conflict` (`ir/codegen.c`); it is
byte-identical over 6,957 host compiles (2,320 corpus files × -O0/-O1/-O2, zero
differing objects), so the pass set moving would have been a surprise.

| Bucket | 20:47 | **20:44** | Δ |
|---|---|---|---|
| On-target compile | 1077.8 s | **1074.2 s** | −3.6 s |
| Harness overhead | 73.8 s | 73.7 s | — |
| On-target execute | 17.4 s | 17.4 s | — |
| **Wall** | **1247.9 s** | **1244.5 s** | **−3.4 s, −0.27%** |

**Only the `mibench_rijndael` line is attributable: 17.7 → 17.26 s (−2.5%).**
The −3.6 s compile-bucket delta is at the noise floor for a full run and the
change measured neutral corpus-wide on the host (600-file instruction count
−0.02%), so the rest is not claimed. Top-30 tail 161 → 155.3 s.

### What the #1 test actually is — the 0.4 attribution was wrong

0.4 filed `rijndael`-class tests as "~58% frontend/IR build (func-body) — 5.1
code-footprint territory". Compiling the pre-expanded `.i` instead of the `.c`
says otherwise:

| | host wall | instructions (callgrind) |
|---|---|---|
| `mibench_rijndael.c` | 14.51 ms | 316.9 M |
| same, pre-expanded `.i` | 8.76 ms | 185.4 M |
| **preprocessing** | **5.75 ms (39.6%)** | **131.5 M (41.5%)** |

**41.5% of the compile is the preprocessor**, and **107.1 M of those 131.5 M
(81%) land inside `gen_function`** — tcc expands macros lazily from `next()`
during the body parse, and the `-bench` seam has no preprocessor bucket to
separate them, so macro expansion is charged to func-body. It also owns **2,730
of the 3,054 mmap-class allocations and 11.3 of the 15.4 MB of churn**. The
source is `aestab.h`/`aes.c`'s nested table macros; tinycc already caches
expanded macro arguments (`arg->e`), so this is the file's macro depth, not a
tcc defect.

**It does not transfer.** Same `.c`-vs-`.i` A/B over the whole 2,319-file corpus
in one process: 1163 ms vs 1149 ms — preprocessing is ~1% of the body. Per file
across the rest of the tail: `20040709-*` 1-2%, `strlen-5` 3.5%, `95_bitfields`
5.4%. rijndael is the suite's only macro-heavy test, and roughly 7 s of its
17.3 s is reachable only by making macro expansion itself cheaper, for one test.
**Item closed: the #1 test is not worth further work.**

### The second finding: instruction count is not a uniform device proxy

The change removed **−5.15% of rijndael's instructions** and delivered
**−2.5% of its device wall**; the host wall A/B (−2.9%) predicted it better.
That is consistent with 0.7's own model rather than against it — the device is
miss-bound and misses answer to *footprint*, so a hot tight loop that stays
resident costs far less per instruction than its share of the instruction count
suggests. The added table is not the explanation (3 extra allocations, 43 KiB
per compile, ~1.5 ms of device mmap cost).

**Consequence for the plan: prefer removing cold, spread-out work (5.1) over
micro-optimising hot loops.** Ir count and device wall agree on the former and
diverge on the latter. Where a lever is a hot loop, price it with a host wall
A/B, not with callgrind.

## Measured: 20:47 (2026-08-04, the tail round)

**1247.9 s (20:47), 4466 passed / 79 skipped.** −129.7 s (−9.4%) from the
tail round — the `ra_build_intervals` FUNCPARAMVAL quadratic fix and the
**-O0 two-walk codegen default** (rehearsal skipped; CBZ and forward-branch
narrowing stay -O1+, where the rootfs and self-host actually build) — and
**−61.7% against the 54:20 baseline.** The pass set has not moved; both
changes were host-validated byte-identical in their respective regimes
before flashing (the fix against the old compiler, the default against the
priced knob arm, with -O1/-O2 untouched).

| Bucket | 22:57 | **20:47** | Δ |
|---|---|---|---|
| On-target compile | 1206.8 s | **1077.8 s** | **−129.0 s, −10.7%** |
| Harness overhead | 74.2 s | 73.8 s | — |
| On-target execute | 17.3 s | 17.4 s | — |
| **Wall** | **1377.5 s** | **1247.9 s** | **−129.7 s** |

The report shows both mechanisms doing exactly what the profiles said:
`limits-fnargs` fell from first (22.4 s) to fourteenth (4.6 s), the
many-small-function cluster (`20040709-*`, `strlen-*`, the `-chk` family)
dropped ~20% each, and the new #1 is `mibench_rijndael` (17.7 s) — the
frontend-bound shape neither change touches. The top-30 tail is now ~161 s
(was ~213): further tail work is frontend/footprint work (5.1), i.e. the
same lever as the body. Per-test mean is 246 ms against 397 ms five days
ago.

Run ledger for 2026-08-04, one day: 25:09 → 22:57 → **20:47** (−17.4%),
via the floor (predef decls, libc primitives) and the tail (one quadratic,
one deliberate size-for-speed trade at -O0 priced at +2.63% on throwaway
objects).

## Measured: 22:57 (2026-08-04, the floor round)

**1377.5 s (22:57), 4466 passed / 78 skipped.** −131.9 s (−8.7%) from the
floor round alone — programmatic builtin prototypes (5.5), word-wise libc
`memset`/`memcpy`/`memmove`, chunked `fwrite`/`fread` — and **−57.7% against
the 54:20 baseline.** The pass set has not moved; the three new skips are the
new opt-in instruments (`tcc_init_breakdown`, `tcc_decls_programmatic_ab`,
`fs_syscall_microbench`).

| Bucket | 25:09 | **22:57** | Δ |
|---|---|---|---|
| On-target compile | 1339.5 s | **1206.8 s** | **−132.7 s, −9.9%** |
| Harness overhead | 72.9 s | 74.2 s | +1.3 s |
| On-target execute | 17.4 s | 17.3 s | — |
| Unaccounted (pytest/session) | 79.7 s | ~79 s | — |
| **Wall** | **1509.4 s** | **1377.5 s** | **−131.9 s** |

The whole step landed in the compile bucket, as it should have: the floor
drop predicted ~102 s (−23 ms × 4,449) and the mem/stdio primitives supplied
the rest inside real compile bodies. Per-category averages moved together —
`ir_tests` 514.8 → 464.9 ms, overall mean ~336 → ~271 ms — which is the
signature of a per-compile constant coming out, not of any particular
workload getting faster.

**What did not move is the tail, and it now dominates what is left.** The
top 30 tests still cost ~213 s — `limits-fnargs` 22.4 s, `mibench_rijndael`
18.3 s, `strlen-5` 11.7 s, the three `20040709-*` at ~10.9 s — that is
**17.6% of the compile bucket in 0.7% of the tests**, and none of this
week's work touched it. The compile bucket now splits: floor ~111 s (9%),
top-30 tail ~213 s (18%), everything else ~880 s (73%). The plan's remaining
leverage, in order: the tail (per-test pathology hunting with PASS_TIME, the
0.4 item that was never run), the body (5.1 code footprint, Phases 3-4
allocation traffic), and 6.3's second board for wall-clock regardless.

## Measured: 25:09 (2026-08-04, loader fixes round two)

**1509.38 s (25:09), 4466 passed / 75 skipped.** −226.8 s (−13.1%) from round
two alone; **−53.7% against the 54:20 baseline**, and the pass set has not moved
across any of it.

| Bucket | 31:44 | 28:56 | **25:09** | Δ over the three |
|---|---|---|---|---|
| On-target compile | 1493.9 s | 1433.9 s | **1339.5 s** | −154.4 s |
| Harness overhead | 387.7 s | 201.8 s | **72.9 s** | **−314.8 s, −81%** |
| On-target execute | 23.0 s | 19.4 s | **17.4 s** | −5.6 s |
| Unaccounted (pytest/session) | ~— | ~— | **79.7 s** | — |
| **Wall** | **1904.6 s** | **1736.2 s** | **1509.4 s** | **−395.2 s** |

Harness overhead is down **81%** from two changes that never touched the
harness: per-test cleanup went 40.3 → 11.6 ms because the `rm` it spawns got
cheaper, not because it stopped spawning. `hash 0.00s` is 1.1 still working, and
`loader: n/a` is the report no longer claiming the loader is free when the
firmware cannot measure it.

### What the shape of the run is now

**The compile bucket is 88.7% of the run.** Everything else put together —
harness, execute, pytest overhead — is 11.3%. The plan is now almost entirely a
question about compiling, and it splits three ways:

| within the 1339.5 s compile bucket | cost | share |
|---|---|---|
| per-compile floor (48.9 ms × 4449) | ~218 s | 16% |
| the 30 slowest tests | ~217 s | 16% |
| everything else — actual compilation | ~905 s | 68% |

And the floor itself has inverted. A whole `ls` spawn is now 7.5 ms, so of the
48.9 ms floor only ~7.5 ms is process spawn and module load — **the other ~41 ms
is tcc's own initialisation**, before it reads a line of source. That is ~184 s,
**12% of the entire run**, and it is now the single largest identified item.
Nothing in Phase 5 currently targets it except 5.3 (resident tcc), which is the
most dangerous item in the plan; the cheaper question — *what does tcc do for
41 ms at startup?* — has never been asked, and `TCC_PASS_TIMING=1` will not
answer it because this is before the passes. Ask it before reaching for 5.3.
*(Asked and answered 2026-08-04: it parses the predefines. See
[0.1, second cut](#01-second-cut-2026-08-04--the-41-ms-is-the-predefines-and-95-of-it-is-the-text)
and the new 5.5.)*

### 0.4, finally run (2026-08-04) — the tail split into two mechanisms, one fixed

PASS_TIME plus two new seams (cg:dry/rehearsal/emit around the three codegen
walks; ra2:* inside `tcc_ir_ssa_regalloc`) profiled the top tail tests. The
optimizer passes are irrelevant at -O0 (14 ms of a 22 s compile); the time
splits by test shape:

- **`limits-fnargs` was 86% one quadratic**: `ra_build_intervals` scanned
  forward per FUNCPARAMVAL to find its paired CALL — O(params × distance)
  with an imm64 decode per step, on a test whose whole point is calls with
  thousands of arguments (17.6 s, plus 9,695 mmap-class allocations / 203 MB
  churn). **Fixed** by a backward sweep (nearest following CALL per call-id);
  byte-identical over ~2,540 corpus files; the test now compiles in **4.5 s
  (was 22.4)**, worth ~18 s of the run by itself.
- **Many-small-function tests are ~81% the three codegen walks** (dry,
  rehearsal, emit — ~10 ms per walk per function, miss-bound, roughly equal
  thirds), plus ~15% SSA regalloc. The rehearsal walk exists only to model
  CBZ distances; making it conditional (or cheaper) is the obvious lever,
  but skipping it changes output (CBZ is a size optimization), so that is a
  size-vs-speed decision to take deliberately, not a bug fix — filed as the
  next candidate, not done.
- **`rijndael`-class tests are ~58% frontend/IR build** (func-body) — 5.1
  code-footprint territory. *(Wrong, corrected 2026-08-04: the func-body seam
  counts lazy macro expansion. rijndael is 41.5% preprocessor, 81% of it inside
  `gen_function`, and the corpus is ~1% preprocessor — see
  [the 20:44 round](#what-the-1-test-actually-is--the-04-attribution-was-wrong).)*

**The rehearsal walk is now priced (TCC_NO_REHEARSAL=1 knob, committed).**
Skipping it and the peepholes only it can feed soundly (CBZ,
forward-branch narrowing):

| | with rehearsal | without | delta |
|---|---|---|---|
| 20040709-3 compile | 8.11 s | 6.42 s | **−21%** |
| strlen-5 compile | 8.81 s | 7.03 s | **−20%** |
| 95_bitfields compile | 5.60 s | 4.56 s | −19% |
| rijndael compile (frontend-bound) | 12.42 s | 11.38 s | −8% |
| object size, 2,320-file corpus @ -O0 | 9.39 MB | 9.64 MB | **+2.63%** |

1,107 of 2,320 objects grow; worst case memclr.c +40 KB. Both sampled
runtime tests execute correctly under the knob. Suite-wide the skip is
plausibly worth ~120-180 s of the compile bucket (a full run would price
it). The decision this buys, still open: (a) leave the default alone and
use the knob as an opt-in fast mode for kernel-dev runs — same class as
6.1, never a baseline; (b) make no-rehearsal the **-O0 default** — the
size cost then lands only where -O0 lands (the suite's throwaway
objects; the rootfs builds -O2 and keeps CBZ), at the price of one full
-O0 revalidation run and the suite no longer exercising the CBZ path at
-O0. Neither is taken here; the knob and these numbers are the
deliverable.

One measurement caveat the comparison surfaced: tail tests run ~30% faster
in a filtered `-k` run than inside the full suite (rijndael 12.1 s vs
18.3 s) — full-run context (SD/source cache state, preceding tests) inflates
them, so tail A/Bs must compare like against like.

The tail is unchanged and unimproved by any of this: `limits-fnargs` 22.7 s,
`mibench_rijndael.c` 18.8 s, `strlen-5` 11.7 s, three `20040709-*` at ~11 s.
Per category, `ir_tests` remains the worst average at 514.8 ms over 498 tests.

The ~80 s of unaccounted wall (5.3%) is pytest collection, session setup and
teardown — it has never been instrumented and is now larger than the entire
harness-overhead bucket it sits outside of.

### The rm spawn, revisited

At 28:56 this was the headline: cleanup was **179.5 s, 10.3% of the run**, spent
on *one `rm -f` spawn per test to delete the output file*
(`tcc_suite_test.py:2071-2075`). Round two cut it to **51.6 s** (11.6 ms/test)
without touching it, because what it costs is a spawn and spawns got 5x cheaper.

It is still 3.4% of the run for an unlink, and still worth removing — but it has
dropped well below the compile-side items above, and the options below should be
weighed against that. Recorded in full because the analysis stands:

- **Batch the unlinks.** Accumulate paths and issue one `rm -f a b c …` every N
  tests. Bounded by the tmpfs: `/tmp` is a 128 KB RAM arena (2.6) with an 8 KB
  reserve, and outputs run 10-40 KB, so N is about 3 before bodies start spilling
  to SD — where 0.8 measured writes at ~1.2 ms/sector, which would give the
  saving straight back. Batch on *accumulated bytes*, not test count. Worth
  ~2/3 of the 179 s.
- **Reuse one output path** so the next compile truncates it and nothing is ever
  unlinked. Worth all of it. **Carries a correctness hazard that has to be closed
  first**: a compile that fails while leaving the previous test's binary in place
  would let the execute step run a stale binary and report a false pass — in a
  suite whose entire purpose is catching tcc regressions. Only viable if the
  harness proves freshness independently of the compile's exit status.

This supersedes the sizing question that has blocked **1.2** since the 31:44 run.
1.2 was written as "fewer round trips"; the measurement says round trips are
cheap (setup is 5.0 ms/test) and *spawns* are expensive (40.3 ms/test). Attack
the spawn, not the round trip.

### Loader time reported 0.00 s, and should not have (fixed)

`loader: 0.00s` never meant the loader was free — it meant `perf.trace` is
compiled out unless `CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y`, so there
was no line to parse. Item 0.2 was written about exactly this failure (*"a zero
column is worse than a missing one"*) and the report kept printing it for two
more runs. It now reads `n/a (needs CONFIG_CONFIG_INSTRUMENTATION_PERF_PROFILING=y)`
and names what would populate it.

### 0.1, second cut (2026-08-04) — the 41 ms is the predefines, and 95% of it is the text

The question the 25:09 run left — *what does tcc do for 41 ms before reading a
byte of source?* — now has a measured answer. tcc stamps a µs timestamp at each
startup milestone, recorded before anything is printed so the instrument cannot
bill its own UART time to a phase (the ~12 ms the `-bench` dump costs on the
serial console lands in a fenced row of its own — the same trap the loader
profiler fell into, dodged this time). The stamps ship enabled; recording is a
dozen `gettimeofday` calls per compile and printing is gated on `-bench`.
`tests/smoke/measure_test.py::test_tcc_init_breakdown` reports the median split
over an empty-source compile:

| phase | cost | share of in-main work |
|---|---|---|
| parse the predefined-macro text | **32.7 ms** | **73%** |
| preprocessor setup (allocator pools, predef string build + copy) | 5.1 ms | 11% |
| write the empty output object to RAM-backed /tmp | 4.1 ms | 9% |
| parse+codegen of the source itself | 1.1 ms | 2% |
| everything else (state alloc, args, sections, ELF begin/end, delete) | ~1.8 ms | 4% |
| **in-main total** | **~44.9 ms** | |

The envelope without `-bench` is 48.9 ms, so only **~4 ms of the floor happens
outside `main()`** — spawn, module load, crt0/libc init, exit and the prompt
round trip — which agrees with the loader's own 3.155 ms per-phase figure and
closes the books on the floor: every layer of it is now attributed.

Every compile re-parses the same ~17.4 KB of predefine text (`tccdefs_.h`
stringified at build time, plus the target/OS defs) through the full tokenizer
and `#define` machinery: ~500 macros and ~227 conditional lines, evaluated to
the same result every time. On the x86 host this costs 0.69 ms; on target it is
32.7 ms — the familiar 47× exchange rate.

The A/B that decides what a fix can recover: an env-gated build that skips the
`tccdefs_.h` string (the arm parses only the few dozen `cstr_printf`'d defines)
ran both arms in one session on the same firmware, and the knob was then
removed:

| arm | predef phase | in-main work |
|---|---|---|
| full predefines | 31.7 ms | 43.9 ms |
| without `tccdefs_.h` | 1.7 ms | 10.2 ms |
| **delta** | **30.0 ms** | **33.7 ms** |

**95% of the predef cost is proportional to the text.** This is per-byte and
per-macro work — lexing, interning ~600 identifiers, building macro token
streams — not first-touch code misses that a later phase would pay anyway. So a
fix that stops re-parsing constant text per compile is worth **~34 ms per
compile, ~150 s, 10% of the whole run**, and it drops the per-compile floor
from ~49 ms to ~15 ms. That fix is 5.5. Measurement noise: the five totals
spread 57.26–57.31 ms, so none of these digits is luck.

### 0.1, third cut (2026-08-04) — the second cut was right about the where and wrong about the what; floor now 25.8 ms

The second cut's A/B removed the whole tccdefs string and concluded "95% of
the predef cost is proportional to the text", pointing at the ~250 macro
defines. Building the fix disproved it: a build-time **pre-tokenized macro
table** (generated by the compiler itself, corpus-validated byte-identical
over 637 files) **did not move the floor at all** — macro parsing was ~1.3 ms;
the table loaded in about what the parse cost, and it is reverted. In-parse
probe stamps then split the region and found the ~30 ms in the ~60 **builtin
alias declarations** (`__builtin_memcpy` prototypes with `__RENAME` asm
labels), which the first A/B had removed *together with* the macros.

Two hypotheses died on the way to the mechanism, each to one measurement:

- **"It's machinery warm-up any source re-pays."** No: skipping the decls
  saved the same ~31 ms on an empty source, a real `main()`, and a
  `#include <stdio.h>` compile — user declarations do not re-pay it, and
  yasos's stdio.h (~45 prototypes) parses in ~0.2 ms right after.
- **"It's the yasos libc byte-loop memcpy."** Half. The XIP access counts
  showed ~45,000 executed instructions per declaration against ~2,500 on the
  host for the same C code, and the excess was `memset`/`memcpy`/`memmove`
  running one byte per ~5 instructions. Fixing those word-wise
  (`libs/libc/string.c`) removed ~2M executed instructions per compile —
  **a system-wide win in its own right, every userspace copy goes through
  them** — but the wall barely moved: the byte loops were cache-resident.
  The serial term is ~1,400 XIP **misses** per declaration: the
  macro-expander/declaration-parser alternation walks ~45 KB of code per
  declaration through the 16 KiB XIP cache, so each of the ~60 declarations
  refetches it. stdio.h's declarations are cheap precisely because they are a
  pure parse loop with no expander interleaved — that fits.

**The fix that shipped: build the prototypes programmatically.**
`tccgen_predef_protos` (tccgen.c) constructs the identical ~58 prototypes
through the same calls parsing would make — `sym_push` param chains,
`convert_parameter_type`, `external_sym` with an asm label — a tight loop
with no expander and no parser. The declarations moved to
`include/tccdecls.h`, which stays authoritative for the configurations the
text is conditional on (bcheck renames, `-fleading-underscore`; `-E` never
sees either form) and is the fallback path.
`TCC_NO_PROGRAMMATIC_DECLS=1` forces the text path — that A/B is the
permanent validation seam, byte-identical over **~2,540 corpus files**
(tests2, ir_tests, gcc-torture execute, c-testsuite) at -O2 on the cross.

Measured on hardware (`test_tcc_decls_programmatic_ab`, medians of 5):
programmatic vs text is **−23.4 / −22.6 / −24.3 ms** on empty / main() /
stdio compiles. The ladder now reads:

| window | 2026-08-03 | after loader fixes | **now** |
|---|---|---|---|
| `ls /tmp` | 48.5 ms | 7.5 ms | 7.5 ms |
| `tcc -c` empty source | 85.8 ms | 48.9 ms | **25.8 ms** |
| + `#include <stdio.h>` | +0.2 ms | +0.1 ms | +0.0 ms |
| + trivial `main()` | +1.2 ms | +1.4 ms | +0.3 ms |

Across ~4,449 compiles the floor drop alone is worth **~102 s of the 1509 s
run**; what the faster mem primitives add inside real compile bodies is not
yet measured — both land in the next full-suite run. Inside the remaining
25.8 ms: ~12 ms is the (macro) predef text parse — which now pays the
cold-touch the declarations used to absorb — ~4 ms preprocessor setup, ~4 ms
writing the output object, ~1 ms parse+codegen, ~4 ms outside `main()`. The
floor question is no longer the biggest identified item; the tail and the
body of real compilation are.

Coda, same day: three follow-up probes sized the remainder before stopping.

- **The macro-table wash verdict does not flip.** With the decls gone, the
  12 ms macro stamp suggested the reverted pre-tokenized table might now pay
  for itself; an env-gated skip measured what it could recover at a
  non-relocating **~5 ms**, of which the table's own load would eat ~2.
  ~3 ms net for ~300 revalidated lines — declined.
- **libc fwrite/fread were byte loops, and fputc flushes per '\n'** — so a
  binary object paid a syscall per 0x0A byte on top of one per 256-byte
  BUFSIZ. Chunked both (straight read()/write() of the caller's buffer for
  full chunks). Floor effect ~1 ms; the real beneficiaries are bulk I/O
  paths across the whole userland.
- **The 4.2 ms "write output" phase is not the writes.** It survived the
  chunking unchanged, so it is the output file's create/close path in the
  hybrid tmpfs/VFS — a kernel-side follow-up (Phase 2 territory), not a tcc
  one.

Final floor: **24.9 ms** (`ls` spawn 7.5 ms). Remaining slices are all ≤5 ms
with worse ROI than the tail (~217 s) and the compile body (~905 s).

Second coda — 0.6's kernel microbenchmarks, finally taken (a C benchmark
compiled by the on-device tcc; `test_fs_syscall_microbench`, kept as a
permanent opt-in instrument): a light syscall (gettimeofday) round-trips in
**0.6 µs**, a tmpfs create+close is **45 µs**, and a full
create/write-2KB/close/unlink lifecycle is **410 µs** — so neither syscall
processing nor the tmpfs is slow, and the 4.2 ms "write output" phase is
**tcc-side cold code** (the ELF writer's footprint through the XIP cache,
~12k misses), not the filesystem. One number that looks alarming but is by
design: sequential 2 KB writes into a file growing to 1 MB average 1.9 ms
each — that is the file crossing the 64 KB spill threshold and continuing at
SD write rates; suite outputs (10-40 KB) stay under it. Getting the
benchmark onto the target surfaced its own lesson: the serial console
mangles pasted lines beyond ~100 chars (leading '#' eaten, long lines
truncated), so the instrument ships its source over zmodem like the corpus
does.

### The tail is now 15% of compile in 0.7% of tests

The top 30 tests total ~218 s of the 1433.9 s compile bucket. `limits-fnargs`
alone is 22.7 s, `mibench_rijndael.c` 18.7 s, and four `20040709-*`/`strlen-5`
tests are ~11 s each. Per category: `gcc_execute` 657.5 s / 1799 tests,
`gcc_compile` 459.2 s / 1954, `ir_tests` 261.3 s / 498 (534.9 ms avg — the
slowest category by a wide margin), `tests2` 55.9 s / 198.

## Expected cumulative outcome (default -O0 remote run)

| After | Wall (est.) | Actual |
|---|---|---|
| Baseline | 3260 s (54:20) | 3260 s (54:20) |
| Phase 1 | ~2300-2600 s (38-43 min) | — (1.2 not implemented) |
| Phase 2 (incl. hybrid /tmp) | ~1900-2300 s (32-38 min) | **1904.6 s (31:44)** with 1.1+1.3+1.4+2.2+2.6 |
| + loader hash table (0.2's fix) | — | **1736.2 s (28:56)** |
| + loader round two (authoritative miss, dead walks) | — | **1509.4 s (25:09)** |
| + floor round (5.5 programmatic decls, libc mem/stdio primitives) | — | **1377.5 s (22:57)** |
| + tail round (intervals quadratic fix, -O0 two-walk codegen) | — | **1247.9 s (20:47)** |
| + #1-test round (scratch-demote operand cache) | — | **1244.5 s (20:44)** |
| + the FAT/VFS open-path work (uncommitted at the time of writing; not attributed here) | — | **1070.1 s (17:50)** |
| + dry-walk round (-O0 forward-branch term dropped from the codegen dry-run gate) | — | **1043.2 s (17:23)** |
| Phase 3 | ~1800-2200 s (30-37 min) | — |
| + conditional reloc-cache (now 5.2) | potentially ~1700-2000 s (28-33 min) | — |
| + Phase 5 (5.1/5.3) + 1.7 pipelining | still no honest number, but 0.7 says 5.1 is where to look: ~65% of a compile is miss stalls | — |
| + 6.3 second board | ~1000-1100 s (17-18 min) | — |

Separately from the full-run numbers: **6.1 changes the kernel-dev question** — with tcc unchanged and the compile bucket cached, a single-board iteration run is bounded by harness + execute + copy, roughly ~10 min.

Floor: 0.7 has now split it. On a 167 ms compile at 618 MHz the core term is ~35%
and clock-scalable — and effectively immovable, since the board is already at its
stable maximum — while the fetch term is ~65% and scales with the miss count, so
it answers to tcc's code size and working set (5.1) and to the allocation traffic
Phases 3-4 reduce. Nearly two thirds of the largest bucket in the run turns out to
sit behind levers this plan already lists but had ranked below it.

## Measured: 13:19 at 532 MHz (2026-08-05, the allocator round and the clock inversion)

**799.8 s (13:19), 4466 passed / 86 skipped — the first fully green run of this
series.** Compile bucket **868.0 → 626.3 s (−241.7 s, −27.9%)**, and **−30.0%**
against the 895.0 s this series started from. Three changes plus a clock:

| Round | Compile bucket | Δ | Change |
|---|---|---|---|
| baseline | 895.0 s | — | 17:50 wall |
| dry walk | 868.0 s | −27.0 | forward-branch term in the codegen dry-run gate |
| **allocator** | **717.7 s** | **−150.3** | libc pool cascade, sliding `MSETMAX` |
| **page clear** | **~645 s** | **−72.7** | kernel zeroes PSRAM through the uncached mirror |
| **clock** | **626.3 s** | **−18.7** | clk_sys 618 → 532 MHz |

### The allocator round: −150 s, the largest single lever in the series

Phase 0 flagged it and it under-promised: `MSETMAX` was 2048, so **every**
allocation ≥ 2 KiB became a raw `mmap` syscall — a kernel entry, a page-pool
walk, and an eager zero, for allocations tcc makes hundreds of times per
compile. The fix (`libs/libc/malloc.c`) is a cascade rather than a bigger
constant, because a bigger constant would tax every small process with a large
pool it never uses:

- pool length starts at 4 KiB and doubles per replacement to a 64 KiB ceiling;
- `MSETMAX` tracks it at half the pool, floored at the old 2048 and capped at
  32 KiB — so a small app keeps exactly today's behaviour and only a process
  that keeps exhausting pools climbs;
- widening happens **only when replacing an exhausted pool** (not on first
  allocation), plus once per four large allocations, so the growth is driven by
  demonstrated demand.

−150.3 s, −17.3% of the bucket. It also repaired the libc test suite as a side
effect: `make` in `libs/libc/tests` had been building into the shared device
`build/` with the host compiler, so device objects were being silently
overwritten by x86 ones. Tests now build into `build-host/`; 78 pass.

### The page clear: −73 s for a one-line window change

Every `mmap` page is eagerly zeroed, and that is load-bearing — pages recycle
between processes. On PSRAM the zero was going through the *cached* window, so
each line was fetched for ownership before being overwritten with zeroes, and
the writeback evicted live code. `Memory.zero_pages` (`rp2350/source/memory.zig`)
writes through the no-cache mirror at `+0x04000000` instead: no fetch, no
eviction, and the cache keeps holding the code the compiler is executing.
−72.7 s, −10.1%.

### The clock inversion: 13.9% less core clock did not cost 13.9%

The board ran at 618 MHz because that was its measured stability ceiling. But
flash and PSRAM SCK is `clk_sys / ceil(clk_sys / 133)` — an integer divider — so
618 MHz lands on `/5` and delivers only **123.6 MHz** to the QSPI bus. 532 MHz
lands on `/4` and delivers the full **133.0 MHz**, and it is the *only* clock in
400-600 MHz that does: 534 MHz already falls to `/5` and 106.8 MHz.

The PLL hits 532 exactly (fbdiv 133, VCO 1596 MHz, `/3/1`), and the frequency
band drops the core to **1900 mV**, its designed voltage, from the 2100 mV that
618 MHz needed.

Cutting the core clock 13.9% moved the compile bucket **−18.7 s** — i.e. it did
not cost throughput at all, it gained a little, though the wall figure rose
~16 s and that difference is inside harness setup/cleanup variance (55.0 s this
run), so the honest reading is **break-even to slightly positive on speed,
decisive on stability**. Either way the direction is the finding: a double-digit
core-clock cut that costs nothing is only possible if the CPU is stalled on
instruction fetch, which is exactly what the 65% fetch term predicted. This
plan's closing paragraph called the clock term "effectively immovable, since the
board is already at its stable maximum" — that was true and beside the point.
The lever was pointing the other way.

### 532 MHz also ended the `nestfunc-2` failure

The last red test in the suite went green with the clock change, after a day
that produced one real bug and a long list of things that were not it.

**The real bug (fixed, and independent of the clock):** yasld's shared
indirect-call thunk did `push {r4, lr}` *before* `blx ip`, so callees ran with
SP 8 bytes low and stack-passed arguments 5+ were read from the wrong place.
`nestfunc-2` is the only test in the corpus calling a function pointer with
seven arguments. Fixed by tail-jumping (`bx ip`) — restoring the caller's r9 was
never the stub's job, since `-msingle-pic-base` makes the caller bracket every
indirect call.

**Ruled out by experiment — do not re-chase.** Each of these was tested against
the failure at 618 MHz and none moved it: core voltage at 1900 / 2100 / 2200 mV;
PSRAM cap 109 and 80 MHz; flash cap 88 MHz; both caps at 109 MHz. Only core
clock correlated — 150 MHz green, 532 MHz green, 618 MHz red across many builds.
The mechanism at 618 MHz remains unexplained and is presumed core marginality of
the kind the 618 MHz investigation already documented (silent wrong data rather
than a clean fault, ~80% intermittent). The fault was also layout-sensitive, so
every minimal reproducer evaporated on the next build and only the full suite
was a trustworthy oracle — budget 13 min per iteration and batch instrumentation.

**Harness change this needed:** `COMPILE_TIMEOUT` in `tests/smoke/tcc_suite_test.py`
now scales from `config/target/config.json` (5 s at the 618 MHz reference, so
5.8 s at 532, 20.6 s at 150). The runner forwards no environment to remote
pytest, but that file is rsynced — so a slower clock no longer reports slow
compiles as "Prompt not found" failures.

## Measured: 12:28 (2026-08-06, the tier round — where a mapping's cost actually goes)

**748.87 s (12:28), 4466 passed / 84 skipped. Compile bucket 626.3 → 596.15 s
(−30.2 s, −4.8%); wall −50.9 s (−6.4%).** One change in `libs/libc/malloc.c`,
and a corrected model of what an `mmap` costs on this board.

### The number that reframed the round

The allocator round left `mmap` as the largest single syscall item: **12.2 calls
per compile at 461.8 µs, 25.0 s of kernel time over a run** (34% of syscall
time, ahead of `open` at 19.8 s and `read` at 18.6 s). The standing model said
that 461.8 µs was a flat per-call cost, so the lever was the count.

It is not flat. It is the kernel's page clear, and it scales with the bytes —
and with the *tier* those bytes are in. Measured from the run's own `poolclear`
rows: **SRAM 777 MB/s, PSRAM 55 MB/s, a factor of 14.** (55 MB/s is not a bug to
fix: 133 MHz QSPI × 4 data lines is 66.5 MB/s of theoretical bandwidth, so the
clear is already at 83% of what the bus can do.) Every later measurement lands
on that line: 423 µs for the ~20 KiB average mapping, 1102 µs for a 64 KiB one.

### Why the compiler's heap was in the slow tier

The kernel prints fast-tier occupancy before every exec. Across the whole run
the median, p90 and max were all **1000 of 1200 pages — 250 KiB of the 300 KiB
`process_ram`, held by the shell** (`proc pid=1 ... heap_b=264 KiB`). It climbs
248 → 296 → 360 → 488 → 744 → 1000 pages within the first ~40 s of a run and
stays there, so effectively every compile in the corpus ran with its 213 KiB
heap in PSRAM.

**A pool retires when its *bump pointer* runs out, not when it empties.** Blocks
inside it go on being freed long afterwards and coalesce, so a long-lived
process ends up owning a chain of pools that are mostly free and completely
unreachable — while every replacement pool is twice the size of the last.

Two changes, both in `malloc.c`:

- **`old_pool_take`**: before mapping a new pool, walk the retired ones and
  promote the first whose free list can serve the request. Reached only on the
  path whose alternative is an `mmap`, so the walk is free by comparison, and it
  is what stops the ratchet.
- **`trim_slack` at vfork**: a process about to hand the machine to a child
  gives back its parked mappings and spare pool. The parent is suspended until
  the child execs, so anything it is sitting on is pure hold — and what the
  child gets depends on what is free at that moment.
- Both reuse paths are inert inside the vfork window: `__malloc_vfork_restore`
  unmaps whatever `pool` points at if it is not the one the parent saved, so a
  child that promoted a parent pool would have it unmapped out from under live
  blocks.

Result (profiled run, like-for-like against the profiled baseline): fast-tier
occupancy **1000 → 760 pages**, shell heap **264 → 204 KiB**, and every
memory-touching path got faster at once — `mmap` −21.5% (461.8 → 368.3 µs/call),
`open` −5%, `read` −4%, loader −9% — which is the signature of work moving to a
faster tier, not of less work being done.

### Rejected by measurement: telling malloc the appetite up front

`malloc_pool_hint(64 KiB)` from tcc's `main`, with the discovered ceiling
lowered to 16 KiB for processes that do not ask. It does exactly what it says —
**mappings per compile 12.2 → 4.3** — and it is **5.5% slower over the corpus
(compile 596 → 661 s, wall 749 → 803 s)**. Two reasons, both general: a mapping
costs its bytes, so twelve small ones and four large ones are the same work; and
a 64 KiB pool spreads a small compile's working set over sixteen times the
address range, which a 16 KiB XIP cache notices. **The ladder is not overhead to
be optimised away — it is what keeps a small compile's heap small.** Reverted;
the reasoning is left in the header comment of `malloc.c` so it is not rebuilt.

A trap for the next round: this was measured on a 198-test slice of small
sources first, where the hint looked like a **win** (mmap 5.16 → 4.72 ms and
loader 4.88 → 3.59 ms per compile). The full corpus said the opposite. Slices
price the syscalls; only a full run prices the working set.

### What is left, in order

1. **The fast tier is still 190 KiB occupied by the shell** (`heap_b` 204 KiB),
   and lowering the pool ceiling did not move it — so it is live/pinned data and
   fragmentation, not the cascade. A compile needs ~315 KiB (213 heap + 100
   loader) and `process_ram` is 300 KiB, so nothing yet lets a whole compile run
   in SRAM. Worth knowing what those 204 KiB actually are.
2. **`temp_ram` is 128 KiB of SRAM** for the /tmp arena against `process_ram`'s
   300 KiB (`hal/source/raspberry/rp2350/linker_script.ld`). Check `MemTmpUsed`
   in /proc/meminfo under load: if the arena runs at a fraction of that, moving
   64 KiB to `process_ram` would put a whole compile in the fast tier — worth far
   more than any further allocator tuning.
3. **Pre-zeroed page pool.** The clear is on the allocation path and cannot be
   made faster (bus-bound). It could be moved off it: keep freed pages on a dirty
   list and zero them when nothing is runnable.
4. tcc's own allocation churn is comparatively small: ~25 allocations ≥2 KiB per
   compile (sym pools 6.1/cc, the 8 KiB `BufferedFile` read buffer 4.3/cc,
   `section_realloc` 3.3/cc, the TinyAlloc arenas 2.0/cc and the largest by bytes
   at 246 MiB over a run). The heaviest source (`mibench_rijndael`) makes 203k
   allocations, three quarters of them 16-byte token-string buffers from
   `tok_str_ensure_heap`.

### Instruments added

- `tests/smoke/measure_test.py::test_malloc_microbench` (opt-in, `-m measure`):
  prices malloc/free pairs at 16 B / 256 B, a doubling realloc chain, an 8 KiB
  and a 48 KiB allocation, and raw `mmap`/`munmap` pairs at 8 KiB and 64 KiB. The
  last two are the ones that would have shown the byte-proportional cost model
  without a corpus run.
- A host replay rig (scratch, not in tree): an `LD_PRELOAD` recorder captures a
  compile's allocation trace from the x86 cross, and a driver replays it through
  the **real** `libs/libc/malloc.c` with `mmap` counted rather than costed, so
  allocator policy can be A/B'd in seconds. It predicted the mapping counts on
  device to within one call — but not the working-set effect, which is what
  decided the hint experiment.

## Measured: 10:36 (2026-08-06, the transaction round — 5.4, taken in full)

**636.60 s (10:36), 4467 passed / 87 skipped. Compile bucket 557.6 → 489.3 s
(−68.3 s, −12.2%); wall −77.3 s (−10.8%).** This is item 5.4 — the price of a
miss rather than the count of them — in two independent parts, measured
separately:

| step | wall | compile bucket |
|---|---|---|
| before | 713.88 s | 557.6 s |
| CS-deselect time from the read row of the datasheet | 687.94 s | 533.6 s |
| + continuous read (opcode off the wire) | **636.60 s** | **489.3 s** |

The second step cost a detour: it broke SD bring-up, and closing that out was
the more valuable half of the round. It was not a flash problem at all — see
[the SDIO race](#the-detour-that-was-worth-more-than-the-round) below.

### The instrument 5.4 was waiting for

5.4 was parked on a question, not a doubt: *what fraction of misses actually pay
the opcode?* `overclock_flash_probe_read_cost` answers it from RAM at boot in
four rows — a real cache-line fill through the cached window, an uncached read
512 B from the last one, an uncached read next to the last one, and the
measuring loop against a cache hit, which the other three are net of. Cycles per
access at 532 MHz, all rows from the same boot:

| arm | line fill | uncached, 512 B apart | uncached, consecutive | loop |
|---|---|---|---|---|
| as shipped | 181 | 149 | 38 | 3 |
| deselect 12 ns | 161 | 129 | 38 | 3 |
| + continuous read | **129** | **97** | 38 | 3 |

Net of the loop that is **178 → 126 cycles per miss, −29%**, and the two
mechanisms are cleanly separable: 32 cycles for the opcode, 20 for the chip
select.

**The caveat 5.4 was written around is real and does not bite.** The consecutive
row never moves — 38 cycles with the opcode and 38 without — so the QMI *is*
holding the transaction open across sequential accesses exactly as the item
feared, and continuous-read has nothing to offer there. It offers 32 cycles on
every *discontinuous* miss, and those are the ones a 2.17 MiB instruction
footprint through a 16 KiB cache produces. The average miss was paying the
opcode; that is why the item's estimate survived its own objection.

### Shipped: the chip-select time was set from the wrong datasheet row

`computeQmiConfig` sized `MIN_DESELECT` from "tSHSL=50ns". In the W25Q128JV AC
table (Rev H) there are two: **tSHSL1, /CS deselect for READ, is 10 ns**;
tSHSL2's 50 ns covers erase, program and write-status. The XIP window only ever
reads — the one path that writes the part is status-register programming in
`qmi_reinitialize_flash`, which runs in direct mode at CLKDIV=30 where the gaps
are two orders of magnitude larger than either figure.

At 532 MHz that was 27 system clocks of enforced CS-high on every miss that
cannot continue a burst, against the 7 that 12 ns asks for (20% over spec,
before the half-SCK the QMI inserts on its own). Measured: **−20 cycles per
miss, −24.0 s of compile over the corpus.** It is now
`CONFIG_FLASH_XIP_DESELECT_NS`, per board, because the number names a part.

The sweep that came with it says the part is nowhere near its limit: all 32
values of the field, **including zero**, read an 8 KiB region back at its
reference CRC, and the cost is linear in the field (122 cycles at 0 against 129
at 7). The datasheet, not the sweep, is what set the value — a CRC that passes
at boot is not evidence about voltage and temperature.

### Shipped: continuous read takes the opcode off the wire

Sending the mode byte as 0xA0 instead of 0xFF leaves the part expecting an
address rather than an opcode, so `PREFIX_LEN` can go to zero and 8 SCK periods
leave every transaction. `overclock_flash_enable_continuous_read` does it from
RAM with interrupts off, CRC-verifies the result against the configuration it
replaced, and backs out through the part's own defined exit (one transaction
whose mode byte is not 0xAx) if it does not match. **−32 cycles per miss,
−44.3 s of compile.**

It runs from `hal.external_memory.enable_fast_reads()`, called by `main` once
storage is up rather than from `ExternalMemory.init`, for one hard reason: after
it, nothing may drive CS0 in QMI direct mode, because the part reads an opcode
as address bits. Everything that does — `qmi_reinitialize_flash`,
`overclock_flash_enable_qe` — runs during bring-up, and the runtime flash driver
never writes.

### The detour that was worth more than the round

Turning continuous read on broke SD card bring-up. Chasing that down found a
race that had been in the SDIO driver all along, and that the tree had already
spent two rounds mis-attributing (the "any codegen change to `mmc_sdio.zig`
breaks the card" note in the optimize-forwarding work).

**The instrument came first**, because every attribution so far had been decided
by a single boot, and single boots had already contradicted each other.
`tests/smoke/sd_bringup_soak_test.py` (opt-in, `-m measure`) resets the target N
times and classifies each boot — 20 boots in 44 s. It has a power-cycled variant
too, which is what separated "this boot's code" from "state the last boot left
behind". One trap, recorded because it cost a run: classify on `wait_for_data`
and never `wait_for_prompt_except_logs`, which strips every `[ERR]` line and
will happily score a run of `DataCrc` boots as clean.

With rates instead of anecdotes the picture was immediate:

| firmware | warm reset | power cycle |
|---|---|---|
| continuous read off | 20/20 clean | — |
| continuous read on | **3/20 clean** | **10/10 clean** |

Clean when the card is power-cycled and failing when it is not says the card was
inheriting something — but SD throughput under continuous read measured
perfectly (`sd_write_perf_test`, every floor met), so it was not the bus.

**Two bugs, one behind the other.** The first was an amplifier: bring-up sent
CMD55 + ACMD6 SET_BUS_WIDTH and discarded both results, then switched the host
to 4 bits unconditionally (`set_wide_bus` is a no-op — the PIO program has no
1-bit mode). A card that never got the ACMD6 stays in 1-bit, and the host reads
DAT3..DAT0 as a nibble: three lines idle high, one carrying data, every nibble
`0xE`. **That is what `0xeeeeeeee` + `DataCrc` was** — not a busy card, a bus
the two ends disagreed about. Checking and retrying the pair removed that
failure class entirely.

The second was the cause. With the amplifier gone the failures moved to ACMD41,
and the driver's own timeout diagnostic named it once it was asked to print more
than it had been: the PIO state machine was parked in `wait_cmd` with **the TX
FIFO holding 2 words right after the pushes and 1 by the time the response timed
out.** The state machine had eaten a word without sending anything.

`sdio_cmd` opens with `mov OSR, ~NULL` precisely because autopull refills an
empty OSR by itself, from the TX FIFO, at any time. But that instruction only
runs once the state machine is *enabled* — and `rp2350_sdio_command` pushes both
command words a few instructions later. Lose that race and autopull takes word0;
the program then idles forever on `mov_status txfifo < 2` with one word left,
the command is never transmitted, and it reads exactly like a card that will not
answer. Executing the same `mov` from the CPU, between the jmp and the enable,
closes the window.

**That is the whole "codegen changes break the card" mystery.** Every one of
those changes shifted the CPU's timing relative to the state machine. Continuous
read shifted it hard — the CPU reaches the pushes sooner — which is why a flash
configuration change presented as an SD fault. Result: **3/20 → 20/20 clean with
continuous read on**, and the lever it was blocking is now shipped.

The soak is the regression test. Anything that changes SDIO codegen, or the
speed of the code around it, should run it.

### What this leaves for the fetch side

The miss is now 126 cycles net (237 ns at 532 MHz), down from 178. What is left
is the address, mode byte and dummy clocks, the data phase, and 9 cycles of
enforced deselect — all irreducible at this SCK. There is no third item of that
size in the QMI configuration — what is left on this axis is
**5.1, the miss count**, which is tcc's code footprint, and the PSRAM side of
the same question (`CONFIG_PSRAM_CE_MIN_DESELECT_NS` is 50 ns for a part whose
tCPH is 18 ns, and the compiler's heap lives there — but PSRAM has a documented
history of intermittent corruption on this board, so that one is not a
one-line change).

## Measured: the footprint round (2026-08-06)

**tcc `.text` 2,541,400 → 1,977,152 B (−564,248 B, −22.2%).** QEMU: 13,364
passed, 216 skipped, 0 failed. Hardware: boots and runs; **wall time not
captured, so this round has no entry in the wall-time table yet.**

This is item 5.1's first delivery. 0.7 left compile time as `misses × cost`;
5.4 took the cost, this takes the count. Note what the item had assumed — that
reaching 1 MB needed the legacy/SSA optimizer merge — and what actually
happened: none of this touched a pass. It was three mechanical defects and one
miscompile.

| step | `.text` | Δ |
|---|---|---|
| before | 2,541,400 | — |
| R9 GOT-base spill hoist | 2,377,184 | −160 KiB |
| zero-addend `adds rX,#0` | 2,347,752 | −28.7 KiB |
| de-inline tccir/tccir_operand headers | 2,069,896 | −272 KiB |
| de-inline `thop_emit` | **1,977,152** | −90.6 KiB |

The starting figure is worth recording on its own: the plan had been quoting
**2.17 MiB** for tcc's `.text` since 2026-06-26, and it had grown to 2.42 MiB
without anything noticing. The top-priority lever in the plan had been moving
backwards for six weeks. A size gate belongs in CI.

### R9 was saved once per call for a value that never changes

R9 holds the PIC GOT base and is caller-saved, so every call reloads it. The
value is function-invariant, so the store only has to happen once — but it was
emitted at each call site next to the reload, producing runs of literally

    ldr.w r9, [sp] ; str.w r9, [sp]

45,329 stores, 42,356 of them dead. What hid it for so long is that R9 was
slotted *after* whichever of R0-R3 happened to be live at that call, so its
frame offset moved from call to call and the redundancy never looked like one
— eight distinct offsets across the binary. Giving R9 slot 0 makes the offset
constant per function, which is what lets the store hoist into the prologue.
No frame-layout change: the area was already sized to hold it.

### The zero addend

The GOT-relative and PC-relative symbol paths both add the addend after
loading the address, and a symbol referenced with no addend is the common
case: 9,733 sites added zero to an address they had just computed. Safe to
skip because nothing relocates that instruction (the addend rides in the
literal-pool entry, `relocation = -1`) and `imm` is identical in the dry-run
and real passes, so the two still agree on sizes.

### The header helpers were never inlined, only duplicated

53 accessors in `tccir.h`/`tccir_operand.h` were `static inline`. **tcc does
not inline them** — every call site in the linked image is a `bl` — so each
including TU got its own out-of-line copy: 179 of `tcc_ir_op_get_src1`, 165 of
`tcc_ir_op_get_src2`, 157 of `irop_get_vreg`. The image carried 6,125 text
symbols for 3,703 distinct names. Because the calls were already out-of-line,
one shared definition costs nothing at the call sites.

`thop_emit` is the same story with a trap attached: it is
`__attribute__((always_inline))`, gcc honours it, **tcc ignores it and emits an
out-of-line copy per TU anyway** — 28 copies at 3,648 B. The direction matters
and cost a build to learn: teaching tcc's inliner to *respect* `always_inline`
would have expanded it at all 182 call sites and made `.text` far bigger. The
fix is to drop the attribute, not to honour it.

### The miscompile the de-inlining exposed

De-inlining failed **1,081 tests — 511 at -O1, 570 at -O2, zero at -O0**. The
split localised it immediately: at -O0 the flat pipeline is one pass, so the
broken code had to be in the optimizer. Two experiments settled the rest.
Re-running without the R9 change failed identically (1,083), so it was
pre-existing rather than an interaction; and the *host* cross compiler, built
from the same de-inlined sources by gcc, compiled the failing test fine, so
the fault was in the ARM code the cross tcc generates, not in the sources.

The device diagnostic was a tripwire, not a crash —
`immediate substituted into barrel-shift-annotated src2` — and disassembling
`tcc_ir_set_src2` showed why it fired:

    strb.w  r1, [sp, #4]     <- inlined u8 return written as one byte
    ldr     r0, [sp, #4]     <- read back as four
    cmp     r0, #0

**Inline expansion of a function with a sub-word return type left the upper
bytes of its return slot uninitialised.** The slot is carved at a minimum of
four bytes, but `return` stored at the return type's own width while the
consumer read a word, so `if (u8_returning_fn(...))` tested three bytes of
whatever the frame was holding. With a clean zero frame it is invisible, which
is why it survived this long. Nothing about it is specific to barrel shifts:
`tcc_ir_barrel_shift_at` returns `uint8_t`, and de-inlining merely made it a
plain extern function that tcc chose to inline. It reproduces in thirteen
lines and hits any inlined callee returning `_Bool`, `char` or `short`.

Fixed by storing the whole word — the value is already zero/sign extended in
its register, so that is correct for a narrow read as well as the word read
the consumer performs. `ir_tests/440` guards it and was checked the only way
that means anything: **it fails at -O1 and -O2 with the fix reverted**. It has
to dirty the frame first, or the bug is invisible.

### The seam is exhausted; what is left and why it was not taken

Every remaining mechanical pattern was measured on the shrunk binary and
rejected for a stated reason, so they do not get re-proposed:

| lever | size | why not |
|---|---|---|
| forward-branch narrowing | 17 KiB | the scaffolding exists with a correct relaxation proof, but **nothing records branches and nothing reads the decision** — `BRANCH_ENC_16BIT` is referenced only inside the analysis. Flipping `optimization_enabled` does nothing (`branch_count == 0`). Needs building. |
| `push{rX}..pop{rX}` | 19 KiB | deliberate — the in-code comment says a smart scratch picks different registers in dry-run vs real pass, desyncing sizes and corrupting literal-pool offsets. Written *after* that bug. |
| duplicate literals | 11 KiB | illusory. Dedup already exists (`th_literal_pool_find_or_allocate`, keyed sym+imm); the plain allocator is deliberate for entries that must stay distinct. The count was post-link identical *words* with distinct pre-link relocations. |
| duplicate symbols | 7.6 KiB | real, but spread over 9 headers at ×2-×9. The rounds above paid because one symbol had 179 copies. |
| R9 reload dead before return | 4 KiB | unsafe as framed: R9 must be valid at every call, and backend libcalls (`__aeabi_*`, memmove) need it while not appearing as IR calls, so an IR-level scan would miss them. |

Also tried and rejected: **`-Os` for the device tcc** via the existing
`NATIVE_TCC_OPT_OVERRIDE`. Measured **−2.6 KiB** — `pipeline_os` differs from
`-O2` only by skipping fusion, which costs almost nothing in size.

Structurally there is no jackpot left either: the top 50 functions are 22% of
`.text` and the distribution is flat. The next real lever is codegen quality —
tcc still emits ~1.48× gcc -O2 for the same TUs — which is a project, not a
peephole.

### Owed

- **A timed hardware run.** The size is measured and the firmware works, but
  until a run is captured the compile-bucket effect of −551 KiB against a
  16 KiB XIP cache is a prediction, not a number.
- **A `.text` size gate**, so the 2.17 → 2.42 MiB drift cannot repeat.
- `build_rootfs.sh` **exits 0 when make fails.** A build whose compile errored
  reported success and left the objects wiped; the next step measured a stale
  binary. This is how a round gets attributed to the wrong change.

## Measured: device-side concurrency is closed (2026-08-12, the XIP-contention round)

**Running two compiles at once on the board is 0.61x — slower than running them
one after the other — and the cause is the shared XIP cache, not the scheduler
and not memory.** This closes test-level concurrency as a lever, including the
memory-aware co-scheduling it would have needed. It does *not* close 6.3 (a
second board), which adds a second cache along with the second core.

Measured with `tests/smoke/prun_scaling_test.py` on the phase-7 SMP kernel,
where both cores genuinely schedule (`test_secondary_core_actually_runs_processes`
passes on the same build). Four workloads, each run lockstep (one console
command per job, what the suite does today) then batched through `prun` at -j1
and -j2, with -j1 arms bracketing the -j2 arm so drift is visible (it was
±0.1%):

| workload | lockstep | -j1 | -j2 | what it runs |
|---|---|---|---|---|
| compile (40 fn) | 511 ms/job | 0.96x | **0.61x** | tcc, from XIP flash |
| compile-small (10 fn) | 167 ms/job | 0.92x | **0.59x** | tcc, from XIP flash |
| compute | 200 ms/job | 1.01x | **1.64x** | ALU loop, from RAM |
| spawn | 3.4 ms/job | 1.81x | 1.90x | trivial exec |

### What each arm rules out

**The cores are fine.** The compute arm — a tight integer loop in a
RAM-resident binary, no allocation, no I/O — gets **1.64x** from a second core.
Whatever is wrong with concurrent compiles is not the scheduler, the IPIs or
phase 7.

**It is not the memory pool.** compile-small quarters the heap and changes the
penalty not at all (0.59x vs 0.61x). A PSRAM-spill explanation predicts the
opposite, and this is the arm that kills it. Corroborating from the corpus side:
against a ~8.4 MB pool (388 KiB SRAM + 8 MB PSRAM), only 2 of 4525 tests exceed
4 MiB and the median is 0.50 MiB, so a memory-aware co-scheduler would have been
gating ten tests out of four and a half thousand.

**It is not a fixed per-job cost** — not a lock, not a syscall, not prun. The
two compiles issue the *same* file operations; a fixed cost would add a similar
absolute penalty to both. It scaled with compute time instead: **+325 ms on a
511 ms job, +118 ms on a 167 ms job** (2.75x the penalty for 3.06x the work).

### What it is, from the cache's own counters

`/proc/xip` carries the RP2350 XIP cache's hit and access counters, and the arms
bracket them:

| workload | arm | hit rate | accesses | misses vs -j1 | wall vs -j1 |
|---|---|---|---|---|---|
| compile | -j1 | 95.5% | 179M | — | — |
| compile | -j2 | 94.6% | 215M | **+44%** | +50% |
| compile-small | -j1 | 95.6% | 62M | — | — |
| compile-small | -j2 | 94.2% | 72M | **+53%** | +55% |
| compute | -j1 | 97.8% | 5.1M | — | — |
| compute | -j2 | 97.7% | 5.1M | **0%** | −38% |

**The extra misses account for the lost time almost exactly.** Two tcc instances
take 20% more accesses at a lower hit rate — they evict each other from a 16 KiB
cache neither fits in — and on a workload that is 83% instruction fetch (see the
predef-phase finding) every extra miss is a QMI fetch. The compute arm is what
makes this causal rather than correlated: 35x less XIP traffic for a job of
similar length, counters that do not move when a second copy runs beside it, and
it is the one arm that speeds up.

### Why nothing schedulable fixes it

The cache is 16 KiB of fixed hardware. PSRAM sits behind the same QMI, so
relocating tcc's text does not escape the contention, and tcc's 1.4 MiB of
`.text` does not fit the 388 KiB of fast SRAM in any case. There is no ordering
of tests, and no footprint budget, that makes two concurrent compiles cheaper
than two sequential ones.

Two things this *does* leave standing:

- **Concurrency pays for RAM-resident work** (1.64x). The suite's execute step
  runs compiled binaries out of /tmp, but it is `total_execute_ms` = 9.2 s of a
  677 s run, so there is nothing to win there.
- **6.4's core1 duties are not refuted by this**, but they are now suspect for
  the same reason: background page re-zeroing drives PSRAM traffic through the
  QMI the compile is already saturating, so it should be measured against this
  instrument before being built.

### Also measured

- **Batching alone loses on compiles.** `prun -j1` removes the console round
  trip and still costs 0.96x: its own spawn is **23 ms/job** where the round
  trip it removes is worth ~9 ms. Batching only pays where the job is short
  (spawn: 1.81x). Item 1.2 should be read against that.
- **The round trip is 0.0297 ms/character echoed**, so the suite's 316
  characters per test are 9.4 ms/test — **42 s over a 4453-test run**, and they
  land in no bucket of `tcc_timing_report.json` (`compile_testcase` starts its
  timer after `write_command` returns).
- **`ticks` in /proc/cpus is elapsed time, not utilisation.** Every online core
  takes its own SysTick whatever it is running, so both cores report near
  identical tick deltas in every arm and the figure tracks the arm's wall time.
  It cannot answer "did the work spread"; the compute arm is what answers that.

### The pipelining variant: sound mechanism, wrong scale (2026-08-12)

The follow-up idea — never overlap two compiles, but let core Y run the previous
test and remove its artifacts while core X compiles — was measured with two more
arms. **The mechanism works and is free. The suite has almost nothing for it to
hide.**

| workload | lockstep | -j1 | -j2 | XIP acc -j1 → -j2 | hit rate |
|---|---|---|---|---|---|
| mixed (compile + 200 ms compute) | 0.71 s | 0.97x | **1.32x** | 46.5M → 46.5M | 95.6% → 95.6% |
| mixed-io (compile + execute-and-clean) | 0.52 s | 0.95x | 0.95x | 48.0M → 46.6M | 95.7% → 95.5% |

**`mixed` is the proof of the mechanism:** 200 ms of RAM-resident work hidden
behind a 511 ms compile for ~29 ms of cost — 85% hidden — with the cache
counters *flat*. Overlapping non-compile work with a compile disturbs nothing,
which is the opposite of what two compiles do to each other.

**`mixed-io` is the proof of the scale problem.** It shows no gain, and not
because it disturbs the compile (the hit rate holds): the io job and the `rm`
together are ~10 ms against a 511 ms compile. There is nothing there to hide.

That matches the run-51 buckets: **execute is 2.1 ms/test and cleanup 5.8 ms/test
against a 111 ms compile.** So the ceiling is 35 s (execute+cleanup) or 53 s
(+setup) of a 677 s run — 5.2% to 7.8% — while prun-shaped orchestration charges
**9-23 ms/job**, i.e. 40-102 s over 4453 tests. The work to be hidden is the same
order as the machinery that would hide it.

Two further discounts before anyone sizes this again:

- **Most of the 8 ms is console round trip, not device CPU.** `rm -f <artifact>`
  is a command the harness waits on. A round trip cannot be hidden on core 1 —
  only by batching, which is exactly what charges the 9-23 ms/job. The
  genuinely CPU-bound part is nearer 3-5 ms/test, i.e. 15-22 s, i.e. 2-3%.
- **The orchestration cost is not a constant to be designed around, it is the
  same disturbance mechanism**: prun costs +23 ms/job on compiles, +12 ms on
  mixed, +9 ms on mixed-io, and *saves* ~2 ms on compute and spawn. It tracks how
  XIP-heavy the jobs are, because prun's own code and the kernel's both run from
  flash between jobs.

**What would have to be true for this to pay:** orchestration below ~8 ms/test.
That is now measurable in isolation (the -j1 arm of any workload is exactly this
number), and it is the thing to attack before building a pipeline — not the
pipeline itself. A leaner runner with no per-job log files and fewer syscalls
between jobs is the shape that could get there; prun was not written for it.

### Three more paths checked (2026-08-12): one refuted, one real, one bug

**Refuted: the command echo is not the host's fault.** `_wait_for_echo` reads one
byte per `serial.read(1)`, and 232 characters costing 7.30 ms against 0.77 ms of
wire time at 3 Mbaud looks exactly like host syscall overhead. It is not.
Draining the same echo bytewise and in `in_waiting`-sized chunks, on the rig's
own port, measures **24.06 vs 25.01 us per character** — identical. The cost is
the device echoing, roughly 21 us of per-character processing on top of 3.3 us of
wire time. **Do not rewrite the echo reader for bulk reads; it buys nothing.**
The only host-side lever left on this path is sending fewer characters.

**Real, and it is the SMP build: the echo path got 48% slower per character.**
Same tree, same test, only `CONFIG_CONFIG_PROCESS_SMP` differs:

| build | per character echoed | over a 4453-test run |
|---|---|---|
| `CONFIG_PROCESS_SMP=n` (`cpus=1 online=1 smp=0`) | **20.1 us** | 28 s |
| `CONFIG_PROCESS_SMP=y` (both cores scheduling) | **29.7 us** | 42 s |

That is **+9.6 us per character, ~14 s per run**, on a path that is a `read` and
a `write` syscall per character — i.e. it reads as a syscall-entry tax from the
locking, not as anything specific to the console. It corroborates independently:
the pre-phase-7 measurement of this same slope was 19.4 us/char, which is the
SMP=n number, not the SMP=y one. The compile bucket does *not* show a matching
regression, and that is consistent rather than contradictory — a compile is 77%
XIP miss stalls (8.06M misses x 204 ns of a 2.14 s arm), so a syscall tax hides
inside it while the echo path, which is nothing but syscalls, exposes it.

**Bug: `CONFIG_PROCESS_SMP=n` panics deterministically on this tree.**

    $ prun -j 1 -o /tmp/pscal /tmp/pscal/compile.txt
    PRUN 0 0
    PRUN 1 0
    PRUN 2 0
    [ERR][kernel_heap] kernel heap exhausted: _sbrk(+1412) heap_end=0x20012fe4 limit=0x20013000 used=53728B
    [ERR][kernel] KERNEL PANIC: kernel heap exhausted (_sbrk over __heap_limit__)
    [ERR][kernel]     0: 0x10006070
    [ERR][kernel]     1: 0x1003311E
    [ERR][kernel]     2: 0x1000134C

Four sequential tcc compiles through prun, on the single-core build: three
complete, the fourth panics the kernel out of its 76 KiB heap. Identical panic on
both attempts, same `used=53728B`, always on the fourth job. The *same four
compiles run as four shell commands* (the lockstep arm) complete fine on the same
boot, so it is the prun path, not the compiles. Note the direction: SMP=n should
have *more* heap than SMP=y (no per-CPU statics), and the SMP=y build runs this
same batch repeatedly without trouble — so this looks like per-spawn kernel-heap
growth that only the single-core build is close enough to the limit to hit.
**Not bisected against pre-SMP history**, so whether the SMP work caused it or
merely uncovered it is open.

**Also settled, for free, from the archived runs:** the wall-time growth from
~591 s (2026-08-10) to 677 s (run 51) is **not** a performance regression. It
tracks the failure count, because a failing test costs a rerun and a target reset
and neither lands in a timing bucket:

| run | failures | unattributed | compile bucket |
|---|---|---|---|
| 3-24 (08-10) | 0 | 27-43 s | ~484 s |
| 26 (08-11) | 21 | 55.5 s | 514.9 s |
| 51 (08-12) | 18 | 84.4 s | 495.9 s |

18 failures x ~3 s of rerun-and-reset is almost exactly run 51's excess. The
compile bucket itself moves 478-520 s across these runs, which is the drift band
to beat before any change of a few seconds is called a win.

#### Where the echo cost actually is (2026-08-12, corrected)

The console **write** path is fine: **3.81 us/byte marginal against a 3.33 us
line rate at 3 Mbaud — 90% of wire speed, 231 KiB/s of a possible 293.** There
is nothing to win there, and an attempt to win it confirmed as much: guarding the
`drain_rx()` call in `Uart.write`'s TX spin loop behind the cheap
`uart_is_readable()` check measured 3.72 vs 3.81 us/byte, i.e. noise. Reverted.

**A correction, because the first version of this measurement was wrong and the
wrong number is the kind that gets acted on.** An earlier probe reported the
write path at 12.45 us/byte — 3.7x off line rate — and that was an artifact of
the probe, not a property of the device: it timed `serial.read(4096)` against a
4022-byte file, and pyserial returns when it has the requested count *or* the
timeout expires, so every arm dutifully reported the 50 ms timeout and looked
identical to three figures whatever the firmware did. **Read to an expected byte
count, never to a buffer size, or the timeout is what gets measured.**

So the ~24 us per echoed character decomposes as roughly **3.8 us of UART write
and ~20 us of syscall-and-shell**, and that is a per-*character* cost because the
shell reads in raw mode with VMIN=1 — one `read` syscall per byte, one `write`
syscall to echo it. Two syscalls per character, at roughly 5-10 us each.

That makes the remaining levers, in order of size:

1. **Bulk read-and-echo in the shell** (~37 s/run, the big one). When the host
   sends a 232-character command it arrives as one burst and sits in the 4 KiB
   RX ring; the line editor could take it in one `read` and echo it in one
   `write` instead of 232 of each. This is a toysh line-editor change, not a
   kernel one, and it approaches wire time (3.3 us/char) from 29.7.
2. **Send fewer characters** (~20 s/run). 316 characters per test today, of
   which ~130 are the compile line's identical status-check boilerplate. Folding
   that into a device-side helper or shell function is harness-only work, but
   watch the trade: a helper that costs an extra spawn (~2-3 ms) loses to the
   ~3 ms of characters it saves.
3. **The SMP syscall tax** (~14 s/run), which is the same two syscalls per
   character seen from the other side — see the SMP=n/=y table above.

#### Shipped: bulk read-and-echo in the shell (2026-08-12)

**29.7 -> 19.7 us per echoed character, a 33% cut, worth ~14 s of a 677 s run.**
Lever 1 from the list above, in `apps/toybox/toys/pending/sh.c`
(`tty_take_pending`, called from `read_line_tty`'s literal-insert fast path).

The editor cost two syscalls per byte of every command line: `scan_key` reads
exactly one byte -- deliberately, so it cannot overshoot an escape sequence --
and the echo writes exactly one byte. A pasted or harness-sent line arrives as
one burst and then sits in the terminal buffer being drained a byte at a time.

The change keeps scan_key's one-byte discipline for anything that could begin a
sequence and fast-paths only what cannot: when appending at the end of the line
with nothing half-parsed in `scratch`, it takes a run of plain printable bytes
in one `read` and echoes them in one `write`. raw mode sets VMIN=1, so the read
blocks exactly as the `scan_key` call it replaces would have. **No `poll` is
involved**, which matters: the interactive path never calls poll today, so
whether this target implements it is not something to find out here.

**Why 33% and not 6x.** The remaining cost is not syscalls. The host cannot send
faster than the wire, so at 3 Mbaud a byte lands every 3.3 us while the shell
drains the buffer faster than that -- each read comes back with only ~6 bytes,
not the 15 it asks for. The floor for this shape is ~2x wire time (6.7 us/char);
19.7 is what partial batching against a live wire actually yields.

**The bug this nearly shipped with.** `scratch` was a per-call local, zeroed at
the top of `read_line_tty`. Reading ahead means a burst carrying `cmd1\ncmd2\n`
leaves the bytes after the newline in `scratch` when the function returns for
`cmd1` -- and a per-call buffer drops them, losing the next command outright,
silently, and only when input happened to arrive in one piece. `scratch` is now
static and deliberately not cleared per line.

**Validated on hardware:** two commands in one write both run; three commands in
one write including a 200-character line all run intact; byte-at-a-time typing
unaffected; backspace still edits (output line is exactly `EDITED`); shell
responsive afterwards. Plus shell/cd/ls/pipe/vfork (15 passed, and the one
failure -- `test_pipe_carries_more_than_it_can_hold` -- reproduces identically on
run 51 before any of this, same `crash detected` signature) and a 7-test tcc
slice. The compile arms are unmoved (519 ms/job, XIP 95.6% hit), as expected:
this touches the console, not the compiler.
