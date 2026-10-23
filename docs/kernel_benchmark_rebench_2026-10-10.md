# Kernel benchmark rebench — 2026-10-10

The current TCC-built kernel needs **1.420× the Zig/LLVM kernel's flash
instructions** for a warm `/bin/true` launch (106,589 vs 75,062 per launch);
counting the identical userspace along with it gives 114,377 vs 82,850 =
**1.381×**. The launch path did **not** move since the 2026-10-09 run
(1.418× kernel-only there), while every compile- and VFS-heavy workload ratio
closed materially: `ps` 1.508× → 1.409×, `sha256sum` 1.388× → 1.204×,
`tcc-hello-c-O2` 1.216× → 1.129×, `tcc-hello-run` 1.256× → 1.156×.

One workload could not be measured: the TCC kernel hardfaults inside its own
`Wyhash.hash` when the device zig runs (see [Regression](#regression)).

## Inputs and evidence

- YasOS HEAD: `fe1c5995` (branch `zig-on-yasos`).
- TinyCC HEAD: `cd8aa1d3` (branch `local-combined-2026-10-06`), **plus the
  working-tree edits present when the cross was pinned**: `source/frontend/gen/store/{struct_copy,vstore}.c`,
  `source/frontend/gen/gen_priv.h`, `source/ir/{codegen,regalloc_entry}.c`,
  the new `source/opt/{flat,ssa}/loop/decrement_carry.c` and the opt Makefiles/`unity.mk`.
- Cross pinned before the builds: `libs/tinycc/bin/armv8m-tcc` copied to
  `.cache/kernel_rebench_20261010/pinned/armv8m-tcc`, SHA256 `bd40731acd7d…`,
  banner `tcc version 0.9.28rc 2026-10-09 local-combined-2026-10-06@cd8aa1d3* (ARM YasOS)`.
  Both kernels were built with that pinned copy through
  `zig build -Doptimize=ReleaseFast -Dkernel_cc={tcc,llvm} -Dkernel_tcc=<pinned>`.
- Rootfs SHA256 `ce19f5b7dcbddf7157b462b573288642970ca1c47b223270fb7702c8f4d492e3`
  (unchanged between the two kernel builds and the capture); board config
  `config/target/config.json` SHA256 `e4cad4dc1f41…` unchanged across the run.
- TCC kernel SHA256 `b520f8b15721…` (26,598 KiB); LLVM kernel SHA256
  `11d32203978c…` (29,142 KiB).
- Artifacts: `.cache/kernel_rebench_20261010/` — `run.log` (inputs, builds,
  battery), `results-20261010-095813.json`, `baseline.json`, `warm-results.json`,
  `insns/*.csv`, `attrib.py` (the flash-only attribution used below).

Since the 2026-10-09 run (`docs/kernel_benchmark_current_2026-10-09.md`,
YasOS `a8cb6be6`, TinyCC `63c2b0cf`) the tree gained `92bc8cc8`/`fe1c5995`
(kernel `eqlBytes` elimination) and TinyCC `858bd8c3` (unrolled boolean exits),
`bd7026b0` (inlined u64 divider), `c498e7a8` (escape-copy-to-call, STORE-form
switch folding, 64-bit load combine) and `cd8aa1d3` (ssa:reroll), plus the
uncommitted SRA/decrement-carry work.

## Method

Same rig as `docs/kernel_benchmark_current_2026-10-09.md`:
`scripts/kernel_compare.py` with the gated icount TCG plugin,
`-icount shift=0,align=off,sleep=off`, dual Cortex-M33 with FPU/DSP on the
board-shaped an524; one fresh QEMU boot per workload and variant. The warm
launch capture reuses the **same prebuilt driver binary** as the 2026-10-09
run (`.cache/kernel_benchmark_20261009_current/launch-payload/launch`) so the
per-launch figures are comparable, 6 fresh boots per variant, 50 measured
`vfork`/`execve("/bin/true")`/`waitpid` launches each. These are guest
instruction counts, not board cycles.

The flash-only attribution keeps PCs inside the kernel ELF's `0x1000_0000`
`LOAD` segments and drops the romfs segment and everything at `0x6600_0000` and
above; the userspace remainder is 7,788 instructions per launch on **both**
kernels, which confirms the A/B measured kernel code only.

## Battery (guest instructions, one boot each)

| Workload | TCC | LLVM | TCC / LLVM | 2026-10-09 ratio | TCC Δ | LLVM Δ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `tcc-bench-c-O2` | 61,225,998 | 60,499,747 | 1.012× | 1.021× | −1.4% | −0.5% |
| `core-sort` | 19,421,779 | 17,924,161 | 1.084× | 1.095× | −3.0% | −1.9% |
| `core-grep` | 7,258,666 | 7,031,418 | 1.032× | 1.036× | −0.8% | −0.4% |
| `tcc-hello-run` | 6,013,251 | 5,201,868 | 1.156× | 1.256× | −14.2% | −6.8% |
| `tcc-hello-c-O2` | 5,843,645 | 5,175,921 | 1.129× | 1.216× | −12.7% | −6.0% |
| `tcc-hello-c-O0` | 5,395,331 | 4,724,240 | 1.142× | 1.232× | −13.5% | −6.7% |
| `ls-bin` | 3,186,993 | 2,445,970 | 1.303× | 1.322× | −15.7% | −14.4% |
| `ps` | 1,052,759 | 747,111 | 1.409× | 1.508× | −11.4% | −5.2% |
| `sha256sum` | 309,872 | 257,277 | 1.204× | 1.388× | −16.9% | −4.3% |
| `uname` | 278,109 | 220,488 | 1.261× | 1.269× | −15.6% | −15.1% |
| `true-launch` | 246,157 | 199,099 | 1.236× | 1.259× | −17.1% | −15.6% |
| `echo` | 117,227 | 115,910 | 1.011× | 1.012× | −1.0% | −0.9% |
| `noop` | 72,708 | 72,051 | 1.009× | 1.009× | −0.1% | −0.1% |
| `zig-version` | 890,559 | 562,539 | 1.583× | — | — | — |
| `zig-obj-tcc` | **rc=255** | 505,705,240 | not measured | 1.028× | — | — |

`zig-version` exits 255 on both kernels (the image has no `zig version`
subcommand) and is reported for completeness. All other rows exit 0 on both
sides and produce byte-identical output. The mixed battery total is 1.056×
against 1.081× on 2026-10-09.

## Warm launch

| Warm measurement, per launch | TCC | LLVM | TCC / LLVM |
| --- | ---: | ---: | ---: |
| Mean CPU0 instructions | 113,444.07 | 82,330.81 | 1.378× |
| Mean CPU1 instructions | 933.19 | 519.33 | — |
| Mean both-CPU instructions | 114,377.25 | 82,850.15 | 1.381× |
| **Kernel flash only** | **106,589.47** | **75,062.37** | **1.420×** |
| Userspace remainder (identical) | 7,787.79 | 7,787.78 | 1.000× |

Against 2026-10-09 (133,620 / 99,163 mixed = 1.347×; 204,459 / 144,230 =
1.418× flash-only): both kernels got much faster (−14.4% TCC, −16.4% LLVM per
launch) and the **launch-path ratio is flat**. The mixed figure rose only because
the userspace part of the window shrank, which exposes the kernel ratio more.

## Regression

`zig-obj-tcc` (device `zig build-obj -ofmt=c` then tcc) fails only on the TCC
kernel: the guest dies with `CFSR=0x01000000` (invalid instruction) at
`stacked_pc=0x100073f4`, inside `hash_wyhash_Wyhash.hash__5836` (function base
`0x100072f8`). The bytes there are `e9d7 2300` — `LDRD r2, r3, [r7]` — and the
base is built a few instructions earlier as `ldr r0,[sp,#44]; adds r7, r0, r4`,
i.e. wyhash's tail load at an arbitrary offset. LDRD/STRD requires a word-aligned
base; on ARMv8-M an unaligned one is unallocated and traps.

The same function in the 2026-10-09 TCC kernel holds 10 LDRD/STRD encodings, the
current build 31, so the 64-bit load combine (`c498e7a8`) and the in-flight
struct-copy/SRA lowering widened 64-bit accesses that wyhash performs unaligned.
This is the only workload the current cross fails; the other 13 run correctly on
both kernels. Until it is fixed, the `zig-obj-tcc` row — previously the single
largest absolute gap, 526.5 M vs 511.9 M — cannot be compared.
