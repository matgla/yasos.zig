<!-- scriptforge:scene 43194696-8497-49d2-9fb4-432ee1b725e7 -->
SCENE 01 · 3:00 · WELCOMING, INFORMATIVE, ENERGETIC

# Intro & Project Overview

## Voiceover

Hi, welcome to the next episode of my series!

If you're new here, let me catch you up. I'm building a custom computer from scratch, which I call MSPC. The latest version uses an RP2350 microcontroller with 8MB of external PSRAM and 16MB of Flash storage. I also run on a Pimoroni Pico Plus 2 stacked with the Pimoroni Pico VGA Demo Base.

On top of that hardware, I'm writing YasOS, my own operating system in Zig. The latest milestone is TinyCC, a small C compiler. I added a backend for ARMv8-M machine code generation. The big advantage is that TinyCC is small, memory-friendly, and fast enough to run natively on my board. On the other hand, the code it produces is far from optimal. The first version of my ARMv8-M support was not really optimized for such small devices. It was fine for simple hello-world programs, but... the backend contained bugs, and they mostly showed up when the native compiler was built by the buggy cross-compiler. I decided to run almost the whole GCC torture suite straight on the hardware. No cross-compiling: a real compiler running on the board, fitting in my 8MB of RAM, fast enough to make sense. My goal was under 30 minutes for the whole suite, with more than 4,000 C source files. But at first I was far from that. In 30 minutes, almost nothing had executed. 

When I started running the tests, a single simple test took over a second — uploading to the memory card and executing. Pretty slow, right? Definitely not a way to run the whole suite on a daily basis. 
For comparison, this is how the same suite runs after the changes. 

The idea to optimize TinyCC itself came to me when I found Falbesoner's research on implementing a global register allocator for an older TinyCC version on ARM. If you are new to compiler internals, it's a good read for understanding intermediate representations and smarter register selection. From there, I added real optimization loops to TinyCC, and finally optimized the hot paths in both the compiler and the OS. 

So, over the last six months, I've been doing a complete rewrite. This video will cover the most important changes I made. I moved from direct translation to a full optimizing backend with a three-address-code intermediate representation, later transformed to SSA with a linear register allocator. I integrated the GCC torture suite, a large set of tricky compiler tests, and hunted down hundreds of bugs that manifested on the board. Then I optimized RP2350 bottlenecks around slow external memory access, and ended up with a compiler that meets my goal. The whole suite at -O0 now takes under 12 minutes, including not only the GCC torture suite but also hundreds of my own tests.

The rest of this video takes those pieces apart one by one. 
Interested? Let's dive in.

## Scene Description

Desk setup, dark room, blue/purple RGB backlighting, dual monitors in frame. Welcoming and energetic, leaning in. The scene cuts between the host to camera and clean, minimalist overlays that build as they are spoken.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Talking head — creator at desk, dark room with blue/purple RGB backlighting, dual monitors visible, leans in slightly on the welcome | 0:00-0:04 | to record |
| Cut back to talking head — creator gestures to emphasize the turn from "it booted" to "it was barely functional" | 0:20-0:32 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Top-down static B-roll: MSPCv2 board on the left, Pimoroni Pico Plus 2 stacked with Pico VGA Demo Base on the right. Overlays appear in sync with VO: left label 'MSPCv2 — RP2350 · 8 MB PSRAM · 16 MB Flash', right label 'Pimoroni Pico Plus 2 + VGA Demo Base'. Recording notes: both boards centered on desk, same depth of field, Pico stack angled 10–15° so VGA header is visible, MSPCv2 flat, one soft key light, no RGB wash, hold 3s before labels fade in, labels fade out before next cut. | 0:08-0:18 | to record |
| Top-down macro of the MSPCv2 board next to the Pimoroni Pico Plus 2 and Pico VGA Demo Base, held still as a context shot. | 1:02-1:18 | to record |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Clean, minimalist overlay diagram appearing next to the creator; hierarchy builds as spoken: `MSPCv2 Board` → `RP2350 MCU` → `YasOS (Zig)` → `TinyCC` | 0:04-0:20 | motion/s01_c0_the-stack.py |
| Brief host-rebuild limitation annotation: one compact line — no make / TinyCC too large for RAM / architecture split: future work — visible for one beat, without spoken elaboration. | 0:20-0:32 | motion/s01_c1_host-rebuild-limits.py |
| Quick montage of text overlays popping up in sync with the spoken points: `SSA Backend`, `GCC Torture Suite`, `Optimizations`, `PSRAM/XIP Bottlenecks` | 0:32-0:50 | motion/s01_c2_what-changed.py |
| Clean split-screen overlay: old compiler terminal output scrolls slowly through the same test list, then new compiler output jumps rapidly down the lines | 0:50-1:02 | motion/s01_c3_old-vs-new-run.py |
| Quick comparison teaser: three compact labels appear side by side — old TCC, GCC, TCC -O2 — as a visual annotation only; no spoken explanation and no full demo. | 1:42-1:50 | motion/s01_c4_three-labels-teaser.py |
| Clean transition overlay: 'Next: compiler internals' with a simple arrow pointing into the next scene. | 1:50-2:00 | motion/s01_c5_next-compiler-internals.py |

## D-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Minimal paper-card overlay: 'Falbesoner's TinyCC paper' with one small arrow from 'C code' to 'machine code'. | 1:18-1:42 | motion/s01_d0_falbesoner-paper.py |

## Notes

Include the requested 1-minute overview for newcomers as per reference notes. Establish the full stack context (MSPC -> RP2350 -> YasOS -> TinyCC). Bridge from last episode's 'it runs' to the current reality (slow/buggy) to justify the 6-month rewrite focus. Visuals should support the overview without re-explaining hardware assembly details already covered.

Extracted compare cue: old TCC / GCC / TCC -O2. Use as visual/annotation only, not spoken.

Keep non-expert glosses brief: one phrase per keyword, and prefer spoken definitions over on-screen jargon.

Keep the added comparison to one quick visual teaser; the full demo comes later.

Keep the host rebuild limitation brief in the intro: no make, TinyCC too large for RAM, architecture split is future work.

Treat the old TCC / GCC / TCC -O2 cue as visual annotation only; keep it to a single quick teaser in this intro.

## Change Request


---

<!-- scriptforge:scene db43021b-3094-4c06-8921-7f3e8cc6dbb1 -->
SCENE 02 · 1:15 · URGENT, TECHNICAL

# GCC Test Suite

## Voiceover

As I already mentioned, the first version of my tinycc was pretty unstable. Adding the GCC torture suite was a cheap way to massively extend test coverage — over four thousand test files. But there's a reason I run it natively on the board. If the cross-compiler has a bug, the native compiler it produces will either crash on target or emit a bad executable. And the compiler itself is a far richer test than any individual torture case. It's multi-pass, complex code, while those test files are mostly simple programs.

The problem was speed. Running that raw, unoptimized code on the board was painfully slow. My hard target was the full suite on -O0 only, in under half an hour. When I first kicked it off, I didn't wait for it to finish. After about an hour I dropped the run — progress was sitting around 25% and barely moving.

So the question became whether the suite could actually become a usable regression gate. That's what drove the whole optimization path. And it's a wider win than just the test suite, because the same backend benefits everything my userland compiles with.

## Scene Description

Close-up of the terminal emulator. First: a native TinyCC crash log — instruction fault on target, cross-compiler build visible in the background. Cut to the legacy run: progress bar stuck near 25%, timer climbing past one hour, then the run is killed. Transition to the optimized run: tests streaming through rapidly, progress bar filling, timer well under the target. Split-screen contrast: left shows the TinyCC source tree with multi-pass optimizer active, right shows a 10-line torture test. Text overlay: 'Compiler = complex self-test' / 'Torture tests = simple programs.'

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal output on the RP2350 target shows a native TinyCC crash log — an unexpected instruction fault or invalid address — while the cross-compiler build log above it indicates the compiler was built from the buggy cross-compiler. | 0:05-0:20 | to record |
| Overlay showing elapsed time passing one hour with progress frozen near 25%, then the run being aborted and the log file closed. | 0:30-0:45 | to record |
| Legacy compiler run on the RP2350: terminal shows repeated test failures or crashes, progress stalls near 25%, elapsed timer passes one hour, then the run is aborted. | 0:32-0:48 | to record |
| Overlay showing test progress percentage and elapsed time decreasing as optimization passes are enabled, with a bar chart contrasting initial hours vs. final <1 hour. | 0:45-1:15 | to record |
| Scale, counted rather than scrolled: one whole torture test on screen entire (`gcc.c-torture/execute/20001027-1.c`, 12 lines) against the two totals — the corpus `3,920 files · 108,513 lines · median 18 a file` and `tinycc itself 622 files · 235,045 lines`, drawn as two bars, closing on `the whole suite is 46% of the code in the compiler that runs it`, stamped "so the real test is the self-host" | 0:50-1:05 | motion/s02_b4_the-richest-test.py |

## Notes

**B-Roll 4 re-briefed 2026-08-26, from a scroll to a count.** The row asked for
the tinycc source tree scrolling past hundreds of files beside a ten-line
torture test. Scrolling implies scale; counting has it, and the count is
stronger than the brief assumed — measured at tinycc `803a2f25`:

    git ls-files -- '*.c' '*.h' ':!tests/*' ':!lib/*' | wc -l        ->    622
    ...the same files, non-blank lines                               -> 235,045
    find .../gcc.c-torture -name '*.c' | wc -l                       ->  3,920
    ...the same files, non-blank lines                               -> 108,513
    ...median non-blank lines per file                               ->     18

So **the entire four-thousand-file corpus is 46% of the code in the compiler
that runs it**, which is the voiceover's "the compiler itself is a far richer
test than any individual torture case" as a number. 622 files is 375 `.c` and
247 `.h` with `tests/` and `lib/` excluded — `lib/` is the shipped runtime, not
the compiler. One file (`20000227-1.c`) holds bytes invalid in this locale and
drops out of the line count, so the median is over 3,919.

**No pass count on that card**, deliberately: every defensible answer to "how
many passes" moves with the next merge, so the label carries the structure
(*multi-pass*) and not a figure. The two line counts have their commands on
screen and can go stale honestly.

Reference: v0.1.0_tinycc_changes.md - 'Note: Why I needed optimizations'. The suite takes 4000+ tests. Goal was 0.5h on -O0 but achieved all -O0/1/2 in ~50min.

**VERIFY** the "killed at ~25% after an hour" run. Nothing in the docs records it and each run wipes `logs/`. Either find a log to put on screen or narrate it explicitly as recollection.

VERIFY: The 25% after one hour is now spoken as recollection; no durable log is assumed because each run wipes logs/.

VERIFY: the "~50 min for all of -O0/-O1/-O2" figure. Not re-measured in the 2026-08-20 data pass — that number needs a full on-board suite run, which was not part of it. The host-side codegen numbers in the Scorecard scene WERE re-measured and have moved a long way, so do not assume this one held still either.

Two B-roll rows (0:30-0:45 and 0:32-0:48) describe the same '25% after one hour, aborted' shot. Consolidate to one entry or differentiate them (e.g. one is the overlay/timer, the other is the terminal with crash lines) before recording.

## Change Request


---

<!-- scriptforge:scene b8afcb96-12bb-4513-81a5-6e847c7e2ea7 -->
SCENE 03 · 1:40 · TECHNICAL, ANALYTICAL

# From Single-Pass to Multi-Pass: Introducing IR

## Voiceover

The original TinyCC was a single-pass compiler: no abstract syntax tree, no intermediate representation, no optimizer, no register allocator. Direct translation from C constructs to machine instructions is fast. That approach is great if you only need to produce correct code, but it leaves no room for optimization. For most uses, optimization is what separates a toy compiler from a tool you can really use.

To enable optimizations, I had to introduce an Intermediate Representation first. My plan was the same as in the paper I found. Instead of generating machine code directly, I generate an IR representation that I can transform in optimization loops. Then, because the program is represented in memory, I can apply backend-level optimizations, such as instruction scheduling for Thumb opcodes, and finally generate machine code from the simplified program. The Three-Address Code representation proposed in the paper is simple, memory-efficient, and still fast. I took that approach. TAC is simple: each instruction has at most three operands, usually two sources and one destination. For example, x = (a + b) / c; becomes t1 = a + b; t2 = t1 / c; x = t2; each step has source 1, source 2, and destination. A conditional becomes if (t1 > t2) goto L1, with source 1, source 2, and a destination. With this representation, a whole function is just a contiguous array in memory.

With that abstraction in place, I can analyze the program, transform it, and finally produce optimized code.

## Scene Description

Diagram showing the original Single-Pass flow (Parse -> Codegen) with a red 'no IR / no optimizer' annotation. Diagram showing the new Multi-Pass flow (Parse -> TAC IR -> Opt Passes -> Codegen) with labels for three-address IR and control-flow graph. Whiteboard diagram of TAC definition with rule t = op t1 t2, and a memory-layout inset showing fixed-size TAC instruction: opcode, src1, src2, dst, jump target. Animation of TAC instructions being grouped into basic blocks and connected into a control-flow graph. Split-screen code example: C source on left, TAC IR in center, and basic-block boundaries highlighted. Animation of optimization passes on IR nodes with constant folding and dead store elimination highlighted. Close up of IR nodes being manipulated and optimization passes rewriting them. The pipeline settles on the final codegen stage, with one quiet line on how many passes ran over the function and how few of them changed an instruction. End card for the section: side-by-side compiler pipeline before and after, with a 'named passes' badge.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Whiteboard TAC rule t = op t1 t2 with memory-layout inset showing opcode / src1 / src2 / dst / jump target | 0:50-1:30 | to record |
| Animation of TAC instructions being grouped into basic blocks and connected into a control-flow graph | 1:30-2:00 | to record |
| Split-screen C source vs TAC IR vs SSA, phi functions highlighted with a circle | 2:00-3:00 | to record |
| One statement at a time: the seven lines of C morph into the nine records in place, one statement per beat, with a ledger keeping the count (`int x = (a + b) / c;  →  2` … `5 statements → 9 records`); then the C scaffolding goes, the record indices arrive and `jumpif L1, gt` becomes `jumpif 7, gt` in place, and the array acquires its three blocks as three washes — B0 0-4, B1 5-6, B2 7-8 (alternative take on the 2:00-3:00 slot, against the SSA/phi row) | 2:00-3:00 | motion/s03_b5_c-becomes-records.py |
| FPU scheduling close-up: floating-point TAC ops mapped directly onto hardware FPU instructions | 4:00-4:30 | to record |
| End card: side-by-side single-pass vs multi-pass pipeline, named-passes badge | 4:30-5:30 | to record |
| Single-pass walkthrough: scale.c tokenized, pushed on the SValue stack, and emitted straight into cur_text_section as the parser reads — prologue included, then the '}' brings the epilogue in and the closing walk names all three parts against the readelf byte counts (real trace from the pre-IR revision) | 0:00-0:50 | motion/s01_direct-to-machine-code.py |
| Optimization passes rewriting IR records: what the V / T / P / immediate operands are, then constant propagation and dead-store elimination on a real -dump-ir-passes run, closing on the same function encoded three ways — pre-IR with its prologue, -O0, -O2 | 2:18-3:29 | motion/s03_b4_passes-rewrite-ir.py |
| The two-box pipeline grows a middle: parse -> TAC IR -> optimise -> allocate -> Thumb | 0:34-0:50 | motion/s03_b6_grew-a-middle.py |
| How a record is built: `tcc_ir_put` is the one function the parser calls where it used to call the Thumb emitter. The listing folds to the twenty lines that matter — grow the instruction array, `memset` the quad, stamp `op` / `orig_index` / `operand_base`, then push each operand into the shared pool — with the pool drawn beside it filling as `operand_base` advances. Closes on the same C statement arriving as two records and five operands. | 1:28-1:52 | motion/s03_b7_how-a-record-is-built.py |

## Notes

**B-Roll 3 built 2026-08-26 as a morph rather than a split screen.** It is a
second take on the 2:00-3:00 slot, cuttable against `s03_b2_phi-function-highlight`
— that one puts three columns side by side and points at the phi, this one has
one column and the C turns into the records in front of the viewer. Both are
honest; they are not the same claim, and the choice is a cut decision.

It uses **the same seven lines of C and the same nine records as `s03_b1`
and `s03_b3`**, character for character, which is deliberate: three clips in one
scene may not spell the same function three ways.

**VERIFY, and verify all three together.** `armv8m-tcc -dump-ir -O0` at
`803a2f25` prints an *eleven*-record pre-optimisation form for this function —
`JMP to 6 if "<=S"` then an unconditional `JMP to 5→9`, and a `JMP to 11` after
the first return — and it is the *post*-optimisation dump that comes out at
nine. The nine-record table predates that and is shared by `s03_b1`, `s03_b3`
and this clip, so it is right for the new clip to match its siblings and wrong
for any one of the three to be re-measured on its own. Re-dump the function once
and settle all three, or leave all three as they are.

Correction: Original TCC was single-pass without AST. Content now reflects introduction of IR for multi-pass optimization.

Extension details drawn from v0.1.0_tinycc_changes.md covering submodule range cae3a049→fb3a6c57. Original TCC described as single-pass without AST/IR; IR introduced without full AST to enable multi-pass optimizations.

TAC description and transformation example added to make this the core 5-minute segment. IR introduced without full AST per v0.1.0_tinycc_changes.md.

Extended to cover the full IR pipeline: TAC instruction layout, control-flow graph construction, and optimization passes. The single-pass description is preserved from the original note; new content is grounded in v0.1.0_tinycc_changes.md (three-address IR, a pipeline of named, individually gated passes). Floating-point support is handled in the separate Floating Point scene.

The FPU B-roll row belongs to the separate Floating Point scene, not this IR scene.

New scene to add after this one: Global Register Allocator: Linear Scan. Draft voiceover: After SSA, the compiler still has values, not registers. The global allocator treats the whole function as one timeline. It assigns a start and end to each SSA value, walks the timeline left to right, and keeps a live register pool. When a value starts and a register is free, it takes one; when a value ends, the register returns. If the live set grows larger than the RP2350 register file, the allocator spills the least active value to a stack slot and restores it later. Phi nodes become simple copies at their join points after allocation. This is why the allocator is global: a local choice can poison a later loop, but linear scan over the whole function makes spills and register pressure visible. Use the tinycc allocator implementation to confirm pass names, live-range construction, and spill strategy before finalizing the script.

SSA and global register allocator details are intentionally removed from this scene and should live in the separate SSA/global register allocator scene.

B-roll row 'Split-screen C source vs TAC IR vs SSA, phi functions highlighted with a circle' should be dropped or re-shot as C source vs TAC IR with basic-block boundaries highlighted.

Production note: the B-roll table currently contains an SSA row and an FPU row that do not belong in this IR scene. In assembly, replace the SSA row with C source vs TAC IR with basic-block boundaries highlighted, and move the FPU row to the Floating Point scene.

Code on screen, added 2026-08-26: `s03_b0` already shows *what* a record is (the `IRQuadCompact` declaration). `s03_b7` shows *how one comes into being* — `source/ir/gen/put.c`, `tcc_ir_put`, lines 78-103 for the append itself, the operand pushes following at ~183. Fold the type-promotion and soft-float-call blocks out of the listing; they are real but they are not the sentence. Verified 2026-08-26 against `libs/tinycc` at `803a2f25`.

## Change Request


---

<!-- scriptforge:scene c1e244cb-e49a-4ff0-86cc-dd7cfab8601e -->
SCENE 04 · 3:30 · CALM, EXPLANATORY, SLIGHTLY PROUD

# Global Register Allocation: Linear Scan

## Voiceover

Global register allocation is the first real optimization technique that changes the generated code. It asks a global question: which values can stay in physical registers, and which must be parked in memory? That is what lets the allocator tell a value that's dead in one arm of a diamond from one that's genuinely live across both.

A physical register can be reused only when the value it currently holds is no longer needed, so the allocator has to measure lifetime in order to decide when registers can be safely reassigned. Lifetime here is deliberately cheap. Every virtual register gets one live interval: a start and an end, two instruction indices, nothing more. A forward walk over the instruction list gives me the first definition and the last use. Then the graph fixes what that walk gets wrong — a value used inside a loop has to survive to the back edge, a value feeding a call argument stays alive until the call itself, and a value whose address is taken lives as long as any pointer derived from it.

That's not precise. A value live on two exclusive branches gets one interval covering both, so it looks like it conflicts with everything in between. I took that on purpose. One interval is two integers, and that is the whole reason the next part is cheap.

Now I can allocate. Sort the intervals by start point and walk them in order, keeping an active set of the ones currently holding a register. At each interval, first expire everything that already ended and hand those registers back to the free pool, then give the current one whatever is free. If nothing is free, something has to go to the stack — and I spill the cheapest one, not the longest. Every use is weighted by loop depth, so a value used once outside a loop loses to a value used once inside it.

And that is the win. TinyCC keeps every local in its stack slot for the entire function: read it three times, that's three loads; write it twice, that's two stores. In the simple case, x = x + 1; y = x * 2; means load x, add, store x, load x, multiply, store y. On top of that it flushes live temporaries to the stack before every call. With intervals, x can stay in a register between the add and the multiply, so the second load disappears, and I only spill when I genuinely need the register back. On a desktop, the cache hides most of that traffic. On the RP2350, cache is smaller, and external PSRAM or flash access is slower. This cost is huge.

For the algorithm, I followed Sebastian Falbesoner's linear scan proof of concept for TinyCC; the original algorithm is Poletto and Sarkar's. Linear scan isn't the best allocator. Graph coloring would spill less. But graph coloring wants an interference matrix that's quadratic in live values, and a simplify loop with no useful bound on rounds — and I still aim to run this compiler on the microcontroller, not just target it. Linear scan is one sorted pass and a handful of bitmaps. Its complexity is the point.

## Scene Description

Talking head with a clean, abstract linear-scan diagram: horizontal instruction order, colored live intervals, register lanes below, and stack spill slots when register pressure gets high. Keep any code abstract and do not show unverified TinyCC source.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator at desk explains why TAC needs a CFG, live intervals, and a cheap allocator for on-target TinyCC. | 0:00-1:00 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Minimal linear-scan animation: horizontal instruction timeline, colored live intervals, register lanes, and stack spill slots appearing under pressure. | 0:12-0:42 | motion/s03_b2_linear-scan-spill.py |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Abstract register-pressure readout: active intervals, free registers, and spill count updating as the scan advances; no source code. | 0:36-0:52 | motion/s04_c0_register-pressure-readout.py |

## D-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Macro shot of the RP2350/QSPI flash area to ground the XIP cost of spilled instructions. | 0:53-1:00 | to record |

## Notes

Insert after the optimizer/SSA explanation and before the hardware XIP section. Use a simple timeline diagram: horizontal program order, colored bars for live values, register lanes below, and spill slots when pressure gets high. If showing code, keep it abstract unless verified directly against the TinyCC source.

TAC in this scene means the three-address-code IR, not TinyCC.

## Change Request


---

<!-- scriptforge:scene 56f710e1-43dd-498a-bb7b-b4eccb08ebdc -->
SCENE 05 · 3:30 · ENTHUSIASTIC, TECHNICAL, EXPLANATORY

# SSA: The Missing Piece Between IR and Optimization

## Voiceover

With global register allocation in place, I was hungry for more. I started by writing flat passes over plain IR to remove unnecessary instructions. But I quickly hit the ceiling, and putting TinyCC's disassembly next to GCC's made the gap obvious.

At that point the compiler was already working. But working and good are not the same thing. The output was full of small inefficiencies: extra loads, extra stores, temporary values spilling to memory, registers allocated too late, and code that kept moving data around for no obvious reason.

On a fast x86 machine, that kind of thing is easy to ignore. On RP2350, it is not. We are talking about a microcontroller with limited registers, limited cache, and a memory system that will absolutely punish you for bad code.

So I started asking the obvious question: why does GCC produce cleaner code in more generic cases? Flat passes were targeting one problem at a time, and they were rarely generic — mostly local optimizations.

The answer was not one clever trick. It was a better representation.

That is where SSA came in.

Static Single Assignment form rewrites the program so that every value is defined exactly once. If a variable is written three times, the compiler stops treating it as one mutable thing and starts tracking separate versions — x_1, x_2, x_3 — and each one has exactly one definition, in exactly one place.

In my IR, a local variable is a stack slot. Every read is a load, every write is a store, and the linear scan allocator we just built can do nothing about it — there is no value there to allocate, just memory traffic. The first thing SSA construction does is remove the stack slot where possible. If a variable's address is never taken, it stops being memory and becomes a value with a name.

Then, where two paths meet and each one carried its own version, SSA inserts a phi node to pick between them. I place them on the dominance frontier, and only where the value is still live, so I don't create phis nobody reads. A walk down the dominator tree then renames every use to the version that reaches it.

And now the questions get clean. Where did this value come from? There is one answer, and it is an instruction — not a search. Is this store dead? Is this copy redundant? Is this constant still a constant here?

That is the unlock. SSA did not magically make TinyCC fast. It made the optimizer possible in a serious way. Constant propagation, global value numbering, range propagation, load common subexpression elimination, and about a dozen separate dead-store passes all sit directly on top of it.

And most importantly, it gave the register allocator something worth allocating. Because register allocation is not just "find a register." On ARMv8-M, register pressure is real. If you allocate badly, you spill. If you spill, you touch memory. If you touch memory, you pay for that.

SSA was the bridge between "we have an IR now" and "we can actually do something really decent with it."

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator at desk, close-up, speaking directly about comparing TinyCC output to GCC. | 0:00-0:10 | to record |
| Creator at desk, close-up, connecting SSA to register pressure and the optimizer payoff. | 1:15-3:30 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| The gap that started it: the same five-line function compiled by tinycc **as it stood before SSA existed** (`460a69a8`) and by gcc, side by side — 19 instructions against 11, with the six `[sp, …]` lines lit in three groups and the two that fetch the *same* fifth argument marked again, closing on "working, and not good" | 0:10-0:24 | motion/s05_b0_the-gap-that-started-it.py |
| The stack slot, and the one line of C that keeps it there: mixk.c beside its Thumb, three str and two ldr against [sp, #4] lit, the eight-byte frame drawn as two words, then the addrtaken gate out of ssa.c and the edit — two lines of C gone, fourteen instructions become five, and x is T5/T6/T7 in r2/r0/r1 (real -dump-ir and objdump output) | 1:34-2:04 | motion/s05_b1_slot-to-values.py |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| One name, three values: mix.c beside its records, the three writes to slot V0 lit, then the same five records morphing into ssa_rename's T5/T6/T7 in place — one definition each — and the x_1/x_2/x_3 bridge under it | 1:13-1:34 | motion/s05_c0_ssa-versions.py |
| Where a phi goes: the four-block CFG out of -dump-ir-passes=ssa_phi with its own preds lines, B1 and B3 spotlit for the dominance frontier, the phi arriving in B3 — and t, written on both arms and never read, getting none, with the pruned-SSA test from ssa.c under the graph | 2:04-2:28 | motion/s05_dominance-frontier-phi.py |

## D-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal/pass-list overlay: constprop, GVN, range propagation, load CSE, dead-store elimination; then a spill-count metric dropping after SSA. | 1:00-1:15 | to record |

## Notes

**B-Roll 0 built 2026-08-26 from a compiler that no longer exists.** The row
asked for a screen capture of the two disassemblies; the clip is the two
disassemblies, and the "before" arm is a real build of **tinycc at `460a69a8`**
(2026-04-02, "added a lot of optimizations") — the last commit before
`f81e23b3` (2026-05-03, "added more ssa") added `ir/ssa.c` and the whole
`ir/opt/ssa_opt_*` family. So it is the IR, the flat passes and the linear-scan
allocator the previous scene has just finished building, and nothing else:
exactly the compiler this voiceover is describing.

    git -C libs/tinycc worktree add /tmp/tcc-pressa 460a69a8 --detach
    cd /tmp/tcc-pressa && sed -i '45s/ -Werror//' Makefile   # gcc 16 vs 2026-04 code
    ./configure --enable-cross --enable-O2 --disable-asan && make cross -j

`-Werror` has to come out of `Makefile:45` or the 2026-04 tree will not build
under gcc 16 — new warnings, not new bugs.

All three faults the voiceover names are on the frame and all three are real:
**extra stores** (`str r0, [sp, #0]`, `str r1, [sp, #0]` — a stack slot used as
scratch), **extra loads** (both of those reloaded, and `[sp, #24]`, the fifth
argument, loaded *twice*), and **a frame for nothing** (`sub sp, #16` /
`add sp, #16` to hold one scratch word). gcc's single memory access is the same
fifth argument, read once into `lr` and kept. Counts: **19 instructions / 6
memory** against **11 / 1**.

Deliberately not on the frame: today's tinycc compiles the same function in 15
instructions with 2 memory accesses — it still loads `[sp, #24]` twice. That
answers a question the scene has not asked yet, at 0:10.

Liberties, both standard for this deck: the address and encoding columns are
dropped, and gcc's trailing alignment `nop` is dropped as padding. Neither
changes a count.

Insert after the IR introduction and before the floating-point scene. Use on-screen side-by-side GCC/TCC disassembly, highlight redundant loads/stores and spilled temporaries. Brief SSA diagram showing x_1, x_2, x_3.

Keep the visual order tied to the voiceover: inefficiency -> SSA values -> phi nodes -> register allocator payoff.

Writer will create the SSA slides; keep the flat-pass ceiling beat before the x_1, x_2, x_3 diagram.

Cover the 1:15-3:30 tail with talking head and before/after disassembly so the register-pressure payoff is visible, not just implied.

## Change Request


---

<!-- scriptforge:scene 8ad6f5fa-9855-49d6-8948-9fc665d5c51c -->
SCENE 06 · 2:00 · PRACTICAL, TECHNICAL, SLIGHTLY WRY

# Writing a Pass: One Optimization, Two Ways

## Voiceover

Once the IR existed, the bottleneck moved. Writing an optimization stopped being about the idea and started being about the paperwork.

Here is a real one. An unsigned divide by a power of two is a shift. That is the whole idea — one line of thought. But to make it a pass, I have to walk the instruction array, check the opcode, check that the second operand really is an immediate and not a stack slot or a dereference, read it, prove it is a power of two, rewrite the opcode, rewrite the operand, and report that I changed something. Every one of those steps is identical in every pass. And every one of them is somewhere to be wrong: most of my miscompiles came from a guard I forgot, not from an idea that was wrong.

So I built a small DSL on top of the generator model. Three macros. PATTERN says what shape of instruction I am matching. GUARD says what has to be true. REWRITE says what it becomes. That is the entire pass — ten lines, and every line is about the transform.

It is still plain C. No code generator, no extra build step: PATTERN, GUARD and REWRITE are preprocessor macros, and this is what the compiler actually builds out of those ten lines. A hundred lines, every check spelled out. The boilerplate did not go away. It stopped being mine to type, and it stopped being mine to get wrong.

Now the honest part, because a DSL that solved everything would be a suspicious thing to claim. It rewrites an instruction in place, and that is all it does. Seventy-four generators are written this way, across eighteen of my hundred and ninety pass files. The moment a pass has to *insert* instructions, it is back to hand-written C — a signed divide by a power of two needs a bias sequence, three fresh temporaries, and a careful argument about where the branches that targeted the old instruction now land. That file is a hundred and fifty lines, and most of it is the comment explaining why.

Which is the right split. The peepholes are where the volume is, and the volume is where the mistakes were.

## Scene Description

Screen-only scene, no talking head except the opening and closing beats. Dark editor theme matching the rest of the episode. Three code panels are the spine: the hand-written guard ladder, the nine-line DSL generator, and the hundred-line preprocessor expansion of that same generator. The comparison is made by *size on screen*, not by a number animating — the expansion cascades in while the nine lines sit still beside it. Close on the one pass that cannot be written this way, side by side with the one that can.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Talking head — creator delivers the 'the bottleneck moved' opening, then hands off to the screen | 0:00-0:12 | to record |
| Cut back to talking head for the closing 'which is the right split' button | 1:50-2:00 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| The paperwork, not the idea: the real hand-written pass `tcc_ir_opt_sdiv_pow2` on screen, its seven `continue` guards lit one at a time — 64-bit, unsigned dividend, non-register dividend, barrel shift, non-immediate divisor, divisor < 2, not a power of two — and then everything except the single line that is the transform drained back to quiet. Closing beat names what is left: one idea, six pieces of paperwork. | 0:12-0:42 | motion/s06_dsl_b0_paperwork-not-idea.py |
| The same transform as a DSL generator: `sr_udiv` out of `source/opt/ssa/scalar/strength.c`, nine lines, arriving one macro at a time — PATTERN inked as shape, GUARD as truth, REWRITE as result — each macro annotated with the guard ladder line it replaced from the previous clip. | 0:42-1:08 | motion/s06_dsl_b1_pattern-guard-rewrite.py |
| Still plain C: the ten lines held fixed on the left while the real `gcc -E` expansion cascades in on the right to a hundred lines, the constraint switches and the rewrite spec appearing as they are generated. The command that produced it stays on screen under the right panel so the frame carries its own provenance. Ends on the two panel heights beside each other, unlabelled. | 1:08-1:34 | motion/s06_dsl_b2_ten-lines-become-a-hundred.py |
| What the DSL does not cover: `sr_udiv` (rewrite in place) against `tcc_ir_opt_sdiv_pow2` (insert instructions) as two panels cut to the same top edge, the second scrolling past its bias sequence and its branch-target comment. Adoption stated once as a proportion rather than a badge: eighteen of a hundred and ninety pass files, seventy-four generators. | 1:34-1:56 | motion/s06_dsl_b3_what-it-does-not-cover.py |

## Notes

Scene added 2026-08-26, between the SSA scene and the Floating Point scene (`order: ws`, id `8ad6f5fa-9855-49d6-8948-9fc665d5c51c`).

**Motion filename numbering.** This scene takes position 06 in `order`, so every existing clip named `s06_*` through `s15_*` now lags its scene's position by one. Nothing reads the filename — only `# scriptforge:scene <uuid>` and `# scriptforge:roll` resolve — so the old clips are correct where they are and are deliberately not being renamed. This scene's clips are named `s06_dsl_b<N>_<slug>.py` to sit next to the Floating Point `s06_*` clips without colliding with them.

VERIFIED 2026-08-26 against `libs/tinycc` at `803a2f25`, every figure re-derivable:

* `sr_udiv` — `source/opt/ssa/scalar/strength.c:46-55`, ten lines including the closing brace. `sr_mul` and `sr_umod` sit beside it in the same shape.
* The hundred-line figure — the real preprocessor output, not an estimate. `gcc -E -P` over `strength.c` with the project's include paths, the `opt_dsl_dispatch_sr_udiv` body extracted and run through `clang-format --style="{BasedOnStyle: LLVM, ColumnLimit: 72}"`: **100 lines**. Re-derive before recording if the DSL headers move; the number is bolted to a formatting choice and should be shown with the command that produced it, the way `s03_b4` shows its `-dump-ir-passes` run.
* The macros — `source/opt/framework/opt_dsl.h`, `OPT_GEN_SSA` / `PATTERN` / `GUARD` / `REWRITE`. The framework's own quick-start is `source/opt/framework/README.md`; full spec at `docs/optimizations/opt_dsl_framework.md`.
* The hand-written contrast — `source/opt/flat/scalar/sdiv_pow2.c`, 153 lines, seven `continue` guards before the rewrite begins. Its head comment on `insert_instr_at` and stale `orig_index` is the real reason the pass is long and is worth a beat on screen.
* Adoption — `grep -rln 'OPT_GEN_SSA(\|OPT_GEN_FLAT(' source/opt/{flat,ssa}` = **18 files**; the same grep counted per generator = **74**; `find source/opt/{flat,ssa} -name '*.c'` = **190**. Consistent with the 190 figure in [[tcc-pass-count-reconciliation]].

**Do not put a pass count on a standing card.** Per the 2026-08-23 decision, the only counts the episode quotes are ones bolted to a run whose command is on screen. The 18 / 190 / 74 figures here are spoken, and the closing clip states them as a proportion, not as a badge that will drift with the next merge.

The DSL is compile-checked in CI: `make opt-dsl-check` builds `source/opt/framework/example_strength.c` with `-fsyntax-only` and is a prerequisite of `make test`. Worth one line on screen if the scene runs short; not worth spoken time.

## Change Request


---

<!-- scriptforge:scene fc69ed8a-5414-4c38-b2d7-2ad047f17b8d -->
SCENE 07 · 3:00 · PRACTICAL, TECHNICAL, SLIGHTLY EXCITED

# Floating Point: Inline VFP, AEABI, SoftFP, and RP2350 DCP

## Voiceover

Another problem I hit with my first version of the native compiler was broken floating point support. I wanted to run GNU Make on the target, and it failed the moment it touched floating point numbers — my codegen was emitting wrong instructions.

The RP2350 has hardware floating point, but only for 32-bit float, through the FPv5-SP extension on the Cortex-M33. Doubles are a different story. Raspberry Pi put its own coprocessor on the chip — the DCP — on a coprocessor port. It is not an FPU. It gives you primitives that a short instruction sequence composes into a real IEEE-754 double-precision operation, and it works on general-purpose register pairs, not on any floating point register file. That last part mattered more than I expected: it means doubles keep the ordinary soft-float calling convention, so I never had to add a double register class to the register allocator. What I lose is portability — DCP code will not run on any other ARMv8-M part.

So, three ways to get double operations:

* Pure software floating point. Slow, but it runs on anything with the same CPU architecture. Compile once, run on any yasos.zig board.

* Hardware, behind a call. The codegen emits ABI calls like __aeabi_dmul for multiplication, for example, and the loader resolves them from whichever FP library the binary was built against — libsoftfp, libvfpv4sp, libvfpv5dp, or librp2350fp. The chosen hardware library uses the coprocessor, so you get the hardware; you just pay for the call.

* Hardware, inlined. The instruction sequence goes straight into the code. Fastest, and no portability at all.

Now I can select FPU behavior using standard flags. For example, -mfloat-abi=soft (or -mfpu=none) gives the soft-float path.
flags	fadd	dmul	i2f
(default)	bl __aeabi_fadd	call	call
-mfpu=fpv5-sp-d16 -mfloat-abi=softfp	vadd.f32	call	call
-mfpu=fpv5-sp-d16 -mfloat-abi=soft	bl __aeabi_fadd	call	call
-mfpu=fpv5-sp-d16 -mfloat-abi=hard	vadd.f32	call	call
-mfpu=none	bl __aeabi_fadd	call	call

In the future I want to extend the ABI-call path to shared libraries too, but that is not needed for now. 

I have a bitmask — one bit per operation. When a bit is clear, the operation becomes a library call; when it is set, the backend emits it inline. So I started with pure soft float, then flipped bits one at a time as each inline sequence landed. 

That forced a change in the dynamic loader: it has to check before it runs anything. Every binary declares the FPU it was built for, its float ABI, and a bitmask of what it needs — single precision, double precision, RP2350 DCP. If the hardware does not have what it needs, the image is rejected instead of doing something crazy with hardware.

The other half of this was the OS itself: once floating point registers are in play, the context switch has to save and restore them. That is a topic for another video.

And the GCC torture suite gave me a lot of floating-point tests to verify it. Of course I also added my own floating point tests. That combination is what stabilized the support and the compiler, and it is what let me turn on the hardware paths where they actually help.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal on the board: GNU Make fails as soon as a test touches floating point, showing the initial wrong-codegen problem. | 0:00-0:12 | to record |
| Three ways to add two doubles: the same C under two -mfpu settings, three panels of real objdump — `b.w __aeabi_dadd`, `b.w __aeabi_dmul`, and the six-instruction DCP sequence (stcl/cdp/ldcl) — with what each costs under it, then the two right-hand panels revealed as one object file and `.has_dadd = 1` / `.has_dmul = 0` out of rp2350-dcp.c as the bit that separates them | 0:25-0:45 | motion/s06_b1_three-fp-modes.py |
| One name, four runtimes: `__aeabi_dmul` alone at the top, four muted wires fanning to libsoftfp / libvfpv4sp / libvfpv5dp / librp2350fp with the -mfpu that selects each and what each gives (pure C, VADD.F32, VADD.F64, DCP on CP4), then the rp2350 wire lit and the other three drained, closing on `__aeabi_dmul → /usr/lib/librp2350fp.so` and the 48 names all four define | 0:45-1:05 | motion/s06_b2_fp-library-selection.py |
| Three bits, three rows: the image's arch section (arch/fpu/float_abi) over `required` 1·0·1, `provided` 1·0·1 and `missing` = required & ~provided, empty, so it execs — then the same binary on a Cortex-M33 with no DCP, two bits flip, one bit is left over and the loader answers ENOEXEC | 1:05-1:25 | motion/s06_b3_feature-bitmask-gate.py |
| GCC torture suite terminal on the board running floating point tests, followed by a short Scorecard-style callout: doubles 1.64x GCC, ~1.00x from -O0 to -O2. | 1:25-1:45 | to record |

## Notes

Insert after Scene 11 or before the Roadmap. Use a split screen or overlay to show the three FP modes: inline VFP, AEABI calls, and softfp. Mention RP2350 DCP as a target-specific acceleration path without over-explaining it unless confirmed.

Confirmed 2026-08-20: all four runtimes named in the voiceover exist and are built — `lib/fp/libsoftfp.a`, `libvfpv4sp.a`, `libvfpv5dp.a`, `librp2350fp.a`.

VERIFIED 2026-08-24 against `source/backend/arch/fpu/arm/rp2350-dcp.c` (`arm_rp2350_dcp_fpu_config`) and confirmed by disassembling a probe with `armv8m-tcc -mfpu=rp2350 -mfloat-abi=softfp`: the inlined set on RP2350 is **float add, sub, mul, div** (FPv5-SP) and **double add, sub, compare** (DCP) — exactly the claim that could not be checked on 2026-08-20. Everything else, `dmul` and `ddiv` included, lowers to a `librp2350fp` call; `.has_ddiv` is documented as deliberately never inline (~35 instructions, five scratch registers). `lib/fp/STATUS.md` remains an unreliable oracle — it still lists implemented files as "TODO: implement". Re-check the struct before recording if the backend has moved since.

The doubles measurement in the Scorecard scene is worth knowing about here: on the RP2350, doubles cost 1.64x GCC and the optimizer gained them nothing (1.00x from -O0 to -O2). If this scene wants a forward hook, that is the honest one.

The inline-operation list is now verified (above), so the VO may name float add/sub/mul/div and double add/sub/compare directly. `s06_b1` puts the table's own field names on screen.

Position note: if this scene is placed before the Scorecard, keep the scorecard reference as a forward hook; if placed after it, the same line works as a summary.

If the Scorecard callout remains in B-roll, it can stay visual; no VO change is needed unless this scene is moved after Scene 13.

## Change Request


---

<!-- scriptforge:scene 32f806f3-a760-4ee7-86c2-0a5ba5b36a2b -->
SCENE 08 · 2:00 · CALM, ANALYTICAL, SLIGHTLY RELIEVED

# Grafana: Watching TinyCC Not Regress

## Voiceover

Once the compiler started getting faster, I wanted to have real regression detector in my continous integration.

A change can make one loop ten percent faster and make another function thirty percent slower. A register allocator can win on arithmetic but lose on function calls. An SSA pass can clean up one code path and accidentally hurt another. So I wanted something that would watch the compiler for me.

I set up a small internal Grafana server. Every time I run the GCC torture suite on QEMU for tinycc repository, the test harness records instruction counts for the whole suite, pass and fail totals, and per-test timing. That data gets pushed to the private dashboard.
I also measure cycle count for some benchmarks directly on RP2350 board.

It’s not public, and it’s not fancy, but it does it's role. 

When I land a commit, I can immediately see whether the median cycle count went down. There is one example where I am comparing tcc to gcc. We had huge gap to gcc in cycle count, over 30 times slower. After commit with fixes gap is almost closed. 

There were a few moments where I thought a pass was an improvement, but the dashboard showed it only helped a small subset. Other times the opposite happened: a risky change looked suspicious locally, but the whole-suite instruction count dropped, and cycle time followed. That’s the kind of signal you don’t want to chase by eye.

For TinyCC, Grafana is basically a regression guard. It just tells me, honestly, whether the next version is getting better or worse — before I’m confident enough to call it a win.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| What one commit did to 20,794 functions: one bar cut where the compiler cut it — 10,024 smaller (-118,180 instructions), 6,994 larger (+74,573), 3,776 identical — then the whole thing collapsing to 600,443/644,050 = 0.93x, and the median per function saying 1.00x. Two honest summaries of the same commit that disagree | 0:10-0:30 | motion/s07_b0_one-number-hides-it.py |
| Where the numbers come from: the `codesize` job on ubuntu-latest handing a scratch db to the `metrics` job on the self-hosted Pi, the four tables a push actually fills (codesize_rollup, codesize_func, compile_time, perf), both funnelling into metrics.db, and Grafana reading it one-way because it is bind-mounted :ro — closing on counted-vs-measured | 0:30-0:48 | motion/s07_b1_metrics-pipeline.py |
| Blurred private Grafana dashboard, with a trend line dropping over several weeks | 0:48-0:58 | to record |
| One red spike on a commit, then a green trend after a follow-up fix | 1:22-1:32 | to record |
| Track first, then block: HEAD compared to its first parent, the two checks that can fail a build (correctness, codesize > 1.0%) beside the two that are only printed (compile_time, perf) because they are noisy by nature, then `default -> exit 0` against `--strict -> exit 1` and gate.py's own line when it declines to fail | 1:34-1:56 | motion/s07_b2_track-first-then-block.py |

## Notes

Use a private Grafana dashboard overlay. Avoid showing hostnames, credentials, or sensitive project details. Show a trend line with commit markers; highlight one red regression spike and one green improvement after a fix. Keep the dashboard visually generic enough to remain private.

VERIFY before recording — "We had huge gap to gcc in cycle count, over 30 times slower. After commit with fixes gap is almost closed." Checked 2026-08-24 against the repo and this number could not be reproduced or located. Nothing in `tests/benchmarks/`, `docs/`, the git log or the recorded scorecard shows a 30x cycle gap: the measured extremes are tcc -O0 at 2.35x gcc -O2 whole-suite, `binary_search` at 1.93x before its fix, and doubles at 1.64x. (`strcpy` reads 15,055x from -O0 to -O2, but that is dead-code elimination inside tcc, not a gap against gcc.) If the 30x came off a dashboard panel, screenshot it and name the benchmark; otherwise quote a number that can be re-derived, or the line will be the one thing in the episode a viewer can falsify.

VO accuracy, checked 2026-08-24 against `.github/workflows/ci.yml` and `metrics/schema.sql`: what a push actually pushes to Grafana is code size (tcc vs gcc **instruction** counts per suite and opt, plus per-function rows to a separate detail db), compile time, and RP2350 cycles per iteration. "Pass and fail totals" is the `correctness` table, which CI deliberately skips — `record.py` runs with `--no-correctness` because the O1/O2 fuzz sweep is expensive and run by hand. Per-test QEMU instruction counts exist (`qemu_cycles`) but are **not** on the dashboard path either: `record_one`'s `do_cycles` defaults to False and only `metrics/compare_worktree.py --cycles` ever turns it on. Consider saying "code size against gcc, compile time, and cycles on the board" rather than "instruction counts, pass and fail totals, and per-test timing".

`docs/metrics_dashboard.md` describes an older job split (`build` / `build-and-measure` / `rp2350-perf`) that `ci.yml` no longer has — the live jobs are `build-and-test`, `codesize` and `metrics`. `s07_b1` follows the workflow, not the doc.

## Change Request


---

<!-- scriptforge:scene 18094da8-e9fb-4694-a74e-98b570130a43 -->
SCENE 09 · 2:30 · SERIOUS, HARDWARE-FOCUSED

# XIP Bottleneck: Why 532MHz Is the Ceiling

## Voiceover

Once TinyCC got fast enough, the bottleneck stopped being the compiler. It was XIP.

Execute-in-place means code lives in QSPI flash and gets fetched on demand, over a four-bit bus — a bus shared with the PSRAM. There is a 16 KiB cache in front of it, so it is not every instruction. But every miss costs about a hundred and forty-six core cycles at the clock I run. Miss often enough and the core is just waiting.

Both The flash and PSRAM chips on Pimoroni and MSPC tops out at 133 megahertz. The core can go much faster. So the obvious move is to overclock — and this is where it gets interesting, because the QSPI clock is not independent. It is the system clock divided by an integer.

At 532 megahertz the divider is four, and the flash lands on exactly 133. Its maximum. Nothing wasted.

Push to 600 and the divider has to become five — because four would ask the flash for 150, which it cannot do. So the flash drops to 120 megahertz. I gained seventy megahertz of core clock and gave away thirteen megahertz of memory bandwidth, on a workload that is bottlenecked on memory.

532 is not only a compromise between speed and stability. It is the top of the divider-four band. It is the fastest the core can go while the flash still runs flat out.

Now, stability. I did go higher — 618 megahertz runs. But it needs 2.1 volts on a core whose nominal supply is 1.1. At 1.9 volts it booted, it compiled, and then it would very occasionally return wrong data from PSRAM. Not a crash. Wrong data.

And that is the part worth saying out loud: the failure was intermittent about eighty percent of the time. A single clean run proves nothing. You can run the whole suite green and still be broken. That is a horrible property for a machine you use to decide whether a compiler change was correct.

The regulator does not give me a clean step between 1.9 and 2.1 volts, so there is no fine-tuning available up there either.

So: 532 megahertz. Fast enough to run the full torture suite, and stable during my testing, with no randomly destroyed bytes.

## Scene Description

Talking head opens the segment, then cut to a white diagram showing core clock vs QSPI flash timing and stall cycles, with flash and PSRAM sharing the same 4-bit bus. B-roll of an oscilloscope trace showing the QSPI clock at 133 MHz and the 532 MHz core clock overlaid. Thermal camera overlay of the blue MSPCv2 board under load with temperature readout and false-color heat map. On-screen text overlays: 532 MHz stable, >600 MHz unstable, data corruption on bus, 4x QSPI clock. Close with terminal window showing GCC torture suite progress across -O0/-O1/-O2 and the ~50 minute total test time.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Nothing runs from RAM: the fetch path as far as the core owns it (Cortex-M33 at 532 MHz, then the 16 KiB XIP cache), a *miss* dropping into one 4-bit QSPI bus at 133 MHz with NOR flash and PSRAM drawn inside it rather than hanging off it — then what one compile does to that path (38.30 M accesses, 98.70% hit, 496.8 k misses at ~146 core cycles each, one access in seventy-seven) and the derived 35/65 split of a 167 ms compile, cut as two cells 35 and 65 wide | 0:05-0:25 | motion/s08_b0_xip-and-the-shared-bus.py |
| The flash clock is not a knob: `SCK = clk_sys / ceil(clk_sys / 133)` plotted as a sawtooth from 420 to 700 MHz, with 532 on the top of the ÷4 tooth at exactly 133.00, one megahertz more dropping it 26.4 MHz, 600 landing on 120.0, and the measured 636 MHz stability ceiling drawn as a wall that puts the next tooth-top (665) out of reach — closing on the clock A/B: core −13.9%, flash SCK +7.6%, compile wall **+0.96%** | 0:25-0:50 | motion/s08_b1_divider-four-band.py |
| Thermal camera overlay of MSPCv2 board under compile load, false-color heat map with temperature readout climbing as clock rises | 0:40-0:55 | to record |
| Oscilloscope/log capture showing a clean PSRAM read and a corrupted PSRAM read at >600 MHz, with the bad byte highlighted | 0:55-1:25 | to record |
| A single clean run proves nothing: the POWMAN regulator's steps in this region (1800 / 1900 / 2000 / 2100 mV — 100 mV apart from vsel 23, so there is nothing to tune between them), then the same 76-test repro run five times at 2000 mV (1 of 5 passed) and five times at 2100 mV (5 of 5), the one lucky green run spotlighted as what you would have shipped on, and what the other four looked like — HardFault · MemManage IACCVIOL · PC = 0x000000AA | 0:55-1:25 | motion/s08_b2_a-single-clean-run-proves-nothing.py |
| Terminal window: GCC torture suite progress across -O0/-O1/-O2 plus own tests, final ~50 minute total | 1:25-1:50 | to record |

## Notes

Explain why overclocking to 532MHz was necessary for XIP performance, show oscilloscope/thermal traces of stability limits, and discuss the trade-offs of pushing the RP2350 beyond 600MHz.

Anchor the entire segment on the shared 4-bit QSPI bus being the fundamental constraint — not the core clock itself. Emphasize the 4x ratio (532 vs 133 MHz) as the stable ceiling on the MSPCv2 board. The 600 MHz+ corruption is worth stressing as the worst kind for a compiler: rare and silent. The realistic number from the run is ~50 minutes for all -O0/-O1/-O2 plus own tests, not just -O0 — keep that as the headline benchmark.

I cannot capture the >600 MHz corruption on an oscilloscope; use a terminal/log capture or text overlay instead of a scope trace for that part.

## Change Request


---

<!-- scriptforge:scene f74992ff-ae01-4d4f-8426-b984a7552737 -->
SCENE 10 · 0:40 · HONEST, REFLECTIVE

# The SMP Experiment vs. XIP Reality

## Voiceover

Next thing I tried was two cores compiling code at once. I was hoping for twenty or thirty percent. I got 0.61x — parallel was slower than sequential.

Not the cores: a RAM-resident ALU loop gets 1.64x from core 1. It's tcc. It executes in place out of QSPI flash, through sixteen kilobytes of shared cache — and tcc's text is 1.4 megabytes. Two copies evict each other from a cache neither ever fit in. Forty-four percent more misses for identical work.

The cache is hardware. Nothing schedulable fixes it. Anyway I added xip performance counters available in OS.

Sometimes the bottleneck isn't the core.

## Scene Description

Talking head in dark RGB-lit studio. Cut to screen capture of profiling graph with XIP cache miss overlay and dual-core vs single-core timing bars showing the parallel run losing. Brief B-roll of RP2350 board and flash bus activity. Returns to talking head for conclusion.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator speaking directly to camera, honest reflective tone. | 0:00-1:30 | studio |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Close-up of RP2350 board on desk with RGB lighting, USB cable connected. | 0:05-0:10 | to record |
| Screen capture of terminal showing two compile commands started with `&` and the `time` output, with the parallel run losing to the single-core baseline. | 0:12-0:20 | to record |
| Screen capture of Grafana metrics / profiling graph showing XIP cache misses rising under SMP load, with red spike overlay. | 0:20-0:45 | screen recording |

## Notes

Explain the failed attempt at dual-core SMP compilation, use a graph overlay to show XIP cache misses causing slowdowns, and justify returning to a highly optimized single-core workflow.

Pull the actual measured compile-time numbers from the benchmark (parallel vs sequential) and display them as a text overlay on the graph — a concrete figure makes the XIP bottleneck tangible. Also show the recorded XIP miss spike clip; it was huge.

SMP here means Symmetric Multiprocessing: both RP2350 cores run compile jobs at the same time under the OS scheduler.

VERIFY: the 0.61x parallel figure, the 1.64x RAM-resident ALU loop, and "forty-four percent more misses". Not re-measured 2026-08-20.

VERIFY: "tcc's text is 1.4 megabytes". The on-device binary is 1,654,488 bytes total (rootfs/usr/bin/tcc, YAFF, 2026-08-20), which is the whole image rather than .text alone. 1.4 MB matches the last recorded .text figure, but confirm .text specifically before saying it on camera.

## Change Request


---

<!-- scriptforge:scene 6a8304cf-e2d2-4b20-8627-524ee630511f -->
SCENE 11 · 1:45 · CALM, TECHNICAL, WITH A HINT OF RELIEF

# QEMU Support for Faster Development and TinyCC Linker Scripts

## Voiceover

Running whole suite on RP2350 was slow at start, so I decided to integrate QEMU target in the compiler's own repo using mps2-an505. So the whole GCC torture suite runs on QEMU using the cross compiler. And it is really fast, so I use this regularly. RP2350 is used at the final verification step.
But that required adding linker script support.

The compiler had a bare-metal memory map baked in, hardcoded for my dynamic loader. The only thing you could move was .text, with a command-line flag. QEMU's address space is somewhere else entirely.

So tinycc got a real linker script parser — fifteen hundred lines. MEMORY regions, SECTIONS, ENTRY, PROVIDE. Placement comes from a script now instead of an assumption, and the same TinyCC linker emits ELF for QEMU and YAFF for the board.

Then the same for the OS: two QEMU board ports, and a smoke run that needs no hardware. Same yasos.zig binary — no separate build. QEMU is single-core where the board runs two, and QEMU's userspace floating-point behavior differs.

That difference is the payoff, not a compromise. Logic bugs die on the desktop, and a QEMU pass next to a board failure is evidence of an SMP race — that's how I caught the reaper freeing a process's pages under the next spawn. XIP contention, timing, voltage marginality still need the board.

And it's cheap to try: clone it, install the tools, run the script. No hardware.

## Scene Description

Talking head with split screen: left side a QEMU window booting the same yasos.zig binary, right side the real MSPCv2 terminal showing the same kernel. Brief code overlay showing TinyCC's linker script parser, then a small workflow diagram: edit → QEMU test → hardware verification. Keep pacing slower than montage sections; let the relief land.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Split screen: QEMU window running yasos.zig on the left, real MSPCv2 terminal on the right, both at the same shell prompt. After a beat, overlay TinyCC linker script parser code. | 0:00-0:45 | screen recording / to record |
| Overlay the identical yasos.zig binary name on both the QEMU and board prompts, then show the edit → QEMU test → hardware verification workflow diagram. | 1:15-1:45 | screen recording / to record |

## Notes

Talking head with split screen: left side QEMU window running yasos.zig, right side real MSPCv2 terminal. Brief code overlay showing TinyCC linker script parser. Keep pacing slower than montage sections.

Emphasize that the same yasos.zig binary runs in QEMU and on hardware — no separate build. This supports the 'same kernel, same syscalls' point and shows why the QEMU loop is trustworthy.

When saying no separate build, show the same yasos.zig binary name on both the QEMU and board prompts.

## Change Request


---

<!-- scriptforge:scene 37ed7794-13b0-490e-96f2-7dc13928c017 -->
SCENE 12 · 1:50 · TRIUMPHANT, TECHNICAL

# Live Demo: Compiler & Test Suite in Action

## Voiceover

That's TinyCC running natively on a Pimoroni Pico Plus 2. Nothing is cross-compiled here — the compiler itself is executing on the microcontroller.

And that's the GCC torture suite. About four and a half thousand tests, every one of them compiled on the board and then run on it.

The board isn't on my desk. It hangs off a debug probe on a Raspberry Pi 5 somewhere on the local network — it isn't even powered over USB, the probe feeds it. My desktop drives the whole thing over SSH: build here, flash there, logs stream back live. That's real serial output from real hardware, as it happens.

At -O0, the whole suite is ten minutes thirty-six. It used to be fifty-four. Same tests, same board — that gap is where most of the last few months went.
Across all three optimization levels it's around fifty minutes, because it's three times the work. Same run, three times over.

And when I don't want to wait on hardware, the same suite runs under QEMU. Same tests, same kernel source, no board in the loop.

## Scene Description

Terminal screencast on black background with monospaced green/white text. First shows a `tcc --help` check and then the native self-compile command with scrolling compilation log. Terminal switches to the gcctorturesuite runner, displaying test names and PASS/FAIL counters incrementing, with a progress bar. Cut to a top-down macro shot of the MSPCv2 blue PCB connected via USB, with an SD card inserted and RGB backlight. Overlay text appears: '532 MHz XIP', 'SDIO storage', and '4,151 tests', followed by the final PASS/FAIL summary. Final shot shows the terminal with the final PASS count and a summary: 'All tests passed in about 50 minutes'.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Talking head creator at desk with dual monitors, pointing at terminal showing native compile | 0:00-0:25 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal screencast of native tcc compiling itself, scrolling output | 0:25-0:55 | to record |
| Terminal screencast of gcctorturesuite execution with PASS counters and test names | 0:55-1:35 | to record |
| Top-down macro shot of MSPCv2 blue PCB connected via USB, SD card inserted, RGB backlight | 1:35-1:45 | to record |
| Top-down macro shot of MSPCv2 blue PCB connected via USB, RGB backlight | 1:35-1:50 | to record |
| Close-up of terminal showing final summary with 'All tests passed in 52 minutes' and the overall PASS/FAIL counts | 1:40-1:50 | to record |
| Close-up of terminal showing final PASS count and summary 'All tests passed in about 50 minutes' | 1:45-1:50 | to record |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Top-down macro shot of MSPCv2 blue PCB connected via USB, SD card inserted, RGB backlight | 1:35-1:45 | to record |

## D-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Close-up of terminal showing final PASS count and the overall PASS/FAIL counts | 1:45-1:50 | to record |

## Notes

Transition to terminal screencast showing the native compiler compiling itself and running gcctorturesuite output, proving the rewrite is fully functional on the MSPCv2 board.

Make sure the terminal shows the real time taken (around 50 minutes) and the final PASS count. The overlay of '4000+ test files' should match the earlier scene's count. The closing shot of the board should include the SD card to visually tie in the SDIO storage point.

Keep all on-screen text free of version numbers or commit hashes.

Use the re-run figures in final on-screen text; the added B-roll rows are the corrected closing shots. The old "4,151 tests" caption is stale — the host corpus now compiles 4,253 (2026-08-20), and the on-board count is its own number.

VERIFY: every timing and count spoken in this scene — "-O0 in ten minutes thirty-six", "it used to be fifty-four", "around fifty minutes across all three levels", and the on-screen PASS total. None was re-measured in the 2026-08-20 pass; that needs a full on-board suite run.

VERIFY: state the pass count as a number, not "all passing" — e.g. "four thousand four hundred and sixty-seven passed". Specific survives scrutiny; "all" does not. (Moved here out of the Voiceover, where it had been left as an editing note and would have been read aloud.)

## Change Request


---

<!-- scriptforge:scene 89e56275-745f-4a6b-a9ce-db82f989f85c -->
SCENE 13 · 1:30 · REFLECTIVE, CANDID

# AI as Co-Developer: Architect vs Coder

## Voiceover

I'm not going to pretend I wrote all of this by hand.

A hundred and forty optimization passes in six months, on top of an OS I was also rewriting. I was genuinely afraid I wouldn't get there. So I gave the AI tools a real try, and I used them hard — generating code, chasing miscompilations, fixing bugs, cleaning up passes I'd made a mess of.

On TinyCC I was the architect more than the developer. I set the direction, the structure, the invariants, and handed off the parts I didn't have time to type.

Here's the thing, though. On autopilot, these tools will wreck your architecture. Give them the wheel and you get code that compiles, passes, and quietly rots. Stay in the seat and they'll take you further than you'd have got alone.

So I stay in the seat. I review every change. I try to break it on purpose. Everything in this video that got measured and then thrown away is what that looks like — two cores made compiles slower, so I killed the idea and published the number.

The compiler stays in that mode. The OS and the hardware I keep in my own hands. Partly because that's where the interesting problems are. Mostly because it's fun.

That's the deal.

## Scene Description

Talking head close-up against RGB backlit desk. Periodic cutaways to a screen capture of an AI chat window showing TinyCC diffs (green add / red delete lines), side-by-side with the repo in a dark editor. Return to creator for the closing beats. Keep the same dark-room, blue/purple backlighting and desk mug as previous episodes for continuity.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| A real commit instead of a chat window: `e6a09f0f` in `source/frontend/gen/builtin/call.c`, six lines of condition, with `!inline_body_has_loops(...)` moving out of one arm of an ` |  | ` in place — then what it cost, from the commit's own message (`the device compiler: "memory full" at -O2`; `the same file on the host: 423 MB / 0.48 s, against 45 MB / 0.03 s`) |
| Brief close-up of the creator's hands at the keyboard while talking about not handing over the wheel | 0:38-0:42 | to record |

## Notes

**B-Roll 0 re-briefed 2026-08-26, and lengthened 0:16 → 0:20.** A chat window is
a picture of a tool; a real commit is a picture of the work, and six lines of C
cannot be read twice in six seconds. The next B-Roll in this scene is at 0:38,
so there is room.

The commit is `e6a09f0f`. The guard `!inline_body_has_loops(...)` was written
*inside* the right-hand arm of an `||`, so the left-hand arm — every call with
at least one argument — reached the inliner without it. One line moves out of
the parentheses and the two-line arm collapses to one; nothing else on the frame
changes, which is what makes it a morph rather than two slides.

What it cost is the commit's own message, not an estimate: the device compiler
died with **"memory full"** at -O2 on `gcc-torture/execute/builtin-bitops-1`
(~220 const-argument calls into 32/64-iteration bit helpers out of one `TEST()`
macro), and on the host the same file cost **423 MB / 0.48 s** against **45 MB /
0.03 s** with auto-inline off. It read as correct, it compiled, and it passed —
which is the segment's argument in one commit.

The listing is verbatim from `git show e6a09f0f -- source/frontend/gen/builtin/call.c`,
dedented by the eight spaces of common indent, comments excluded (the commit adds
nineteen lines of comment around the change; they are the reasoning, not the
change). `803a2f25`, the commit after it, replaces the outright ban with a
per-caller budget — a better answer, and not this clip's subject.

Talking head close-up. Cut to screen capture of AI chat window with TinyCC diffs, then back to creator. Keep RGB backlighting consistent with previous episodes.

Keep pace steady and reflective — this is the honest-workflow beat between the fast bug-war stories. The phrase 'That's the deal' is the scene's button; leave a half-beat of silence after it before cutting to the live demo. If AI-chat footage is hard to source cleanly, a static screenshot of the chat with a diff overlay will do.

## Change Request


---

<!-- scriptforge:scene b8ecb683-7d18-40d9-92b2-ca42305d2d92 -->
SCENE 14 · 3:25 · HONEST, ANALYTICAL

# The Scorecard: How Far Off GCC Is It?

## Voiceover

Alright. The uncomfortable question. It's an optimizing compiler now — but is the code any good?

Three numbers, measured on the actual chip. Twenty-nine benchmarks on the RP2350, every one checked against its expected result before I timed anything, and the whole run reproducible to the cycle.

Where I started — TinyCC at minus O0, no optimizer — a hundred and thirteen million cycles. TinyCC today, at minus O2: fifty million. GCC at minus O2, same benchmarks, same board: forty-four million.

So the optimizer bought a factor of two. Two point two three, to be exact. And against GCC I went from two point five five times slower to one point one four. Fourteen percent off GCC, on real silicon, from a compiler that runs on the microcontroller it's compiling for.

Now let me take that fourteen percent apart, because it is not spread evenly.

Doubles are one point six four. And here is the damning part — at minus O0 they were already there. The optimizer bought them nothing. One point zero zero. Every pass I wrote sails straight past double arithmetic.

Take the doubles out, and the rest of the suite is one point zero eight. Eight percent off GCC — and the optimizer bought that side two point four eight times over.

The two biggest real workloads in there, dijkstra and qsort, come in at one point zero one and one point zero zero. Dead level with GCC.

So the honest headline isn't "fourteen percent slower". It's level with GCC on integer and pointer code, and losing badly on doubles.

There's one number I have to be straight about, because it flatters me and I nearly put it on a card. Count instructions instead of cycles, across the whole four-thousand-test corpus, and I come out at zero point nine three — seven percent *fewer* instructions than GCC. That is meaningless. Five files in that corpus are machine-generated, two thousand near-identical functions apiece, and between them they are half of every function I measure. I expand that one idiom tighter than GCC, and it drags the whole average under one. Pull those five files out and it's one point one four. The median function is exactly one point zero zero.

Cycles on hardware are the number. Instruction counts over a corpus are a trap I set for myself.

And encoding width — the one I was certain was the problem.

Thumb-2 is two instruction sets sharing one encoding space. Most common operations have a sixteen-bit form; everything else costs thirty-two. Over that same corpus I use the wide form twenty-nine percent of the time. GCC, thirty-four. I'm the narrower of the two.

So here's what actually forces the wide form. A constant the narrow encoding can't hold. A shift folded into an operand — the barrel shifter only exists in the thirty-two-bit encodings. A register above r7, because most of the narrow forms have three-bit register fields. An offset past five bits. And some things have no sixteen-bit form at all: divide, count-leading-zeros, bit-field extract — and every single call. Fourteen thousand of my forty-nine thousand wide encodings are just `bl`, and neither compiler gets a say in that.

None of that is a slower instruction. It's a bigger one.

So look at one function — `std_eqn`, out of `divconst-2` in the torture suite. Multiply by INT_MIN, add, compare.

GCC folds the shift into the add. One instruction, four bytes, and it can only do that because the barrel shifter is wide-only. I can't, so I shift and then I add: two narrow instructions. Also four bytes. Dead even — and GCC is an instruction ahead.

Then turning that comparison into a zero or a one. I do compare, if-then-else, move one, move zero: four narrow instructions, eight bytes. GCC does subtract, count-leading-zeros, shift right five: three instructions, one of them wide, eight bytes. Even again. Then we both return — two bytes each.

Nine instructions from me, not one of them wide. Five from GCC, two of them wide. And GCC's function is *smaller* — fourteen bytes against my eighteen. The four bytes are two register moves at the top that GCC never needed. A copy my allocator didn't coalesce.

That's the whole lesson. A wide instruction that replaces two narrow ones is free. Width is a *rate* — bytes per instruction — and what the flash holds and what the cache fetches is the rate times the count.

So do the multiplication. A hundred and sixty-nine thousand instructions at two point five eight bytes each: four hundred and thirty-seven thousand bytes. GCC, a hundred and forty-three thousand instructions at two point six eight: three hundred and eighty-five thousand. I win the rate. I lose the total, by thirteen and a half percent.

And bytes are what this part charges for. The image has to fit in flash — my dot-text on the benchmark build is eighty-seven kilobytes against GCC's seventy-three. And everything running out of flash comes through a sixteen-kilobyte cache at about a hundred and forty-six cycles a miss, so thirteen percent more code is thirteen percent less of your program sitting in it.

Encoding width was never the gap. And the reason it was never the gap is that it was the wrong ratio.

## Scene Description

Clean data scene, no talking head until the last beat. Opens on a three-bar card — tcc -O0, tcc -O2, gcc -O2 — the first bar towering over the other two, so the optimizer's 2.23x and the remaining 1.14x read in one picture. Then the decomposition: doubles pulled out as their own pair of bars against everything-else, with the O0 column showing the doubles bar barely moving. Then dijkstra and qsort called out at parity. Then the instruction-count card, presented as a trap and dismissed, with the five generated files shown eating half the corpus. Then the encoding-width card, dismissed — and then, instead of moving on, three cards that say what it was dismissing: what actually forces a wide encoding, four real objdump pairs at a time; one function compiled by both compilers side by side with the byte column kept, where TCC uses no wide encoding at all and is still four bytes bigger; and the multiplication that closes it, width times count, where the rate TCC wins turns into the byte total it loses. Close on the Grafana dashboard scrubbing through six months.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Three-bar hero card: `tcc -O0 112,880,275` · `tcc -O2 50,512,675` · `gcc -O2 44,288,006` cycles, with `2.23x` bracketing the first two and `1.14x` the last two | 0:10-0:40 | motion/s13_b0_three-bar-cycle-comparison.py |
| Gap-closing card: `tcc -O0 was 2.55x GCC` → `tcc -O2 is 1.14x GCC` | 0:40-0:55 | motion/s13_b1_gap-closing.py |
| Split bars, doubles vs everything-else: `doubles 1.64x, optimizer gained 1.01x` against `rest 1.08x, optimizer gained 2.48x` | 0:55-1:25 | motion/s13_b2_doubles-vs-everything-else.py |
| Parity callout: `mibench_dijkstra 1.01x` and `mibench_qsort 1.00x` next to a GCC reference line | 1:25-1:40 | motion/s13_b3_parity-dijkstra-qsort.py |
| Instruction-count trap card: `0.93x` struck through, then `5 generated files = 10,245 of 20,797 functions`, resolving to `1.14x · median function 1.00x` | 1:40-2:05 | motion/s13_b4_instruction-count-trap.py |
| Encoding-width card `TCC 29.0% vs GCC 34.2% wide` stamped "not the gap" | 2:05-2:15 | motion/s13_b5_encoding-width.py |
| What forces a wide encoding: four real objdump pairs — a constant (`movs r0, #1` → `mov.w r0, #32768`), a folded shift (`adds` → `add.w …, lsl #31`), a register above r7 (`str` → `str.w lr`), an offset past five bits (`ldrb` → `ldrb.w …, #65`) — closing on "no 16-bit form at all: sdiv, clz, ubfx, and every bl" and "not a slower instruction, a bigger one" | 2:15-2:30 | motion/s13_b6_what-makes-it-wide.py |
| One function, both ways: `std_eqn` out of `divconst-2.c`, TCC's nine instructions against GCC's five with objdump's byte column kept, three spans marked as byte-for-byte even (4 ↔ 4, 8 ↔ 8, 2 ↔ 2) and one that pairs with nothing, resolving to `0% wide · 18 bytes` against `40% wide · 14 bytes` | 2:30-2:52 | motion/s13_b7_one-function-both-ways.py |
| Width is a rate: `169,285 × 2.58 B = 436,844` against `143,438 × 2.68 B = 385,046`, the colour flipping between the middle column and the right, then the two byte totals as bars — `+51,798 bytes · 1.135x` — over the two places bytes are charged (`.text 87,256 vs 72,856`; the 16 KiB XIP cache at ~146 cycles a miss) | 2:52-3:08 | motion/s13_b8_bytes-not-widths.py |
| Grafana dashboard: per-commit code size, compile time and cycle counts, scrubbing through the six months | 3:08-3:25 | screen capture |

## Notes

**All figures re-measured 2026-08-20** on branch `loop-opts-iv-ptr-walk` (tinycc `7262c810`). The previous draft's numbers (1.08x instructions, 696,942 / 648,284, `main` at 47%, wide encodings 33.9% vs 31.6%) are superseded — they came from `docs/plans/o2_size_and_speed_levers.md` §2, measured months ago at `bc0e02ce`.

Cycles — `tests/benchmarks/run_benchmark.py 192.168.0.113 -O all`, real RP2350 silicon, 29 benchmarks, 26 verified against expected results and 3 with no expected value. Re-measured 2026-08-25 at tinycc `803a2f25`, run twice with all 87 measurements identical. Totals: tcc -O0 112,880,275 / tcc -O2 50,512,675 / gcc -O2 44,288,006. Optimizer 2.23x; tcc -O0 vs gcc -O2 2.55x; tcc -O2 vs gcc -O2 1.14x. Median per-benchmark 1.28x. Doubles 1.64x (optimizer gain 1.01x); everything else 1.08x (optimizer gain 2.48x). `.text` 98,240 → 87,256 for TCC, GCC 72,856 (1.20x). Supersedes the 2026-08-20 figures at `7262c810` (tcc -O0 103,978,975, optimizer 2.06x, -O0 vs gcc 2.35x): `3fee660e` stopped -O0 running const-prop, which cost -O0 8.6%. The gcc arm and the 1.14x headline are unchanged.

Two things make those cycle numbers trustworthy, and both are worth knowing before anyone challenges them. The run was repeated and came back **identical on all 58 measurements** (29 benchmarks × 2 compilers). And the double comparison is genuinely compiler-vs-compiler: `BENCH_GCC_FP_FROM_SOURCE` defaults ON, so both arms compile the *same* `lib/fp/soft` C sources at -O2 — GCC is not being handed its hand-written `ieee754-df.S`. With libgcc's assembly instead, double_add reads 4.12x, which would be an unfair number to quote.

The image-size artifact in tcc-rig-image-size-confounds-benchmarks does not apply here: the two arms' `.text` differ by 14,048 bytes, which is an exact multiple of 16, so the code-to-data displacement is unchanged. The doubles are placement-insensitive anyway, and they are where the gap lives.

Five benchmarks (`function_calls`, `conditionals`, `switch_stmt`, `strcpy`, `strcmp`) collapse to ~35 cycles at -O2 under both compilers — the body is optimized away. Excluding them moves the aggregate by nothing (2.23x → 2.22x, 1.14x unchanged), so the headline is not resting on them. Do **not** put the raw `strcpy` O0/O2 ratio (15,116x) on screen; it is dead-code elimination, not a speedup.

Instructions — **re-measured 2026-08-25 at `803a2f25`**, superseding the 2026-08-20 figures at `7262c810` (4,253 tests, 20,794 functions, 600,443 / 644,050). `./scripts/regression_disasm.py --suite all -j24 --csv`: 4,363 tests, 20,797 functions, TCC 599,397 / GCC 644,315 = **0.93x**. The five generated files (`memclr`, `memcpy-a1`, `-a2`, `-a4`, `-a8`) carry 2,049 functions each = 10,245 of 20,797 (49.3% of the functions, 55.2% of the instructions). Excluding them: TCC 296,374 / GCC 260,475 = **1.14x**. Median per-function ratio **1.00x**. Better on 10,023 functions (−117,728 instructions), worse on 6,997 (+72,810), identical 3,777; `main` is 47.2% of the gross excess across 1,331 `main`s. Every claim the voiceover makes about this corpus reproduces at HEAD.

Encoding width — **re-measured 2026-08-25**, and the sample matters more than the previous note allowed. Counting each instruction's encoded length from objdump's byte column over the `gcc-execute` dumps (`--suite gcc-execute --dump-dir`), and excluding the same five generated files: **TCC 29.0% wide vs GCC 34.2%**, over 1,788 tests (TCC 169,285 instructions, GCC 143,438). Left in, those five alone read 9.6% wide for TCC against 41.9% for GCC and drag the whole-suite figure to TCC 16.4% vs GCC 39.8% — the same contamination as the instruction ratio, and much stronger, so quote the excluded-five number. Over the *first 250* execute tests only — the cut the 2026-08-20 collection used — it reads TCC 29.7% vs GCC 31.7%, close to but not identical with the 29.6%/32.6% that collection recorded; the exact 250 could not be reproduced. **The direction is the same in every cut and TCC is the narrower of the two**, which is all the line claims.

**Encoding width, part two — the three cards added 2026-08-26** (`s13_b6`,
`s13_b7`, `s13_b8`), which turn the dismissal into an explanation. Same sweep,
same exclusion, re-run and reproduced *exactly* — 169,285 / 49,137 for TCC and
143,438 / 49,085 for GCC, to the instruction — from a fresh build of `803a2f25`
in a throwaway worktree, because the in-tree `libs/tinycc/armv8m-tcc` is an ARM
binary under the self-host configure and will not exec (see
`tinycc-two-configures-test-vs-rootfs`):

    git -C libs/tinycc worktree add /tmp/tcc-encwidth 803a2f25 --detach
    cd /tmp/tcc-encwidth && ./configure --enable-cross --enable-O2 --disable-asan && make cross -j
    TCC_OVERRIDE=/tmp/tcc-encwidth/armv8m-tcc ./.venv/bin/python \
        ./scripts/regression_disasm.py --suite gcc-execute -j24 --csv --dump-dir DUMPS

**The byte column is arithmetic, not a third measurement** — a 16-bit encoding
is two bytes and a 32-bit one is four, so `bytes = 2 x instructions + 2 x wide`:

                       instructions      32-bit wide       code bytes     B/insn
    tcc -O2                 169,285     49,137   29.0%       436,844       2.58
    gcc -O2                 143,438     49,085   34.2%       385,046       2.68

TCC is **1.135x** the code — +51,798 bytes — while winning bytes-per-instruction
outright. That flip is the point of `s13_b8` and the reason the whole encoding
segment now exists rather than being one dismissive line.

**The like-for-like cut agrees and is what to quote if anyone pushes.** Over
only the 6,053 functions both compilers emitted under the same name — dropping
what GCC inlined away and the helpers TCC emits into its own object, which are
14,971 instructions on TCC's side against 1,228 on GCC's — it reads TCC 154,314
insns / 30.1% wide / 401,396 bytes against GCC 142,210 / 34.3% / 381,958, so
**1.05x** rather than 1.135x. Narrower per instruction and bigger overall in
both cuts; only the size of the loss moves. The whole-`.text` cut is the one on
screen because it is the *same population* the 29.0%/34.2% card is cut from, and
the two cards have to compose.

Worth knowing before quoting an instruction ratio off this sweep: the same
matched-function cut gives **1.09x** on gcc-execute, which is neither the 0.93x
nor the 1.14x of the `--suite all` collection. Three different populations,
three different numbers, and only the byte ratio is claimed on screen.

`s13_b7`'s function is `std_eqn` from
`gcc.c-torture/execute/divconst-2.c`, and it reproduces from four lines of C
with no test suite in sight:

    long std_eqn (long num, long denom, long quot, long rem)
    { return quot * (-0x7fffffffL - 1L) + rem == num; }

    armv8m-tcc -O2 -c eqn.c -o eqn_tcc.o
    arm-none-eabi-gcc -mcpu=cortex-m33 -mthumb -O2 -std=gnu11 -c eqn.c -o eqn_gcc.o
    arm-none-eabi-objdump -d eqn_{tcc,gcc}.o

TCC: 9 instructions, **0 wide**, 18 bytes. GCC: 5 instructions, 2 wide, 14
bytes, plus a two-byte alignment `nop` the card drops as padding rather than
code — say so if challenged, because left in, GCC reads 6 / 16 bytes / 33.3%
wide and the gap is two bytes rather than four. Dropping it is what makes the
accounting land exactly on TCC's two leading register moves: `lsls`+`adds` (4 B)
against `add.w …, lsl #31` (4 B), `cmp`+`ite`+`moveq`+`movne` (8 B) against
`subs`+`clz`+`lsrs` (8 B), `bx lr` (2 B) against `bx lr` (2 B), and
`mov r1, r2`/`mov r2, r3` (4 B) against nothing. The clip asserts those three
equalities at load time rather than writing them on the frame as a claim.

**What `s13_b8` must not be allowed to imply**, and the narration is written to
avoid it: this is *not* where the 1.14x cycle headline comes from. The benchmark
image links into SRAM, and `tcc-rig-image-size-confounds-benchmarks` is about
the code-to-data offset rather than about size. The claim is only that bytes are
charged for — by the flash the image has to fit in, and by the 16 KiB XIP cache
scene 8 already drew.

**VOICEOVER MISMATCHES introduced by the 2026-08-25 re-measurement** — two, both small, neither changing a point being made:
1. The narration says the optimizer bought doubles "one point zero zero". Measured, it is **1.01x** (8,459,166 → 8,390,567, a 0.82% gain). The animated card says 1.01x. Either re-record the word or accept the card reading one hundredth higher than the line.
2. ~~The narration says wide encodings are "twenty-nine point six percent … GCC, thirty-two point six".~~ **Resolved 2026-08-26**: that sentence was replaced outright when the encoding segment was extended, and the new passage says twenty-nine and thirty-four. The whole block from "And encoding width" to "it was the wrong ratio" is unrecorded and needs a take.

CI measures cycles on real silicon via a self-hosted Raspberry Pi 5 runner with a board attached, not in an emulator. `metrics/gate.py` compares a run against its parent and can fail the build.

Header fixed: the tone field held a second duration ("2:00 · 2:30"). Set to 2:30 with a real tone. The `*new_scene*` marker was dropped from the title — only `*deleted_scene*` means anything on import, so it was being carried as literal title text.

VERIFY: the correctness beat was cut from this draft rather than left stale. The old script said "nineteen open codegen failures as of the twelfth of August, last fully green run the sixth, 4,467 passed / 87 skipped", from rig run `logs/68`. None of that was re-measured in this pass and the count will have moved. Re-run the on-board suite, then decide whether to put the beat back — it was a good beat and the video is better for having it.

## Change Request


---

<!-- scriptforge:scene a15cfa6d-2a85-4cfd-94d1-8e73e9b348e6 -->
SCENE 15 · 2:00 · FORWARD-LOOKING, ENGAGING

# Roadmap: VGA, keyboard, Doom

## Voiceover

So where are we now? TinyCC is running natively on the MSPC board, and the compiler foundation is stable enough to start adding the missing user-facing pieces.

Right now the system has a basic shell running the toybox userland suite, a VFS layer for ROMFS, RAMFS, and memory cards, round-robin scheduling with I/O and sleep wait queues, and of course the native C compiler.

But the OS is still fragile. I still need to harden the OS and the basic libraries like libc. I did add some user-process error handling and safety — a crashing user program no longer takes down the whole OS — but there are still gaps.

Functionally, the next step is VGA output, plus keyboard and mouse input through the USB hub. The problem: the RP2350 USB host has known errata, so this may fail in a way that forces a board revision. We'll see.

And Doom is the long-term milestone. That needs compiler optimizations too — I plan to compile it with TinyCC right here on the board, the same as every other tool in the rootfs. One thing at a time though: video and input first, then eventually Doom. If the USB host misbehaves badly enough, everything shifts to a board revision. I'm hoping it doesn't come to that.

## Scene Description

Talking head opening with creator at desk with dual monitors and RGB lighting. Cuts to diagram overlays of YasOS architecture, VFS layers, and scheduler queues. Mid-section shows top-down macro shots of MSPCv2 board with USB hub wiring and connections to VGA card. Ends with a wide shot of the desk setup, then a terminal window showing current build status and an ASCII Doom mockup teasing the goal.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator talking to camera at desk with dual monitors RGB backlight | 0:00-0:20, 1:10-1:50 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Top-down macro of MSPCv2 board with USB hub cable and VGA card connections, board hub wiring close-up | 0:45-1:10 | to record |
| Clean white diagram overlays: VFS stack ROMFS/RAMFS/SDIO, scheduler round-robin with wait queues | 0:20-0:45 | motion/s14_b1_what-the-system-has-now.py |
| Clean white roadmap timeline diagram: current state (TinyCC, shell, VFS, scheduler) → VGA output + USB hub keyboard/mouse → Doom; red risk marker on the USB host step | 1:50-2:00 | motion/s14_b2_roadmap-timeline.py |

## Notes

Recap current OS state, outline the next phases (set up the VGA/keyboard through USB hub, show board hub and connections). Raise problem that host on RP2350 has bugs and it may fail not nicely.

Show the physical USB hub and VGA card connections on the board (top-down macro) while naming the RP2350 USB host errata — it is the main schedule risk, so say clearly that a board revision is possible. End with a terminal showing the current build status or an ASCII Doom mockup to tease the goal. Tie the roadmap back to episode 3's promised plan (VGA/keyboard first; Doom as a long-term milestone).

Keep this scene forward-looking: do not re-explain the TinyCC optimizer, GCC torture suite, or hardware speed-up work that earlier scenes already covered.

## Change Request


---

<!-- scriptforge:scene 59ac4bbf-bef1-4229-b7a1-e7bca3e9c1ac -->
SCENE 16 · 1:40 · WARM, CONVERSATIONAL

# Outro & Community Engagement

## Voiceover

That's it for this deep dive into TinyCC. We went from a single-pass Thumb backend to an IR-based optimizer with a register allocator. The GCC torture suite now runs in under an hour on the board, and the compiler can compile itself without manifesting bugs.

Thank you for sticking through the story — the miscompilations, the XIP bottleneck, the SMP dead end, and the QEMU changes for host testing.

Repositories are in the description for anyone interested.

Thanks for watching, and see you in the next one.

## Scene Description

Talking head close-up of creator at desk with dual monitors and RGB lighting, then slow push-in for sign-off. Intercut with brief cutaways of terminal output showing TinyCC self-compile success, GCC torture suite progress, and the board. Ends with wide shot from behind the creator showing the desk setup and monitors, then fade to black.

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

