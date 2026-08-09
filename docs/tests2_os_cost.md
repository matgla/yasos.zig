# What the OS costs the `tests2` suite — measured

**Status (2026-08-10):** measured on the RP2350 rig at 532 MHz, `--profile`
build, 199 `tests2` cases at `-O0` (134 sources; the multi-flag ones expand).
Follows `docs/syscall_path_profile.md` (the syscall *path* is ~1% of syscall
time) and `docs/fs_open_write_profile.md` (where the handlers spend it). This
one answers the corpus-level question: **how much of a whole suite run is the
OS?**

**Headline: 13.3%.** Of 23.52 s on-target, the kernel accounts for 3.12 s —
2.38 s of syscalls while compiling, 0.71 s loading images, 0.02 s of syscalls
in the compiled binaries. The other 20.4 s is tcc's own user-mode compute.
An OS change cannot win more than that 13%, and three calls own 89% of it.

Reproduced three times; the on-target total varies by 0.6% between runs and the
syscall total by less than that. The terminal block reports **18.4%** rather
than 13.3% because it also counts the 1.20 s that `-bench` spends printing its
own report — real time, but paid only while profiling. Subtract it when judging
the workload; see below.

## How to reproduce

```bash
scripts/remote_smoke_tui.py --run-cached --profile --smoke-tcc-opt-levels -O0 \
    --pytest-args "tests/smoke/tcc_suite_test.py -k 'not ir_tests and not gcc_'"
```

~35 s of rig time. The numbers land in the run directory
(`workdir/logs/<N>/tcc_timing_report.json`, mirrored to
`.cache/remote_smoke_logs/<target>/<N>/`) under `summary.kernel`, and are
printed as the "OS cost of the whole suite" block of the terminal report.

The instrument is two measurements that are disjoint by construction:

* tcc's own `-bench` dump covers the compile up to the moment it prints, and
  **resets** the counters (`perf_dump_print_compact(1)`, `libs/libc/sys/perf.c`);
* the kernel prints a per-process line at *every* exit
  (`source/kernel/interrupts/syscall_handlers.zig`), which covers the rest of
  tcc's life and every other process — the compiled test binaries included,
  which tcc structurally cannot see. `tests/smoke/kernel_profile.py` parses
  those out of each test's serial transcript, bracketed by the markers the
  suite already echoes around the compile and run phases.

## Where the 23.52 s goes

| | time | share |
|---|---|---|
| tcc user-mode compute | 20.40 s | 86.7% |
| syscalls while compiling | 2.38 s | 10.1% |
| image loading (execve) | 0.71 s | 3.0% |
| syscalls in the compiled binaries | 0.02 s | 0.1% |

Per test that is 117 ms on target, of which ~16 ms is the OS. The median case
spends **17.3%** of its life in the kernel; the range runs from 4.9%
(`55_lshift_type.c`, a 568 ms compile) to 21.7% (`18_include.c`, which opens
the most files). The share falls as the compile gets longer, which is the
shape to expect: the OS cost per compile is nearly fixed (~260 syscalls) while
the compute is not.

## The 2.38 s of compile syscalls

51 750 calls over 199 compiles — 260 per compile, 46 us each.

| syscall | calls | total | per call | share |
|---|---|---|---|---|
| `read` | 7 479 | 0.90 s | 121 us | 37.9% |
| `mmap` | 2 425 | 0.71 s | 292 us | 29.7% |
| `open` | 2 146 | 0.52 s | 242 us | 21.8% |
| `close` | 2 140 | 0.07 s | 33 us | 3.0% |
| `gettimeofday` | 27 916 | 0.07 s | 2.3 us | 2.7% |
| `write` | 2 170 | 0.05 s | 25 us | 2.2% |
| `lseek` | 7 029 | 0.03 s | 4.3 us | 1.3% |
| `unlink` | 138 | 0.03 s | 184 us | 1.1% |

**`read` + `mmap` + `open` are 89.4%.** Everything else together is 11%, and
the syscall *path* — the dispatch this all rides on — is 0.2%.

Two of those rows are the instrument, not the workload: the 27 916
`gettimeofday` calls are `-bench`'s own timing (140 per compile), and 12 002 of
the writes counted after tcc's dump are `-bench` printing its report to the
console (1.19 s, 5.1% of the run, paid only while profiling). A non-profiling
run is that much cheaper and has that much less write traffic.

## What each of the three is

**`read`, 121 us for 830 bytes.** 5.92 MiB across the suite at 6.55 MiB/s,
37.6 reads per compile. This is source and headers off FAT.

**`mmap`, 292 us.** 12 per compile. Per `yasos-mmap-cost-is-bytes-not-calls`,
an mmap costs the bytes it clears, not a constant: the kernel cleared 4.97 MiB
over 16 527 pages in the part of the window it can still see after tcc's dump.

**`open`, 242 us.** 10.8 per compile. `docs/fs_open_write_profile.md` measured a
warm romfs hit at 120-125 us and a failed probe at 276-280 us; 242 us average
says the suite's opens are dominated by the miss-and-search shape, which is
what `docs/vfs_lookup_cache_plan.md` exists to remove.

## What this rules out

**Dispatch.** 0.2% of syscall time, already measured and already fixed as far
as it goes (`docs/syscall_path_profile.md`).

**The compiled binaries.** 127 runs cost 20 ms of syscalls between them — 0.1%
of the suite. Their loading (63 ms, 0.5 ms each) is three times their syscall
time, and still rounding error. Nothing in the execute window is worth
optimising for this workload.

**Anything that needs more than 13.3%.** That is the whole ceiling. A 20%
reduction in OS cost is 0.6 s off a 23.4 s run — 2.7%. The suite's wall clock
is a tcc problem first (`libs/tinycc/docs/plans/`), an OS problem second.

## A defect this found

The compact dump's `other` bucket is a subtraction (`total_cycles -
shown_cycles`), so it inherits any 32-bit `DWT_CYCCNT` wrap that slipped the
kernel's own `implausible_cycles` filter. Two such samples across 199 tests
made the aggregated table report `other` as **8589.93 s** — larger than the run
that produced it. The report now prints such rows as `implausible (wrapped
cycle counter)` rather than as seconds; the underlying sample is still
recorded on the device, and `perf_profile.record`'s filter is where a real fix
belongs.
