# Kernel and native TCC performance: findings and implementation plan

Latest: the [October 9 current-checkout recheck](kernel_performance_recheck_2026-10-09.md)
measures **153,627 TCC versus 108,626 LLVM CPU0 instructions per warm launch
(1.414×)**, with a private cross built from current working-tree sources and a
fixed rootfs. It updates the hotspot priorities below.

The [afternoon rebenchmark](../libs/tinycc/docs/bugs/tcc_kernel_ab_rebench_2026-10-09b.md)
reused those hash-identical artifacts and reproduced the numbers (**154,432
versus 109,078 both-CPU instructions, 1.416×**; all 15 workloads and the
8-object compile matrix green), then root-caused the six largest
compiler-side bottlenecks into defect reports:
register-allocation eviction of loop-invariant carriers
(the replay data loop's 2,528 SP loads per launch; `ra:loop_split` landed
default-off, census pending; fixed in `8395ce4c` — entry-copy ordering —
and the pass is now default-on, verified by a 401-seed sweep), plus
per-iteration param-home reloads in the
thunk loop (fixed: late `ra:licm` + `stack_param_promote`), the CAS
desired-value stack round trip (fixed in `a18f690d`), and byte-assembled
word compares through a stack buffer (fixed in `f17818b9`, `mem.eql` 6,090
instructions per launch) — those three reports are closed in git history — plus
[per-page invariant reloads in the allocator bitmap helpers](../libs/tinycc/docs/bugs/pool-mark-per-page-invariant-reloads.md)
(16,102 instructions per launch) and
out-of-line wyhash wrappers (fixed kernel-side by the integer context in K3;
previously 35 hash calls + 35 state-copying inits per launch). The `kernel_compare`
baseline was re-stored from that run.

Measured on 2026-10-08. The largest remaining warm-launch hotspot is relocation
template replay. TCC emits repeated stack accesses and address calculations in
that loop even after `word_at` is inlined. Parsing also repeats symbol-name
scans, and generic hashing performs expensive wide arithmetic for small integer
keys. These are the next targets; another ROMFS lookup cache is unnecessary.

This document is a plan. No further compiler or loader optimization was applied
while collecting these measurements.

The [current recollection at `9bda2a24` plus working-tree improvements](../libs/tinycc/docs/bugs/tcc_stack_recollect_9bda2a24_2026-10-08.md)
shows **187,683 TCC versus 115,181 LLVM instructions (1.629×)**.
Against the previous read-only-loop fix, instructions fall **0.25%**,
direct SP accesses **1.83%**, stack bytes **0.66%** and calls **0.45%**.
Replay remains **55,329 instructions and 5,573 direct SP accesses**; `memset`
remains **22,507 versus 10,113 instructions**. Six fresh boots per variant and
the frozen-native compile matrix pass. **Self-host and fuzz testing are deferred
until optimizations are complete and stabilization begins.**

The [read-only loop inliner fix](../libs/tinycc/docs/bugs/tcc_readonly_loop_inliner_fix_2026-10-08.md)
recovers the scan regression while retaining atomic-loop inlining. Six fresh
boots each for control, fixed and LLVM show **198,951 → 188,129 instructions
(−5.44%, 1.637× LLVM)**. Synchronization/atomic helper calls remain about 37.
Restoring reusable scan calls raises total calls 16.94% and stack bytes 1.42%
against the regression control. The full suite and frozen-native matrix pass;
no new fuzz divergences appear in the rechecked failing seeds.

The [earlier recollection at `b7833dbc` plus the working-tree fixes](../libs/tinycc/docs/bugs/tcc_stack_recollect_b7833dbc_2026-10-08.md)
includes inline atomics and the current atomic header. Against the previous
general-inliner build, calls fall **30.91%**, direct SP accesses **8.76%** and
stack bytes **19.01%**, but instructions rise **1.20%** to **198,973**
(**1.731× LLVM**). New small-loop inlining duplicates symbol-name scans before
call-result reuse can eliminate them. Disabling `inline:small_loop` recovers
**5.47%**, reaching **188,097 instructions** across six boots. Preserving
read-only scan reuse while keeping atomic-loop inlining is the next compiler
target; replay remains 55,345 instructions and 5,577 direct SP accesses.

The [fresh instruction comparison](../libs/tinycc/docs/bugs/tcc_instruction_comparison_2026-10-08.md)
adds six profiles each for frozen LLVM, TCC control and the isolated equal-end
allocator probe. It includes instruction mix, function attribution and stack
traffic: control remains 2.343× LLVM in instructions, and the probe 2.329×.

The [recheck after delivered fixes](../libs/tinycc/docs/bugs/tcc_stack_recheck_2026-10-08.md) builds
the same frozen C with TinyCC `8f6ae7b4`: launch instructions fall 4.60% and
direct SP traffic 21.31% against the frozen control. A caller-save on/off
comparison confirms the replay induction-spill improvement. Current TCC
remains 2.233× LLVM in instructions; the frozen measurements below retain
their original scope.

The [recollection at `ca1f6655`](../libs/tinycc/docs/bugs/tcc_stack_recollect_ca1f6655_2026-10-08.md)
includes pair eviction and accessor/wrapper inlining. Against `8f6ae7b4`, it
reduces launch instructions 9.81%, direct SP accesses 12.57% and call
instructions 42.29%. At that revision TCC is 2.017× LLVM in instructions; `__multi3`
and the remaining replay invariant loads are still major stack-traffic targets.

The [earlier recollection at `2afaa5b9` plus our branch-aware spill-cost patch](../libs/tinycc/docs/bugs/tcc_stack_recollect_2afaa5b9_2026-10-08.md)
includes `__multi3` inlining, indexed loads/stores and repeated read-only call
reuse. It rebuilds both frozen kernel C and compiler-runtime C. Latest executes
**198,553 instructions and 11,709 direct SP accesses**, versus LLVM's
**114,909 and 6,551** (**1.728× and 1.787×**). Against `ca1f6655`, instructions
fall **14.41%** and SP accesses **38.66%**. Standalone `__multi3` execution
disappears; sentinel scans fall 514→267 per launch. Replay remains the largest
individual hotspot (55,406 instructions, 5,641 SP accesses), with entry-pointer
and bound reloads the next allocator targets. `memset` remains 22,507 versus
LLVM's 10,113 instructions. The frozen-native compile matrix passes with
identical objects; latest native compiler throughput still needs a separate
board-model measurement.

A [discarded Symbol.size loader prototype](../libs/tinycc/docs/bugs/tcc_symbol_size_2026-10-08.md)
removed 243 calls and saved 1.54% of instructions, but the target is a general
inliner fix. The source workaround was reverted; its captures remain useful
for understanding the cost of the helper boundary. Atomic-helper work is
independent.

The [general TinyCC inliner fix on the original loader](../libs/tinycc/docs/bugs/tcc_inliner_symbol_size_2026-10-08.md)
now removes all 243 `Symbol.size` calls while preserving 267 sentinel scans.
Across six boots per variant, instructions fall 0.70%, calls fall 10.18%,
and stack transfer bytes fall 4.09%; direct SP accesses rise 1.78% and kernel
text grows 2,304 bytes. Wrapper budgets are local to the caller, nested
dependencies can expand, repeated scans survive forward alignment branches
as one call, and SSA removes dead comparison inputs before allocation.

## 1. Baseline and scope

The new controlled comparison includes:

- The small-copy operand-classification fix in TCC.
- The CFG-cycle-aware automatic inliner fix. `Layout.word_at` remains an ordinary
  function; there is no forced-inline annotation in this experiment.
- The ROMFS path-to-entry-offset cache from YasOS commit `e6028ade`.
- The same frozen native TCC, libraries, and rootfs in every kernel.

The kernel comparison uses the existing isolated AN524 source snapshot with
the current ROMFS cache copied into it, not every unrelated pending change in
the main working tree. TCC builds use the isolated cross containing our two
compiler fixes. LLVM was explicitly built with `-Dkernel_cc=llvm`; the build
default is TCC. Both kernels are ReleaseFast.

The rootfs SHA256 is
`e2b87861598e93cb2311f1201102e9ac83f8040454e9e2ac4a62710529900a93`.
The new TCC kernel SHA256 is
`bfd0e5dc3c9ad2e58db60c9ad0b2c98557060d163b572f94971331464c8ef5f9`;
LLVM is
`e0d257c62c920eb339408cfc2d8754c614f04f1fe63b8bfccc85cff0d01324a9`.
Compiler/source hashes are recorded in the capture manifest.

### Warm `/bin/true` launch

The instruction profile covers five warm-up launches followed by 50 measured
launches, using the gated QEMU TCG plugin. Both completed with `rc=0`.

| Measurement | LLVM | TCC | TCC / LLVM |
| --- | ---: | ---: | ---: |
| Instructions per launch, both CPUs | 114,873.50 | 268,923.64 | 2.341× |
| Mean guest microseconds, profile run | 146.98 | 344.12 | 2.341× |
| Median guest microseconds, separate benchmark | 144.50 | 341.00 | 2.360× |

The original TCC profile was 736,198.66 instructions per launch. The combined
fixes reduce that by **63.5%**. The remaining difference from LLVM is about
154,050 instructions per launch. The ratio remains substantial because ROMFS
caching also removes a large amount of work from LLVM.

QEMU uses dual Cortex-M33 with DSP/FPU enabled and
`-icount shift=0,align=off,sleep=off`. Instruction counts are directly counted;
guest times are not physical board cycles or host wall time. The existing
AN524 timer conversion scales absolute guest readings by 1.28; ratios survive
that scaling. Physical-board priorities also depend on XIP/PSRAM costs.

### Native TCC compilation under those kernels

Two fresh boots per kernel, reversing order in the second round; six
repetitions per workload per boot, with repetition zero discarded. Each
median uses ten samples. Sources are on `/mnt`, objects on `/tmp`.

| Workload | LLVM kernel, guest ms | TCC kernel, guest ms | Ratio |
| --- | ---: | ---: | ---: |
| hello, `-O0` | 6.4810 | 8.5375 | 1.317× |
| scopes, `-O0` | 5.4430 | 6.1565 | 1.131× |
| inline, `-O0` | 5.1265 | 6.7925 | 1.325× |
| bitops, `-O0` | 66.6210 | 68.9020 | 1.034× |
| hello, `-O2` | 6.8485 | 8.9315 | 1.304× |
| scopes, `-O2` | 5.9600 | 6.6940 | 1.123× |
| inline, `-O2` | 6.9410 | 8.6185 | 1.242× |
| bitops, `-O2` | 998.7975 | 1003.4880 | 1.005× |

The third control kernel has the ROMFS cache and small-copy fix, but the old
inliner. Against it, the new inliner reduces `/bin/true` median time from
407 to 341 µs (**16.2%**) and these small compilation medians by approximately
1.0–1.6%. Its bitops `-O2` median changes by only 0.07%.

All **288 timed compilations**, **36 true launches**, and **six linked hello
runs** passed. All eight object files are byte-identical across all six boots.
The native compiler was held identical: this experiment measures effects of
kernel code generation, including launch and kernel services during compilation.
It does not measure rebuilding the native compiler with the latest cross.

## 2. What is hot now

These are instructions executed inside the listed functions, excluding their
callees. Helper families below are disjoint from the named caller rows.
They are not inclusive loader phase times. LLVM inlines substantially more
code into `Loader.load_module`, so a missing LLVM helper symbol does not mean
the corresponding work disappeared.

Refreshed **2026-10-09 (afternoon)** from
`.cache/kernel_rebench_20261009b/summary.json` (six alternating boots, 50
measured launches each, both CPUs, exclusive attribution). The 2026-10-08
rows this table replaced are in git history; the frozen §1 tables above keep
their original scope.

| TCC location/family | Instructions per launch | Share | Evidence and report |
| --- | ---: | ---: | --- |
| `Loader.load_from_template` (replay) | 34,252 | 22.2% | Data loop 14,330 (2,528 SP loads), GOT loop 9,708 (0), thunk loop 8,370 (1,488); post-opt IR clean, the data/GOT difference is made in register allocation — RA eviction report (closed: `ra:loop_split` default-on since `8395ce4c`), [thunk param-homing report](../libs/tinycc/docs/bugs/loop-invariant-params-reloaded-per-iteration.md) |
| Pool reserve/mark-used/mark-free | 16,102 | 10.4% | 7,889 + 4,167 + 4,046; per-page invariant reloads — [pool report](../libs/tinycc/docs/bugs/pool-mark-per-page-invariant-reloads.md); the lock path also pays the [CAS round trip](../libs/tinycc/docs/bugs/atomic-cas-desired-round-trips-through-stack.md) |
| `memcpy` | 14,177 | 9.2% | Parity: LLVM 14,100 |
| `memset` | 9,826 | 6.4% | LLVM 7,819; the 64-byte `strd` loop is at parity, byte head/tail alignment is the gap |
| Sentinel scanning | 9,115 | 5.9% | 267 calls vs LLVM's 264 `strlen` — at parity since the inliner fixes |
| `Parser.create` | 6,672 | 4.3% | 993 direct SP accesses vs LLVM's 201; post-opt IR nearly clean — same RA-spill family as the eviction report |
| Wyhash init + hash | 6,560 | 4.2% | 35.4 hashes + 35.4 state-copying inits in this snapshot; fixed kernel-side for integer keys (K3); `UMULL`, no `__multi3` |
| `mem.eql` (eqlBytes inlined) | 6,090 | 3.9% | 585 stack stores; byte-assembly round trip — [report](../libs/tinycc/docs/bugs/byte-assembled-word-compare-round-trips-through-stack.md) |
| kheap lock/unlock | 5,658 | 3.7% | Call frequency dominates; contended path pays the CAS round trip |

ROMFS `FileHeader.load` now runs only **twice per launch**, consuming **284
instructions**. It previously ran 282 times. Warm directory walking is no
longer a major bottleneck. Cold lookup and cache eviction need separate tests.

The symbol mapper leaves some assembly/padding and userspace PCs unattributed;
the total instruction count includes them. CPU1 contributes about 1,007
instructions per TCC launch, so the dominant excess is on CPU0.

## 3. Prioritized kernel/loader work

### K1. Improve the generated relocation replay loop in TCC

**Why first:** this is the largest individual measured hotspot, and compiler
fixes can improve analogous loops elsewhere.

Relevant sources:
`dynamic_loader/source/template.zig` (`View.apply`, `Layout.word_at`,
`Layout.thunk_offset`),
`libs/tinycc/source/opt/flat/loop/licm.c`,
`source/opt/flat/loop/stack_param_promote.c`,
`source/opt/ssa/memory/load_cse.c`,
`source/opt/ssa/loop/iv_strength_reduction.c`, and
`source/ir/regalloc_entry.c` inside the TinyCC submodule.

The measured TCC loop at `0x1003bd90..0x1003be30` executes 1,674 entries.
It loads its induction variable and limit from the stack, recomputes
`(data.len + got.len) / 4`, computes `data.len / 4` again, reloads base-table
and region pointers, and spills the updated induction variable each iteration.
Thunk entries also execute a runtime divide/multiply/subtract sequence for
`offset % thunk_code.len`. Inlining removed the call boundary but did not
remove this repeated work.

The subsequent [stack-traffic analysis](../libs/tinycc/docs/bugs/tcc_stack_analysis_2026-10-08.md)
quantifies 11,817 explicit stack accesses in this loop per launch and confirms
that its induction variable reaches SSA successfully, then spills during
allocation. It also identifies register pressure from disabled temporary timing
accounting. Use that evidence to distinguish allocation work from promotion and
to preserve a matched uninstrumented baseline before measuring a fix.

The subsequent [branch-cost experiment](../libs/tinycc/docs/bugs/tcc_replay_branch_cost_2026-10-08.md)
adds a generic allocator cost correction: conditional loop paths receive one
quarter of the latch-path weight for both uses and call saves. On the matched
`b3c1c495` compiler, replay stack accesses fall 7,216→5,641 (-21.8%) and replay
instructions 57,168→55,406 (-3.1%). Six alternating boots per variant confirm
-0.79% whole-launch instructions and -11.52% explicit SP accesses after the
separate `__multi3` merge. The frame grows 560→568 bytes, so this improves
traffic rather than peak stack size. The entry-array home and loop limit still
reload 1,674 times each. The fresh native compiler reproduces all 76 objects
and its executable byte-for-byte; fuzzing found no new failures and exec/vfork
smoke passed. See the experiment report for exact baseline failures and
remaining physical-board/varied-workload rollout checks.

Implementation sequence:

1. Extract the *actual emitted C* replay loop into a small standalone compiler
   regression, preserving slices, struct copies, the conditional thunk
   `memcpy`, and the base-table access. Record per-pass IR and final ARM.
2. Follow the induction variable and layout fields through promotion, LICM,
   load CSE, SSA construction and register allocation. Determine whether the
   stack traffic already exists before allocation or is introduced by spills.
   Disable one candidate pass at a time to establish causality.
3. Fix the earliest incorrect or unnecessarily conservative classification.
   Reuse `irop_is_vreg_value` for value reads where appropriate. Extend
   escape/clobber reasoning only when it proves the thunk copy cannot overwrite
   the stack-local layout/loop state. A pointer read, an address-taken local,
   and a pointee load need distinct treatment.
4. Hoist proven invariant arithmetic and retain the induction value in a
   register when profitable. Keep profitability sensitive to calls/register
   pressure; moving more values into registers can increase spills elsewhere.
5. Rebuild the kernel with unchanged loader source and frozen rootfs, then
   repeat the gated profile and compilation capture.

The existing MemorySSA forwarding path is opt-in and has documented subword
limitations. Do not enable it globally as a shortcut. Any new tracking should
be computed once per relevant IR generation and invalidated on mutations;
a permanent one-bit “dereferenced” flag cannot prove aliasing or loop invariance.
Avoid a whole-function scan for every operand query.

**Acceptance:** the reduced case demonstrates fewer loop stack operations or
invariant calculations; the actual kernel executes fewer replay instructions.
Run pointer/alias, intervening-call, volatile, VLA, nested-function, join and
loop regressions, compiler units/runtime suites, fuzzing, kernel exec/vfork
smoke, and native self-host verification before broadly adopting the cross.
The 61,837-instruction loop is a cost envelope, not an achievable saving:
loads, base lookup and relocation stores are necessary.

### K2. Stop repeatedly measuring symbol tables by scanning names

**Current result:** TinyCC's [general inliner fix](../libs/tinycc/docs/bugs/tcc_inliner_symbol_size_2026-10-08.md)
uses the original `Symbol.size()` as a regression case and removes all 243
remaining calls. The loader-side scalar/single-stride prototype was reverted.
See its [diagnostic measurements](../libs/tinycc/docs/bugs/tcc_symbol_size_2026-10-08.md).

Relevant sources: `dynamic_loader/source/item_table.zig`, `symbol.zig`,
`parser.zig`, and the YAFF writer/validation code.

`ItemTable.size()` calls `it.size(alignment)` and then `it.next(alignment)`
for every item. `Symbol.next()` calls `size()` again, and `size()` finds the
name terminator. The measured 486 symbol-size calls are consistent with this
double traversal. `Parser.create()` uses the imported-table size to locate the
exported table on every load. The format already supplies symbol lookup offsets.
`Iterator.next()` also computes `data.next()` twice when it continues.

Implementation sequence:

1. Compute the item stride once per `size()` iteration; advance the pointer
   using that stride. Compute the iterator's next pointer once. This removes
   redundant source work for both compilers without changing the format.
2. For symbol tables with a validated lookup array, derive the extent from
   the last physical symbol offset plus that symbol's size. First verify the
   writer guarantees physical-order offsets and validate count/range/ordering.
   Keep the walk for dependency tables or formats lacking a suitable lookup.
3. If the format cannot guarantee this, cache validated parser/table extents
   for immutable pinned images. Tie entries to image lifetime and reclaim;
   an address-only cache must not outlive replaceable image storage.
4. Separately trace why tiny helpers such as `Symbol.name/size/next` remain
   out of line. Fix cost/eligibility accounting if a reduced example proves
   a compiler issue; do not scatter forced-inline annotations.

**Acceptance:** warm parsing stops doing two sentinel scans per visited symbol;
the indexed path scales independently of table length. Check empty/single-item
tables, long names, alignment padding, malformed offsets/counts, dependency
tables, and old format behavior. Compare parser addresses and loaded output
against the existing walk. Re-profile after K1: these helper totals overlap
algorithmically with inlining opportunities, so predicted savings do not add.

### K3. Specialize hashing of small fixed-size keys

**Implemented 2026-10-09:**
[`IntegerHashMap`](../dynamic_loader/source/integer_hash_map.zig) uses the
scalar seed-zero Wyhash small-key path for the loader's address map, kernel
pid maps, file-descriptor maps and the process page allocator's pid map.
The initializer's seed state is computed at compile time. String and content
hashes keep the standard implementation; the compiler's general inliner is
unchanged.

Regression coverage includes every `u16`, randomized signed/unsigned integers
of all supported widths, aligned image addresses, collisions, growth, deletion
and cloning. `cd dynamic_loader && zig build test` runs the semantic tests;
`zig build test-hash-codegen` (with pytest on Python's path) checks ReleaseSafe
and ReleaseFast Zig C through the kernel cross at `-O2`: the hash entry points
must contain no helper calls or out-of-line state copies. The codegen regression
failed against the standard context before the fix.

Same-checkout/rootfs/cross warm-launch A/B (5 warmups, 50 measured launches):
231,547.66 → 219,642.60 both-CPU guest instructions (**−5.14%**), general
hash/init calls 34.94 → 2 per launch, kernel text **+384 bytes**. The two
remaining calls hash strings. Artifacts: `.cache/wyhash-regression/`.
The loader tests, 22 process tests, 22 page-pool tests and 14 QEMU smoke tests
(vfork, pipes and directory listing) pass. The original investigation follows.

Relevant sources: loader `modules_list` in `loader.zig`, process file-handle
maps, TCC inliner/constant propagation, emitted Zig C and the wide-arithmetic
runtime helpers. Check the actual lowering before choosing the layer to fix.

Executed call-site counts show:

- 30 calls through the `usize` auto-hash wrapper used by the loader module map.
- 3.02 through the `u16` wrapper used by file-handle maps.
- Two string-map hash calls.
- All 105.06 `__multi3` calls come from Wyhash initialization/hash code:
  three wide multiplications per measured hash.

The emitted integer wrappers pass **seed zero** and **length four/two** to the
large generic Wyhash function. Those constants should permit a much smaller
path and constant initialization. The current call boundary prevents that
specialization. Wyhash uses a widened 64-bit product; the emitted-C path calls
a general 128-bit multiply helper.

Implementation sequence:

1. Reduce the constant-seed, two/four-byte hash call to a compiler test. Inspect
   whether call-site specialization or inlining can fold initialization and
   eliminate irrelevant long-input branches with bounded code growth.
2. Prefer a compiler/helper fix that preserves exact Wyhash results. If a
   source-level small-key implementation is needed, make it a narrowly scoped,
   bit-identical context with exhaustive `u16` and randomized `usize` checks.
3. Inspect wide multiply lowering separately. A zero-extended 64×64 product
   can use 32-bit partial products and carries; preserve both 64-bit halves.
   Do not change arbitrary 128-bit multiplication on the basis of this case.
4. Measure whole-launch instructions, text size, native compiler work and
   board XIP misses. Faster arithmetic can lose its benefit through code growth.

**Acceptance:** exact hash equivalence and unchanged map behavior under collisions,
resize, deletion and aligned/consecutive image-address keys. Attribute savings
to the integer-map path, preserving general string/content hashes. The full
24,589-instruction family is an upper bound, not all removable overhead.

### K4. Reduce clear-loop overhead, then investigate redundant clearing

Relevant sources: `libs/libc/string.c`, TCC loop/Thumb code generation,
`source/kernel/memory/heap/process_memory_pool.zig`, board `memory.zero_pages`,
and `dynamic_loader/source/module.zig`.

TCC's `memset` executes 22,507 instructions versus LLVM's 10,113. The large
TCC loop writes 16 bytes with two `strd` instructions but uses a top test and
an unconditional back jump. LLVM's hot loop processes a larger block.
The call histogram records 38,912 bytes of pool clearing, 10,440 bytes of
BSS clearing, and 1,488 bytes of thunk clearing per launch.

Implementation sequence:

1. Extract the common C clear loop and determine whether existing loop rotation,
   bottom-test or unrolling should improve it. Prefer fixing that generic pass
   over replacing an already word-wise implementation with assembly.
2. Measure a bounded larger-block loop as a probe. Verify every alignment,
   small size, tail length and byte value with buffer guards. Account for
   unaligned `strd` requirements and text-size/cache effects.
3. Trace destination ranges, allocation fill/poison and initialization before
   considering zero removal. The copy histogram records byte counts but does
   not prove the destinations overlap.
4. Introduce a loader-only zeroed-allocation contract only if it survives the
   allocator interface and guarantees every process-visible byte is initialized.
   The pool explicitly warns that `std.mem.Allocator` may overwrite fresh
   memory with `undefined`; deleting BSS clearing directly is incorrect.
   Preserve zero descriptors for unresolved weak thunk slots and recycled-page
   isolation. Keep clears outside the IRQ-masked pool lock.

**Acceptance:** lower instructions per cleared byte and measured launch benefit,
without allocator/loader behavior changes across build modes. The measured
`memset` difference is about 12,394 instructions, **4.6% of total TCC launch**;
this alone cannot close the remaining gap. Validate board-specific PSRAM
zeroing separately before replacing its existing mechanism.

### K5. Audit remaining frequent tiny helpers and allocation metadata

The pool performs 613.4 out-of-line `DynamicManaged.isSet` calls per launch,
costing 8,588 instructions before caller overhead. Seven reserve/free operations
also call bitmap mark helpers. The allocator already has a first-fit frontier,
256-byte allocation grains in this configuration, and clearing outside its lock.

Trace inliner rejection reasons for `isSet`, symbol helpers and remaining
alignment helpers: eligibility, optimized size, nested budget, definition order,
indirect call or register pressure. Instrument aggregate summaries rather than
printing for every invocation. Keep safety gates for volatile, escaping state,
static locals, nested functions and computed control flow. Optimize bitmap
range marking only if its executed loop remains hot after helper inlining;
preserve frontier, allocation ownership, tier selection and fragmentation.

**Acceptance:** reduced ARM call/spill work and a net full-launch improvement
with stable text size and compiler build time. Existing allocator tests plus
fragmented SRAM/PSRAM allocation, reclaim and cross-process free cases should
continue to pass. Treat this as a measured follow-up after K1–K4, not a reason
to increase global inline budgets indiscriminately.

### K6. Simplify template replay only after compiler fixes are measured

If replay remains dominant, exploit its sorted entries: process data, GOT and
thunk ranges with hoisted region boundaries/base pointers, rather than selecting
the region for every entry. Make the thunk code size statically visible where
the architecture guarantees it; avoid runtime modulo for a fixed slot layout.

Prefer a replay-only change that preserves the existing eight-byte entry format
and flash precache compatibility. Adding region tags, explicit byte offsets or
separate thunk records requires a format/version and memory-budget comparison.
Preserve entry ordering, alignment-one input handling, base-kind selection,
dependency identity/pinning, weak slots and function-pointer identity. Copy
relocations still read dependencies' live data; they cannot be replaced with
cached bytes from a previous process.

**Acceptance:** template-vs-full-relocation verification, dependency changes,
cache reclaim/eviction, weak/function-pointer/copy-relocation tests, and lower
instructions on both TCC and LLVM. Record template bytes and cold capture cost.

## 4. Native compiler throughput needs a separate baseline

The long bitops compile is within 0.5% between these kernels. The next large
compile-time gains require examining native TCC itself and board memory costs.
A `/bin/true` profile cannot identify those pass bottlenecks.

The latest saved board-model evidence is in
[the October 7 TCC profile](board_model_tcc_profile_2026-10-07.md).
Its `psram-agg-index` image uses an older cached kernel-source baseline and a
separately rebuilt native compiler. Do not combine its seconds or percentages
with this launch capture. Aggregate folding's forward-predecessor index is
already implemented: it reduced one slow pass by 42%, that compile by 3%, and
the selected nine-compile total by 0.9%.

The indexed image's 2,605 timed compiles total 1,017.5 modeled seconds; exclusive
timed passes total 532.1 seconds:

| Pass | Seconds | Share of timed passes | Share of full compile total |
| --- | ---: | ---: | ---: |
| `cg:dry` | 67.97 | 12.8% | 6.7% |
| `ra2:ssaopt` | 45.50 | 8.6% | 4.5% |
| `P:requirements` | 39.80 | 7.5% | 3.9% |
| `ra:ssa_post_ra` | 37.57 | 7.1% | 3.7% |
| `cg:emit` | 36.35 | 6.8% | 3.6% |
| `cg:rehearsal` | 20.38 | 3.8% | 2.0% |

### C1. Refresh and complete phase accounting

Build a board-shaped image with an explicitly recorded current YasOS checkout,
cross compiler, native optimization flags and native binary hash. Include the
existing aggregate index and both inliner fixes. Run the same selected slow
compiles and a representative mix of small/medium compiles; then confirm the
rankings on a broader corpus.

Separate actual TCC startup from compile work: time a minimal invocation or
empty translation unit, frontend/parse, optimization, register allocation,
codegen, allocation and file output. Do not subtract `/bin/true` startup as if
TCC had the same writable state and relocation count. The difference between
1,017.5 full seconds and 532.1 timed-pass seconds is not automatically a new
unidentified pass; several frontend/I/O phases are outside that pass accounting.

For each candidate, run both `-bench`/PASS_TIME and an uninstrumented replay.
Record instruction counts, XIP instruction/data misses, PSRAM traffic and peak
scratch memory. The previous aggregate-index experiment reduced instructions
but increased instruction-fetch misses by 2.17%; instruction counts alone can
mis-rank board improvements.

### C2. Decompose SSA and post-allocation overhead

Add exclusive sub-timers/counters around untimed work under `ra2:ssaopt` in
`libs/tinycc/source/ir/regalloc_entry.c` and `ra:ssa_post_ra` in
`source/backend/generators/regalloc.c`: context initialization, use-list/CFG
work, cleanup, target fusions and final repair. Preserve nested timing semantics
so inner passes are not counted twice.

Find repeated whole-IR scans or analyses rebuilt without a relevant mutation.
Optimize the demonstrated expensive operation with a worklist/index or a
generation-scoped cache. Measure index allocation and PSRAM traffic as well as
scan reduction. Keep SSA renaming/phi repair at `-O0`; existing source documents
miscompiles when those correctness steps are skipped.

### C3. Reduce requirements rebuilds with verified invalidation contracts

Instrument `source/opt/engine/pipeline_run.c` and `ctx.c`: count DU, merge,
block and loop builds, requesting pass, preceding mutation, IR size and rebuild
time. Start with avoidable duplicate requests and scratch-buffer reuse.

The driver deliberately invalidates everything after a mutating pass. Simply
restoring per-pass masks repeats the documented stale-generation bug in
`docs/plans/opt_pass_dedup_and_perf.md`. Introduce explicit mutation categories
and generations first, update every relevant mutation site, and add a debug
mode that compares cached analyses against fresh recomputation. Only then
preserve analyses across changes that demonstrably cannot affect them.

**Acceptance:** fewer builds on the same workloads, cached/fresh equality,
unchanged optimizer convergence and output semantics, native runtime corpus
and self-host fixpoint. The 39.8 seconds is the current full cost envelope;
required first builds will remain.

### C4. Reduce repeated codegen walks without weakening layout/scratch discovery

Profile dry-run eligibility, operand decoding, scratch save analysis, branch
layout, rehearsal and emission in `source/ir/codegen.c`. The dry-run skip path
and an operand-decode cache already exist. Improve their demonstrated misses,
or reuse information whose input generation is unchanged.

Keep branch-width/range decisions, prologue/LR saves, scratch conflicts,
literal pools, switches and frame layout correct. Do not remove the dry or
rehearsal walk globally: they have different consumers. Check generated text
size and runtime, especially for the native compiler whose code executes
through the small shared XIP cache.

**Acceptance:** lower uninstrumented modeled compile time across the corpus,
correct ARM emission/runtime and self-hosting. The 67.97-second dry pass is
6.7% of full compile time, not a 12.8% or older-comment 39% whole-compile gain.

## 5. Execution order and decision gates

1. Preserve this capture as the baseline. Prepare the replay C reduction and
   inliner rejection summaries; investigate K1 before changing loader layout.
2. Make K2's single-stride traversal change independently, then validate the
   lookup-offset extent optimization. Measure each separately.
3. Investigate K3's fixed-key specialization and K4's loop code generation.
   Re-profile before starting allocator or replay-format changes.
4. Refresh the native board-model baseline (C1). Use that ranking to choose
   between C2, C3 and C4; the saved numbers motivate investigation, not an
   assumption that the order is still identical.
5. After each accepted compiler fix, rebuild the native compiler separately,
   verify self-hosting, and measure its effect. Keep the rootfs frozen during
   kernel A/B experiments so compiler and kernel gains remain distinguishable.
6. Rerun the original compilation matrix and selected board workloads, then
   validate the promising combination on physical hardware.

For every patch: record old/new source and binary hashes, repeat A/B in opposite
order, compare warm and cold launch, and save raw samples. Use the same image,
payload, native compiler and QEMU settings for kernel comparisons. Test a
working set exceeding the ROMFS cache's 16 entries; a repeated single path
does not predict cold or varied application launches. Keep a change only when
its intended operation improves and whole-workload performance agrees.

Savings from these items must not be summed: eliminating scans changes inline
opportunities; inlining changes register pressure; replay grouping changes
memory accesses; code size changes XIP behavior. Re-rank after each substantial
improvement. Stop tuning residual ROMFS headers or tiny dispatch costs while
replay, symbol scans and hashing remain dominant.

The existing compiler validation has known baseline failures: eight host IR
volatile-trace assertions reproduced with the old inliner, and the separate
board-model native corpus has 32 baseline failures. Track exact test IDs;
require no new failures instead of attributing those known failures to a new
optimization. A full native self-host fixpoint and physical-board rerun remain
required rollout checks, not results of this analysis.

## 6. Saved evidence and reproduction

Artifacts under `.cache/kernel_ab_20261007/remaining_20261008/`:

- `manifest.json`: source/cross identities.
- `analysis.json`, `analysis.txt`, `analyze.py`: own-function and hot-PC counts,
  copy-size/caller histograms and kernel/rootfs hashes.
- `callers.json`: executed direct call-site attribution for Wyhash/wide multiply.
- `tcc.s`, `wyhash-tcc.s`: generated ARM supporting the loop/hash findings.
- `results.json`, `benchmark.log`, `run-{llvm,control,fixed}-{1,2}.log`:
  compilation samples, object hashes and guest output.
- `capture.py`, `payload/`: six-boot benchmark driver and inputs.
- `build-{llvm,tcc}.log`, `profile-{llvm,tcc}.log`: controlled build/profile logs.

Raw gated instruction profiles are in
`.cache/kernel_ab_20261007/launch_profile/remaining-20261008-{tcc,llvm}.*`.
The earlier cache-only comparison is in
`launch_profile/romfs_cache/RESULTS.md`; the earlier compiler-fix comparison
without the ROMFS cache is in `benchmark_cycle_fix/RESULTS.md`.

With these cached binaries present, repeat the current compilation capture:

```bash
.qemu_smoke_venv/bin/python \
  .cache/kernel_ab_20261007/remaining_20261008/capture.py
```

Repeat one gated profile (the runner uses the plugin-enabled cached QEMU):

```bash
.qemu_smoke_venv/bin/python \
  .cache/kernel_ab_20261007/launch_profile/run_profile.py \
  remaining-20261008-tcc \
  .cache/kernel_ab_20261007/zig-out-tcc-remaining-20261008/bin/yasos_kernel
```

These caches are local evidence, not tracked release artifacts. A clean rebuild
must recreate the stated isolated source/ROMFS/compiler combination and record
new hashes. Do not silently substitute the current native rootfs or default
compiler selection when comparing against this baseline.
