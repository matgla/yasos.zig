# Current kernel performance recheck — 2026-10-09

The current TCC-built kernel takes **1.414× LLVM's CPU0 instructions** for a
warm `/bin/true` launch: **153,627 versus 108,626**. Counting both CPUs gives
154,597 versus 109,146 (1.416×). Template replay remains the largest hotspot;
its three loops execute 32,408 instructions per launch. The former large
`memset` gap is substantially smaller.

This recheck builds the current kernel sources and a private host cross from
**all current TinyCC working-tree sources**, including uncommitted changes.
It holds the existing native compiler and userspace identical in both kernels.
It does not benchmark a newly rebuilt native compiler or physical board time.

## Inputs and evidence

- YasOS HEAD: `a8cb6be6`.
- TinyCC HEAD: `dc20e3c5`, plus the source snapshot recorded in the manifest.
- Both kernel variants: `ReleaseFast`; TCC compilation uses `-O2`.
- Zig: `0.17.0-dev.1640+2597da025`.
- Board configuration: current `qemu_mps3_an524`.
- Rootfs SHA256: `101eece5327d4ee5f4ba840d5c9a5bafefa73ebc64b0cc352e18cf5b5b25528f`.
- TCC kernel SHA256: `4f52704bd4d8c9ff4fce59ecd13026a0004f3f131696c5be7c59cede2d4fb33b`.
- LLVM kernel SHA256: `a758450653f5a46edc2e2b69885792e6a3970b06cdc2e72f7e6070d3a406bf82`.

Artifacts: `.cache/kernel_recheck_20261009/`. `manifest.json` records compiler
source hashes, cross and kernel binary hashes, and configuration identity.
No TinyCC source changed between taking the snapshot and finishing the capture.
The installed cross, native compiler and rootfs were preserved.

`workloads.log` and `results-20261009-110657.json` contain the full workload
comparison. `warm-results.json`, `summary.json`, `*-warm-*.json` and
`insns/*-warm-*.csv` contain the repeated warm profiles and stack census.
`compile-matrix.json` records the eight object hashes from each kernel.

## Method and variation

The plugin-enabled QEMU runs dual Cortex-M33 with DSP/FPU enabled and
`-icount shift=0,align=off,sleep=off`. The gated TCG plugin counts executed
instructions between UART markers. These are instruction counts, not hardware
cycles or measured board latency.

Warm launches use one identical C driver, built once with the installed cross.
Each boot performs five unmeasured `vfork`/`execve`/`waitpid` launches, then 50
measured launches. Six fresh boots per variant alternate execution order:
**300 measured launches per kernel**, all successful. The marker and driver
loop overhead remain in the reported counts; shell startup is outside the gate.

CPU0 executes the launch path. CPU1 idle/reaper activity is reported separately.
Scheduling and lock overlap cause some variation even with `-icount`; the
existing comparison script's claim that every count is exact/deterministic is
stronger than these observations support.

| Warm measurement, per launch | TCC | LLVM | Ratio |
| --- | ---: | ---: | ---: |
| Mean CPU0 instructions | 153,626.93 | 108,626.17 | 1.414× |
| CPU0 minimum–maximum across six boots | 152,972–154,165 | 108,192–108,876 | — |
| Mean CPU1 instructions | 969.96 | 519.40 | — |
| Mean both-CPU instructions | 154,596.89 | 109,145.57 | 1.416× |
| Explicit scalar SP loads + stores | 10,012.17 | 3,689.02 | 2.714× |
| Explicit SP transfer bytes, including push/pop and multiple transfers | 85,184.02 | 45,350.64 | 1.878× |

SP accesses through derived pointers are outside this census. Neither metric
is a peak stack-size or spill-count measurement.

The earlier 268,924-versus-114,874 and later 187,683-versus-115,181 captures
used frozen inputs and a different rootfs/driver. They document progress but
are not controlled comparisons against this new capture.

## Current workload comparison

One fresh boot per workload and variant. Counts below include the marker
script's overhead; they are not the warm-launch metric above.

| Workload | TCC instructions | LLVM instructions | Ratio |
| --- | ---: | ---: | ---: |
| Harness `noop` | 74,116 | 72,455 | 1.023× |
| `/bin/true`, single launch | 321,314 | 246,961 | 1.301× |
| TCC hello compile, `-O0` | 6,448,288 | 5,200,422 | 1.240× |
| TCC hello compile, `-O2` | 6,891,674 | 5,672,000 | 1.215× |
| TCC larger compute-source compile, `-O2` | 60,891,961 | 59,582,760 | 1.022× |
| TCC compile and execute hello | 7,586,392 | 6,049,358 | 1.254× |
| Sort corpus | 21,537,063 | 19,404,707 | 1.110× |
| Grep corpus | 7,498,492 | 7,191,108 | 1.043× |
| Zig render to C, then TCC compile | 559,298,899 | 544,374,540 | 1.027× |

All 14 supported workloads return zero on both kernels, with matching checked
outputs. `ps` checks status only because its output varies. The additional
`zig version` probe returns the same known unsupported-command failure, 255,
on both kernels; it is not counted as a successful workload.

A separate matrix compiles hello, scopes, inline and bitops at `-O0` and `-O2`:
**16 successful compilations; all eight objects byte-identical across kernels**.

Against the stored October 9 baseline, the same-rootfs single-launch count
falls from 421,904 to 321,314 on TCC, while LLVM varies from 253,114 to 246,961.
The small `-O2` compile falls from 7,926,323 to 6,891,674 on TCC. The freshly
rebuilt LLVM ELF is byte-identical to the stored LLVM ELF. These single-run
count deltas include scheduling variation; the repeated warm capture is the
better measure of the remaining launch gap.

## Remaining hotspots and next work

These are both-CPU instructions executed **inside** each function, excluding
callees, averaged over six boots. Function boundaries differ between compilers
because of inlining, so LLVM's `Loader.load_module` cannot be compared directly
with TCC's `Loader.load_from_template` as an equivalent phase.

| TCC function/family | Instructions per launch | Share of total |
| --- | ---: | ---: |
| `Loader.load_from_template` | 34,252 | 22.2% |
| `memcpy` | 14,177 | 9.2% |
| `memset` | 9,826 | 6.4% |
| Sentinel scanning | 9,115 | 5.9% |
| Pool reserve/mark-used/mark-free combined | 16,073 | 10.4% |
| `Parser.create` | 6,672 | 4.3% |
| Byte equality helper | 6,090 | 3.9% |
| Wyhash init + hash | 6,597 | 4.3% |
| Kernel heap lock/unlock helpers combined | 5,659 | 3.7% |

1. **Remove the remaining replay reloads at the compiler level.** The data
   loop executes 14,330 instructions, including **2,528 SP loads**. Disassembly
   reloads the entry-array pointer, bases pointer and array bound on every
   iteration. The GOT loop executes 9,708 instructions with **no direct SP
   accesses**: the desirable register behavior already exists in a nearby
   loop. Compare the emitted C, promoted IR and allocation decisions for these
   two loops. Determine whether each stack home is retained by alias reasoning
   or introduced by register allocation before changing either pass. Prioritize
   loop-live values over values needed only at exits, without extending unsafe
   assumptions across calls or stores. Validate on this unchanged loader and
   rerun the six-boot profile and object matrix.

2. **Simplify the remaining thunk replay path.** Its loop executes 8,370
   instructions and 1,488 direct SP loads. It still computes a runtime remainder
   with `udiv`/multiply/subtract, reloads layout fields, and retains data/GOT
   destination checks inside the thunk suffix. First test general compiler
   constant propagation and range reasoning. Any loader specialization should
   explicitly preserve image alignment and sorted-entry contracts; a plain
   dereference marker is insufficient evidence for hoisting across `memcpy`.
   The three loop ranges together execute 32,408 instructions; the remaining
   1,844 instructions in the containing function include setup between loops.

3. **Reduce parser/equality and hashing overhead.** `Parser.create` costs
   6,672 versus LLVM's 2,595 instructions and has 993 direct scalar SP accesses
   versus 201. The equality helper contributes another 6,090 instructions and
   585 SP accesses. Inspect caller arguments, inliner decisions and redundant
   copies before adding caches. Sentinel scans are already down to **267**
   calls versus LLVM's 264 `strlen` calls, so the old duplicated-scan diagnosis
   is largely addressed. Wyhash still runs 35.37 times per launch; use exact
   fixed-size/seed specialization and wide-multiply improvements where proven,
   retaining identical hash values. A missing standalone multiply helper does
   not mean its arithmetic disappeared.

4. **Profile allocator and lock paths with the board model before larger
   changes.** Pool bookkeeping contributes 10.4% and heap lock/unlock helpers
   another 3.7% in exclusive instruction attribution. Inspect repeated bitmap
   work, lock lowering and stack traffic, while preserving atomic ordering and
   allocator ownership. Replay alone accounts for 4,485 scalar SP accesses,
   nearly 45% of all such accesses, so it remains the clearer first target.

5. **Deprioritize bulk memory helpers as the main compiler gap.** `memcpy`
   costs 14,177 versus LLVM's 14,100 instructions. `memset` costs 9,826 versus
   7,819; the old 22,507-versus-10,113 result is stale after the 64-byte-loop
   change. Copy/clear volume may still matter on PSRAM, but another bulk-loop
   rewrite offers less instruction-count upside than the remaining replay and
   parser work. Do not remove zeroing without proving initialization contracts.

To measure native compiler improvements themselves, rebuild that compiler and
run a separate board-model comparison; these results isolate current kernel
code generation with a fixed userspace compiler.

## Reproduction

The private cross build and kernel build logs are saved beside the artifacts.
With those kernels present:

```bash
.qemu_smoke_venv/bin/python scripts/kernel_compare.py --skip-build \
  --work .cache/kernel_recheck_20261009 --jobs 4 \
  --baseline .cache/kernel_compare/baseline.json
.qemu_smoke_venv/bin/python .cache/kernel_recheck_20261009/warm.py
.qemu_smoke_venv/bin/python .cache/kernel_recheck_20261009/compile-matrix.py
.qemu_smoke_venv/bin/python .cache/kernel_recheck_20261009/summarize.py
```

The summarizer's replay address ranges belong to the recorded TCC ELF and must
be updated after rebuilding changed code. No optimization was implemented as
part of this measurement recheck.
