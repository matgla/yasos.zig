# TCC -O2 versus Zig/LLVM kernel benchmark — 2026-10-09

The current TCC kernel uses **1.347× as many guest instructions** as the Zig/LLVM kernel for a warm `/bin/true` launch: **133,620 versus 99,163 instructions per launch**, counting both CPUs. Both kernels were rebuilt from the current working tree in `ReleaseFast`; the TCC pipeline compiles the generated C at `-O2`.

The rootfs, native TCC, Zig and other userspace binaries are identical between kernels. This measures the effect of the kernel compiler on these workloads. Counts are executed guest instructions under QEMU, not hardware cycles or board latency.

## Workload comparison

One fresh QEMU boot per workload and variant. Counts include the marker script overhead and both CPUs. The `noop` row measures the harness; the rows below are raw totals, without subtracting it.

| Workload | TCC instructions | LLVM instructions | TCC / LLVM |
| --- | ---: | ---: | ---: |
| `noop` | 72,767 | 72,104 | 1.009× |
| `uname` | 329,662 | 259,834 | 1.269× |
| `ls-bin` | 3,778,510 | 2,858,573 | 1.322× |
| `echo` | 118,353 | 116,920 | 1.012× |
| `true-launch` | 297,021 | 236,007 | 1.259× |
| `sha256sum` | 373,114 | 268,719 | 1.388× |
| `ps` | 1,188,053 | 787,750 | 1.508× |
| `core-sort` | 20,022,609 | 18,278,382 | 1.095× |
| `core-grep` | 7,316,867 | 7,062,277 | 1.036× |
| `tcc-hello-c-O0` | 6,236,336 | 5,063,589 | 1.232× |
| `tcc-hello-c-O2` | 6,694,509 | 5,504,974 | 1.216× |
| `tcc-bench-c-O2` | 62,103,810 | 60,816,872 | 1.021× |
| `tcc-hello-run` | 7,010,246 | 5,580,354 | 1.256× |
| `zig-obj-tcc` | 526,503,424 | 511,946,875 | 1.028× |

All 14 supported workloads return zero on both kernels with matching checked outputs. `ps` checks status only because its output varies. The separate `zig version` probe returns the same known unsupported-command panic and status 255 on both kernels; it is excluded from successful workload and performance summaries.

## Repeated warm launches

The same saved C driver and binary run on both kernels. Each boot performs five unmeasured launches followed by 50 measured `vfork` / `execve` / `waitpid` launches. Six boots per kernel alternate variant order: 300 measured launches per kernel, all successful. Shell startup is outside the counting window; marker and driver overhead remain included.

| Instructions per launch | TCC | LLVM | TCC / LLVM |
| --- | ---: | ---: | ---: |
| Mean CPU0 | 132,691.58 | 98,675.18 | 1.345× |
| Mean CPU1 | 928.46 | 488.22 | — |
| Mean both CPUs | 133,620.04 | 99,163.40 | 1.347× |
| Both-CPU range across six boot averages | 132,085.56–134,223.82 | 98,892.38–99,918.36 | — |

The boot-to-boot variation reflects scheduling and lock overlap. Single-boot workload counts should be read with that limitation.

## Kernel contribution

Counting PCs in kernel flash (`0x10000000`–`0x100fffff`) separately shows why larger workloads have smaller total ratios. This includes kernel-exported memory helpers called by userspace; it is an address-region attribution, not a syscall-only measurement.

| Workload | TCC kernel-flash instructions | LLVM kernel-flash instructions | TCC / LLVM |
| --- | ---: | ---: | ---: |
| `true-launch` | 204,459 | 144,230 | 1.418× |
| `ls-bin` | 2,706,072 | 1,785,689 | 1.515× |
| `tcc-hello-c-O2` | 2,631,647 | 1,442,112 | 1.825× |
| `tcc-bench-c-O2` | 2,869,330 | 1,582,392 | 1.813× |
| `zig-obj-tcc` | 32,381,313 | 17,824,764 | 1.817× |

In the larger TCC compile, kernel-flash instructions account for approximately 4.6% of the TCC-kernel total and 2.6% of the LLVM-kernel total. Most work executes in the identical userspace compiler.

## Inputs and artifacts

- YasOS HEAD: `a8cb6be6eeace80654fcdce552c14c9cc3daff03`, plus current working-tree changes.
- TinyCC HEAD at build capture: `63c2b0cf47c09ba773d86e4b14a839f18ca0be44`; installed cross used for the kernel build. HEAD advanced to `2987c1e7` during measurement via a documentation-only commit; the measured binary hashes are recorded in the manifest.
- Zig: `0.17.0-dev.1640+2597da025`.
- Configuration: current `qemu_mps3_an524`, dual Cortex-M33; QEMU FPU/DSP enabled.
- QEMU: plugin-enabled board-model binary, with `-icount shift=0,align=off,sleep=off`.
- Rootfs SHA256: `ff3cff293e3581e7e0dc1bb0ddd7f3f0b98269b00303a284197121aefd676a99`.
- TCC kernel SHA256: `53f6f4ad71bf2ffeb4e752fdff2064645c7d97a50c20a28342168172a73a8122`.
- LLVM kernel SHA256: `e381021c9e1611c75904af5af4fa409ad2582d776aaea0d7782c52fdc819794f`.

Artifacts: `.cache/kernel_benchmark_20261009_current/`. `manifest.json` records input hashes, revisions and working-tree status; `results-20261009-204454.json` contains workload results; `warm-results.json` contains all repeated samples; `summary.json` contains the derived summary. Per-PC CSVs are in `insns/`; console logs and both built kernels are preserved. All recorded binary and configuration hashes were rechecked after measurement.

The comparison command exits 1 against the historical baseline because `uname` reports build date `2026-10-09` instead of `2026-10-08` on both kernels. The rootfs has also changed. These historical differences do not indicate a current A/B mismatch, and historical instruction deltas are not presented as controlled kernel-only improvements. The stored baseline was preserved.

## Reproduction

```bash
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" \
  .qemu_smoke_venv/bin/python scripts/kernel_compare.py \
  --work .cache/kernel_benchmark_20261009_current --jobs 4 \
  --baseline .cache/kernel_compare/baseline.json
.qemu_smoke_venv/bin/python .cache/kernel_benchmark_20261009_current/warm.py
```

Use `--skip-build` on the comparison command to rerun the saved kernels. The warm driver and its source are saved under the artifact directory.
