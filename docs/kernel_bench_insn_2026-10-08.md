# On-device workload instruction counts, 2026-10-08

Instruction counts for representative userspace workloads on the
**ReleaseFast kernel + `-O2` native TCC** build, measured with the gated
per-PC instruction-count TCG plugin under QEMU (mps3-an524, dual M33 with
FPU/DSP). This is a snapshot of the current toolchain, not an A/B comparison;
it gives the per-workload cost baseline for future kernel/compiler changes.

## Frozen inputs and measurement

Built once with:

```bash
YASOS_KERNEL_OPTIMIZE=ReleaseFast ./build_rootfs.sh -o rootfs.img --zig /home/mateusz/repos/zig-mem
```

| Artifact | SHA256 |
| --- | --- |
| Kernel `zig-out/bin/yasos_kernel` | `9be2c40a783105210d075019e1f2c05db4a63b04a0abef4d23987bbdbdd252e6` |
| `rootfs.img` (embeds native TCC at `-O2`, coreutils, Zig) | `101eece5327d4ee5f4ba840d5c9a5bafefa73ebc64b0cc352e18cf5b5b25528f` |

All runs use `.cache/board_model/qemu/qemu-system-arm` with the board
`-global sse-200.*` FPU/DSP flags and `-icount shift=0,align=off,sleep=off`,
plus the per-PC counting plugin `.cache/bench_insn_20261008/icount.so`. The
plugin counts guest instructions only between the `@@PROFILE_BEGIN@@` /
`@@PROFILE_END@@` UART markers the workload driver prints, so kernel boot and
the payload upload are excluded. Guest microseconds elsewhere in these docs are
icount readings, not board time; this document reports instruction counts only.

Each workload runs in its own fresh boot; runs are deterministic under
`-icount`. Evidence: `.cache/bench_insn_20261008/` (`out/<tag>.csv` per-PC
counts, `run-<tag>.log` guest transcripts, `payload/` sources; the LLVM-kernel
run's CSVs and transcripts are the `llvm-*`-prefixed files in the same
directory).

## Workloads and counts

`noop` runs the same script with an empty case and measures the harness
(toysh startup, script parsing, marker echo) — subtract it from the others.

| Workload (`tag`) | What runs | Raw insns | Net of harness |
| --- | --- | ---: | ---: |
| `noop` | harness baseline | 794,168 | — |
| `core-cat` | `cat corpus.txt` (2,000 lines) → `/dev/null` | 1,410,682 | 616,514 |
| `core-wc` | `wc -l -w corpus.txt` | 6,419,243 | 5,625,075 |
| `core-sort` | `sort corpus.txt` → file | 25,818,428 | 25,024,260 |
| `core-uniq` | `sort \| uniq -c \| sort -rn \| head -20` | 27,979,761 | 27,185,593 |
| `core-sha` | `sha256sum corpus.txt` | 11,357,531 | 10,563,363 |
| `core-grep` | `grep -c the corpus.txt` | 10,340,844 | 9,546,676 |
| `zig-hello` | Zig `build-obj` of a hello `.zig` → C, `-OReleaseSmall`, freestanding | 440,585,133 | 439,790,965 |
| `tcc-hello-O0` | native TCC `-c -O0 hello.c` | 8,165,373 | 7,371,205 |
| `tcc-hello-O2` | native TCC `-c -O2 hello.c` | 8,457,176 | 7,663,008 |
| `tcc-scopes-O2` | native TCC `-c -O2 scopes.c` (43 lines) | 7,158,774 | 6,364,606 |
| `tcc-inline-O2` | native TCC `-c -O2 inline.c` (132 lines) | 8,373,448 | 7,579,280 |
| `tcc-bitops-O2` | native TCC `-c -O2 bitops.c` (GCC-torture-style, 281 lines) | 676,447,374 | 675,653,206 |

Notes:

- The `core-*` counts include the pipeline's real work (sort/uniq/sort chain
  for `core-uniq`), which is why `core-uniq` exceeds `core-sort`.
- `zig-hello` is dominated by Zig's own front end (≈395M of the count sits in
  Zig's text range); the freestanding hello still pulls in `std.fmt`.
- `tcc-bitops-O2` is a known outlier: the same pathological case appears in
  [the allocator rebenchmark](tcc_allocator_rebenchmark_2026-10-08.md)
  (bitops `-O2` ≈ 989 s guest vs 66 s at `-O0`). It is kept as a workload
  because it is a real cost center, not because it is representative.
- Per-PC CSVs let any region be re-cut: e.g. `bitops` spends ≈654M of its
  count in one 8-instruction loop at `0x61400ecc`, and ≈178k×8 instructions in
  kernel `memcpy` (0x1003b0xx) — kernel `memcpy` is a legitimate workload cost
  (userspace links the kernel-provided `memcpy`).

## A/B: LLVM-backend kernel (same rootfs)

The same rootfs was re-embedded into a second kernel built with Zig's LLVM
backend instead of the Zig C backend + TCC pipeline:

```bash
zig build -Doptimize=ReleaseFast -Dkernel_cc=llvm
```

| Artifact | SHA256 |
| --- | --- |
| Kernel, Zig C backend + TCC (`kernel_cc=tcc`, default) | `9be2c40a783105210d075019e1f2c05db4a63b04a0abef4d23987bbdbdd252e6` |
| Kernel, Zig LLVM backend (`kernel_cc=llvm`) | `036de5ed697ffae8f0818ef70e2dc598fbf6ef251d8a2d238a8bed8fe33b4221` |
| `rootfs.img` — identical in both builds | `101eece5327d4ee5f4ba840d5c9a5bafefa73ebc64b0cc352e18cf5b5b25528f` |

The LLVM variant's harness baseline is 847,228 (toysh itself runs on the kernel,
so the harness differs per variant); each variant is netted against its own
baseline.

| Workload | tcc-kernel net insns | LLVM-kernel net insns | Change |
| --- | ---: | ---: | ---: |
| harness baseline | 794,168 | 847,228 | +6.69% |
| `core-cat` | 616,514 | 563,454 | −8.61% |
| `core-wc` | 5,625,075 | 5,572,015 | −0.94% |
| `core-sort` | 25,024,260 | 24,971,200 | −0.21% |
| `core-uniq` | 27,185,593 | 27,132,533 | −0.20% |
| `core-sha` | 10,563,363 | 10,510,303 | −0.50% |
| `core-grep` | 9,546,676 | 9,493,616 | −0.56% |
| `zig-hello` | 439,790,965 | 439,737,905 | −0.01% |
| `tcc-hello-O0` | 7,371,205 | 7,318,145 | −0.72% |
| `tcc-hello-O2` | 7,663,008 | 7,609,948 | −0.69% |
| `tcc-scopes-O2` | 6,364,606 | 6,311,546 | −0.83% |
| `tcc-inline-O2` | 7,579,280 | 7,526,220 | −0.70% |
| `tcc-bitops-O2` | 675,653,206 | 675,600,146 | −0.01% |

Interpretation: **every net delta is exactly 53,060 instructions.** The LLVM
kernel saves a fixed amount of per-run kernel work (process startup and the
kernel-provided startup path) and nothing inside the workload bodies. Userspace
binaries are byte-identical across the two builds, so the workload instruction
streams are identical; the kernel's only measured contribution is that fixed
path. The fixed saving is 6.3% of the tcc kernel's harness baseline, which is
why tiny workloads (`core-cat`, −8.6%) look dramatically better while compute-
heavy ones (`zig-hello`, `tcc-bitops`) move by −0.01%.

## Reproducing

```bash
# one-time: build as above, then
python3 .cache/bench_insn_20261008/run.py \
  --kernel .cache/bench_insn_20261008/kernel_tcc_ReleaseFast \
  noop core-cat core-wc core-sort \
  core-uniq core-sha core-grep zig-hello tcc-hello-O0 tcc-hello-O2 \
  tcc-scopes-O2 tcc-inline-O2 tcc-bitops-O2

# LLVM-kernel variant (same payload; the LLVM kernel is the current
# zig-out/bin/yasos_kernel, the tcc-kernel copy is kept beside the evidence):
python3 .cache/bench_insn_20261008/run.py --variant llvm \
  noop core-cat core-wc core-sort core-uniq core-sha core-grep zig-hello \
  tcc-hello-O0 tcc-hello-O2 tcc-scopes-O2 tcc-inline-O2 tcc-bitops-O2
```

`run.py` boots QEMU per workload via `scripts/qemu_mount.py` with the plugin
and prints `tag: rc=… insns=N` (sum of the per-PC CSV). Guest driver:
`.cache/bench_insn_20261008/payload/wl.sh`.
