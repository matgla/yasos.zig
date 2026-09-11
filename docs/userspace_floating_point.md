# Userspace floating point

How the rootfs — every library, every application, and the on-device C compiler
— gets built against the CPU's floating point hardware instead of software
floating point, and what that costs.

Configured by **`CONFIG_BUILD_USERSPACE_HARDWARE_FP`** (menuconfig → Build
options → *Hardware floating point for userspace code*), on by default wherever
`CONFIG_CPU_USE_FPU` is set.

## What the switch does

The mode is compiled into the toolchain rather than passed per target. Both tcc
stages in `build_rootfs.sh` are configured with

```
-DCONFIG_TCC_DEFAULT_FPU=<arm_fpu_type enumerator>
```

so `armv8m-tcc` (cross) and `/usr/bin/tcc` (on device) *default* to that FPU.
An explicit `-mfpu=` on a command line still wins, and `-mfpu=none` opts a single
translation unit back out.

Compiling it in rather than adding `-mfpu=…` to `ROOTFS_OPT_CFLAGS` is
deliberate: only about half the Makefiles under `libs/` and `apps/` thread that
variable into their `CFLAGS`, none thread it into `LDFLAGS`, and the link step is
what selects the matching `__aeabi_*` runtime. One knob in the compiler reaches:

- all libraries and applications, including the ones with hardcoded flags
  (`yasos_curses`, `textvaders`, `yasvi`, `zork`, toybox),
- tcc's own native bootstrap,
- every link, so `librp2350fp` / `libvfpv4sp` / `libsoftfp` is chosen correctly,
- programs compiled later *on the device*, which then match the libraries they
  link against.

The per-CPU FPU name comes from `CONFIG_BUILD_USERSPACE_FP_MFPU`, set by the CPU
because it names silicon:

| CPU | `-mfpu` | float | double |
|---|---|---|---|
| `rp2350` | `rp2350` | FPv5-SP FPU, inline `vadd/vsub/vmul/vdiv.f32` | DCP on CP4: inline add/sub/compare, rest via `librp2350fp` |
| `qemu_mps2`, `qemu_mps3` | `fpv5-sp-d16` | same | software (`libvfpv4sp`; QEMU's Cortex-M33 has no double unit and no CP4) |
| anything else | — | software (`libsoftfp`) | software |

**The float ABI does not change.** `-mfpu` only says which instructions may be
emitted inline; FP arguments and results stay in general-purpose registers
(softfp). So there is no flag day: objects and `.so` files built before and after
the switch stay link-compatible, and a plugin compiled on the device against a
soft-float image still loads.

## Three ways to reach a double, and how to ask for each

A double operation can be done three ways on this part, and they are not a
spectrum of one thing — they differ in *where the arithmetic lives*:

| | where the work happens | how it is reached | flags |
|---|---|---|---|
| **software** | `libsoftfp`, bit-exact IEEE-754 in C | `__aeabi_` call | `-mfpu=none` |
| **hardware, behind a call** | `librp2350fp`: DCP sequences and FPv5-SP | `__aeabi_` call | `-mfp-inline=none` |
| **hardware, inline** | the caller's own instruction stream | no call | *(default)* |

The middle row used to have no way to say it. It could only be reached by
pairing `-mfloat-abi=soft` with a hardware `-mfpu`, which meant "emit no FP
instructions" and yet quietly linked a runtime full of them — and wrote a YAFF
header that asked the loader for nothing while the image needed a DCP. Now
`-mfloat-abi=soft` means what it says (no FP instructions *and* the software
runtime), and **`-mfp-inline=none`** is the flag for "keep this board's FP
hardware, put every operation behind a call".

The third row is a mixture by construction, and honestly so: the backend inlines
what has a short sequence — on RP2350 float add/sub/mul/div and double
add/sub/compare — and calls the runtime for the rest. Double multiply, double
divide and every conversion are library calls in all three rows, which makes
them the control when comparing: a conversion that moves between two columns
means the measurement moved, not the code.

`apps/fpbench` builds one source four times along exactly these lines (the
fourth is the middle row linked statically, so the dynamic linkage can be
priced on its own) and prints the table.

## One shared runtime, or a copy in every module

**`CONFIG_BUILD_USERSPACE_FP_SHARED`** (on by default) decides whether the
`__aeabi_` runtime is a shared library or is copied into each module out of an
archive. It is delivered the same way as the `-mfpu` default above —
`-DCONFIG_TCC_DEFAULT_FP_LIB=ARM_FP_LIB_SHARED` compiled into both tcc stages,
because this is a *link* decision and no Makefile in the tree threads `LDFLAGS`
— and `-mfp-lib=static|shared|auto` overrides it per invocation.

Off, every shared object and every program carries its own copy, and one
consequence is not obvious: **the copy that wins is libc's.** The loader
resolves an import by walking the image's dependencies in order
(`Module.find_symbol` over `children`, appended in import order), libc comes
first in every link, and libc.so re-exports the fifteen double entry points it
absorbed. So a program built with one `-mfpu` would run libc's implementation
from another, and the flag it was compiled with decided nothing.

On, there is one copy in the system, and an image's own choice sticks. tcc binds
the FP runtime **ahead of libc** in the import table for exactly this reason.

The cost is real: an `__aeabi_` call that was a local `bl` becomes a
cross-module call through the GOT with the R9 save/restore that goes with it.
Operations the backend inlines never became calls and do not pay; the ones that
did — double multiply and divide above all — do. `apps/fpbench`'s `hwlib` and
`hwstatic` arms differ in nothing else, so their difference is that price.

## Every image says which machine it needs

An image compiled for the wrong part does not fail politely — inline
`vadd.f32` on a CPU whose FPU was never enabled at CPACR is a UsageFault, and a
mismatched float ABI is worse: no fault at all, just wrong numbers. So each YAFF
module carries an **architecture section** naming what it requires, and the
loader refuses anything it cannot satisfy.

The section (`YaffArchSection` in `libs/tinycc/source/obj/tccyaff.h`) sits between the
module name and the imported-library table, at `YaffHeader.arch_section_offset`,
and holds:

| field | meaning |
|---|---|
| `arch` | instruction set (`YaffArch`; also in `YaffHeader.arch`) |
| `fpu` | which `-mfpu` the code was built for — diagnostics |
| `float_abi` | soft / softfp / hard |
| `required_features` | bitmask: single-precision FPU, double-precision FPU, DCP |

`required_features` is the machine-checkable part; `fpu` names the intent so an
error message can say *why*. The bits are keyed on what `-mfpu` selected rather
than on which operations the backend happened to inline, because the module also
links an FP runtime (`librp2350fp`, `libvfpv4sp`) whose instructions are just as
much a requirement — and because "this part has a DCP" is stable while "dmul is
inline this month" is not.

The kernel builds the matching machine profile from KConfig in
`source/kernel/modules.zig` (`machine_profile`) and hands it to the loader at
init. Features are only advertised when the kernel actually enables the unit: on
a `CONFIG_CPU_USE_FPU=n` build nothing is claimed, and images with inline FP are
refused rather than left to fault. Every module is checked, shared libraries
included, so a `libm.so` for the wrong part is caught at the point it is pulled
in.

A refusal is reported as `ENOEXEC` and logged with the mismatch, e.g.

```
[ERR][yasld] image needs fpu-sp+dcp (built for fpu 'rp2350'), this machine provides fpu-sp -- missing dcp
[ERR][yasld] Refusing to load module: UnsupportedCpuFeatures
```

`tests/smoke/yaff_arch_test.py` covers the rejections by patching one field of a
known-good executable at a time; `scripts/readyaff.c` dumps the section.

The section arrived with **YAFF format version 2**, and the loader refuses
version 1 outright — so switching to a kernel with this change requires a rootfs
rebuild (`./build_rootfs.sh -c -o rootfs.img`), not an incremental one.

Measured on RP2350 (tcc `-O1`, `tests/benchmarks/bench_double.c`): 21–29x on
double add/sub/compare, ~2.8x on multiply, 1.14x on divide (the control — divide
has no DCP sequence). See `libs/tinycc/docs/plan_rp2350_dcp.md` for the full
table and the conformance results.

## Switching the option

Changing the mode changes code generation for every object, but `make` only looks
at timestamps — an incremental build would keep soft-float objects and link them
against a hardware FP runtime. `build_rootfs.sh` records the active mode in
`libs/tinycc/.yasos-build/fp-mode` and forces a clean rebuild when it changes, so
just toggling the option and rebuilding is safe (and slow: it is a full
bootstrap). The stamp records the runtime linkage too (`rp2350/shared`), because
switching `CONFIG_BUILD_USERSPACE_FP_SHARED` relinks every image while changing
no source file at all — the stale `.so` files would keep their absorbed copies
and go on winning every lookup. `scripts/run_qemu_smoke.sh` compares the same
string before deciding an image is fresh enough to boot.

## Two things to know about doubles on RP2350

### 1. Subnormals flush to zero

`-mfpu=rp2350` is **not** fully IEEE-754 for subnormal doubles. The DCP flushes
subnormal operands and results to zero and offers no path that doesn't;
pico-sdk's `double_aeabi_dcp.S` behaves the same way and says so in its own
comments. Everything else — including all NaN, infinity and signed-zero handling
— is bit-identical to the software implementation, verified over 3057 double and
2803 float vectors on hardware. Single precision is unaffected: FPv5-SP is fully
IEEE.

Concretely: `1e-310 + 1e-310` yields `0.0` in a hardware FP build and the correct
subnormal in a soft-float build. Code that depends on subnormal doubles must
build with `CONFIG_BUILD_USERSPACE_HARDWARE_FP` off, or compile the sensitive
translation unit with `-mfpu=none`.

Code that needs to *know* can test `__TCC_DOUBLE_FLUSHES_SUBNORMALS__`, which tcc
defines only for `-mfpu=rp2350` (alongside `__TCC_FPU_RP2350__`). `__ARM_FP` is
12 for both the DCP and a real FPv5-D16, so it cannot make this distinction.
`tests/fp/fp_conformance.c` uses the macro to accept exactly the double-bank
mismatches whose operands or reference result are subnormal — the deviation
above and nothing wider — so `421_fp_conformance` stays a meaningful gate on
hardware instead of permanently red. `tests/benchmarks/run_fp_conformance.py`
reaches the same verdict from the outside with `--allow-ftz`.

### 2. The context switch preserves DCP state

The FPU needs no help from the kernel: the hardware stacks `s0-s15` on exception
entry and the software frame already carried `s16-s31`. The DCP is different.

It is not an FPU. It holds X, Y and EFD state that no exception entry touches,
and a double operation is a *sequence* of CP4 instructions — `WXUP; WYUP; ADD0;
ADD1; NRDD; RDDA` for an add. Preempt one of those six instructions, let the next
process start its own DCP sequence, and the first resumes on top of foreign
state: a wrong double result, silently, with no fault. At a 5 ms switch period
that is a rare event, and a silent one, which is the worst combination.

So on a `CONFIG_CPU_HAS_DCP` part with userspace hardware FP enabled, the context
switch saves and restores that state (`source/arch/armv8-m/context_switch.S`,
`DCP_SAVE_STATE` / `DCP_RESTORE_STATE`, gated by `YASOS_SAVE_DCP_STATE` from
`build.zig`; the matching frame slot is in `SoftwareStoredRegisters` in
`source/arch/arm-m/process.zig` — the two must stay in sync).

The common case costs one non-engaging peek: `PCMP` reports whether a sequence is
actually in flight, and only then are the six state words read. The frame slot is
a fixed 28 bytes either way.

Why the flag survives a second preemption: `PCMP`/`PXMD`/`PYMD` are the
non-engaging peek encodings (`mrc2`/`mrrc2`), `REFD` is an engaging read that
*clears* the flag — which is why the save does it last — and `WXMD`/`WYMD`/`WEFD`
are engaging writes, so the restore leaves the flag set and a process preempted
twice inside one sequence is saved twice.

This is the scheduler-side half of the "preemptor saves" contract in the tinycc
plan. The library-side half (an ISR that does double arithmetic reaching the DCP
through `__aeabi_*` entry points that save/restore) is **not** implemented in
`librp2350fp` yet — see phase 3d in `libs/tinycc/docs/plan_rp2350_dcp.md`. Kernel
interrupt handlers do not use the DCP: the kernel is compiled by
arm-none-eabi-gcc, which has no DCP support, and its doubles come from libgcc.
Do not add double arithmetic to an ISR in a userspace library until that half
lands.

## Turning it off

```
zig build menuconfig    # Build options -> Hardware floating point for userspace code
./build_rootfs.sh -c -o rootfs.img
```

With the option off the toolchain gets no `-DCONFIG_TCC_DEFAULT_FPU`, every FP
operation becomes an `__aeabi_*` call into `libsoftfp`, the DCP save/restore
disappears from the context switch, and doubles are fully IEEE-754 again.

## Related

- `libs/tinycc/docs/plan_rp2350_dcp.md` — the DCP port: sequences, conformance
  numbers, benchmark tables, remaining phases.
- `libs/tinycc/docs/plan_vfp_hard_float.md` — the VFP codegen plan (floats living
  in `s0-s15` is still open; today every inline op moves through GPRs).
- `libs/tinycc/lib/fp/` — the four FP runtimes and the `check-self-contained`
  gate that keeps them from leaning on libgcc.
