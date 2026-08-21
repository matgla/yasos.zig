<!-- scriptforge:scene 43194696-8497-49d2-9fb4-432ee1b725e7 -->
SCENE 01 · 2:00 · WELCOMING, INFORMATIVE, ENERGETIC

# Intro & Project Overview

## Voiceover

Hi, welcome into the next episode of my series!

If you're new here, let me catch you up. I'm building a custom computer from scratch. It starts with the MSPC motherboard that I designed, having RP2040 MCU. Upgraded to the RP2350 for MSPCv2. With external PSRAM, the system has 8MB of RAM and 16MB of Flash. 

On top of that hardware, I'm writing a custom operating system called YasOS in Zig. And recently, I reached a massive milestone: I successfully ported the TinyCC C compiler to run natively on the RP2350 supporting armv8m thumb machine code generation. That means my board can now compile code for itself. It's nearing a fully self-hosting loop—the only piece I haven't solved yet is recompiling the OS itself. 

Previoulsy we saw the first version of TinyCC. It could compile the userland and run simple 'Hello World' programs, but it was barely functional—it was essentially just a direct translation from the AST to machine code. It had no IR, no optimizer, and no register allocator. The ARM backend was full of bugs, and it was incredibly slow.

So, over the last six months, I've been doing a complete rewrite. I'll show you how I moved from direct translation to a full optimizing backend with a three-address IR and an SSA register allocator, why I integrated the GCC torture suite to hunt down thousands of hidden bugs that only manifested on the target, and how I battled the RP2350's PSRAM and XIP bottlenecks to make this compiler performant enough to run nearly the entire GCC torture suite—over 4,000 files—directly on the microcontroller.

This entire approach was heavily motivated by Falbesoner's research on pushing compiler architectures to their absolute limits. By implementing a three-address code IR and global register allocation, I've finally brought the optimization capabilities close to what you'd expect from GCC.

<compare old TCC / GCC / TCC -O2>

Let's get into it.

## Scene Description

Desk setup, dark room, blue/purple RGB backlighting, dual monitors in frame. Welcoming and energetic, leaning in. The scene cuts between the host to camera and clean, minimalist overlays that build as they are spoken.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Talking head — creator at desk, dark room with blue/purple RGB backlighting, dual monitors visible, leans in slightly on the welcome | 0:00-0:04 | to record |
| Cut back to talking head — creator gestures to emphasize the turn from "it booted" to "it was barely functional" | 0:20-0:32 | to record |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Clean, minimalist overlay diagram appearing next to the creator; hierarchy builds as spoken: `MSPCv2 Board` → `RP2350 MCU` → `YasOS (Zig)` → `TinyCC` | 0:04-0:20 | to animate |
| Quick montage of text overlays popping up in sync with the spoken points: `SSA Backend`, `GCC Torture Suite`, `Optimizations`, `PSRAM/XIP Bottlenecks` | 0:32-0:50 | to animate |

## Notes

Include the requested 1-minute overview for newcomers as per reference notes. Establish the full stack context (MSPCv2 -> RP2350 -> YasOS -> TinyCC). Bridge from last episode's 'it runs' to the current reality (slow/buggy) to justify the 6-month rewrite focus. Visuals should support the overview without re-explaining hardware assembly details already covered.

## Change Request

**RETIME** header `2:00` → `2:15`.

**CUT** the sentence beginning "This entire approach was heavily motivated by Falbesoner's research…" — the reference cannot be sourced anywhere in the repo or the literature. If a citation is wanted, use Fabrice Bellard for TCC itself, or Braun et al. 2013 for the SSA construction algorithm.

**CUT** the `<compare old TCC / GCC / TCC -O2>` placeholder. That comparison becomes its own scene — see the new scene inserted before *Live Demo*.

**FIX** the self-contradiction in paragraph 3: "essentially just a direct translation from the AST to machine code. It had no IR, no optimizer, and no register allocator." Upstream TCC has no AST either — it emits machine code as it parses. Replace "from the AST" with "from source, as it parsed".

**REPLACE** paragraphs 4-6 (from "So, over the last six months…" to "Let's get into it.") with:

> So I spent six months rewriting it. Two and a half thousand files, four hundred forty-five thousand lines added, sixty-three thousand deleted. It now has a three-address IR, SSA form, an SSA register allocator, and around a hundred and eighty optimization pass files. Six other CPU backends were deleted to get there.
>
> Here's where that lands. My full regression suite is over four thousand test files, and every one of them gets compiled on the board — at minus O0, minus O1 and minus O2. All three. That whole matrix now runs in fifty-eight minutes. Under an hour, on a microcontroller.
>
> And the configuration I actually live in day to day, the minus O0 leg, went from fifty-four minutes to ten minutes and thirty-six seconds — in a single week, and almost none of it by making the compiler faster.
>
> That's the story: six months building a compiler, then one week discovering that almost everything I believed about why it was slow was wrong.
>
> Let's get into it.

**WHY.** The draft's "~50 minutes / under an hour" is right for the full `-O0 -O1 -O2` matrix but it buries the actual result. Two different numbers exist and they must never merge on screen:

- **58 min** — the whole matrix, which is what `scripts/remote_smoke_tui.py` runs by default (`SMOKE_TCC_ALL_OPT_LEVELS`, lines 186-193). **VERIFY**: no full-matrix run is timed anywhere in the docs. Produce one and read the wall out of `workdir/logs/latest/run_info.txt`.
- **54:20 → 10:36** — the `-O0` leg, −80.5% in one week. Every figure in `docs/remote_smoke_speedup_plan.md` is `-O0` only (see its line 108). This is the story scenes 05-08 tell and the draft never mentioned it.

Note 10:36 × 3 = 31:48, so 58 is *not* derivable from it — `-O1`/`-O2` compiles cost far more per file.

**ADD C-Rolls:**

| Description | Timing | Source |
| --- | --- | --- |
| Diff-stat card typing in: `2,429 files · +445,120 / −62,727` | 0:40-0:52 | to animate |
| Hero card A: `whole suite · -O0 -O1 -O2 · 58:00` | 1:12-1:24 | to animate |
| Hero card B: `-O0 leg: 54:20` crossed out, `10:36` slams in beneath it, subtitle `4,467 passed / 87 skipped · 2026-08-06` | 1:24-1:40 | to animate |
| Beauty shot of the tuned MSPCv2 on the desk, RGB backlight, SD card in | 1:40-1:55 | to record |

**RETIME C-Roll 2** ("Quick montage of text overlays…") to `0:52-1:12` and change its labels to `Three-address IR`, `SSA`, `Register allocator`, `~180 pass files`, `6 backends deleted`.

**VERIFY** "8MB of RAM and 16MB of Flash". 16 MB flash is correct for both boards (`CONFIG_FLASH_MEMORY_SIZE="16MB"`). The 8 MB PSRAM figure is not in any defconfig — it is detected at runtime, and 8 MB is the Pico Plus 2's part. Confirm the MSPCv2's own PSRAM before stating it.

**BOARD.** Every number in this script was measured on a **Pimoroni Pico Plus 2** — that is the CI rig (`DEFAULT_CONFIG["board"]`). `configs/mspc_defconfig` is currently a different machine: 150 MHz, no `FLASH_XIP_DESELECT_NS`, no `FLASH_XIP_CONTINUOUS_READ`, `PSRAM_CE_MIN_DESELECT_NS=50`, SPI not SDIO, and no `CONFIG_PROCESS_SMP` line at all. If MSPC is tuned and re-measured before the shoot, no caveat is needed. If it is not, add this after the 10:36 line and stay consistent for the rest of the episode:

> One thing up front — the benchmarks in this video are measured on a Pico Plus 2, because that's the board bolted to my CI rig. The MSPCv2 is where it's all going.

What is not an option is a 10:36 timer over MSPC footage with no caption; someone will diff the defconfigs.

---

<!-- scriptforge:scene db43021b-3094-4c06-8921-7f3e8cc6dbb1 -->
SCENE 02 · 1:30 · URGENT, TECHNICAL

# GCC Test Suite

## Voiceover

I decided to run the full GCC torture suite on the board. That's over 4000 test files designed to stress-test compiler backends, verify feature completeness for C standards—covering complex numbers, floats, long longs, and more—and catch bugs in codegen. But execution on the raw, unoptimized code was painfully slow. Running the whole suite on -O0 alone would take hours. To make the torture suite viable for regular use, I needed to speed things up significantly. That led directly to the need for an optimizing compiler backend.

So I set a hard target: the full suite on -O0 tests only, in under half an hour. When I first kicked it off, I didn't wait for it to finish. After about an hour I dropped the run — progress was sitting around 25% and barely moving. That was the moment I knew the single-pass backend had to go. From here on, every optimization pass had to pay for itself in compile time.

And the result? All of -O0, -O1 and -O2, plus my own custom tests, complete in about fifty minutes. Under an hour, exactly where I wanted it. Along the way I fixed hundreds of bugs and miscompilations — a lot of them introduced by the optimizations themselves, but the speed win was worth it. After the rewrite, the full GCC test suite runs on my test hardware in CI, completing in less than an hour across all supported optimization levels alongside my custom tests. I'm really happy with that result.

## Scene Description

Close-up of the terminal emulator. The GCC torture suite is compiling and running test files rapidly. A text overlay shows 'Target: < 1 hour' and a live timer counting up. As tests pass, a progress bar fills and the timer slows visibly. Cut to a split-screen comparison: before (unoptimized) showing hours, after (optimized) showing minutes.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Overlay showing test progress percentage and elapsed time decreasing as optimization passes are enabled, with a bar chart contrasting initial hours vs. final <1 hour. | 0:45-1:15 | to record |
| Overlay showing elapsed time passing one hour with progress frozen near 25%, then the run being aborted and the log file closed. | 0:30-0:45 | to record |

## Notes

Reference: v0.1.0_tinycc_changes.md - 'Note: Why I needed optimizations'. The suite takes 4000+ tests. Goal was 0.5h on -O0 but achieved all -O0/1/2 in ~50min.

## Change Request

**RETITLE** `GCC Test Suite` → `The Test Suite That Forced the Rewrite`.
**RETIME** header `1:30` → `2:30`. (Draft was 250 words ≈ 1:40 of speech in a 1:30 slot.)

**REPLACE** the entire voiceover with:

> I decided to run the GCC torture suite on the board. Over four thousand C files, written by the GCC developers specifically to break compiler backends — complex numbers, long longs, bitfields, every corner of the C standard, and a lot of things that are technically legal and nobody sane writes.
>
> With the single-pass compiler, I kicked off a run and walked away. After about an hour it had reached roughly a quarter, and it was not speeding up. I killed it.
>
> That was the decision point. Not "the compiler produces bad code" — I already knew that. It was that the compiler was too slow to tell me how bad, because I could never finish a run. You can't fix what you can't measure, and I couldn't measure.
>
> So the rewrite had a very specific goal, and it was not elegance. I needed the cross compiler to be fast enough, and to generate code good enough, that a native TinyCC built with it could get through the whole suite in an evening.
>
> That worked. Today the whole matrix — every test at minus O0, minus O1 and minus O2, plus my own suites — runs in fifty-eight minutes on one board.
>
> But the number I want to talk about is a narrower one. Most days I'm not running all three levels. I'm running the minus O0 leg, because that's the fast correctness check, and that's the loop I live in. At the end of July it was fifty-four minutes and twenty seconds.
>
> Then I spent one week doing nothing but measuring the system underneath it. It went to ten minutes thirty-six. Same tests, same pass set, four thousand four hundred sixty-seven passing and eighty-seven skipped, on both ends.
>
> Five times faster, in a week. And almost nothing about it was what I expected. The overclock wasn't it. The syscalls weren't it. Using both cores made it worse. The single biggest fix was a number copied out of the wrong row of a datasheet.
>
> That week is the rest of this video.

**WHY.** The `-O0` ladder from `docs/remote_smoke_speedup_plan.md`, same pass set throughout: 2026-07-30 baseline **3,260 s (54:20)**, 4,466 passed / 79 skipped → 2026-08-03 **1,904.6 s (31:44)** → 2026-08-05 **1,043.2 s (17:23)** → 2026-08-06 **636.60 s (10:36)**, 4,467 passed / 87 skipped. **−80.5%.**

The 54:20 baseline **already includes** the rewritten optimizing compiler. So the rewrite bought the ability to finish a run at all; the 54 → 10 came from measuring the system, not from the compiler. Keeping those two apart is what makes the episode honest, and it is what sets up scenes 05 through 08.

Say "-O0" out loud the first time you say 10:36, then let the on-screen badge carry it.

**VERIFY** the "killed at ~25% after an hour" run. Nothing in the docs records it and each run wipes `logs/`. Either find a log to put on screen or narrate it explicitly as recollection.

The corpus is ~4,545 source files and the run reports 4,531 tests, so "over four thousand" is safe.

**ADD B-Rolls:**

| Description | Timing | Source |
| --- | --- | --- |
| `ls gcc.c-torture/execute/*.c \| wc -l` and the corpus size on screen | 0:05-0:20 | screen capture |
| Full-matrix line `-O0 -O1 -O2 · 58:00`, styled distinctly, sitting above the ladder | 0:55-1:15 | to animate |
| Three-step ladder card animating in, `-O0` badge attached: killed → 54:20 → 10:36 | 1:15-1:50 | to animate |
| Real `run_info.txt` from the 2026-08-06 numbered run directory, pass/skip counts and opt levels visible | 1:35-1:50 | screen capture |

**REPLACE** the Scene Description's "Target: < 1 hour" framing: the ladder card is the visual, the `-O0` label is attached from the first frame and never removed, and the 58-minute figure sits above it in a distinct style so the two can never be read as the same measurement.

**NOTE FOR LATER SCENES.** The four surprises in the last spoken paragraph are a cold-open promise, paid off individually in scenes 05 and 08 and restated as a set in the outro. If one of those scenes is cut, cut its line here too.

---

<!-- scriptforge:scene b8afcb96-12bb-4513-81a5-6e847c7e2ea7 -->
SCENE 03 · 5:0 · TECHNICAL, ANALYTICAL

# From Single-Pass to Multi-Pass: Introducing IR

## Voiceover

The original TinyCC was a single-pass compiler. There was no abstract syntax tree, no intermediate representation, no optimizer, no register allocator. It translated C constructs directly to machine instructions as it parsed them. That approach is great if you only need to produce correct code quickly, but it leaves no room for optimization. And on a microcontroller, optimization is what separates a demo from a daily driver.

To enable optimizations, I had to introduce an Intermediate Representation, or IR, without building a full AST to keep memory footprint low. I chose Three-Address Code as my IR. TAC is simple: every instruction has at most one operator and uses temporaries. For example a = b + c becomes t1 = b + c; a = t1. That representation is easy to transform and keeps RAM usage low on RP2350. Each TAC instruction is a fixed-size structure - opcode, two sources, destination, and a jump target for branches. No per-instruction heap allocation, no pointer chasing. A whole function is just a contiguous array in memory.

But TAC on its own is a linear instruction list. To make real optimization possible, I built a control-flow graph on top of it, grouping instructions into basic blocks. Now a pass can reason about the whole function, not just one instruction at a time. That IR let me separate parsing from code generation and run multiple passes over the same data.

From parsing I build TAC, then convert to SSA form so each variable is assigned once, then run an SSA register allocator to map temporaries to registers. SSA is what makes the optimizer tractable. In SSA, every variable has exactly one definition, and join points carry phi functions. That single property means data-flow analysis becomes trivial: a use is always dominated by its definition. After that, roughly 180 optimization passes run - constant folding, dead code elimination, common subexpression elimination, loop optimizations, and a dozen other families. Each pass is small, but together they transform the IR into something a human would have written.

I also added hardware floating point support. The RP2350 has a hardware FPU, but the old single-pass backend never actually used it - it emitted software floating-point calls. With the IR, floating-point operations become just another TAC instruction, so the register allocator can schedule them on the FPU directly.

This shift to a multi-pass architecture is what made serious optimization possible. It cost me the entire old code generator - there was no clean way to bolt an IR onto that backend. The register allocator alone is a whole compiler project. But the payoff is measurable: the same source tree that was a single-pass Thumb translator is now a three-address IR compiler with SSA, a register allocator, and roughly 180 optimization passes. And it all still fits on an RP2350.

## Scene Description

Diagram showing the original Single-Pass flow (Parse -> Codegen) with a red 'no IR / no optimizer' annotation. Diagram showing the new Multi-Pass flow (Parse -> TAC IR -> SSA -> Opt Passes -> Codegen) with labels for three-address IR, SSA form and SSA register allocator. Whiteboard diagram of TAC definition with rule t = op t1 t2, and a memory-layout inset showing fixed-size TAC instruction: opcode, src1, src2, dst, jump target. Animation of TAC instructions being grouped into basic blocks and connected into a control-flow graph. Split-screen code example: C source on left, TAC IR in center, SSA after conversion on right, with phi functions called out by a highlight circle. Animation of optimization passes on IR nodes with constant folding and dead store elimination highlighted. Close up of IR nodes being manipulated and SSA transformation visualization. FPU scheduling pass: floating-point TAC ops highlighted and mapped directly onto hardware FPU instructions. On-screen counter showing optimization pass count rising from 0 to ~180. End card for the section: side-by-side compiler pipeline before and after, with the '~180 passes' badge.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Whiteboard TAC rule t = op t1 t2 with memory-layout inset showing opcode / src1 / src2 / dst / jump target | 0:50-1:30 | to record |
| Animation of TAC instructions being grouped into basic blocks and connected into a control-flow graph | 1:30-2:00 | to record |
| Split-screen C source vs TAC IR vs SSA, phi functions highlighted with a circle | 2:00-3:00 | to record |
| FPU scheduling close-up: floating-point TAC ops mapped directly onto hardware FPU instructions | 4:00-4:30 | to record |
| End card: side-by-side single-pass vs multi-pass pipeline, ~180 passes badge | 4:30-5:30 | to record |

## Notes

Correction: Original TCC was single-pass without AST. Content now reflects introduction of IR for multi-pass optimization.

Extension details drawn from v0.1.0_tinycc_changes.md covering submodule range cae3a049→fb3a6c57. Original TCC described as single-pass without AST/IR; IR introduced without full AST to enable multi-pass optimizations.

TAC description and transformation example added to make this the core 5-minute segment. IR introduced without full AST per v0.1.0_tinycc_changes.md.

Extended to cover the full IR pipeline: TAC instruction layout, control-flow graph construction, SSA/phi motivation, and hardware FPU scheduling. The single-pass description is preserved from the original note; new content is grounded in v0.1.0_tinycc_changes.md (three-address IR, SSA, SSA register allocator, ~180 passes, VFP support).

## Change Request

**RETIME** header `5:0` → `4:00` (also fixes the malformed timecode; the B-roll table currently runs to 5:30 in a 5:00 scene — retime it to land at 4:00).

**REPLACE** the hardware-FP paragraph ("I also added hardware floating point support…") with:

> I also got floating point onto the hardware, and the RP2350 is strange here. It has a single-precision FPU and no double-precision unit at all — what it has instead is a "double coprocessor" on slot four, so for doubles the compiler emits inline sequences for add, subtract and compare. There's a genuinely good story in that one, including the fact that the ARM calling convention passes doubles in `d0` through `d7` even on a chip that cannot do double arithmetic. It's self-contained enough that I'm going to do it as its own short rather than derail this.

**INSERT** after the ~180-passes paragraph:

> And they are not a hardcoded sequence. There's a pipeline table. Every pass is registered with a name — `ssa:branch`, `loop:licm` — and gated by a flag. Which matters more than it sounds, and I'll show you why in a minute.

**REPLACE** the closing paragraph ("This shift to a multi-pass architecture…") with:

> All of this cost me the entire old code generator. There was no clean way to bolt an IR onto it. And it cost six CPU backends — x86, x86-64, ARM64, RISC-V, C67, and the .NET IL one. Twenty-five thousand lines, deleted, because carrying six targets through a new IR was never going to happen. `tccgen.c` — eight and a half thousand lines, the heart of upstream TCC — is gone too, split into about fifty files.
>
> What's left is one target, done properly.

**PASS COUNT — be careful on camera.** The defensible figure is **~180 pass *source files*** (210 `.c` under `source/opt/` today), ~86,900 lines; the optimizer is the largest subsystem in the compiler and is bigger than the rest of it. The runtime registry is much smaller and about 65 unique `phase:name` pass IDs are greppable. Say "a hundred and eighty pass files" and be ready to show `find source/opt -name '*.c' | wc -l`. Do **not** say "180 passes run on every function" — that is not true and someone will check.

**B-ROLL changes:**
- ADD: `source/opt/engine/pipeline_table.c` scrolling — the pass table as data, not code · `2:35-2:55` · screen capture
- ADD: DCP card `FPU: single-precision only` / `DCP: coprocessor 4`, held briefly · `2:55-3:10` · to animate
- ADD: `git log --stat` on the backend-deletion commit, `−25,000` visible · `3:20-3:45` · screen capture
- REPLACE the "FPU scheduling close-up" row — the FP material is now a mention plus a separate short
- RETIME the end card to `3:45-4:00`

**SPIN-OFF SHORT — script it from these facts** (cut from this scene to hold 4:00; too good to bury, too long to keep):
- Two orthogonal knobs: `-mfloat-abi=` (soft / softfp / hard — how FP crosses a call boundary) and `-mfpu=` (none / fpv4-sp-d16 / fpv5-sp-d16 / fpv5-d16 / **rp2350** — what may be used inside a function).
- No double FPU. `-mfpu=rp2350` emits inline **DCP** sequences on coprocessor 4 for double add/sub/compare. Four matching runtime libraries ship.
- **AAPCS-VFP passes doubles in `d0-d7` even on a single-precision-only FPU** — the ABI says where arguments *live*, not what arithmetic *exists* — so the callee unpacks `d0` into a GPR pair to call `__aeabi_dadd`. You find that when your program prints the wrong number.
- Hard-float `.ARM.attributes` match `arm-none-eabi-gcc` **byte-for-byte**.
- Honest limit: the DCP **flushes subnormals to zero** in compare and `d2f`, with no path that doesn't; the conformance runner takes `--allow-ftz` for that configuration only, and the soft-float baseline stays at full IEEE-754.
- Still open: `float` compares/converts/negate still call `__aeabi_*`; no native `vadd.f64`; DCP `dmul`/`dneg` not inlined.

---

<!-- scriptforge:scene 6c3f06d0-d11a-415d-b735-0245e1e7b03b -->
SCENE 04 · 1:40 · FOCUSED, PROBLEM-SOLVING

# Debugging Miscompilations & Optimizers

## Voiceover

After the GCC torture suite started running on the board, the failures showed up fast. Hundreds of miscompilations, and most of them were the same class of bug lurking in my Thumb backend. Here's a representative one: a simple loop that should have produced a constant, but the generated Thumb-2 code jumped to the wrong address. Split screen here — source on the left, GDB trace on the right. The register allocator was spilling a value it thought was dead, and the optimizer had removed the store too early. That was the old direct AST to machine code path. With the new IR in place I could actually see the three-address form and the SSA values, so I reproduced the bug with a minimal test case, added prints around vstack usage, and found the double vstore. One line fixed it, and that crash was gone. But fixing miscompilations was only half the problem. The suite has over four thousand tests, and my first run was crawling — after an hour it had only reached about a quarter. I needed the compiler itself to be faster, so the cross compiler could build a much faster native TinyCC. That meant real optimizations: three-address IR, SSA form, an SSA register allocator, and about one hundred eighty passes on top. I also added hardware floating point for the RP2350. And honestly, the optimizations introduced new bugs — that's the trade-off. I kept fixing them, and it paid off. The full suite, all -O0, -O1 and -O2 levels plus my own tests, now finishes in about fifty minutes on the board. And the payoff: the native TinyCC is now fast enough to compile itself.

## Scene Description

Talking head intro transitions to split-screen debugging. Left side shows TinyCC source and the minimal test case in VS Code, right side shows a GDB terminal with backtrace, register dump, and disassembly of the wrong jump highlighted. Overlay diagram of AST → Three-address IR → SSA → optimized IR → machine code with ~180 passes labeled. A short diff view shows the one-line double vstore fix. Closes with a terminal showing the torture suite progress stalled at ~25% after one hour, followed by the full suite completing in ~50 minutes.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator at desk with dual monitors, talking head, RGB lighting. | 0:00-0:20 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Split-screen: left side TinyCC source in VS Code, right side GDB terminal with backtrace and register dump. | 0:22-0:55 | screen capture |
| Diagram overlay showing AST → Three-address IR → SSA → optimized IR → machine code pipeline with ~180 passes labeled. | 0:56-1:10 | motion graphic |
| Terminal output of GCC torture suite progress bar, test count 4000+, elapsed time ~50 minutes. | 1:11-1:30 | screen capture |
| Split-screen: left side the minimal test case in VS Code, right side GDB stepping through vstack increments with print statements, call stack showing vstore called twice. | 0:45-0:55 | screen capture |
| Diff view highlighting the one-line double vstore fix, with text overlay 'root cause: vstore called twice'. | 0:55-1:02 | screen capture |
| Terminal showing torture suite progress stalled at ~25% after 1 hour elapsed, text overlay 'too slow — need a faster compiler'. | 1:02-1:12 | screen capture |
| Side-by-side terminal: before (1 hour → 25%) vs after (~50 min → 100%), ending with overlay 'native TinyCC compiles itself'. | 1:30-1:40 | screen capture |

## Notes

Walk through a specific miscompilation case, show split-screen code/GDB traces, and detail how ~180 optimization passes and hardware FP support were implemented to fix them.

Reference v0.1.0_tinycc_changes.md for commit range cae3a049 → fb3a6c57, 31 commits, ~180 optimization passes, SSA register allocator, hardware FP support, and GCC torture suite timing ~50 minutes on RP2350.

Source facts worth keeping: hundreds of miscompilations fixed — many the same class of Thumb backend bug; the first torture run was dropped after 1 hour at ~25% progress; optimizations introduced new bugs (a trade-off that paid for itself in speed); the whole point was a cross compiler fast enough to produce a much faster native TinyCC. Reference v0.1.0_tinycc_changes.md — 31 commits, cae3a049 → fb3a6c57.

## Change Request

**RETITLE** `Debugging Miscompilations & Optimizers` → `The Bug Class I Found Five Times`.
**RETIME** header `1:40` → `2:30`. (Draft was 279 words ≈ 1:51 of speech in a 1:40 slot.)

**REPLACE the entire voiceover.** The draft's bug is self-contradictory and cannot be shot as written: `vstack`/`vstore` is upstream TCC's single-pass value stack — the code path this rewrite *deleted* — so the story claims the bug was in "the old direct AST to machine code path" *and* that the new IR is how it was found. The scene also re-tells scene 02's 25% run and scene 03's IR/SSA/180-passes recap almost verbatim.

New voiceover:

> Once the suite was actually finishing, the failures came in fast. And the interesting part is not any single bug. It's that the same shape of bug kept coming back.
>
> Here's the best one. At minus O1 and above there's a pass called `var_tmp_fwd`. It's simple: if you assign a temporary into a variable, later reads of that variable can read the temporary instead. Straightforward.
>
> It checked that the destination was a variable. It never checked that the destination was an lvalue.
>
> Look at this IR. `V-DEREF ← T` — that's a store through the pointer V. It does not define V. It writes to where V points. But the pass saw "destination is V" and concluded "V now holds T", so every later read of that pointer got rewritten to the value that had been written through it.
>
> In the generated code, the base register of an indexed store became a loop counter. So stores landed at the absolute address of the counter, plus an offset.
>
> What that broke, on the board, was every shell redirect in toybox. Every single one. `echo hello > file` — gone.
>
> The fix is one line: if the destination is an lvalue, bail out. The mirror of a guard the same pass already had on the source operand.
>
> And this is the fifth time I've fixed that bug. Different pass, different symptom, same mistake: a pass keys on "the destination of a store" and assumes a destination is a definition. Sometimes a destination is an address. I've now hit it in SSA phi construction, in parameter entry definitions, in round-trip elimination, in the LEA handling, and here.
>
> So how do you find one of these in a hundred and eighty passes?
>
> You don't rebuild. Every pass has a name, and there's an environment variable — `TCC_DISABLE_PASS`. Take a test that fails. Turn off one pass. Run it again. When it passes, you've named the guilty pass, from a shell, in seconds. That one design decision — a pass table as data instead of a hardcoded call sequence — has probably saved me more time than any optimization in the compiler.

**WHY.** This bug is real, documented and fixed, with a regression test at `tests/ir_tests/439_assign_expr_pointer_base.c`; the fix is `if (irop_op_is_lval(dest)) return 0;`. It broke *every toybox shell redirect*, which is a consequence a viewer feels. The bug-*family* framing is the actual insight and is what makes this a scene rather than an anecdote — the five members are SSA LEA-dest phi miss, parameter entry-def single-def fold, round-trip elimination latest-def, const-var-prop dominance, and this one.

**`TCC_DISABLE_PASS` is the best demo in the project and the draft did not have it.** `docs/video/v0.1.0_tinycc_changes.md` calls it out explicitly: "which is how a miscompile gets bisected to a single pass without rebuilding." Rehearse it so the bisect lands in one take.

**REPLACE the whole B-Roll table with:**

| Description | Timing | Source |
| --- | --- | --- |
| `armv8m-tcc -dump-ir` output with `V***DEREF*** <- T` on screen, the DEREF highlighted | 0:25-0:50 | screen capture |
| The emitted `str.w r5, [r1, r2, lsl #2]` with the wrong base register annotated | 0:50-1:05 | screen capture |
| Board terminal: a shell redirect failing, then the one-line diff, then it working | 1:05-1:30 | to record on hardware |
| Diff view of the one-line fix: `if (irop_op_is_lval(dest)) return 0;` | 1:20-1:30 | screen capture |
| Card listing the five members of the bug family, appearing one at a time | 1:30-1:50 | to animate |
| Live bisect: failing test, then `TCC_DISABLE_PASS=<name>` on the command line, then green | 1:50-2:25 | to record |

**REPLACE the Scene Description**: split-screen with the IR dump and the emitted Thumb (base register circled, annotated "this should be `rr`, it's `cnt`"), then the board terminal failing and working, closing on a live `TCC_DISABLE_PASS` bisection — red FAIL, one environment variable, green PASS.

**ALTERNATES** if a second bug is wanted, all documented: the multi-MiB `sub sp` from a raw `.btype` overwrite; a device-only `-O2` *hang* because backedges never set `is_jump_target`, found by PC-sampling under `qemu -gdb`; literal-pool overflow because raw `o()` byte emission bypassed the size proxy.

---

<!-- scriptforge:scene 18094da8-e9fb-4694-a74e-98b570130a43 -->
SCENE 05 · 2:00 · SERIOUS, HARDWARE-FOCUSED

# Hardware Reality: XIP Bottleneck & 532MHz

## Voiceover

Once TinyCC got fast enough, the bottleneck stopped being the compiler. It was XIP. Execute in place means every instruction fetch comes from QSPI flash over a shared 4-bit bus — and that bus is shared with PSRAM too. Flash tops out around 133 MHz. The core can run much faster, but when it stalls waiting for flash, all that extra clock is wasted. So I overclocked the RP2350 to 532 MHz — four times the QSPI clock — to keep the core busy while the flash catches up. On the MSPCv2 board that is the highest stable clock I could get with the QSPI clock maxed at 133 MHz. I tried pushing past 600 MHz. The board would boot and compile, then very rarely corrupt data on the bus. Rare is enough to be unusable for reliable testing. Thermal imaging and oscilloscope traces show the limit clearly: temperature climbs and signal integrity degrades as clock increases. 532 MHz is the compromise. It is fast enough to run the full GCC torture suite — all three optimization levels plus my own tests — in under an hour on the RP2350. About fifty minutes. Stable enough for daily use. More clock is not free. It costs heat, margin, and the risk of silent data corruption.

## Scene Description

Talking head opens the segment, then cut to a white diagram showing core clock vs QSPI flash timing and stall cycles, with flash and PSRAM sharing the same 4-bit bus. B-roll of oscilloscope waveform of QSPI clock at 133 MHz with core clock overlay at 532 MHz. Thermal camera overlay of the blue MSPCv2 board under load with temperature readout and false-color heat map. On-screen text overlays: 532 MHz stable, >600 MHz unstable, data corruption on bus, 4x QSPI clock. Close with terminal window showing GCC torture suite progress across -O0/-O1/-O2 and the ~50 minute total test time.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| White diagram: core at 532 MHz, QSPI flash at 133 MHz, flash and PSRAM sharing the same 4-bit bus, stall cycles highlighted in red | 0:05-0:25 | to record |
| Oscilloscope waveform: QSPI clock at 133 MHz with 532 MHz core clock overlay, visible stall gaps where core waits on flash | 0:25-0:40 | to record |
| Thermal camera overlay of MSPCv2 board under compile load, false-color heat map with temperature readout climbing as clock rises | 0:40-0:55 | to record |
| Terminal window: GCC torture suite progress across -O0/-O1/-O2 plus own tests, final ~50 minute total | 1:25-1:50 | to record |

## Notes

Explain why overclocking to 532MHz was necessary for XIP performance, show oscilloscope/thermal traces of stability limits, and discuss the trade-offs of pushing the RP2350 beyond 600MHz.

Anchor the entire segment on the shared 4-bit QSPI bus being the fundamental constraint — not the core clock itself. Emphasize the 4x ratio (532 vs 133 MHz) as the stable ceiling on the MSPCv2 board. The 600 MHz+ corruption is worth stressing as the worst kind for a compiler: rare and silent. The realistic number from the run is ~50 minutes for all -O0/-O1/-O2 plus own tests, not just -O0 — keep that as the headline benchmark.

## Change Request

**RETITLE** `Hardware Reality: XIP Bottleneck & 532MHz` → `The Clock Was Not the Problem`.
**RETIME** header `2:00` → `3:45`.

**REPLACE the entire voiceover.** The draft's premise — "I overclocked to 532 MHz to keep the core busy while the flash catches up, and that is what made the suite fast" — is contradicted by the project's own A/B. Measured, the result is far better television than the assumption.

> So the compiler is fast now. Time to make the hardware keep up. I overclocked the RP2350 to 532 megahertz — the board default — and the flash bus runs at 133. Four times the ratio. More clock, more compiles. Obviously.
>
> Then I actually measured it.
>
> I ran the same corpus at 532 megahertz and at 618, which is this board's measured stable maximum. The difference in median compile time was zero point nine six percent. Under one percent, for a sixteen percent clock increase.
>
> Because the core isn't what's busy. Here's one compile: thirty-eight million XIP accesses, about four hundred ninety-five thousand misses, a 98.71% hit rate — which sounds great. Of that hundred and sixty-seven millisecond compile, thirty-five percent is the core executing, and sixty-five percent is stalled waiting on flash.
>
> Execute-in-place means every instruction fetch that misses the cache goes out over a four-bit QSPI bus — the same bus the PSRAM is on. A compiler has a two-megabyte instruction footprint going through a sixteen-kilobyte cache. It misses constantly. Making the core faster just means it waits faster.
>
> So I stopped attacking how many misses there are, and attacked what a miss costs.
>
> And I found this. The QSPI config sets a minimum chip-select deselect time, and it was set from the datasheet. From the wrong row of the datasheet. The Winbond part has two: tSHSL-one is chip-select deselect for read — ten nanoseconds. tSHSL-two is fifty nanoseconds, and it covers erase, program, and write-status.
>
> I'd used fifty. The XIP window only ever reads.
>
> At 532 megahertz that is twenty-seven system clocks of enforced chip-select-high on every miss that can't continue a burst — against the seven that the read row asks for. Then a second one: sending the mode byte as 0xA0 instead of 0xFF puts the part into continuous read, which takes the opcode off the wire entirely.
>
> Together: a cache miss went from a hundred and seventy-eight cycles to a hundred and twenty-six. Twenty-nine percent off the price of every miss. Sixty-eight seconds off the compile bucket across the whole corpus.
>
> A datasheet row, read wrong, was costing me twenty-nine percent of every cache miss.
>
> And the second half of that change broke the SD card. Which turned out not to be a flash problem at all — it was a race in the card's command path, in the PIO program driving it, and it had been quietly breaking bring-up for two rounds under the world's least useful bug description: "any codegen change breaks the card." Finding that was worth more than the round it was blocking.
>
> I still run at 532. It costs heat and margin, and past 618 you get rare, silent data corruption — the worst possible failure mode for a compiler. But I want to be straight about it: the overclock is not why the suite got fast.
>
> And that's the pattern for the whole week. I also spent two days convinced the operating system's syscall path was the bottleneck — built the instruments, measured it, and it came back at about one percent of a program's runtime. Not the bottleneck. Not even close. Measure first, not because it's virtuous, but because your intuition about a machine this strange is going to be wrong, and it's cheaper to find that out in an afternoon than after a month of optimizing the wrong thing.

**FIGURES**, all from `docs/remote_smoke_speedup_plan.md`, section "Measured: 10:36 (2026-08-06, the transaction round)":
- clock A/B: 618 vs 532 MHz moved median compile wall by **+0.96%**
- per compile: 38.3 M XIP accesses, ~495 k misses, 98.71% hit rate; 167 ms compile = **35% core / 65% XIP stall**
- cycles per access, net of the measuring loop: **178 → 126, −29%** (20 cycles chip select, 32 cycles opcode)
- compile bucket 557.6 → 489.3 s (−12.2%); wall −77.3 s (−10.8%); CS-deselect alone −24.0 s of compile
- now `CONFIG_FLASH_XIP_DESELECT_NS`, per board, *because the number names a part*

**B-ROLL changes:**
- ADD: anticlimax card `618 MHz vs 532 MHz → +0.96%` · `0:35-0:50` · to animate
- ADD: `cat /proc/xipstat` during a real compile — accesses, misses, hit rate ticking · `0:50-1:10` · to record on hardware
- ADD: split card `35% core / 65% stalled on XIP` · `1:05-1:20` · to animate
- ADD: W25Q128JV AC table with tSHSL1 (10 ns) and tSHSL2 (50 ns), the wrong row circled in red · `1:40-2:00` · to record
- ADD: cycles-per-miss table animating row by row `181 → 161 → 129` (`178 → 126` net of loop) · `2:00-2:20` · to animate
- CUT: the oscilloscope "stall gaps" row — it illustrates the premise that turned out to be wrong
- DEMOTE: thermal camera to ~15 s of decoration at `2:20-2:35`

**OPTIONAL EXTRA.** The sweep found all 32 values of the deselect field, *including zero*, read an 8 KiB region back at its reference CRC — and the value was still set from the datasheet, not the sweep, because "a CRC that passes at boot is not evidence about voltage and temperature." Good engineering-judgement beat if there is room.

**ON 618 MHz.** It is the measured stable max, and the failures are ~80% intermittent, so single runs lie. That is why 532 shipped — say it that way rather than "past 600 MHz is unstable".

**SDIO STAYS UNNAMED** per the decision to keep the card silent this episode: the autopull-race detour is told as "the card's command path, in the PIO program driving it". This is the one place SDIO could not be cut without losing something.

**THE CLOSING PARAGRAPH** is the rescued thesis of the deleted syscall-profiling scene, and it is the only intended trace of it in the finished video.

---

<!-- scriptforge:scene 4c0d272a-3426-4c73-8efc-cb01ef607ad3 -->
SCENE 06 · 1:45 · OPTIMISTIC, ENGINEERING-FOCUSED

# Memory & I/O: Removing Zeroing + SDIO

## Voiceover

Compiler work is mostly load, analyze, transform, output — a tight loop of I/O. On RP2350 every one of those file reads and writes spends real time on the bus, so to cut compile time I had to attack both I/O and RAM usage. First, I removed unnecessary zeroing in the kernel and TinyCC allocations. Less memset means less bus traffic and faster startup of temporary buffers. Second, I added SDIO support for memory cards. Reading source and libraries from an SD card over SDIO is dramatically faster than QSPI flash for bulk data, and since that bus is shared with XIP, every file that comes off the card instead of the flash is one fewer round trip competing with code fetches. On the RAM side I extended the kernel to allocate process memory from SRAM when possible instead of PSRAM. The heap on PSRAM was the slow part — small files now compile in about a hundred milliseconds because the working set stays on fast SRAM. I also restructured allocations for cache friendliness to cut XIP cache transactions. Faster I/O and smarter RAM placement together make the native compiler feel usable, not experimental.

## Scene Description

Talking head in studio with RGB backlight. Cut to a terminal showing SDIO vs QSPI file-read benchmarks side by side, then a split screen of code diffs for the zeroing removal. Overlay a simplified memory map (SRAM vs PSRAM) animated to show a process being placed in SRAM, plus an XIP cache-miss counter ticking and settling. Close on a terminal timing a small-file compile at ~100ms.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Animated simplified memory map (SRAM vs PSRAM) with a process box sliding into the SRAM region; XIP cache-miss counter overlay ticking down and settling. | 0:50-1:05 | to animate / record |
| Terminal benchmark: SDIO vs QSPI file read times side by side, with the SDIO numbers highlighted. | 0:20-0:35 | to record on hardware |

## Notes

Record real SDIO vs QSPI read throughput numbers on hardware before cutting; the voiceover claims 'dramatically faster' so the compared benchmark needs to back it up on screen.

## Change Request

**RETITLE** `Memory & I/O: Removing Zeroing + SDIO` → `Memory: Zeroing and the Floor`.
**RETIME** header `1:45` → `1:30`.

**REPLACE the entire voiceover:**

> A compile is a tight loop of load, analyze, transform, write out. On this hardware every one of those touches costs real time on a bus that's already saturated. So the rest of the win came from memory.
>
> First: zeroing. An `mmap` on this kernel doesn't cost a constant — it costs the bytes it clears. Which means allocating a big buffer you're about to overwrite is pure loss. Removing unnecessary zeroing in the kernel and in TinyCC's allocations took real time off startup.
>
> Then the one I did not expect at all.
>
> Every compile had a fixed floor of about eighty-six milliseconds before it touched a single line of your actual file. I assumed that was parsing the predefined macros — there's about seventeen kilobytes of them and it happens on every single invocation.
>
> It wasn't. It was the builtin alias declarations. And it wasn't parsing them either — it was the instruction fetch to walk them, bouncing the XIP cache between the macro expander and the declaration parser. Building them programmatically instead of parsing them took that floor from eighty-six milliseconds to twenty-five point eight.
>
> Sixty milliseconds. On a suite of four thousand files, that one change is about four minutes of wall clock — and it is time the compiler was spending before it read a byte of input.

**CUT — this claim is not true of the current tree:**

> ~~On the RAM side I extended the kernel to allocate process memory from SRAM when possible instead of PSRAM. The heap on PSRAM was the slow part — small files now compile in about a hundred milliseconds because the working set stays on fast SRAM.~~

There is no SRAM-preferring tiering in the tree — `grep` for `prefer_fast` / `sram_first` returns nothing, and that experiment was **reverted**. Do not narrate reverted work as a shipped win. The "~100 ms small file" figure is also off: the measured per-compile **floor** is 25.8 ms (down from 85.8) and the median compile in the corpus is ~167 ms.

**CUT the SDIO paragraph** ("Second, I added SDIO support for memory cards…"). Per the decision to keep the card silent, SDIO is used on MSPC but never mentioned. Scene reads better for it: three memory findings building to one number instead of a storage detour in the middle.

**REPLACE the whole B-Roll table with:**

| Description | Timing | Source |
| --- | --- | --- |
| Code diff of the zeroing removal, with a byte counter beside it | 0:15-0:35 | screen capture |
| Per-compile profile bar, init segment highlighted and collapsing `85.8 ms → 25.8 ms`, rest of the bar static | 0:50-1:15 | to animate |
| `pass_timing` / `-bench` output on the device showing the floor before and after | 1:15-1:30 | to record on hardware |

**REPLACE the Scene Description**: drop the SDIO-vs-QSPI benchmark and the SRAM/PSRAM memory-map animation. The shot is the profile bar — the init segment shrinking while the rest of the bar stays exactly where it is, because that shows the win came off the *front* of the compile and not out of the work.

**HELD FOR THE OS EPISODE, do not lose:** SDIO over PIO is `sdio_rp2350.c` (1,445 lines) + `sdio_rp2350.pio` (365) + `mmc_sdio.zig` (663), and the CMD25 result is the best table in the repository — 512 B `373 → 376 KiB/s` (unchanged), 4 KiB `406 → 2,139`, 32 KiB `412 → 3,514`. The *unchanged* 512 B row is what makes it trustworthy: single sectors still use CMD24, so that row should be flat, and it is. Plus hybrid `/tmp`: files ≤64 KB RAM-backed under a hard arena budget, larger ones spill to card, motivated by an unbounded RamFs having been a measured net loss.

**OPTIONAL BEAT** for the init floor, on-theme for this episode: option (b), build-time pre-tokenization of the macro *defines*, was built, measured as a wash, and reverted — the cost was the *declarations*. What shipped is programmatic prototype construction (`tccgen_predef_protos`). Source: `docs/remote_smoke_speedup_plan.md` item 5.5.

**STATE THE MMAP POINT AS A PRINCIPLE**, not a fix — "an mmap costs the bytes it clears" reframes how a viewer thinks about embedded allocation.

---

<!-- scriptforge:scene 35dbb780-38e1-4cb8-b0c2-cf242e71ac2e -->
SCENE 07 · 1:30 · ANALYTICAL, PRECISE

# Syscall Profiling & Framework Overhead *deleted_scene*

## Voiceover

After fixing miscompilations and adding the optimizations, the next bottleneck wasn't the compiler IR at all — it was the OS underneath it. Profiling the GCC torture suite run showed a surprising share of time spent in syscalls and inside oop.zig, the framework that underpins Yasos. File reads, memory allocations, process dispatch — all of it went through layered virtual calls with extra checks. And on this hardware that overhead hurts twice as much. Heap allocations land in PSRAM, which shares its bus with flash, so every wasted allocation blocks the very memory the compiler needs. I captured syscall latency, measured framework dispatch overhead, and picked out the hot paths. Then I trimmed oop.zig to cut virtual dispatch cost, inlined the frequently used methods, and rewrote syscall wrappers as thin trampolines generated at compile time. The profiling numbers dropped. Heap churn fell. And total compile time for the test suite improved measurably. Lower OS overhead translated directly into faster TinyCC runs on RP2350.

## Scene Description

Talking head in studio with dark RGB background. Terminal overlay shows profiling output and syscall timing graphs. Cut to code editor showing oop.zig dispatch changes and syscall table. Quick split screen of before/after compile time metrics.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal window with profiling output and syscall latency numbers overlay | 0:10-0:25 | screen capture |
| Code editor diff of oop.zig framework showing inlined dispatch and reduced virtual calls | 0:40-0:55 | screen capture |
| Graph overlay comparing before/after total compile time for GCC torture suite | 1:05-1:20 | screen capture |
| Code editor showing compile-time generated syscall trampolines replacing the handwritten dispatch block | 0:55-1:05 | screen capture |

## Notes

Demonstrate profiling results via terminal overlays, explain the optimization of the `oop.zig` framework and OS syscalls, and show how reduced overhead directly impacted compiler speed.

Carry the shared-bus reality from Scene 5 forward: heap allocations land in PSRAM on the same 4-bit QSPI bus as flash, which is why cutting heap churn produced a measurable wall-clock improvement. Capture raw syscall latency numbers and a before/after heap-churn metric in the terminal overlays so the 'analytical, precise' tone is backed by concrete figures.

## Change Request

**DELETE THIS SCENE.** Tag added to the title. Do not record it; the text is retained only so the cut is visible.

**WHY — the draft claims a win the project measured and disowned.** `docs/syscall_path_profile.md` opens with the opposite conclusion:

> **The headline is a negative result: the syscall *path* is ~1% of syscall time and well under 1% of a program's runtime, so it is not where the time is.** The handlers are.

Two of the planned items in that same document are marked **rejected**: re-enabling lazy FP stacking (measured tax was zero, nothing to win) and widening the fast-syscall set (negligible payoff, real deadlock risk). The one real win — moving the ARMv8-M syscall and context-switch stub into `.time_critical` with the fast-path table read inlined — is **0.11 ms → 0.02 ms per compile**, against a ~167 ms compile. That is nine hundredths of a millisecond. It is nothing.

**No evidence was found for the `oop.zig` virtual-dispatch trimming** anywhere in `docs/remote_smoke_speedup_plan.md`, `docs/syscall_path_profile.md`, or the tree. **VERIFY** — if that work exists, point at it and it can be revived, but it belongs in the OS video either way.

**Two reasons this is cut rather than corrected.** Corrected, it is an OS scene, and the OS is getting its own episode where the negative result is genuinely strong material. And it is the only scene in the script with no artifact to put on screen.

**THE THESIS SURVIVES.** The last paragraph of scene 05 now carries it — "I also spent two days convinced the operating system's syscall path was the bottleneck… it came back at about one percent". That one sentence is the intended trace of this scene in the finished video.

---

<!-- scriptforge:scene f74992ff-ae01-4d4f-8426-b984a7552737 -->
SCENE 08 · 1:30 · HONEST, REFLECTIVE

# The SMP Experiment vs. XIP Reality

## Voiceover

I thought using both cores would be a free win. I enabled SMP, kicked off two parallel compilations on the RP2350, and waited for a 2x speedup. It didn't happen. In fact it got slower. The reason is XIP. Execute in place means every instruction fetch comes from QSPI flash over a shared 4-bit bus. Both cores contend for the same bus, the same flash controller, and the same cache. The graph shows it clearly: XIP misses spike under parallel load, and the bus saturates long before the CPUs do. In fact, two parallel compiles took longer than running the same compiles back-to-back on one core. Both cores were busy, but they were all fighting over the same bus. I overclocked the chip to 532 MHz to push XIP as far as it would go, but two compilations fighting for flash just made the misses worse. I tried it, measured it, and reverted. A highly tuned single-core pipeline with better syscalls, SDIO file I/O, and less zeroing beats a contended dual-core setup on this hardware. Sometimes the bottleneck isn't the core, it's the bus.

## Scene Description

Talking head in dark RGB-lit studio. Cut to screen capture of profiling graph with XIP cache miss overlay and dual-core vs single-core timing bars showing the parallel run losing. Brief B-roll of RP2350 board and flash bus activity. Returns to talking head for conclusion.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator speaking directly to camera, honest reflective tone. | 0:00-1:30 | studio |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Screen capture of Grafana metrics / profiling graph showing XIP cache misses rising under SMP load, with red spike overlay. | 0:20-0:45 | screen recording |
| Close-up of RP2350 board on desk with RGB lighting, USB cable connected. | 0:05-0:10 | to record |
| Screen capture of terminal showing two compile commands started with `&` and the `time` output, with the parallel run losing to the single-core baseline. | 0:12-0:20 | to record |

## Notes

Explain the failed attempt at dual-core SMP compilation, use a graph overlay to show XIP cache misses causing slowdowns, and justify returning to a highly optimized single-core workflow.

Pull the actual measured compile-time numbers from the benchmark (parallel vs sequential) and display them as a text overlay on the graph — a concrete figure makes the XIP bottleneck tangible. Also show the recorded XIP miss spike clip; it was huge.

## Change Request

**RETITLE** `The SMP Experiment vs. XIP Reality` → `Two Cores, and the Cache They Share`.
**RETIME** header `1:30` → `2:15`.

**REPLACE the entire voiceover.** Two things in the draft are wrong: it says SMP was **reverted** (it was not — `CONFIG_PROCESS_SMP=y` is the default and `docs/smp_plan.md` line 269 records phase 7 complete, "both cores now run processes", with `/proc/cpus` evidence `cpu1_switches 1 → 5` under load and `RoundRobin.try_claim` / `claimed_by_any_core` in `source/kernel/scheduler/round_robin.zig`), and it omits the control experiment that turns "it's cache contention" from a hunch into a proof.

> One more, and then I'll stop. The RP2350 has two Cortex-M33 cores, and this release is the one where YasOS started using both. That's a big piece of kernel work — an entire synchronization layer, a lock hierarchy, the scheduler — and it's getting its own video, so I'm not going to do it justice here.
>
> But there's one result from it that belongs in this video, because it's about compiling.
>
> Both cores now run processes. So I did the obvious thing: two compiles at once. Expecting two times.
>
> I got zero point six one. It got slower.
>
> And this is where the instruments paid for themselves, because "it's cache contention" is a guess until you prove it. Two TinyCC instances take forty-four percent more cache misses for the same work — they're evicting each other out of that same sixteen-kilobyte XIP cache. Then the control: a RAM-resident arithmetic loop, no instruction fetches from flash at all, run on both cores. That gets one point six four times. The second core is fine. And quartering the heap changed nothing, which rules out PSRAM.
>
> So it's not the scheduler and it's not memory. It's one sixteen-kilobyte cache in front of one flash chip, and two compilers do not fit inside it.
>
> Let me be precise about what that closes, because it's narrower than it sounds. I didn't turn SMP off — it's on by default and both cores schedule. What's closed is running my test suite in parallel on one board. And the fix isn't a better scheduler. It's a second board, because a second board brings its own cache.
>
> Which is the same lesson as the datasheet, really. The bottleneck was never the thing with "compiler" written on it.

**SCOPED DOWN ON PURPOSE.** The OS gets its own episode, so this scene is a mention plus the single result that is about *compiling*. **Held for that episode:** the synchronization inventory (`source/kernel/sync/`, ~1,900 lines); **ranked locks** — runtime-enforced, mutexes ordered before spinlocks so "never sleep holding a spinlock" falls out of the ordering, console innermost so anything can log, sparse numbering (5, 8, 10, 20, 30) so a new lock inserts without renumbering; `block_context_switch` deleted across **37 sites** with a CI grep guarding it; the **48% syscall tax** on the echo path (20.1 → 29.7 µs/char, invisible in a compile because it hides inside the XIP stall); and the `CONFIG_PROCESS_SMP=n` deterministic panic (four sequential tcc compiles through `prun -j1`, the fourth dies on kernel heap exhaustion).

**REPLACE the whole B-Roll table with:**

| Description | Timing | Source |
| --- | --- | --- |
| `cat /proc/cpus` on the board — `cpu0_switches` and `cpu1_switches` both climbing | 0:15-0:30 | to record on hardware |
| Terminal showing `prun -j2` two compiles vs the sequential baseline, `time` output, the parallel run losing | 0:40-0:55 | to record on hardware |
| The pair of bars: `two compiles: 0.61x` next to `RAM-resident control: 1.64x` | 0:55-1:25 | to animate |
| `/proc/xipstat` miss counter under one compile vs two — the +44% | 1:25-1:40 | to record on hardware |

Put the 0.61x and 1.64x bars **adjacent** — the contrast is the argument. Drop the "Grafana metrics" framing on the XIP-miss shot; `/proc/xipstat` is the real instrument.

**RETIME the A-Roll** to `0:00-0:15, 1:40-2:15`.

**BLOCKING FOR THE SHOOT.** `configs/mspc_defconfig` has **no `CONFIG_PROCESS_SMP` line**, so MSPC boots single-core — which is both the wrong configuration for this scene and the arm documented as panicking on the fourth compile. `/proc/cpus` is the money shot and it will read one core until that flips. Verify with `cat /proc/cpus`, **not** the boot banner: the banner's "Cores: 2" is the *hardware* count and says nothing about whether the kernel schedules on both.

**FIX TWO SOURCE DOCS** before the OS video is scripted, or they will mislead you: `docs/smp_plan.md`'s status header (line 31) and its phase table still say phase 7 is "not started" while line 269 of the same document records it done; and `docs/video/v0.1.0_yasos_changes.md` inherited the stale version ("Core 1 boots and parks; it does not yet schedule work"). That understates the single best result in the OS half.

---

<!-- scriptforge:scene 6a8304cf-e2d2-4b20-8627-524ee630511f -->
SCENE 09 · 0:45 · CALM, TECHNICAL, WITH A HINT OF RELIEF

# QEMU Support for Faster Development and TinyCC Linker Scripts

## Voiceover

To make tinycc testable on host I integrated QEMU support in tinycc repository. That forced a change in TinyCC itself. Before, the compiler assumed a fixed bare-metal memory map hardcoded for my dynamic loader, with only .text movable via a CLI argument. To run inside QEMU, TinyCC needs to know where code and data actually live in the real or emulated device address space.

That meant implementing real linker script support. TinyCC now parses linker scripts to understand section placement, memory regions, and symbol definitions instead of relying on baked-in assumptions. The linker can emit proper ELF with the right memory layout for both the real board and the QEMU target, and the runtime can map .text, .data, and .rodata accordingly.

While the RP2350 is great for proving it actually works, developing on real hardware is painful. Every change means rebuilding TinyCC, flashing over a slow SWD, and then running the GCC torture suite again.

So I added QEMU support to yasos.zig too. Now I can boot the whole OS, VFS, and the native compiler inside an emulated ARMv8-M environment on my desktop. Same kernel, same syscalls, same TinyCC binary, just running much faster. It’s not cycle-accurate, but it’s more than enough to validate logic, catch crashes, and iterate on the toolchain without touching the board.

It’s a small change with a huge payoff. I can develop and test the compiler and OS features in QEMU in seconds, then push the final build to hardware for validation. Faster loop, fewer flash cycles, less waiting on XIP. That’s the setup I’m using for everything from now on. A fast check on QEMU, then slower hardware validation, removes most of the problems previously detected only on the board.

And it is much cheaper for you if you want to try the OS on your own. Just fetch the repository, execute the script, and after providing the tools the OS needs, you should be able to run it.

## Scene Description

Talking head with split screen: left side a QEMU window booting yasos.zig, right side the real MSPCv2 terminal showing the same kernel. Brief code overlay showing TinyCC's linker script parser, then a small workflow diagram: edit → QEMU test → hardware verification. Keep pacing slower than montage sections; let the relief land.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Split screen: QEMU window running yasos.zig on the left, real MSPCv2 terminal on the right, both at the same shell prompt. After a beat, overlay TinyCC linker script parser code. | 0:00-0:45 | screen recording / to record |

## Notes

Talking head with split screen: left side QEMU window running yasos.zig, right side real MSPCv2 terminal. Brief code overlay showing TinyCC linker script parser. Keep pacing slower than montage sections.

Emphasize that the same yasos.zig binary runs in QEMU and on hardware — no separate build. This supports the 'same kernel, same syscalls' point and shows why the QEMU loop is trustworthy.

## Change Request

**RETITLE** `QEMU Support for Faster Development and TinyCC Linker Scripts` → `QEMU, and Real Linker Scripts`.
**RETIME** header `0:45` → `2:15`. The draft is 325 words ≈ **2:10 of speech in a 0:45 slot** — nearly 3x over, the worst mismatch in the script.

**REPLACE the entire voiceover** (trimmed to fit, and with the limits added):

> Developing on real hardware is painful. Every change means a rebuild, a flash over SWD, and another suite run.
>
> So I put both halves in QEMU. On the compiler side, so tests run on the host. On the OS side, two new board targets — full HAL ports — so the whole system boots in an emulated ARMv8-M environment on my desktop. Same kernel, same syscalls, same rootfs.
>
> Getting the compiler there forced a change I'd been avoiding. TinyCC had a bare-metal memory map hardcoded for my dynamic loader, with only the text section movable, via a command-line argument. That doesn't survive contact with a second target.
>
> So I implemented real linker script support. Fifteen hundred lines that parse `MEMORY` and `SECTIONS` blocks, `ORIGIN` and `LENGTH`, `ENTRY`, and place sections accordingly. The linker emits correct ELF for whichever address space it's given.
>
> The loop is now: change something, check it in QEMU in seconds, then validate on hardware.
>
> But I have to be honest about the limits, because they're sharp. QEMU's Cortex-M model never advances the cycle counter. It models no exception-entry cost, no pipeline flushes, and no XIP or PSRAM latency. Which is precisely what the last three scenes were made of. QEMU tells you whether the code is correct. It can never tell you whether it's fast. Every performance number in this video came off real silicon, and there was no shortcut.
>
> Two smaller caveats while I'm at it: the QEMU smoke run never exercises the exit and shutdown path, so bugs live there. And a QEMU run costs two clean rootfs rebuilds, so it is not free.
>
> The upside for you is that it's much cheaper to try. Clone the repository, run the script, and once the tools are in place you should be able to boot the OS without owning any of this hardware.

**VERIFIED:** linker script support is `libs/tinycc/source/obj/tccld.c`, 1,562 lines, with real `MEMORY` / `SECTIONS` / `ORIGIN` / `LENGTH` / `ENTRY` parsing. QEMU targets are `qemu_mps2_an505` and `qemu_mps3_an524`, plus `scripts/run_qemu_smoke.sh` and `scripts/qemu_fatdisk_run.py`.

**ADDED OVER THE DRAFT — the QEMU limits.** The "QEMU tells you correct, never fast" line comes almost verbatim from `docs/syscall_path_profile.md`, and it is the single best sentence available for this scene: it retroactively justifies why the whole performance story had to run on real hardware, which is otherwise the least glamorous part of the project. The exit/shutdown gap and the two-rootfs-rebuild cost are from `docs/video/v0.1.0_yasos_changes.md`.

**B-ROLL changes** — expand the single 0:00-0:45 row into:

| Description | Timing | Source |
| --- | --- | --- |
| Split screen: QEMU window running yasos.zig on the left, real board terminal on the right, both at the same shell prompt | 0:00-0:25 | screen recording / to record |
| `source/obj/tccld.c` on screen — the `MEMORY` / `SECTIONS` parser | 0:35-0:55 | screen capture |
| Workflow diagram: edit → QEMU test → hardware validation, QEMU box annotated "correctness only" | 0:55-1:15 | to animate |
| The kernel's own `cyc=off` line printed under QEMU — it says so itself | 1:15-1:30 | screen capture |
| `git clone` → run script → OS booting, sped up | 1:30-1:45 | screen recording |

---

<!-- new scene: insert between "QEMU Support…" and "Live Demo" -->
SCENE 09b · 2:30 · ANALYTICAL, CONFIDENT

# The Scorecard: How Far Off GCC Is It? *new_scene*

## Voiceover

Alright. The uncomfortable question. It's an optimizing compiler now — but is the code any good?

I measured it against `arm-none-eabi-gcc` at minus O2. Four thousand one hundred fifty-one tests. Twenty thousand four hundred thirty-five functions. Counting instructions.

TinyCC: six hundred ninety-six thousand nine hundred forty-two. GCC: six hundred forty-eight thousand two hundred eighty-four.

One point zero eight times. Eight percent more instructions than GCC. Later rounds of tuning brought the corpus down to one point zero five.

Now let me take that number apart, because on its own it flatters me.

TinyCC generates better code than GCC on seven thousand eight hundred thirty-nine functions — eighty thousand instructions fewer. And worse on nine thousand seven hundred forty-eight, by a hundred and twenty-nine thousand. The aggregate is a large win netted against a large loss, and quoting only the aggregate hides that.

It's also very uneven by workload. On the GCC execute suite — sixteen thousand functions — it's one point zero zero. Dead level. On my own hand-written IR tests, it's two point zero six. Twice as many instructions.

And one function is forty-seven percent of my total excess. `main`. Which makes sense once you think about it: `main` in a torture test is enormous, full of setup, and the hardest possible case for the kind of local optimization I do well.

One thing I checked that turned out not to be the answer: instruction encoding width. Thumb-2 lets you encode many instructions in sixteen bits instead of thirty-two, and I assumed I was leaving size on the table there. TinyCC uses wide encodings 33.9% of the time, GCC 31.6%. Basically identical. The gap isn't how I encode instructions. It's how many I emit.

I also have to be straight about correctness. As of the twelfth of August there are nineteen open codegen failures in the torture suite, and I know where they came from — the hardware floating point commit on the eighth. I've got a fully green run recorded on the sixth of August, so I know exactly what regressed and when. That's what the per-commit metrics are for.

Eight percent off GCC, from a compiler that runs on the microcontroller it's compiling for. I'll take it.

## Scene Description

Clean data scene, no talking head until the last beat. Big number card: 1.08x. Then it decomposes — the win/loss split as two opposing bars, then the per-suite spread as a small bar chart with gcc-execute 1.00x highlighted, then `main = 47%` called out. Then the encoding-width card, presented as a dead end and dismissed. Then the Grafana dashboard scrubbing through six months. Close on the honest correctness slide.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Big number card: `TCC 696,942 / GCC 648,284 = 1.08x` | 0:20-0:40 | to animate |
| Opposing bars: `better on 7,839 fns (−80,811)` vs `worse on 9,748 (+129,446)` | 0:45-1:10 | to animate |
| Per-suite bar chart, `gcc-execute 1.00x` highlighted, `ir 2.06x` at the other end | 1:10-1:30 | to animate |
| `main = 47% of gross excess` card | 1:30-1:45 | to animate |
| Encoding-width card `33.9% vs 31.6%` stamped "not the gap" | 1:45-2:00 | to animate |
| Grafana dashboard: per-commit code size, compile time and cycle counts, scrubbing through the six months | 2:00-2:20 | screen capture |
| Honest slide: `19 open failures · last fully green run 2026-08-06 · 4,467 passed / 87 skipped` | 2:20-2:30 | to animate |

## Notes

Figures from `docs/video/v0.1.0_tinycc_changes.md` chapter 8, sourced from `docs/plans/o2_size_and_speed_levers.md`: 4,151 tests / 20,435 functions against `arm-none-eabi-gcc -O2`; 696,942 / 648,284 = 1.08x, later rounds 1.05x; better on 7,839 functions (−80,811 instructions), worse on 9,748 (+129,446); gcc-execute 1.00x across 16,308 functions, the hand-written ir suite 2.06x; `main` alone is 47% of gross excess; wide encodings 33.9% vs 31.6%.

The nineteen open failures are from the 2026-08-12 rig run (`logs/68`): 22 failed, of which one was a genuine SMP double-schedule (fixed), one a libc `signed char` bug (fixed — plain `char` is unsigned on ARM, so `%hhd` never printed a sign), one a serial flake, and 19 tinycc codegen regressions traced to the VFP/DCP commit of 08-08. Re-run before recording; the count will have moved.

CI measures cycles on real silicon via a self-hosted Raspberry Pi 5 runner with a board attached, not in an emulator. `metrics/gate.py` compares a run against its parent and can fail the build.

## Change Request

**ADD THIS SCENE.** It does not exist in the draft. Insert between *QEMU Support…* and *Live Demo*, and renumber accordingly.

**WHY.** The episode is named after this gap and the draft never puts a number on it — the `<compare old TCC / GCC / TCC -O2>` placeholder in scene 01 is the only trace of the intent. "Closing the gap" with no figure is the one thing a technical audience will not forgive.

The self-critical decomposition is not modesty, it is the most persuasive material available: quoting 1.08x and stopping would invite exactly the objection this pre-empts. Same for the nineteen open failures — stating them, with the date of the last green run and the commit that caused them, is what makes every other number in the episode believable.

**The Grafana shot belongs here.** `docs/video/v0.1.0_tinycc_changes.md` says it plainly: "If there is one shot that sells *this is a serious compiler project*, it is that one."

---

<!-- scriptforge:scene 37ed7794-13b0-490e-96f2-7dc13928c017 -->
SCENE 10 · 1:50 · TRIUMPHANT, TECHNICAL

# Live Demo: Compiler & Test Suite in Action

## Voiceover

Watch this. This is TinyCC v0.1.0 running natively on the MSPCv2 board. It just compiled itself — from source, on the microcontroller itself. Now it's taking on the GCC torture suite: over 4000 test files designed to break compiler backends. And it's passing. Look at those counters. That's three-address IR, SSA form, a register allocator, and 180 optimization passes — all running on the RP2350 I built by hand. No host, no cross compiler. Just this board, an SD card, and a terminal. And the best part? It's not just working — it's fast. The whole suite finishes in under an hour — about 50 minutes — thanks to XIP at 532 megahertz and SDIO for storage. This is the proof that the rewrite was worth it.

## Scene Description

Terminal screencast on black background with monospaced green/white text. First shows `tcc --version` and then the native self-compile command with scrolling compilation log. Terminal switches to the gcctorturesuite runner, displaying test names and PASS/FAIL counters incrementing, with a progress bar. Cut to a top-down macro shot of the MSPCv2 blue PCB connected via USB, with an SD card inserted and RGB backlight. Overlay text appears: '532 MHz XIP', 'SDIO storage', and '4000+ test files', followed by the commit range cae3a049 → fb3a6c57. Final shot shows the terminal with a summary: 'All tests passed in 52 minutes'.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Talking head creator at desk with dual monitors, pointing at terminal showing native compile | 0:00-0:25 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal screencast of native tcc compiling itself, scrolling output | 0:25-0:55 | to record |
| Terminal screencast of gcctorturesuite execution with PASS counters and test names | 0:55-1:35 | to record |
| Top-down macro shot of MSPCv2 blue PCB connected via USB, RGB backlight | 1:35-1:50 | to record |
| Close-up of terminal showing final summary with 'All tests passed in 52 minutes' and the overall PASS/FAIL counts | 1:40-1:50 | to record |

## Notes

Transition to terminal screencast showing the native compiler compiling itself and running gcctorturesuite output, proving the v0.1.0 rewrite is fully functional on the MSPCv2 board.

Make sure the terminal shows the real time taken (around 50 minutes) and the final PASS count. The overlay of '4000+ test files' should match the earlier scene's count. The closing shot of the board should include the SD card to visually tie in the SDIO storage point.

## Change Request

**RETITLE** `Live Demo: Compiler & Test Suite in Action` → `Live Demo`.
**RETIME** header `1:50` → `1:50` (unchanged; draft was 127 words ≈ 0:50 of speech in a 1:50 slot, so it was badly *under* — the new copy fills it).

**REPLACE the entire voiceover:**

> Let's actually run it.
>
> This is TinyCC v0.1.0, on the board. `tcc --version`. Now a C file — written here, compiled here, linked here, run here. No host, no cross compiler, no SD card shuffling. Just this board and a terminal.
>
> Now the suite. Over four thousand test files, every one compiled on the microcontroller. This is the minus O0 leg — the one I run every day.
>
> And the clock. Ten minutes, thirty-six seconds. All three optimization levels together is fifty-eight minutes, and that's the run I leave going while I eat.
>
> Now, self-hosting — let me be precise, because it's the question I get most and I don't want to overstate it. Two things are true today. The cross compiler compiles TinyCC's own source tree, so the compiler can ingest itself. And the native compiler, running on the device, compiles and correctly runs test programs, checked against the cross-compiled reference. What I have not done yet is build the whole compiler on the board and then use that binary to build itself again.
>
> So: close, and closer than I expected six months ago. Not done. When it's done, you'll hear about it.
>
> And one thing that surprised me, watching this run for the first time. This isn't a demo binary. It's the compiler the whole userland is built with, and it's the same source tree that produces the cross compiler on my desktop. One compiler, two hosts.

**WHY the self-host claim changed.** The draft says "It just compiled itself — from source, on the microcontroller itself." `libs/tinycc/tests/selfhost/README.md` describes two gates and neither is that:

1. **Compile-only gate** (`test_selfhost_compile.py`) — cross-compiles tinycc's sources with `armv8m-tcc`. It "proves the compiler can ingest its own source tree", and it runs on the **host**.
2. **FAT round-trip gate** (`test_selfhost_fat.py`) — copies a curated subset of `tests/tests2/` to the guest FAT drive, compiles each with the native `/usr/bin/tcc`, runs it, and diffs output and exit code against the cross-compiled reference. Under QEMU.

Scene 01 already hedges correctly ("nearing a fully self-hosting loop"); the draft's scenes 04, 10 and 13 contradict that hedge three times. **VERIFY** — if a full on-device bootstrap has landed, this scene becomes the headline rather than a caveat.

**OVERLAY changes in the Scene Description:**
- CUT the `SDIO storage` overlay → replace with `-O0 / -O1 / -O2`
- CUT the closing card "All tests passed in 52 minutes" → the real `-O0` line is **636.60 s, 4,467 passed / 87 skipped**
- If the full-matrix run is shown instead, show its own `run_info.txt` and keep the level labels in frame

**B-ROLL changes:**
- ADD `-O0` visible in the run header on the timer shot, and change its overlay to `10:36` with the real pass/skip counts
- ADD a closing card: `one source tree → host cross compiler + on-device compiler` · `1:50-2:00` · to animate

**BOARD.** This is the scene where the tuned MSPCv2 has to be both the board on the desk *and* the board producing the timer, in the same shot. That is the whole reason the tuning is worth doing — a cutaway to a different board while a benchmark runs is the one edit a technical audience notices. Blocking items: `PROCESS_SMP`, the clock, and the two flash timing values.

---

<!-- scriptforge:scene 89e56275-745f-4a6b-a9ce-db82f989f85c -->
SCENE 11 · 0:50 · REFLECTIVE, CANDID

# AI as Co-Developer: Architect vs Coder

## Voiceover

Let's be honest about how TinyCC v0.1.0 actually got done.

Six months ago this was still Fabrice Bellard's TinyCC with an ARM Thumb backend bolted on. No IR, no optimizer, direct AST to machine code. Today it's a single-target optimizing compiler with a three-address IR, SSA form, an SSA register allocator, about 180 optimization passes, hardware floating point, and over 2100 test files passing.

I am not going to pretend I wrote all of that by hand.

I was terrified I wouldn't be able to integrate that many optimization loops in just six months. So I gave AI tools a real try. I used them heavily to generate code, to debug miscompilations, to fix bugs, to refactor messy passes. For TinyCC I was more the architect than the developer. I set the direction, the structure, the invariants, and let the AI speed up the parts I didn't have time for.

But for future work I'm going to write the core parts myself. Just because it's fun. 

This is the whole point of this project for me. With AI you can absolutely destroy code architecture and quality if you just run on autopilot. But you can also improve it massively if you are the driver. I am not handing over the steering wheel. I review every change, I break it on purpose, I understand it, I keep the OS and hardware side in my own hands.

TinyCC will stay in that mode. I want to focus on the OS and hardware. AI can extend the compiler, I will keep architecting it.

That's the deal.

## Scene Description

Talking head close-up against RGB backlit desk. Periodic cutaways to a screen capture of an AI chat window showing TinyCC diffs (green add / red delete lines), side-by-side with the repo in a dark editor. Return to creator for the closing beats. Keep the same dark-room, blue/purple backlighting and desk mug as previous episodes for continuity.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Screen capture of AI chat window with a TinyCC diff visible (green additions, red deletions), dark theme | 0:10-0:16 | to record |
| Brief close-up of the creator's hands at the keyboard while talking about not handing over the wheel | 0:38-0:42 | to record |

## Notes

Talking head close-up. Cut to screen capture of AI chat window with TinyCC diffs, then back to creator. Keep RGB backlighting consistent with previous episodes.

Keep pace steady and reflective — this is the honest-workflow beat between the fast bug-war stories. The phrase 'That's the deal' is the scene's button; leave a half-beat of silence after it before cutting to the live demo. If AI-chat footage is hard to source cleanly, a static screenshot of the chat with a diff overlay will do.

## Change Request

**RETIME** header `0:50` → `1:45`. The draft is 263 words ≈ **1:45 of speech in a 0:50 slot**. The copy is good; the slot was wrong.

**NO REORDER NEEDED.** This scene is already positioned after the live demo, which is correct: following "here is exactly how far off GCC I am, and here are my nineteen open bugs" with "and I used AI heavily" reads as confidence rather than as a disclaimer. Nothing moves.

**KEEP THE VOICEOVER**, with three small corrections:

- "Six months ago this was still Fabrice Bellard's TinyCC…" → drop "still".
- "No IR, no optimizer, direct AST to machine code." → **"No IR, no optimizer, direct translation to machine code."** Upstream TCC has no AST; this is the same error as in scene 01.
- "about 180 optimization passes" → **"around a hundred and eighty pass files"** (see scene 03's note on the pass count).

Everything else in this scene is accurate and it is the best-written passage in the script. "Over 2100 test files passing" is correct — 2,148 per `docs/video/v0.1.0_tinycc_changes.md`, up from 492 at v0.0.8.

**DIRECTION.** "That's the deal" is the scene's button; leave a half-beat of silence after it before cutting. If AI-chat footage is hard to source cleanly, a static screenshot of the chat with a diff overlay will do.

---

<!-- scriptforge:scene a15cfa6d-2a85-4cfd-94d1-8e73e9b348e6 -->
SCENE 12 · 2:00 · FORWARD-LOOKING, ENGAGING

# Roadmap: VGA, keyboard, Doom

## Voiceover

So where are we now? TinyCC v0.1.0 is running natively on the MSPCv2 board. We went from a single-pass AST-to-machine-code translator to a three-address IR with SSA, a register allocator, and about 180 optimization passes. The GCC torture suite runs in under an hour on RP2350 at 532 MHz — with XIP tuned, SDIO card support in, and syscall overhead reduced.

Right now the system has a basic shell running the toybox userland suite, a VFS with ROMFS, RAMFS and FATfs, round-robin scheduling with sleep handling so waiting processes don't block the rest of the system, and of course the native C compiler.

But the host is still fragile. I still need to harden the OS and the basic libraries like libc. I did add some user-process error handling and safety — a crashing user program no longer takes down the whole OS — but there are still gaps.

Functionally, the next step is VGA output, plus keyboard and mouse input through the USB hub. The problem: USB host support on RP2350 is a little buggy, and this might fail in a way that forces a board redesign. We'll see.

And getting closer to Doom. That needs compiler optimizations too — I plan to compile it with TinyCC right here on the board, the same as every other tool in the rootfs. One thing at a time though: video and input first, then Doom. If the USB host misbehaves badly enough, everything shifts to a board revision. I'm hoping it doesn't come to that.

## Scene Description

Talking head opening with creator at desk with dual monitors and RGB lighting. Cuts to diagram overlays of YasOS architecture, VFS layers, and scheduler queues. Mid-section shows top-down macro shots of MSPCv2 board with USB hub wiring and connections to VGA card. Ends with wide shot of desk setup and terminal window showing current build status.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator talking to camera at desk with dual monitors RGB backlight | 0:00-0:20, 1:10-1:50 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Top-down macro of MSPCv2 board with USB hub cable and VGA card connections, board hub wiring close-up | 0:45-1:10 | to record |
| Clean white diagram overlays: VFS stack ROMFS/RAMFS/SDIO, scheduler round-robin with wait queues, USB hub connection schematic | 0:20-0:45, 1:50-2:00 | to generate |
| Clean white roadmap timeline diagram: current state (TinyCC, shell, VFS, scheduler) → VGA output + USB hub keyboard/mouse → Doom; red risk marker on the USB host step | 1:50-2:00 | to generate |

## Notes

Recap current OS state, outline the next phases (set up the VGA/keyboard through USB hub, show board hub and connections). Raise problem that host on RP2350 has bugs and it may fail not nicely.

Show the physical USB hub and VGA card connections on the board (top-down macro) while naming the RP2350 USB host errata — it is the main schedule risk, so say clearly that a board revision is possible. End with a terminal showing the current build status or an ASCII Doom mockup to tease the goal. Tie the roadmap back to episode 3's promised plan (VGA/keyboard → Doom).

## Change Request

**RETIME** header `2:00` → `1:45`.

**REPLACE paragraphs 2 and 3** (the current-state recap and the "host is still fragile" paragraph) with:

> There's a shell running the toybox userland, a VFS on a real SD card, pipes — real `pipe(2)`, so `ls | grep` works on a Cortex-M33 — both cores scheduling, an MPU, and every pointer userspace hands the kernel now validated in code. That's a whole video's worth of kernel work and it's getting one. Next episode. I'll keep it to that here.
>
> Some things are designed and not shipped, and I'd rather say so than let you find out. Virtual terminals: there's a four-hundred-line design document, the driver files exist, and the initialization call in `main.zig` is commented out. PTY and multiplexing: a plan, nothing more.
>
> For the compiler specifically, the honest list is shorter and I've already given you most of it. Nineteen open codegen failures. No full on-device bootstrap yet. And a gap to GCC that is eight percent on average and much worse in places I know about.

**WHY.** The draft's recap describes the system as it was at **v0.0.8** — "a basic shell, a VFS, round-robin scheduling with sleep handling" — and omits everything this release actually added: SMP with both cores scheduling, `pipe(2)`, `uaccess` pointer validation, MPU support, SDIO. Syscalls went **47 → 53**; the new ones are `pipe`, `ftruncate`, `mremap`, `prlimit`, `klog_ctl`, `perf_dump`.

It is then deliberately compressed to a hand-off, because the OS is getting its own episode. **Held for that episode, do not spend it here:** the `uaccess` header's own argument — *"Syscall handlers run privileged, so an unchecked pointer is an arbitrary read/write primitive for any process. **The MPU is no defence**: PRIVDEFENA plus the background map means it only ever restricted *unprivileged* access"* — which `docs/video/v0.1.0_yasos_changes.md` calls "the best 30 seconds of the video"; the wrinkle that a valid user pointer can legitimately point into **flash**, because the loader borrows `.rodata` straight out of XIP rather than copying it, so `open("/bin/ls")` hands the kernel a flash address; `pipe(2)` implemented as two ordinary `IFile`s so dup2, redirects and the vfork fd-table copy need no special cases; ranked locks; SDIO and CMD25; and the `CONFIG_PROCESS_SMP=n` panic.

**KEEP** the VGA / USB-host / Doom paragraphs unchanged — they are accurate and the USB-host risk is worth stating plainly.

**B-ROLL changes:**
- ADD: `ls | grep` running on the board — a pipeline on a Cortex-M33, as a quick flash · `0:12-0:22` · to record on hardware
- ADD: card `next episode — the OS` over a fast montage of `/proc/cpus`, a lock diagram, `pipe(2)` · `0:22-0:35` · to animate
- ADD: `initialize_virtual_terminals()` commented out in `source/main.zig` — the honest shot · `0:35-0:50` · screen capture
- CUT "SDIO" from the VFS diagram label; use "SD card"
- RETIME the board/USB macro to `0:55-1:20` and the roadmap timeline to `1:20-1:45`

**KEEP the "scaffolded but not shipped" beat** — `docs/video/v0.1.0_yasos_changes.md` recommends it explicitly ("Say this, don't skip it — it is more credible than pretending otherwise"), and after the scorecard scene's nineteen open bugs it reads as consistent rather than deflating.

---

<!-- scriptforge:scene 59ac4bbf-bef1-4229-b7a1-e7bca3e9c1ac -->
SCENE 13 · 2:00 · WARM, CONVERSATIONAL

# Outro & Community Engagement

## Voiceover

That's it for this deep dive into TinyCC v0.1.0. We went from Fabrice Bellard's single-pass Thumb backend to a three-address IR with SSA, a register allocator, and about 180 optimization passes. The GCC torture suite is now running in under an hour on the MSPCv2 board at 532 MHz, and the compiler can compile itself without manifesting bugs.

Thank you for sticking through the story — the miscompilations, the XIP bottleneck, the SMP dead end, and the QEMU changes that made host testing possible.

Thanks for watching, and see you in the next one.

## Scene Description

Talking head close-up of creator at desk with dual monitors and RGB lighting, then slow push-in for sign-off. Intercut with brief cutaways of terminal output showing TinyCC v0.1.0 self-compile success, GCC torture suite progress, and the MSPCv2 board. Ends with wide shot from behind the creator showing the desk setup and monitors, then fade to black.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator direct-to-camera sign-off and thank you, warm conversational tone | 0:00-1:40 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal window with TinyCC v0.1.0 compiling itself and GCC torture suite passing, overlaid with brief metrics graphic | 0:30-0:45 | screen capture |

## Notes

Close with a direct-to-camera sign-off. No comment-voting reminder — the upcoming episode roadmap is already decided.

## Change Request

**RETITLE** `Outro & Community Engagement` → `Outro`.
**RETIME** header `2:00` → `1:15`. The draft is 94 words ≈ **0:37 of speech in a 2:00 slot**.

**REPLACE the entire voiceover:**

> That's the deep dive.
>
> Six months ago this was a single-pass translator that couldn't finish a test run. It's now an optimizing compiler with a three-address IR, SSA, a register allocator and around a hundred and eighty pass files — running on a microcontroller, within eight percent of GCC's instruction count, getting through four thousand test files at three optimization levels in fifty-eight minutes. And the daily loop went from fifty-four minutes to ten and a half in one week.
>
> And the thing I'll actually remember from it isn't any of that. It's that almost every real win came from measuring something I was sure I already understood. The overclock didn't matter. The syscall path didn't matter. Two cores made it slower. And the biggest single fix in the whole six months was a chip-select timing value read off the wrong row of a datasheet.
>
> Thanks for sticking through the miscompilations, the XIP bottleneck, the SMP dead end, and the week I spent profiling something that turned out to be one percent.
>
> Next time: VGA and keyboard. See you then.

**CUT** the claim "the compiler can compile itself without manifesting bugs" — see the live demo scene's change request for what is actually true.

**WHY the middle paragraph is new and load-bearing.** Four measured surprises stated as a set is a stronger ending than a feature recap, and it is the thesis the corrected script has been building since scene 02. It also lands the datasheet story a second time, which is the most repeatable fact in the episode.

**ADD B-Roll:** rapid cutaways including the datasheet row circled · `0:20-0:45` · screen capture.

**RETIME the A-Roll** to `0:00-1:15`.
