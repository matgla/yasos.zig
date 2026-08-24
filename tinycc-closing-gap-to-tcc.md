<!-- scriptforge:scene 43194696-8497-49d2-9fb4-432ee1b725e7 -->
SCENE 01 · 3:00 · WELCOMING, INFORMATIVE, ENERGETIC

# Intro & Project Overview

## Voiceover

Hi, welcome to the next episode of my series!

If you're new here, let me catch you up. I'm building a custom computer from scratch. The current hardware is the MSPCv2 motherboard I designed. It has an RP2350 microcontroller, or MCU, an upgrade from the RP2040, plus 8MB of slow external RAM, 512KB of fast internal SRAM, and 16MB of Flash storage. So I also support combining the Pimoroni Pico Plus 2 with the Pimoroni Pico VGA Demo Base.

On top of that hardware, I'm writing YasOS, my own operating system in Zig. The recent milestone is TinyCC: a small C compiler, initially without sophisticated optimization techniques, but small enough to run natively on my board. The microcontroller runs it directly, and the compiler generates native ARMv8-M Thumb machine code, so the board can now compile code for itself. It's nearing a self-hosting loop—a compiler rebuilding itself with its own toolchain. The remaining pieces are recompiling YasOS itself and rebuilding the whole toolchain on the host. I still don’t have make, and TinyCC is now large enough that I don’t think it will fit in RAM, so splitting its architecture is future work.

But the first version of my TinyCC fork, which added ARMv8-M backend support, could compile simple Hello World programs, but it was barely functional. The ARM backend was full of bugs and incredibly slow. It had no AST, the parsed code tree; no IR, intermediate code for analysis; no optimizer; and no register allocator to choose CPU registers. Original TCC is a straight C-to-machine-code translator without any abstractions.

So, over the last six months, I've been doing a complete rewrite. This video will cover the most important changes I made. To summarize, I moved from direct translation to a full optimizing backend with a three-address-code intermediate representation, later transformed to SSA with a linear register allocator. I integrated the GCC torture suite, a large set of tricky compiler tests, and hunted down thousands of bugs that manifested on the board. Then I optimized RP2350 bottlenecks around slow external memory access, and ended up with a compiler running fast enough that I can run nearly the entire GCC torture suite—over 4,000 files—directly on the microcontroller. This is how slow it was, and this is the speed after the changes. 

The idea to integrate optimizations into TinyCC came to me when I saw Falbesoner's research on implementing a global register allocator in an older TinyCC version for ARM architecture. If you are new to compiler internals, this is a really good paper to understand intermediate representations and optimization techniques that help a compiler select processor registers in a smarter way.

Let's get into it.

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
| Top-down macro of the MSPCv2 board next to the Pimoroni Pico Plus 2 and Pico VGA Demo Base, held still as a context shot. | 1:02-1:18 | to record |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Clean, minimalist overlay diagram appearing next to the creator; hierarchy builds as spoken: `MSPCv2 Board` → `RP2350 MCU` → `YasOS (Zig)` → `TinyCC` | 0:04-0:20 | to animate |
| Quick montage of text overlays popping up in sync with the spoken points: `SSA Backend`, `GCC Torture Suite`, `Optimizations`, `PSRAM/XIP Bottlenecks` | 0:32-0:50 | to animate |
| Clean split-screen overlay: old compiler terminal output scrolls slowly through the same test list, then new compiler output jumps rapidly down the lines | 0:50-1:02 | to animate |
| Clean transition overlay: 'Next: compiler internals' with a simple arrow pointing into the next scene. | 1:50-2:00 | to animate |

## D-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Minimal paper-card overlay: 'Falbesoner's TinyCC paper' with one small arrow from 'C code' to 'machine code'. | 1:18-1:42 | to animate |

## Notes

Include the requested 1-minute overview for newcomers as per reference notes. Establish the full stack context (MSPC -> RP2350 -> YasOS -> TinyCC). Bridge from last episode's 'it runs' to the current reality (slow/buggy) to justify the 6-month rewrite focus. Visuals should support the overview without re-explaining hardware assembly details already covered.

Extracted compare cue: old TCC / GCC / TCC -O2. Use as visual/annotation only, not spoken.

Keep non-expert glosses brief: one phrase per keyword, and prefer spoken definitions over on-screen jargon.

Keep the added comparison to one quick visual teaser; the full demo comes later.

Keep the host rebuild limitation brief in the intro: no make, TinyCC too large for RAM, architecture split is future work.

## Change Request


---

<!-- scriptforge:scene db43021b-3094-4c06-8921-7f3e8cc6dbb1 -->
SCENE 02 · 1:45 · URGENT, TECHNICAL

# GCC Test Suite

## Voiceover

As I mentioned, the first version of my tinycc fork contained bugs. Many of them only showed up in the native compiler built by the buggy cross-compiler, and then only on the RP2350 itself. I needed a much wider net than my own examples: a public torture suite with thousands of tests that stress compiler backends, exercise C standard features, and catch codegen regressions. That's why I chose the GCC torture suite — over 4000 test files. But running that raw, unoptimized code on the board was painfully slow. On -O0 alone it would have taken hours, which made it useless as a regular regression gate. To make the suite viable, I needed to speed things up significantly. That led directly to the need for an optimizing compiler backend.

So I set a hard target: the full suite on -O0 tests only, in under half an hour. When I first kicked it off, I didn't wait for it to finish. After about an hour I dropped the run — progress was sitting around 25% and barely moving. That was the moment I knew the single-pass backend had to go. From here on, every optimization pass had to pay for itself in compile time.

So the question wasn't whether I could optimize something; it was whether the suite could become a usable regression gate. That's what this whole path was about. It’s also a wider win than just the regression gate, because the same optimizations benefit everything built with my TinyCC. Whether it actually works, I’ll show when we get to the live run.

## Scene Description

Close-up of the terminal emulator. The GCC torture suite is compiling and running test files rapidly. A text overlay shows 'Target: < 1 hour' and a live timer counting up. As tests pass, a progress bar fills and the timer slows visibly. Cut to a split-screen comparison: before (unoptimized) showing hours, after (optimized) showing minutes.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Overlay showing test progress percentage and elapsed time decreasing as optimization passes are enabled, with a bar chart contrasting initial hours vs. final <1 hour. | 0:45-1:15 | to record |
| Overlay showing elapsed time passing one hour with progress frozen near 25%, then the run being aborted and the log file closed. | 0:30-0:45 | to record |
| Terminal output on the RP2350 target shows a native TinyCC crash log — an unexpected instruction fault or invalid address — while the cross-compiler build log above it indicates the compiler was built from the buggy cross-compiler. | 0:05-0:20 | to record |

## Notes

Reference: v0.1.0_tinycc_changes.md - 'Note: Why I needed optimizations'. The suite takes 4000+ tests. Goal was 0.5h on -O0 but achieved all -O0/1/2 in ~50min.

**VERIFY** the "killed at ~25% after an hour" run. Nothing in the docs records it and each run wipes `logs/`. Either find a log to put on screen or narrate it explicitly as recollection.

VERIFY: The 25% after one hour is now spoken as recollection; no durable log is assumed because each run wipes logs/.

VERIFY: the "~50 min for all of -O0/-O1/-O2" figure. Not re-measured in the 2026-08-20 data pass — that number needs a full on-board suite run, which was not part of it. The host-side codegen numbers in the Scorecard scene WERE re-measured and have moved a long way, so do not assume this one held still either.

## Change Request


---

<!-- scriptforge:scene b8afcb96-12bb-4513-81a5-6e847c7e2ea7 -->
SCENE 03 · 2:00 · TECHNICAL, ANALYTICAL

# From Single-Pass to Multi-Pass: Introducing IR

## Voiceover

Since the original TinyCC is a single-pass compiler. There is no abstract syntax tree, no intermediate representation, no optimizer, no register allocator. Direct translation from C constructs to machine instructions is crazy fast. That approach is great if you only need to produce correct code, but it leaves no room for optimization. And for most of usages optimization is what separates a toy compiler from a tool you can use instead of beasts like gcc or clang.

To enable optimizations I had to introduce an Intermediate Representation. My plan was same as in paper I discovered. Instead of machine code generation I'll generate IR representation, that I can transform in optimization loops. Then since I have code represented in memory I can apply backend level optimizations like shifting instructions for Thumb opcodes and finally generate machine code from already simplified program. Three-Address Code representation proposed in paper is simple, can be memory efficient, while still being fast. I took that approch. TAC is simple: every instruction is represented at most by three operands. Typically two sources and one destination. For example x = (a + b) / c; represented in TAC becomes t1 = a + b; t2 = t1 / c; x = t2; source 1, source 2 and destination. Similar for conditional instructions that becomes in if (t1 > t2) goto L1, source 1, source 2 and desitnation. With this representation a whole function is just a contiguous array in memory.

That in-memory representation is what makes the compiler multi-pass. 

This was enabler for optimization. I can now analyze that data, transform and finally produce optimized code.

## Scene Description

Diagram showing the original Single-Pass flow (Parse -> Codegen) with a red 'no IR / no optimizer' annotation. Diagram showing the new Multi-Pass flow (Parse -> TAC IR -> Opt Passes -> Codegen) with labels for three-address IR and control-flow graph. Whiteboard diagram of TAC definition with rule t = op t1 t2, and a memory-layout inset showing fixed-size TAC instruction: opcode, src1, src2, dst, jump target. Animation of TAC instructions being grouped into basic blocks and connected into a control-flow graph. Split-screen code example: C source on left, TAC IR in center, and basic-block boundaries highlighted. Animation of optimization passes on IR nodes with constant folding and dead store elimination highlighted. Close up of IR nodes being manipulated and optimization passes rewriting them. The pipeline settles on the final codegen stage. On-screen counter showing optimization pass count rising from 0 to ~140. End card for the section: side-by-side compiler pipeline before and after, with the '~140 passes' badge.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Whiteboard TAC rule t = op t1 t2 with memory-layout inset showing opcode / src1 / src2 / dst / jump target | 0:50-1:30 | to record |
| Animation of TAC instructions being grouped into basic blocks and connected into a control-flow graph | 1:30-2:00 | to record |
| Split-screen C source vs TAC IR vs SSA, phi functions highlighted with a circle | 2:00-3:00 | to record |
| FPU scheduling close-up: floating-point TAC ops mapped directly onto hardware FPU instructions | 4:00-4:30 | to record |
| End card: side-by-side single-pass vs multi-pass pipeline, ~140 passes badge | 4:30-5:30 | to record |

## Notes

Correction: Original TCC was single-pass without AST. Content now reflects introduction of IR for multi-pass optimization.

Extension details drawn from v0.1.0_tinycc_changes.md covering submodule range cae3a049→fb3a6c57. Original TCC described as single-pass without AST/IR; IR introduced without full AST to enable multi-pass optimizations.

TAC description and transformation example added to make this the core 5-minute segment. IR introduced without full AST per v0.1.0_tinycc_changes.md.

Extended to cover the full IR pipeline: TAC instruction layout, control-flow graph construction, and optimization passes. The single-pass description is preserved from the original note; new content is grounded in v0.1.0_tinycc_changes.md (three-address IR, ~140 passes). Floating-point support is handled in the separate Floating Point scene.

The FPU B-roll row belongs to the separate Floating Point scene, not this IR scene.

New scene to add after this one: Global Register Allocator: Linear Scan. Draft voiceover: After SSA, the compiler still has values, not registers. The global allocator treats the whole function as one timeline. It assigns a start and end to each SSA value, walks the timeline left to right, and keeps a live register pool. When a value starts and a register is free, it takes one; when a value ends, the register returns. If the live set grows larger than the RP2350 register file, the allocator spills the least active value to a stack slot and restores it later. Phi nodes become simple copies at their join points after allocation. This is why the allocator is global: a local choice can poison a later loop, but linear scan over the whole function makes spills and register pressure visible. Use the tinycc allocator implementation to confirm pass names, live-range construction, and spill strategy before finalizing the script.

SSA and global register allocator details are intentionally removed from this scene and should live in the separate SSA/global register allocator scene.

B-roll row 'Split-screen C source vs TAC IR vs SSA, phi functions highlighted with a circle' should be dropped or re-shot as C source vs TAC IR with basic-block boundaries highlighted.

## Change Request


---

<!-- scriptforge:scene c1e244cb-e49a-4ff0-86cc-dd7cfab8601e -->
SCENE 04 · 3:30 · CALM, EXPLANATORY, SLIGHTLY PROUD

# Global Register Allocation: Linear Scan

## Voiceover

But TAC on its own is a linear instruction list. Without transform passes it generates the same machine code an unoptimized compiler would. So for the first real optimization I built a control-flow graph on top of it, grouping instructions into basic blocks. Now a pass can reason about the whole function instead of one instruction at a time — and that is what I needed to work out lifetimes across branches and loops.

Lifetime here is deliberately cheap. Every virtual register gets one live interval: a start and an end, two instruction indices, nothing more. A forward walk over the instruction list gives me the first definition and the last use. Then the graph fixes what that walk gets wrong — a value used inside a loop has to survive to the back edge, a value feeding a call argument stays alive until the call itself, and a value whose address is taken lives as long as any pointer derived from it.

That's not precise. A value live on two exclusive branches gets one interval covering both, so it looks like it conflicts with everything in between. I took that on purpose. One interval is two integers, and that is the whole reason the next part is cheap.

Now I can allocate. Sort the intervals by start point and walk them in order, keeping an active set of the ones currently holding a register. At each interval, first expire everything that already ended and hand those registers back to the free pool, then give the current one whatever is free. If nothing is free, something has to go to the stack — and I spill the cheapest one, not the longest. Every use is weighted by loop depth, so a value used once outside a loop loses to a value used once inside it.

And that is the win. TinyCC keeps every local in its stack slot for the entire function: read it three times, that's three loads; write it twice, two stores. On top of that it flushes live temporaries to the stack before every call. With intervals I can keep a value in a register across the gap between two uses, and only spill when I genuinely need the register back. On a desktop the cache hides most of that traffic. On RP2350 it doesn't — the extra instructions come over QSPI, out of flash.

For the algorithm I followed Sebastian Falbesoner's linear scan proof of concept for TinyCC; the original algorithm is Poletto and Sarkar's. Linear scan isn't the best allocator. Graph coloring would spill less. But graph coloring wants an interference matrix that's quadratic in live values, and a simplify loop with no useful bound on rounds — and I still aim to run this compiler on the microcontroller, not just target it. Linear scan is one sorted pass and a handful of bitmaps. Its complexity is the point.

## Scene Description

Talking head with a clean, abstract linear-scan diagram: horizontal instruction order, colored live intervals, register lanes below, and stack spill slots when register pressure gets high. Keep any code abstract and do not show unverified TinyCC source.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator at desk explains why TAC needs a CFG, live intervals, and a cheap allocator for on-target TinyCC. | 0:00-1:00 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Minimal linear-scan animation: horizontal instruction timeline, colored live intervals, register lanes, and stack spill slots appearing under pressure. | 0:12-0:42 | to create |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Abstract register-pressure readout: active intervals, free registers, and spill count updating as the scan advances; no source code. | 0:36-0:52 | to create |

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

I was hungry for more. Putting TinyCC's disassembly next to GCC's, I saw a lot of opportunity.

At that point the compiler was already working. But working and good are not the same thing. The output was full of small inefficiencies: extra loads, extra stores, temporary values spilling to memory, registers reused too late, and code that kept moving data around for no obvious reason.

On a fast x86 machine, that kind of thing is easy to ignore. On RP2350, it is not. We are talking about a microcontroller with limited registers, limited cache, and a memory system that will absolutely punish you for bad code.

So I started asking the obvious question: why does GCC produce cleaner code?

The answer was not one clever trick. It was a better representation.

That is where SSA came in.

Static Single Assignment form rewrites the program so that every value is defined exactly once. If a variable is written three times, the compiler stops treating it as one mutable thing and starts tracking separate versions — x_1, x_2, x_3 — and each one has exactly one definition, in exactly one place.

That sounds almost boring. Here is why it isn't.

In my IR, a local variable is a stack slot. Every read is a load, every write is a store, and the register allocator from the last chapter can do nothing about it — there is no value there to allocate, just memory traffic. The first thing SSA construction does is remove the stack slot where possible. If a variable's address is never taken, it stops being memory and becomes a value with a name.

Then, where two paths meet and each one carried its own version, SSA inserts a phi node to pick between them. I place them on the dominance frontier, and only where the value is still actually live, so I don't manufacture phis nobody reads. A walk down the dominator tree then renames every use to the version that reaches it.

And now the questions get clean. Where did this value come from? There is one answer, and it is an instruction — not a search. Is this store dead? Is this copy redundant? Is this constant still a constant here?

That is the unlock. SSA did not magically make TinyCC fast. It made the optimizer possible in a serious way. Constant propagation, global value numbering, range propagation, load CSE, and about a dozen separate dead-store passes all sit directly on top of it.

And most importantly, it gave the register allocator something worth allocating. Because register allocation is not just "find a register." On ARMv8-M, register pressure is real. If you allocate badly, you spill. If you spill, you touch memory. If you touch memory, you lose.

SSA was the bridge between "we have an IR now" and "we can actually do something really decent with it."

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator at desk, close-up, speaking directly about comparing TinyCC output to GCC. | 0:00-0:10 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Split-screen GCC and TinyCC ARM Thumb disassembly; highlight redundant loads, stores, and spilled temporaries in the TinyCC side. | 0:10-0:24 | to record |
| IR/code view showing a local variable stack slot being replaced by named SSA values; loads/stores fade out. | 0:36-0:48 | to create |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Minimal SSA diagram: mutable x becomes x_1, x_2, x_3, with one definition per version. | 0:24-0:36 | to create |
| Control-flow graph with two branches merging; highlight the dominance frontier and insert a phi node picking between incoming values. | 0:48-1:00 | to create |

## D-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Terminal/pass-list overlay: constprop, GVN, range propagation, load CSE, dead-store elimination; then a spill-count metric dropping after SSA. | 1:00-1:15 | to record |

## Notes

Insert after the IR introduction and before the floating-point scene. Use on-screen side-by-side GCC/TCC disassembly, highlight redundant loads/stores and spilled temporaries. Brief SSA diagram showing x_1, x_2, x_3.

Keep the visual order tied to the voiceover: inefficiency -> SSA values -> phi nodes -> register allocator payoff.

## Change Request


---

<!-- scriptforge:scene fc69ed8a-5414-4c38-b2d7-2ad047f17b8d -->
SCENE 06 · 2:00 · PRACTICAL, TECHNICAL, SLIGHTLY EXCITED

# Floating Point: Inline VFP, AEABI, SoftFP, and RP2350 DCP

## Voiceover

Floating point support was a must for me. I wanted to run GNU Make on the target, and it failed the moment it touched floating point numbers — my codegen was emitting wrong instructions.

The plan was simple: describe what the hardware can actually do in a table, and let everything else follow from that.

RP2350 has hardware floating point, but only for 32-bit float, through the FPv5-SP extension on the Cortex-M33. Doubles are a different story. Raspberry Pi put their own coprocessor on the chip — the DCP, on coprocessor port four. It is not an FPU. It gives you primitives that a short instruction sequence composes into a real IEEE double operation, and it works on general-purpose register pairs, not on any floating point register file. That last part mattered more than I expected: it means doubles keep the ordinary soft-float calling convention, so I never had to add a double register class to the register allocator. What I lose is portability — DCP code will not run on any other ARMv8-M part.

So, three ways to get a double multiplied:

Pure software floating point. Slow, but it runs on anything with the same CPU architecture. Compile once, run on any yasos.zig board.
Hardware, behind a call. The codegen emits __aeabi_dmul, and the loader resolves it from whichever FP library the binary was built against — libsoftfp, libvfpv4sp, libvfpv5dp, or librp2350fp. The library itself uses the coprocessor, so you get the hardware; you just pay for the call.
Hardware, inlined. The instruction sequence goes straight into the code. Fastest, and no portability at all.
The important part is that the last two are not a choice. They are the same path at two stages. I have a table of bits — one per operation — and when a bit is clear the operation becomes a library call, when it is set the backend emits it inline. So I started with pure soft float, then flipped bits one at a time as each inline sequence landed. Today float add, subtract, multiply and divide are inline, and on the double side add, subtract and compare. Everything else still goes through the library.

And the loader checks before it runs anything. Every binary declares the FPU it was built for, its float ABI, and a bitmask of what it needs — single precision, double precision, DCP. If the hardware does not have it, the image is rejected instead of crashing.

The other half of this was the OS itself: once floating point registers are in play, the context switch has to save and restore them. That is a topic for another video.

And the GCC torture suite gave me a lot of floating point tests, which I extended with my own. That is what actually found the bugs.

## Notes

Insert after Scene 11 or before the Roadmap. Use a split screen or overlay to show the three FP modes: inline VFP, AEABI calls, and softfp. Mention RP2350 DCP as a target-specific acceleration path without over-explaining it unless confirmed.

Confirmed 2026-08-20: all four runtimes named in the voiceover exist and are built — `lib/fp/libsoftfp.a`, `libvfpv4sp.a`, `libvfpv5dp.a`, `librp2350fp.a`.

VERIFY: the exact inlined-operation list — "float add, subtract, multiply and divide are inline, and on the double side add, subtract and compare". Could not confirm it against the backend in the 2026-08-20 pass, and it is the kind of claim that moves: there has been a lot of recent soft-float work (dadd rewrite, classify-chain nesting). `lib/fp/STATUS.md` is NOT a reliable oracle here — it still lists implemented files as "TODO: implement". Check the backend's call-vs-inline decision directly before recording.

The doubles measurement in the Scorecard scene is worth knowing about here: on the RP2350, doubles cost 1.64x GCC and the optimizer gained them nothing (1.00x from -O0 to -O2). If this scene wants a forward hook, that is the honest one.

## Change Request


---

<!-- scriptforge:scene 6c3f06d0-d11a-415d-b735-0245e1e7b03b -->
SCENE 07 · 1:40 · FOCUSED, PROBLEM-SOLVING

# Debugging Miscompilations & Optimizers

## Voiceover

Once the GCC torture suite started running on the board, the failures showed up fast. Hundreds of them.

Here's a representative one. Split screen — source on the left, GDB on the right. A simple loop that should collapse to a constant, and the generated Thumb-2 code jumps to the wrong address.

This was still the old path: AST straight to machine code, nothing in between. So there is nothing to inspect. No intermediate form to dump, no way to ask the compiler what it thought the program was. You reproduce it with the smallest test case you can build, put prints around the value stack, and read disassembly until something looks wrong. In this case it was a double vstore — the same value written twice, and the second write landed somewhere it should not have. One line fixed it.

That is the part worth sitting with. The fix was one line. Finding it took an afternoon, because the compiler had no memory of its own reasoning. That is the real argument for building an IR — not that it makes the compiler better, but that it makes the compiler answerable.

But fixing miscompilations was only half the problem. Four and a half thousand tests, each one run at -O0, -O1 and -O2 — about thirteen thousand compile-and-run cycles. My first attempt was crawling. After an hour it had reached maybe a quarter of the way.

So I needed the compiler itself to be faster. And here is the useful part: TinyCC compiles TinyCC. The cross compiler builds the native one. So every optimization I add makes the compiler that gets built better — which makes the next suite run faster, which makes the next round of debugging bearable.

That is what all the machinery was for. Three-address IR. SSA. A linear-scan register allocator. About a hundred and forty optimization passes on top. Hardware floating point for RP2350.

And honestly — the optimizations introduced new bugs. That is the trade. Every pass is a new opportunity to be wrong, and a lot of them were. I kept fixing them.

It paid off. The full suite, all three optimization levels plus my own tests, now finishes in about fifty minutes on the board.

And the real payoff: the native TinyCC is now fast enough to compile itself.

## Scene Description

Talking head intro transitions to split-screen debugging. Left side shows TinyCC source and the minimal test case in VS Code, right side shows a GDB terminal with backtrace, register dump, and disassembly of the wrong jump highlighted. Overlay diagram of AST → Three-address IR → SSA → optimized IR → machine code with ~140 passes labeled. A short diff view shows the one-line double vstore fix. Closes with a terminal showing the torture suite progress stalled at ~25% after one hour, followed by the full suite completing in ~50 minutes.

## A-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Creator at desk with dual monitors, talking head, RGB lighting. | 0:00-0:20 | to record |

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Split-screen: left side TinyCC source in VS Code, right side GDB terminal with backtrace and register dump. | 0:22-0:55 | screen capture |
| Diagram overlay showing AST → Three-address IR → SSA → optimized IR → machine code pipeline with ~140 passes labeled. | 0:56-1:10 | motion graphic |
| Terminal output of GCC torture suite progress bar, test count 4000+, elapsed time ~50 minutes. | 1:11-1:30 | screen capture |
| Split-screen: left side the minimal test case in VS Code, right side GDB stepping through vstack increments with print statements, call stack showing vstore called twice. | 0:45-0:55 | screen capture |
| Diff view highlighting the one-line double vstore fix, with text overlay 'root cause: vstore called twice'. | 0:55-1:02 | screen capture |
| Terminal showing torture suite progress stalled at ~25% after 1 hour elapsed, text overlay 'too slow — need a faster compiler'. | 1:02-1:12 | screen capture |
| Side-by-side terminal: before (1 hour → 25%) vs after (~50 min → 100%), ending with overlay 'native TinyCC compiles itself'. | 1:30-1:40 | screen capture |
| Corrected B-Roll sequence: 0:22-0:35 split-screen source/GDB miscompilation; 0:35-0:55 vstack prints and double vstore call stack; 0:55-1:02 one-line diff; 1:02-1:12 suite stalled at ~25% after 1h; 1:12-1:25 self-hosting pipeline diagram; 1:25-1:40 before/after 50 min completion. | 0:22-1:40 | screen capture / motion graphic |

## C-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Close-up of the double vstore line in VS Code, with the duplicate call highlighted and text overlay 'root cause: vstore called twice'. | 0:50-0:56 | screen capture |
| Close-up of terminal progress bar completing at 100%, elapsed 49:42, ending on 'native TinyCC compiles itself'. | 1:34-1:40 | screen capture |

## D-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Diagram overlay showing the self-hosting loop: cross TinyCC builds native TinyCC, which runs the torture suite and exposes more bugs faster. | 1:12-1:22 | motion graphic |
| Diagram overlay showing the optimization trade-off: more IR passes improve speed and codegen, but each pass adds new failure modes to test. | 1:22-1:28 | motion graphic |

## Notes

Walk through a specific miscompilation case, show split-screen code/GDB traces, and detail how ~140 optimization passes and hardware FP support were implemented to fix them.

Reference v0.1.0_tinycc_changes.md for commit range cae3a049 → fb3a6c57, 31 commits, ~140 optimization passes, SSA register allocator, hardware FP support, and GCC torture suite timing ~50 minutes on RP2350.

Source facts worth keeping: hundreds of miscompilations fixed — many the same class of Thumb backend bug; the first torture run was dropped after 1 hour at ~25% progress; optimizations introduced new bugs (a trade-off that paid for itself in speed); the whole point was a cross compiler fast enough to produce a much faster native TinyCC. Reference v0.1.0_tinycc_changes.md — 31 commits, cae3a049 → fb3a6c57.

Roll pass: use the corrected B-Roll sequence row as the primary editorial sequence for this scene.

Pass count updated 2026-08-20 from ~180 to ~140: counted as distinct *named* passes in the optimizer pipeline — 60 in the flat pipeline table plus 79 in the `ssa:` / `ra:` / `flat:` namespaces = 139. Counting the DSL generator tables as well takes it to 211, and there are 131 individual rewrite rules underneath those. Pick one basis and keep it across scenes 03, 07 and 12; ~140 is the one those three now use.

VERIFY: "the full suite, all three optimization levels, finishes in about fifty minutes" and the "quarter of the way after an hour" figure. Neither was re-measured in the 2026-08-20 pass.

## Change Request


---

<!-- scriptforge:scene 18094da8-e9fb-4694-a74e-98b570130a43 -->
SCENE 08 · 2:30 · SERIOUS, HARDWARE-FOCUSED

# XIP Bottleneck: Why 532MHz Is the Ceiling

## Voiceover

Once TinyCC got fast enough, the bottleneck stopped being the compiler. It was XIP.

Execute-in-place means code lives in QSPI flash and gets fetched on demand, over a four-bit bus — a bus shared with the PSRAM. There is a 16 KiB cache in front of it, so it is not every instruction. But every miss costs about a hundred and forty-six core cycles at the clock I run. Miss often enough and the core is just waiting.

The flash tops out at 133 megahertz. The core can go much faster. So the obvious move is to overclock — and this is where it gets interesting, because the QSPI clock is not independent. It is the system clock divided by an integer.

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
| White diagram: core at 532 MHz, QSPI flash at 133 MHz, flash and PSRAM sharing the same 4-bit bus, stall cycles highlighted in red | 0:05-0:25 | to record |
| Oscilloscope waveform: QSPI clock at 133 MHz with 532 MHz core clock overlay, visible stall gaps where core waits on flash | 0:25-0:40 | to record |
| Thermal camera overlay of MSPCv2 board under compile load, false-color heat map with temperature readout climbing as clock rises | 0:40-0:55 | to record |
| Terminal window: GCC torture suite progress across -O0/-O1/-O2 plus own tests, final ~50 minute total | 1:25-1:50 | to record |
| Oscilloscope/log capture showing a clean PSRAM read and a corrupted PSRAM read at >600 MHz, with the bad byte highlighted | 0:55-1:25 | to record |
| On-screen text: “No >600 MHz scope capture available,” followed by a terminal/log view of a PSRAM stress test at 618 MHz showing intermittent wrong-byte errors, with the bad byte highlighted in text | 0:55-1:25 | to record |

## Notes

Explain why overclocking to 532MHz was necessary for XIP performance, show oscilloscope/thermal traces of stability limits, and discuss the trade-offs of pushing the RP2350 beyond 600MHz.

Anchor the entire segment on the shared 4-bit QSPI bus being the fundamental constraint — not the core clock itself. Emphasize the 4x ratio (532 vs 133 MHz) as the stable ceiling on the MSPCv2 board. The 600 MHz+ corruption is worth stressing as the worst kind for a compiler: rare and silent. The realistic number from the run is ~50 minutes for all -O0/-O1/-O2 plus own tests, not just -O0 — keep that as the headline benchmark.

I cannot capture the >600 MHz corruption on an oscilloscope; use a terminal/log capture or text overlay instead of a scope trace for that part.

## Change Request


---

<!-- scriptforge:scene f74992ff-ae01-4d4f-8426-b984a7552737 -->
SCENE 09 · 0:40 · HONEST, REFLECTIVE

# The SMP Experiment vs. XIP Reality

## Voiceover

Next thing I tried was two cores compiling code at once. I was hoping for twenty or thirty percent. I got 0.61x — parallel was slower than sequential.

Not the cores: a RAM-resident ALU loop gets 1.64x from core 1. It's tcc. It executes in place out of QSPI flash, through sixteen kilobytes of shared cache — and tcc's text is 1.4 megabytes. Two copies evict each other from a cache neither ever fit in. Forty-four percent more misses for identical work.

The cache is hardware. Nothing schedulable fixes it.

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
| Screen capture of Grafana metrics / profiling graph showing XIP cache misses rising under SMP load, with red spike overlay. | 0:20-0:45 | screen recording |
| Close-up of RP2350 board on desk with RGB lighting, USB cable connected. | 0:05-0:10 | to record |
| Screen capture of terminal showing two compile commands started with `&` and the `time` output, with the parallel run losing to the single-core baseline. | 0:12-0:20 | to record |

## Notes

Explain the failed attempt at dual-core SMP compilation, use a graph overlay to show XIP cache misses causing slowdowns, and justify returning to a highly optimized single-core workflow.

Pull the actual measured compile-time numbers from the benchmark (parallel vs sequential) and display them as a text overlay on the graph — a concrete figure makes the XIP bottleneck tangible. Also show the recorded XIP miss spike clip; it was huge.

SMP here means Symmetric Multiprocessing: both RP2350 cores run compile jobs at the same time under the OS scheduler.

VERIFY: the 0.61x parallel figure, the 1.64x RAM-resident ALU loop, and "forty-four percent more misses". Not re-measured 2026-08-20.

VERIFY: "tcc's text is 1.4 megabytes". The on-device binary is 1,654,488 bytes total (rootfs/usr/bin/tcc, YAFF, 2026-08-20), which is the whole image rather than .text alone. 1.4 MB matches the last recorded .text figure, but confirm .text specifically before saying it on camera.

## Change Request


---

<!-- scriptforge:scene 6a8304cf-e2d2-4b20-8627-524ee630511f -->
SCENE 10 · 0:45 · CALM, TECHNICAL, WITH A HINT OF RELIEF

# QEMU Support for Faster Development and TinyCC Linker Scripts

## Voiceover

To test tinycc on the host, I put a QEMU target in the compiler's own repo — 543 programs, compiled and run under mps2-an505. That forced a change in tinycc itself.

The compiler had a bare-metal memory map baked in, hardcoded for my dynamic loader. The only thing you could move was .text, with a command-line flag. QEMU's address space is somewhere else entirely.

So tinycc got a real linker script parser — fifteen hundred lines. MEMORY regions, SECTIONS, ENTRY, PROVIDE. Placement comes from a script now instead of an assumption, and one linker emits ELF for QEMU and YAFF for the board.

Then the same for the OS: two QEMU board ports, and a smoke run that needs no hardware. Same source — not the same build. QEMU is single-core where the board runs two, and userspace floating point differs.

That difference is the payoff, not a compromise. Logic bugs die on the desktop, and a QEMU pass next to a board failure is evidence of an SMP race — that's how I caught the reaper freeing a process's pages under the next spawn. XIP contention, timing, voltage marginality still need the board.

And it's cheap to try: clone it, install the tools, run the script. No hardware.

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


---

<!-- scriptforge:scene 37ed7794-13b0-490e-96f2-7dc13928c017 -->
SCENE 11 · 1:50 · TRIUMPHANT, TECHNICAL

# Live Demo: Compiler & Test Suite in Action

## Voiceover

Improved demo VO (~200 words)
[board, tcc running]

That's TinyCC running natively on a Pimoroni Pico Plus 2. Nothing is cross-compiled here — the compiler itself is executing on the microcontroller.

[suite starts scrolling]

And that's the GCC torture suite. About four and a half thousand tests, every one of them compiled on the board and then run on it.

[TUI / topology]

The board isn't on my desk. It hangs off a debug probe on a Raspberry Pi 5 somewhere on the local network — it isn't even powered over USB, the probe feeds it. My desktop drives the whole thing over SSH: build here, flash there, logs stream back live. That's real serial output from real hardware, as it happens.

[timer / result]

At -O0, the whole suite is ten minutes thirty-six. It used to be fifty-four. Same tests, same board — that gap is where most of the last few months went.
Across all three optimization levels it's around fifty minutes, because it's three times the work. Same run, three times over.

[QEMU]

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
| Top-down macro shot of MSPCv2 blue PCB connected via USB, RGB backlight | 1:35-1:50 | to record |
| Close-up of terminal showing final summary with 'All tests passed in 52 minutes' and the overall PASS/FAIL counts | 1:40-1:50 | to record |
| Top-down macro shot of MSPCv2 blue PCB connected via USB, SD card inserted, RGB backlight | 1:35-1:45 | to record |
| Close-up of terminal showing final PASS count and summary 'All tests passed in about 50 minutes' | 1:45-1:50 | to record |

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
SCENE 12 · 1:30 · REFLECTIVE, CANDID

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
| Screen capture of AI chat window with a TinyCC diff visible (green additions, red deletions), dark theme | 0:10-0:16 | to record |
| Brief close-up of the creator's hands at the keyboard while talking about not handing over the wheel | 0:38-0:42 | to record |

## Notes

Talking head close-up. Cut to screen capture of AI chat window with TinyCC diffs, then back to creator. Keep RGB backlighting consistent with previous episodes.

Keep pace steady and reflective — this is the honest-workflow beat between the fast bug-war stories. The phrase 'That's the deal' is the scene's button; leave a half-beat of silence after it before cutting to the live demo. If AI-chat footage is hard to source cleanly, a static screenshot of the chat with a diff overlay will do.

## Change Request


---

<!-- scriptforge:scene b8ecb683-7d18-40d9-92b2-ca42305d2d92 -->
SCENE 13 · 2:30 · HONEST, ANALYTICAL

# The Scorecard: How Far Off GCC Is It?

## Voiceover

Alright. The uncomfortable question. It's an optimizing compiler now — but is the code any good?

Three numbers, measured on the actual chip. Twenty-nine benchmarks on the RP2350, every one checked against its expected result before I timed anything, and the whole run reproducible to the cycle.

Where I started — TinyCC at minus O0, no optimizer — a hundred and four million cycles. TinyCC today, at minus O2: fifty million. GCC at minus O2, same benchmarks, same board: forty-four million.

So the optimizer bought a factor of two. Two point zero six, to be exact. And against GCC I went from two point three five times slower to one point one four. Fourteen percent off GCC, on real silicon, from a compiler that runs on the microcontroller it's compiling for.

Now let me take that fourteen percent apart, because it is not spread evenly.

Doubles are one point six four. And here is the damning part — at minus O0 they were already there. The optimizer bought them nothing. One point zero zero. Every pass I wrote sails straight past double arithmetic.

Take the doubles out, and the rest of the suite is one point zero seven. Seven percent off GCC — and the optimizer bought that side two point two seven times over.

The two biggest real workloads in there, dijkstra and qsort, come in at one point zero one and one point zero zero. Dead level with GCC.

So the honest headline isn't "fourteen percent slower". It's level with GCC on integer and pointer code, and losing badly on doubles.

There's one number I have to be straight about, because it flatters me and I nearly put it on a card. Count instructions instead of cycles, across the whole four-thousand-test corpus, and I come out at zero point nine three — seven percent *fewer* instructions than GCC. That is meaningless. Five files in that corpus are machine-generated, two thousand near-identical functions apiece, and between them they are half of every function I measure. I expand that one idiom tighter than GCC, and it drags the whole average under one. Pull those five files out and it's one point one four. The median function is exactly one point zero zero.

Cycles on hardware are the number. Instruction counts over a corpus are a trap I set for myself.

And encoding width, which I was certain was the problem? Thumb-2 lets you use sixteen bits instead of thirty-two. I use the wide form twenty-nine point six percent of the time. GCC, thirty-two point six. I'm narrower than GCC. That was never the gap.

## Scene Description

Clean data scene, no talking head until the last beat. Opens on a three-bar card — tcc -O0, tcc -O2, gcc -O2 — the first bar towering over the other two, so the optimizer's 2.06x and the remaining 1.14x read in one picture. Then the decomposition: doubles pulled out as their own pair of bars against everything-else, with the O0 column showing the doubles bar barely moving. Then dijkstra and qsort called out at parity. Then the instruction-count card, presented as a trap and dismissed, with the five generated files shown eating half the corpus. Then the encoding-width card, also dismissed. Close on the Grafana dashboard scrubbing through six months.

## B-Rolls

| Description | Timing | Source |
| --- | --- | --- |
| Three-bar hero card: `tcc -O0 103,978,975` · `tcc -O2 50,425,368` · `gcc -O2 44,288,006` cycles, with `2.06x` bracketing the first two and `1.14x` the last two | 0:10-0:40 | to animate |
| Gap-closing card: `tcc -O0 was 2.35x GCC` → `tcc -O2 is 1.14x GCC` | 0:40-0:55 | to animate |
| Split bars, doubles vs everything-else: `doubles 1.64x, optimizer gained 1.00x` against `rest 1.07x, optimizer gained 2.27x` | 0:55-1:25 | to animate |
| Parity callout: `mibench_dijkstra 1.01x` and `mibench_qsort 1.00x` next to a GCC reference line | 1:25-1:40 | to animate |
| Instruction-count trap card: `0.93x` struck through, then `5 generated files = 10,245 of 20,794 functions`, resolving to `1.14x · median function 1.00x` | 1:40-2:05 | to animate |
| Encoding-width card `TCC 29.6% vs GCC 32.6% wide` stamped "not the gap" | 2:05-2:15 | to animate |
| Grafana dashboard: per-commit code size, compile time and cycle counts, scrubbing through the six months | 2:15-2:30 | screen capture |

## Notes

**All figures re-measured 2026-08-20** on branch `loop-opts-iv-ptr-walk` (tinycc `7262c810`). The previous draft's numbers (1.08x instructions, 696,942 / 648,284, `main` at 47%, wide encodings 33.9% vs 31.6%) are superseded — they came from `docs/plans/o2_size_and_speed_levers.md` §2, measured months ago at `bc0e02ce`.

Cycles — `tests/benchmarks/run_benchmark.py 192.168.0.113 -O all`, real RP2350 silicon, 29 benchmarks, 26 verified against expected results and 3 with no expected value. Totals: tcc -O0 103,978,975 / tcc -O2 50,425,368 / gcc -O2 44,288,006. Optimizer 2.06x; tcc -O0 vs gcc -O2 2.35x; tcc -O2 vs gcc -O2 1.14x. Median per-benchmark 1.28x. Doubles 1.64x (optimizer gain 1.01x); everything else 1.07x (optimizer gain 2.27x). `.text` 99,272 → 86,904 for TCC, GCC 72,856 (1.19x).

Two things make those cycle numbers trustworthy, and both are worth knowing before anyone challenges them. The run was repeated and came back **identical on all 58 measurements** (29 benchmarks × 2 compilers). And the double comparison is genuinely compiler-vs-compiler: `BENCH_GCC_FP_FROM_SOURCE` defaults ON, so both arms compile the *same* `lib/fp/soft` C sources at -O2 — GCC is not being handed its hand-written `ieee754-df.S`. With libgcc's assembly instead, double_add reads 4.12x, which would be an unfair number to quote.

The image-size artifact in [[tcc-rig-image-size-confounds-benchmarks]] does not apply here: the two arms' `.text` differ by 14,048 bytes, which is an exact multiple of 16, so the code-to-data displacement is unchanged. The doubles are placement-insensitive anyway, and they are where the gap lives.

Five benchmarks (`function_calls`, `conditionals`, `switch_stmt`, `strcpy`, `strcmp`) collapse to ~35 cycles at -O2 under both compilers — the body is optimized away. Excluding them moves the aggregate by nothing (2.06x → 2.05x, 1.14x unchanged), so the headline is not resting on them. Do **not** put the raw `strcpy` O0/O2 ratio (15,055x) on screen; it is dead-code elimination, not a speedup.

Instructions — `./scripts/regression_disasm.py --suite all -j24`: 4,253 tests, 20,794 functions, TCC 600,443 / GCC 644,050 = 0.93x. The five generated files (`memcpy-a1`, `-a2`, `-a4`, `-a8`, `memclr`) carry 2,049 functions each = 10,245 of 20,794. Excluding them: 1.14x. Median per-function ratio 1.00x. Better on 10,024 functions (−118,180 instructions), worse on 6,994 (+74,573); `main` is 48.6% of the gross excess across 2,516 `main`s. Encoding width re-measured over the first 250 `gcc.c-torture/execute` tests: TCC 29.6% wide vs GCC 32.6% — the direction has flipped since the old 33.9%/31.6% figure, so the line is now "I'm narrower", not "basically identical".

CI measures cycles on real silicon via a self-hosted Raspberry Pi 5 runner with a board attached, not in an emulator. `metrics/gate.py` compares a run against its parent and can fail the build.

Header fixed: the tone field held a second duration ("2:00 · 2:30"). Set to 2:30 with a real tone. The `*new_scene*` marker was dropped from the title — only `*deleted_scene*` means anything on import, so it was being carried as literal title text.

VERIFY: the correctness beat was cut from this draft rather than left stale. The old script said "nineteen open codegen failures as of the twelfth of August, last fully green run the sixth, 4,467 passed / 87 skipped", from rig run `logs/68`. None of that was re-measured in this pass and the count will have moved. Re-run the on-board suite, then decide whether to put the beat back — it was a good beat and the video is better for having it.

## Change Request

---

<!-- scriptforge:scene a15cfa6d-2a85-4cfd-94d1-8e73e9b348e6 -->
SCENE 14 · 2:00 · FORWARD-LOOKING, ENGAGING

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
| Clean white diagram overlays: VFS stack ROMFS/RAMFS/SDIO, scheduler round-robin with wait queues, USB hub connection schematic | 0:20-0:45, 1:50-2:00 | to generate |
| Clean white roadmap timeline diagram: current state (TinyCC, shell, VFS, scheduler) → VGA output + USB hub keyboard/mouse → Doom; red risk marker on the USB host step | 1:50-2:00 | to generate |

## Notes

Recap current OS state, outline the next phases (set up the VGA/keyboard through USB hub, show board hub and connections). Raise problem that host on RP2350 has bugs and it may fail not nicely.

Show the physical USB hub and VGA card connections on the board (top-down macro) while naming the RP2350 USB host errata — it is the main schedule risk, so say clearly that a board revision is possible. End with a terminal showing the current build status or an ASCII Doom mockup to tease the goal. Tie the roadmap back to episode 3's promised plan (VGA/keyboard first; Doom as a long-term milestone).

Keep this scene forward-looking: do not re-explain the TinyCC optimizer, GCC torture suite, or hardware speed-up work that earlier scenes already covered.

## Change Request


---

<!-- scriptforge:scene 59ac4bbf-bef1-4229-b7a1-e7bca3e9c1ac -->
SCENE 15 · 1:40 · WARM, CONVERSATIONAL

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

