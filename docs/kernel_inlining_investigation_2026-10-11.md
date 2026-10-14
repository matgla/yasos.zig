# Kernel lifecycle inlining investigation, 2026-10-11

The echo profile does **not** establish roughly 2,500 instructions of removable
call overhead. Repeated boots of the same kernel sometimes execute process
teardown inside the marker window and sometimes do not. Forcing the selected
lifecycle helpers inline showed no material workload improvement and increased
kernel `.text` by 5,688 bytes. No compiler policy change was retained.

## Measurement correction

The frozen afternoon TCC echo profile attributed 6,113 kernel instructions,
including one `reap_terminated` entry and eight `get_used_size` entries. Reusing
that exact ELF produced 2,682 instructions with neither helper entered. Three
additional frozen-ELF repetitions produced 2,682, 6,113 and 5,414 instructions.
The LLVM repetitions produced 1,642, 1,721 and 1,642 instructions.

Absence of a physical LLVM symbol is not proof of zero cost: its work may be
inlined into a caller. Here there is an additional confound: the measured
window can contain different lifecycle work. The old inference that echo's
morning-to-afternoon change necessarily came from inliner decisions is therefore
unsupported. An exact instruction counter does not make scheduled work inside
a marker window identical between boots.

## Inliner findings

The installed cross was left unchanged. `TCC_INL_DBG=1` on the current generated
ReleaseFast kernel C showed these post-optimization classifications:

| Helper | Live IR operations | Calls, including machine intrinsics | Auto inline |
| --- | ---: | ---: | --- |
| `claimed_by_any_core` | 20 | 0 | no |
| `region_for_addr` | 21 | 0 | no |
| `get_used_size` | 28 | 1 | no |
| `mark_free` | 91 | 0 | no |
| `free_pages` | 103 | 13 | no |
| `reap_terminated` | 184 | 16 | no |
| `yasos_kheap_lock` | 31 | 3 | no |
| `yasos_kheap_unlock` | 23 | 4 | no |

`claimed_by_any_core` and `region_for_addr` qualify for the small-loop class,
but `inline:readonly_loops` subsequently revokes their eligibility. This rule
preserves call boundaries so repeated read-only scans can share their results.
Disabling it demonstrated that these two helpers can inline; it did not show
a consistent whole-workload benefit. The existing non-static wrapper fix is
already in this checkout and does not explain these static helpers.

## Controlled experiments

All variants used the same installed cross, rootfs, Zig configuration and
ReleaseFast build. Temporary compiler wrappers changed only generated C or
the compiler's debug pass setting. Production C and Zig sources were unchanged.

- **Control:** ordinary `-O2` kernel build.
- **Read-only loops:** set `TCC_DISABLE_PASS=inline:readonly_loops`.
- **Heap locks:** mark the two kernel heap-lock helpers `static inline
  __attribute__((always_inline))` in generated C.
- **Lifecycle chain:** force those two helpers plus `get_used_size`,
  `region_for_addr`, `mark_free`, `free_pages`, `claimed_by_any_core`,
  `reap_terminated`, `release_pid`, and `ProcessInterface.deinit` inline.
- **Loader maps:** separately force the current `LoadedModule` integer map's
  `Custom.getIndex`, `HashMap.getPtr` and `HashMap.remove` inline.

The lifecycle variant has no defined out-of-line symbols for those ten
helpers. It tests an aggressive source-directed strategy, not every possible
future inliner cost model. The other allocator helpers were not forced inline.

Five fresh boots per variant per workload, 75 boots total, produced the
following **kernel-only instruction counts**. Parentheses contain sample
standard deviations; they are not timing measurements.

| Variant | Echo mean (SD) | True launch mean (SD) | `ls /bin` mean (SD) | `.text` growth |
| --- | ---: | ---: | ---: | ---: |
| Control | 4,054 (1,879) | 149,486 (2,738) | 1,975,261 (6,209) | 0 B |
| Read-only loops | 3,412 (1,518) | 147,512 (46) | 1,977,865 (3,931) | +864 B |
| Heap locks | 3,404 (1,614) | 150,184 (2,483) | 1,974,993 (5,306) | +24 B |
| Lifecycle chain | 4,042 (1,863) | 148,905 (1,432) | 1,973,804 (3,975) | +5,688 B |
| Loader maps | 3,409 (1,512) | 149,866 (3,901) | 1,975,529 (4,874) | +1,408 B |

All 75 runs returned zero, and each workload had one identical output hash
across all variants. This is workload validation, not a compiler regression
suite or self-host fixpoint check.

The lifecycle variant's `ls /bin` mean improved by just 1,457 instructions
(0.074%), within the observed variation. Echo samples without teardown were
identically 2,682 instructions in both control and lifecycle variants. Control
samples containing teardown were 6,113, versus 6,083 in the lifecycle variant:
the apparent several-thousand-instruction opportunity became a 30-instruction
difference in those samples. Inlining relocates necessary loop, allocator and
cleanup work; it does not remove it all.

The separate loader-map experiment removed all three helpers' out-of-line
definitions, but its `ls /bin` mean was 268 instructions higher than control,
also within the variation. It does not establish an inlining opportunity.

## Artifacts and reproduction

Artifacts live in `.cache/inlining_20261011/`:

- `base.trace`, `readonly.trace`: compiler classification and expansion logs.
- `readonly-tcc`, `locks-tcc`, `chain-tcc`, `maps-tcc`: compiler wrappers.
- `control/`, `readonly/`, `locks/`, `chain/`, `maps/`: kernel ELFs and initial runs.
- `measure.py`: repeat-run driver, using `scripts/kernel_compare.py --_worker`.
- `samples.json`, `measure.log`, `samples/`: first 60 results and per-PC CSVs.
- `measure_maps.py`, `maps-samples.json`, `measure-maps.log`: 15 loader-map runs.

Build each wrapper variant with the existing installed cross:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/inlining_20261011/zig-global" \
ZIG_LOCAL_CACHE_DIR="$PWD/.cache/inlining_20261011/zig-local" \
zig build -Doptimize=ReleaseFast -Dkernel_cc=tcc \
  -Dkernel_tcc=.cache/inlining_20261011/chain-tcc \
  --prefix .cache/inlining_20261011/chain/tcc
python3 .cache/inlining_20261011/measure.py
```

Use `readonly`, `locks` or `maps` in place of `chain` for the other experiments;
omit `-Dkernel_tcc` for control. Run `measure_maps.py` for the map samples.
The wrappers depend on this checkout's paths and
generated symbol names and deliberately reject unexpected match counts.

## Decision

Keep the current inliner policy. These measurements do not justify a general
threshold increase, disabling read-only loop protection, or forcing the whole
teardown chain inline. Further work should target a demonstrated call-site
saving such as eliminated aggregate marshalling or constant specialization,
and compare equal executed lifecycle work. Forced loader-map inlining also
showed no measurable gain in the workloads tested here.
