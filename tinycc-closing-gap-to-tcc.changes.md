# Change list — TinyCC episode script

Changes only, against the original 13-scene draft. Keyed to **original** scene
numbers. `→` gives the new scene number in the revised running order.

Legend: **REPLACE** = swap the whole voiceover · **EDIT** = swap one passage ·
**NEW** = scene did not exist · **CUT** = remove, do not re-add.

---

## 0. Global fact corrections

Apply these everywhere they appear, not only in the scenes called out below.

| # | Was | Is | Source |
|---|---|---|---|
| G1 | "~50 min / under an hour / 52 min" used as one number | **Two numbers.** Full `-O0 -O1 -O2` matrix = **58 min [VERIFY]**. The `-O0` leg = **54:20 → 10:36** (−80.5%). | `remote_smoke_speedup_plan.md` L108; `remote_smoke_tui.py:186-193` |
| G2 | 54:20 → 10:36 read as the whole suite | It is **`-O0` only**. `--smoke-tcc-opt-levels -O0` reproduces it; the default run is ~3x the work. | same, L108 |
| G3 | "180 optimization passes" | **~180 pass *source files*** (210 `.c` today), ~86,900 lines. Runtime registry is far smaller; ~65 unique `phase:name` IDs. | `find source/opt -name '*.c'` |
| G4 | Benchmarks implicitly MSPCv2 | Measured on **Pico Plus 2**. MSPC is being tuned to match — see §4. | `DEFAULT_CONFIG["board"]` |
| G5 | SMP "reverted" | **Not reverted.** Default-on; phase 7 landed, both cores run processes. Only *parallel test runs* closed. | `smp_plan.md` L269 |
| G6 | "It compiled itself on the MCU" | Cross compiler ingests tcc's sources; native tcc compiles/runs *test programs*. Full on-device bootstrap **not done**. | `tests/selfhost/README.md` |
| G7 | SRAM-preferring process memory as a win | **Reverted.** Not in the tree. Delete the claim. | grep `prefer_fast` → empty |
| G8 | Syscall/`oop.zig` overhead as a win | **Negative result**: syscall path ≈1%. Two items rejected. No evidence for the `oop.zig` work. | `syscall_path_profile.md` |
| G9 | "Falbesoner's research" | Unverifiable — appears nowhere. Cite Bellard, or Braun et al. 2013 for SSA construction, or cut. | — |
| G10 | "small files compile in ~100 ms" | Per-compile **floor** 85.8 → **25.8 ms**; median compile ~167 ms. | `remote_smoke_speedup_plan.md` 5.5 |

---

## 1. Scene map

| Orig | New | Action |
|---|---|---|
| 01 | 01 | EDIT — headline numbers, cut Falbesoner |
| 02 | 02 | REPLACE — retitled, ladder corrected |
| 03 | 03 | EDIT — FP cut to a mention + a short; deletions added; 5:00 → 4:00 |
| 04 | 04 | REPLACE — new bug, new title |
| 05 | 05 | REPLACE — premise inverted, new title, absorbs old 07's thesis |
| 06 | 06 | REPLACE — SDIO and `/tmp` cut; 1:45 → 1:30 |
| 07 | — | **CUT** — syscall profiling; one sentence survives in Scene 05 |
| 08 | **07** | REPLACE — OS content cut to a mention; keeps 0.61x / 1.64x |
| 09 | **08** | REPLACE — trimmed to fit, limits added |
| — | **09** | **NEW** — the GCC scorecard |
| 10 | **10** | EDIT — self-host + numbers |
| 11 | **11** | EDIT — moved after the demo, 0:50 → 1:45 |
| 12 | **12** | REPLACE — OS state cut to a hand-off |
| 13 | **13** | REPLACE — 2:00 → 1:15 |

---

## 2. Header changes

```
01  2:00 → 2:15   Intro & Project Overview                      (title unchanged)
02  1:30 → 2:30   GCC Test Suite → The Test Suite That Forced the Rewrite
03  5:0  → 4:00   (title unchanged — also fixes the malformed timecode)
04  1:40 → 2:30   Debugging Miscompilations & Optimizers → The Bug Class I Found Five Times
05  2:00 → 3:45   Hardware Reality: XIP Bottleneck & 532MHz → The Clock Was Not the Problem
06  1:45 → 1:30   Memory & I/O: Removing Zeroing + SDIO → Memory: Zeroing and the Floor
07  ----- CUT --- Syscall Profiling & Framework Overhead
07  1:30 → 2:15   The SMP Experiment vs. XIP Reality → Two Cores, and the Cache They Share   [was 08]
08  0:45 → 2:15   QEMU Support… → QEMU, and Real Linker Scripts                              [was 09]
09  NEW   2:30    The Scorecard: How Far Off GCC Is It?          ANALYTICAL, CONFIDENT
10  1:50 → 1:50   Live Demo: Compiler & Test Suite in Action → Live Demo
11  0:50 → 1:45   AI as Co-Developer: Architect vs Coder         (title unchanged)
12  2:00 → 1:45   Roadmap: VGA, keyboard, Doom                   (title unchanged)
13  2:00 → 1:15   Outro & Community Engagement → Outro
```

---

## 3. Scene changes

### SCENE 01 → 01 · EDIT

**CUT** this sentence entirely (G9):

> This whole approach was heavily inspired by Falbesoner's research on pushing compiler architectures to their absolute limits. With the three-address IR and SSA-based register allocation, the generated code is much closer to what you'd expect from a serious optimizing compiler.

**REPLACE** the final three paragraphs (from "Previously, we saw the first version…" to "Let's get into it.") with:

> It was also barely a compiler. Single-pass — no syntax tree, no intermediate representation, no optimizer, no register allocator. It translated C straight to machine instructions as it parsed. The ARM backend was full of bugs, and it was slow.
>
> So I spent six months rewriting it. Two and a half thousand files, four hundred forty-five thousand lines added, sixty-three thousand deleted. It now has a three-address IR, SSA form, an SSA register allocator, and around a hundred and eighty optimization pass files. Six other CPU backends were deleted to get there.
>
> Here's where that lands. My full regression suite is over four thousand test files, and every one of them gets compiled on the board — at minus O0, minus O1 and minus O2. All three. That whole matrix now runs in fifty-eight minutes. Under an hour, on a microcontroller.
>
> And the configuration I actually live in day to day, the minus O0 leg, went from fifty-four minutes to **ten minutes and thirty-six seconds** — in a single week, and almost none of it by making the compiler faster.
>
> That's the story: six months building a compiler, then one week discovering that almost everything I believed about why it was slow was wrong.
>
> Let's get into it.

**C-ROLL changes:**
- ADD: diff-stat card `2,429 files · +445,120 / −62,727`
- ADD: hero card A `whole suite · -O0 -O1 -O2 · 58:00`
- ADD: hero card B `-O0 leg: 54:20` struck out, `10:36` beneath, subtitle `4,467 passed / 87 skipped · 2026-08-06`
- REPLACE the `<compare old TCC / GCC / TCC -O2>` placeholder: that comparison is now Scene 09.

**[VERIFY]** "8 MB of RAM" — 8 MB is the Pico Plus 2's PSRAM; confirm MSPCv2's part. 16 MB flash is correct for both.

**Fallback line** if you do *not* re-measure on MSPC, insert after the 10:36 sentence:
> One thing up front — the benchmarks in this video are measured on a Pico Plus 2, because that's the board bolted to my CI rig. The MSPCv2 is where it's all going.

---

### SCENE 02 → 02 · REPLACE

> I decided to run the GCC torture suite on the board. Over four thousand C files, written by the GCC developers specifically to break compiler backends — complex numbers, long longs, bitfields, every corner of the C standard, and a lot of things that are technically legal and nobody sane writes.
>
> With the single-pass compiler, I kicked off a run and walked away. **[VERIFY]** After about an hour it had reached roughly a quarter, and it was not speeding up. I killed it.
>
> That was the decision point. Not "the compiler produces bad code" — I already knew that. It was that the compiler was too slow to tell me *how* bad, because I could never finish a run. You can't fix what you can't measure, and I couldn't measure.
>
> So the rewrite had a very specific goal, and it was not elegance. I needed the cross compiler to be fast enough, and to generate code good enough, that a native TinyCC built with it could get through the whole suite in an evening.
>
> That worked. Today the whole matrix — every test at minus O0, minus O1 and minus O2, plus my own suites — runs in fifty-eight minutes on one board.
>
> But the number I want to talk about is a narrower one. Most days I'm not running all three levels. I'm running the minus O0 leg, because that's the fast correctness check, and that's the loop I live in. At the end of July it was fifty-four minutes and twenty seconds.
>
> Then I spent one week doing nothing but measuring the system underneath it. It went to **ten minutes thirty-six**. Same tests, same pass set, four thousand four hundred sixty-seven passing and eighty-seven skipped, on both ends.
>
> Five times faster, in a week. And almost nothing about it was what I expected. The overclock wasn't it. The syscalls weren't it. Using both cores made it *worse*. The single biggest fix was a number copied out of the wrong row of a datasheet.
>
> That week is the rest of this video.

**B-ROLL changes:**
- ADD: full-matrix line `-O0 -O1 -O2 · 58:00`, styled distinctly, above the ladder
- ADD: ladder card `killed at ~25% / 1 h` → `54:20` → `10:36`, with a permanent `-O0` badge
- ADD: real `run_info.txt` from the 2026-08-06 run, opt levels visible
- The last paragraph is a cold-open promise paid off in 05, 07 and 08. If you cut one of those scenes, cut its line here too.

**[VERIFY]** the "killed at ~25%" run — not recorded anywhere, and each run wipes `logs/`. Find a log or narrate it as recollection.

---

### SCENE 03 → 03 · EDIT

**REPLACE** the hardware-FP paragraph:

> ~~I also added hardware floating point support. The RP2350 has a hardware FPU, but the old single-pass backend never actually used it - it emitted software floating-point calls. With the IR, floating-point operations become just another TAC instruction, so the register allocator can schedule them on the FPU directly.~~

with:

> I also got floating point onto the hardware, and the RP2350 is strange here. It has a single-precision FPU and no double-precision unit at all — what it has instead is a "double coprocessor" on slot four, so for doubles the compiler emits inline sequences for add, subtract and compare. There's a genuinely good story in that one, including the fact that the ARM calling convention passes doubles in `d0` through `d7` even on a chip that cannot do double arithmetic. It's self-contained enough that I'm going to do it as its own short rather than derail this.

**Scripts the FP short from these facts** (cut from the scene to hold 4:00 — the material is too good to bury and too long to keep):

- Two orthogonal knobs: `-mfloat-abi=` (soft / softfp / hard — how FP crosses a call) and `-mfpu=` (none / fpv4-sp-d16 / fpv5-sp-d16 / fpv5-d16 / **rp2350** — what may be used inside a function).
- No double FPU; `-mfpu=rp2350` emits inline **DCP** (coprocessor 4) sequences for double add/sub/compare. Four runtime libraries ship to match.
- **AAPCS-VFP passes doubles in `d0-d7` even on a single-precision-only FPU** — the ABI says where arguments *live*, not what arithmetic *exists* — so the callee unpacks `d0` into a GPR pair to call `__aeabi_dadd`. You find that when your program prints the wrong number.
- Hard-float `.ARM.attributes` match `arm-none-eabi-gcc` **byte-for-byte**.
- Honest limit: **the DCP flushes subnormals to zero** in compare and `d2f`, no path that doesn't; the conformance runner takes `--allow-ftz` for that configuration only.
- Still open: `float` compares/converts/negate still call `__aeabi_*`; no native `vadd.f64`; DCP `dmul`/`dneg` not inlined.

**REPLACE** the closing paragraph ("This shift to a multi-pass architecture…") with:

> All of this cost me the entire old code generator. There was no clean way to bolt an IR onto it. And it cost six CPU backends — x86, x86-64, ARM64, RISC-V, C67, and the .NET IL one. Twenty-five thousand lines, deleted, because carrying six targets through a new IR was never going to happen. `tccgen.c` — eight and a half thousand lines, the heart of upstream TCC — is gone too, split into about fifty files.
>
> What's left is one target, done properly.

**INSERT** after the ~180-passes paragraph:

> And they are not a hardcoded sequence. There's a pipeline table. Every pass is registered with a name — `ssa:branch`, `loop:licm` — and gated by a flag. Which matters more than it sounds, and I'll show you why in a minute.

**B-ROLL changes:**
- ADD: `source/opt/engine/pipeline_table.c` scrolling — the pass table as data
- ADD: DCP card `FPU: single-precision only` / `DCP: coprocessor 4`, held briefly
- ADD: `git log --stat` on the backend-deletion commit, `−25,000` visible
- FIX: B-roll table ran to 5:30 in a 5:00 scene — retimed to 4:00

Apply G3 to the on-screen pass count.

---

### SCENE 04 → 04 · REPLACE

The draft's bug was self-contradictory: `vstack`/`vstore` is upstream's single-pass value stack — the path this rewrite deleted — so it cannot be both "the old AST path" and "found via the new IR". It also re-told Scene 02's 25% run and Scene 03's IR recap.

> Once the suite was actually finishing, the failures came in fast. And the interesting part is not any single bug. It's that the same *shape* of bug kept coming back.
>
> Here's the best one. At minus O1 and above there's a pass called `var_tmp_fwd`. It's simple: if you assign a temporary into a variable, later reads of that variable can read the temporary instead. Straightforward.
>
> It checked that the destination was a variable. It never checked that the destination was an *lvalue*.
>
> Look at this IR. `V-DEREF ← T` — that's a store *through* the pointer V. It does not define V. It writes to where V points. But the pass saw "destination is V" and concluded "V now holds T", so every later read of that pointer got rewritten to the value that had been written through it.
>
> In the generated code, the base register of an indexed store became a loop counter. So stores landed at the absolute address of the counter, plus an offset.
>
> What that broke, on the board, was every shell redirect in toybox. Every single one. `echo hello > file` — gone.
>
> The fix is one line: if the destination is an lvalue, bail out. The mirror of a guard the same pass already had on the source operand.
>
> And this is the fifth time I've fixed that bug. Different pass, different symptom, same mistake: a pass keys on "the destination of a store" and assumes a destination is a definition. Sometimes a destination is an *address*. I've now hit it in SSA phi construction, in parameter entry definitions, in round-trip elimination, in the LEA handling, and here.
>
> So how do you find one of these in a hundred and eighty passes?
>
> You don't rebuild. Every pass has a name, and there's an environment variable — `TCC_DISABLE_PASS`. Take a test that fails. Turn off one pass. Run it again. When it passes, you've named the guilty pass, from a shell, in seconds. That one design decision — a pass table as data instead of a hardcoded call sequence — has probably saved me more time than any optimization in the compiler.

**B-ROLLS — replace the whole table:**

| Description | Timing | Source |
| --- | --- | --- |
| `-dump-ir` output with `V***DEREF*** <- T`, DEREF highlighted | 0:25-0:50 | screen capture |
| Emitted `str.w r5, [r1, r2, lsl #2]`, wrong base register annotated | 0:50-1:05 | screen capture |
| Board terminal: shell redirect failing → one-line diff → working | 1:05-1:30 | to record on hardware |
| Diff: `if (irop_op_is_lval(dest)) return 0;` | 1:20-1:30 | screen capture |
| Card: the five members of the bug family, one at a time | 1:30-1:50 | to animate |
| **Live bisect**: failing test → `TCC_DISABLE_PASS=<name>` → green | 1:50-2:25 | to record |

Regression test is `tests/ir_tests/439_assign_expr_pointer_base.c`. Rehearse the bisect — it is the best demo in the project. Alternate bugs if you want a second: the multi-MiB `sub sp` from a raw `.btype` overwrite; the device-only `-O2` hang from backedges never setting `is_jump_target`; literal-pool overflow from raw `o()` bytes bypassing the size proxy.

---

### SCENE 05 → 05 · REPLACE

Premise inverted: the draft claimed the overclock is why the suite got fast. The project's own A/B says 618 vs 532 MHz = **+0.96%**.

> So the compiler is fast now. Time to make the hardware keep up. I overclocked the RP2350 to 532 megahertz — the board default — and the flash bus runs at 133. Four times the ratio. More clock, more compiles. Obviously.
>
> Then I actually measured it.
>
> I ran the same corpus at 532 megahertz and at 618, which is this board's measured stable maximum. The difference in median compile time was **zero point nine six percent**. Under one percent, for a sixteen percent clock increase.
>
> Because the core isn't what's busy. Here's one compile: thirty-eight million XIP accesses, about four hundred ninety-five thousand misses, a 98.71% hit rate — which sounds great. Of that hundred and sixty-seven millisecond compile, **thirty-five percent is the core executing, and sixty-five percent is stalled waiting on flash.**
>
> Execute-in-place means every instruction fetch that misses the cache goes out over a four-bit QSPI bus — the same bus the PSRAM is on. A compiler has a two-megabyte instruction footprint going through a sixteen-kilobyte cache. It misses constantly. Making the core faster just means it waits faster.
>
> So I stopped attacking how *many* misses there are, and attacked what a miss *costs*.
>
> And I found this. The QSPI config sets a minimum chip-select deselect time, and it was set from the datasheet. From the wrong row of the datasheet. The Winbond part has two: tSHSL-one is chip-select deselect for **read** — ten nanoseconds. tSHSL-two is fifty nanoseconds, and it covers erase, program, and write-status.
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

That last paragraph is the rescued thesis of the **cut** Scene 07 — it is the only surviving trace, and it is what keeps "measure first" as the episode's spine.

**B-ROLL changes:**
- ADD: anticlimax card `618 MHz vs 532 MHz → +0.96%`
- ADD: `cat /proc/xipstat` during a real compile
- ADD: split card `35% core / 65% stalled on XIP`
- ADD: W25Q128JV AC table with tSHSL1 / tSHSL2, wrong row circled
- ADD: cycles-per-miss table `181 → 161 → 129` (`178 → 126` net of loop)
- DEMOTE: thermal camera to a 10 s decoration at the end
- CUT: oscilloscope "stall gaps" shot — it illustrates the premise that was wrong

SDIO stays unnamed: the detour is told as "the card's command path".

---

### SCENE 06 → 06 · REPLACE

SDIO pulled from narration; `/tmp` cut as OS material. Slot 1:45 → **1:30**. What remains is the two findings that are about compiling: `mmap` costs bytes, and the tcc init floor.

> A compile is a tight loop of load, analyze, transform, write out. On this hardware every one of those touches costs real time on a bus that's already saturated. So the rest of the win came from memory.
>
> First: zeroing. An `mmap` on this kernel doesn't cost a constant — it costs the *bytes it clears*. Which means allocating a big buffer you're about to overwrite is pure loss. Removing unnecessary zeroing in the kernel and in TinyCC's allocations took real time off startup.
>
> Then the one I did not expect at all.
>
> Every compile had a fixed floor of about eighty-six milliseconds before it touched a single line of your actual file. I assumed that was parsing the predefined macros — there's about seventeen kilobytes of them and it happens on every single invocation.
>
> It wasn't. It was the builtin *alias declarations*. And it wasn't parsing them either — it was the instruction fetch to walk them, bouncing the XIP cache between the macro expander and the declaration parser. Building them programmatically instead of parsing them took that floor from eighty-six milliseconds to **twenty-five point eight**.
>
> Sixty milliseconds. On a suite of four thousand files, that one change is about four minutes of wall clock — and it is time the compiler was spending before it read a byte of input.

**CUT** (G7) — do not re-add:
> ~~On the RAM side I extended the kernel to allocate process memory from SRAM when possible instead of PSRAM. The heap on PSRAM was the slow part — small files now compile in about a hundred milliseconds because the working set stays on fast SRAM.~~

**B-ROLLS — replace the whole table:**

| Description | Timing | Source |
| --- | --- | --- |
| Code diff: the zeroing removal, byte counter beside it | 0:15-0:35 | screen capture |
| Per-compile profile bar, init segment collapsing `85.8 → 25.8 ms`, rest static | 0:50-1:15 | to animate |
| `pass_timing` / `-bench` on device, floor before and after | 1:15-1:30 | to record on hardware |

**Held for the OS episode** (do not lose): SDIO is `sdio_rp2350.c` (1,445) + `.pio` (365) + `mmc_sdio.zig` (663). CMD25: 512 B `373 → 376` (unchanged), 4 KiB `406 → 2,139`, 32 KiB `412 → 3,514` KiB/s — the unchanged 512 B row is what makes the table trustworthy. Plus hybrid `/tmp`: small files ≤64 KB RAM-backed under a hard arena budget, larger spill to card, motivated by an unbounded RamFs having been a measured net loss.

Optional extra beat: for the init floor, build-time pre-tokenization of the macro *defines* was built, measured as a wash, and reverted — the cost was the declarations. On-theme for this episode.

---

### SCENE 07 · **CUT ENTIRELY**

*Syscall Profiling & Framework Overhead.* Remove the scene. Two reasons:

1. The draft claimed a win the project measured and **disowned** (G8). `docs/syscall_path_profile.md` opens: *"The headline is a negative result: the syscall **path** is ~1% of syscall time and well under 1% of a program's runtime, so it is not where the time is. The handlers are."* Two planned items are marked **rejected** (lazy FP stacking — tax measured at zero; widening the fast-syscall set — negligible payoff, real deadlock risk). The one real win, the syscall/context-switch stub into `.time_critical`, is **0.11 → 0.02 ms per compile** against a ~167 ms compile.
2. Corrected, it is an OS scene, and the OS gets its own video. It is also the only scene with no artifact to put on screen.

**One sentence survives**, appended to Scene 05 — see that entry. It carries the "measure first" thesis, which the episode needs.

**[VERIFY]** the `oop.zig` dispatch work: I found no evidence for it in the perf plan, the syscall profile, or the tree. If it exists, it belongs in the OS video, not here.

---

### SCENE 08 → **07** · REPLACE

Scoped down to a mention plus one result, because the OS gets its own video. Slot 1:30 → **2:15**.

> One more, and then I'll stop. The RP2350 has two Cortex-M33 cores, and this release is the one where YasOS started using both. That's a big piece of kernel work — an entire synchronization layer, a lock hierarchy, the scheduler — and it's getting its own video, so I'm not going to do it justice here.
>
> But there's one result from it that belongs in *this* video, because it's about compiling.
>
> Both cores now run processes. So I did the obvious thing: two compiles at once. Expecting two times.
>
> I got **zero point six one**. It got *slower*.
>
> And this is where the instruments paid for themselves, because "it's cache contention" is a guess until you prove it. Two TinyCC instances take forty-four percent more cache misses for the same work — they're evicting each other out of that same sixteen-kilobyte XIP cache. Then the control: a RAM-resident arithmetic loop, no instruction fetches from flash at all, run on both cores. That gets **one point six four times**. The second core is fine. And quartering the heap changed nothing, which rules out PSRAM.
>
> So it's not the scheduler and it's not memory. It's one sixteen-kilobyte cache in front of one flash chip, and two compilers do not fit inside it.
>
> Let me be precise about what that closes, because it's narrower than it sounds. I didn't turn SMP off — it's on by default and both cores schedule. What's closed is running my *test suite* in parallel on one board. And the fix isn't a better scheduler. It's a second board, because a second board brings its own cache.
>
> Which is the same lesson as the datasheet, really. The bottleneck was never the thing with "compiler" written on it.

**B-ROLLS — replace the whole table:**

| Description | Timing | Source |
| --- | --- | --- |
| `cat /proc/cpus` — `cpu0_switches`, `cpu1_switches` both climbing | 0:15-0:30 | to record on hardware |
| `prun -j2` two compiles vs sequential, `time` output, parallel losing | 0:40-0:55 | to record on hardware |
| **The pair of bars**: `two compiles: 0.61x` beside `RAM-resident control: 1.64x` | 0:55-1:25 | to animate |
| `/proc/xipstat` miss counter, one compile vs two — the +44% | 1:25-1:40 | to record on hardware |

**Two corrections that still apply.** (1) SMP was **not reverted** — `docs/smp_plan.md` records phase 7 complete, "both cores now run processes", `cpu1_switches 1 → 5` under load, `RoundRobin.try_claim` / `claimed_by_any_core` in the tree. Only *parallel test runs* closed. (2) The control experiment is what turns "it's the cache" from hunch into proof; the draft omitted it.

**Held for the OS episode:** the synchronization inventory (`source/kernel/sync/`, ~1,900 lines), **ranked locks** (runtime-enforced, mutexes ordered before spinlocks so "never sleep holding a spinlock" falls out of the ordering, console innermost, sparse numbering so new locks insert without renumbering), `block_context_switch` deleted across 37 sites with a CI grep guarding it, the **48% syscall tax** (20.1 → 29.7 µs/char, invisible in a compile because it hides inside the XIP stall), and the `CONFIG_PROCESS_SMP=n` deterministic panic on the 4th `prun -j1` compile.

**Fix these two docs before scripting the OS video** — they will mislead you: `docs/smp_plan.md`'s status header and phase table say phase 7 is "not started" while line 269 records it done, and `docs/video/v0.1.0_yasos_changes.md` inherited the stale claim ("core 1 boots and parks; it does not yet schedule work"). That understates the best result in the OS half.

---

### SCENE 09 → **08** · REPLACE

Draft was 325 words in a 0:45 slot — ~3x over.

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
> But I have to be honest about the limits, because they're sharp. QEMU's Cortex-M model never advances the cycle counter. It models no exception-entry cost, no pipeline flushes, and no XIP or PSRAM latency. Which is precisely what the last three scenes were made of. **QEMU tells you whether the code is correct. It can never tell you whether it's fast.** Every performance number in this video came off real silicon, and there was no shortcut.
>
> Two smaller caveats while I'm at it: the QEMU smoke run never exercises the exit and shutdown path, so bugs live there. And a QEMU run costs two clean rootfs rebuilds, so it is not free.
>
> The upside for you is that it's much cheaper to try. Clone the repository, run the script, and once the tools are in place you should be able to boot the OS without owning any of this hardware.

**B-ROLL changes:**
- ADD: `source/obj/tccld.c` — the `MEMORY` / `SECTIONS` parser (1,562 lines, verified)
- ADD: workflow diagram with the QEMU box annotated "correctness only"
- ADD: the kernel's own `cyc=off` line printed under QEMU
- ADD: `git clone` → script → OS booting, sped up

---

### SCENE **09** · NEW · 2:30 · ANALYTICAL, CONFIDENT

# The Scorecard: How Far Off GCC Is It?

The episode is named after this gap and the draft never numbered it.

> Alright. The uncomfortable question. It's an optimizing compiler now — but is the code any *good*?
>
> I measured it against `arm-none-eabi-gcc` at minus O2. Four thousand one hundred fifty-one tests. Twenty thousand four hundred thirty-five functions. Counting instructions.
>
> TinyCC: six hundred ninety-six thousand nine hundred forty-two. GCC: six hundred forty-eight thousand two hundred eighty-four.
>
> **One point zero eight times.** Eight percent more instructions than GCC. Later rounds of tuning brought the corpus down to one point zero five.
>
> Now let me take that number apart, because on its own it flatters me.
>
> TinyCC generates *better* code than GCC on seven thousand eight hundred thirty-nine functions — eighty thousand instructions fewer. And worse on nine thousand seven hundred forty-eight, by a hundred and twenty-nine thousand. The aggregate is a large win netted against a large loss, and quoting only the aggregate hides that.
>
> It's also very uneven by workload. On the GCC execute suite — sixteen thousand functions — it's **one point zero zero**. Dead level. On my own hand-written IR tests, it's two point zero six. Twice as many instructions.
>
> And one function is forty-seven percent of my total excess. `main`. Which makes sense once you think about it: `main` in a torture test is enormous, full of setup, and the hardest possible case for the kind of local optimization I do well.
>
> One thing I checked that turned out not to be the answer: instruction encoding width. Thumb-2 lets you encode many instructions in sixteen bits instead of thirty-two, and I assumed I was leaving size on the table there. TinyCC uses wide encodings 33.9% of the time, GCC 31.6%. Basically identical. The gap isn't how I encode instructions. It's how many I emit.
>
> I also have to be straight about correctness. As of the twelfth of August there are **nineteen open codegen failures** in the torture suite, and I know where they came from — the hardware floating point commit on the eighth. I've got a fully green run recorded on the sixth of August, so I know exactly what regressed and when. That's what the per-commit metrics are for.
>
> Eight percent off GCC, from a compiler that runs on the microcontroller it's compiling for. I'll take it.

**Scene description.** Data scene, no talking head until the last beat. `1.08x` card → win/loss opposing bars → per-suite spread with `gcc-execute 1.00x` highlighted → `main = 47%` → encoding-width card dismissed as a dead end → **Grafana dashboard** → honest correctness slide.

**B-ROLLS:**

| Description | Timing | Source |
| --- | --- | --- |
| `TCC 696,942 / GCC 648,284 = 1.08x` | 0:20-0:40 | to animate |
| Opposing bars `better on 7,839 (−80,811)` vs `worse on 9,748 (+129,446)` | 0:45-1:10 | to animate |
| Per-suite bars, `gcc-execute 1.00x` and `ir 2.06x` at the ends | 1:10-1:30 | to animate |
| `main = 47% of gross excess` | 1:30-1:45 | to animate |
| Encoding width `33.9% vs 31.6%` stamped "not the gap" | 1:45-2:00 | to animate |
| **Grafana**: per-commit size / compile time / cycles, scrubbing six months | 2:00-2:20 | screen capture |
| `19 open · last fully green 2026-08-06 · 4,467 passed / 87 skipped` | 2:20-2:30 | to animate |

Source: `v0.1.0_tinycc_changes.md` ch. 8, from `docs/plans/o2_size_and_speed_levers.md`. Also available: `metrics/gate.py` fails the build on regression against parent; CI measures cycles on real silicon via a self-hosted Pi 5 runner. **[VERIFY]** re-run the 19 — the number will have moved since 08-12.

---

### SCENE 10 → **10** · EDIT

**REPLACE** the opening block (from "Watch this." through "This is the proof that the rewrite was worth it.") with:

> Let's actually run it.
>
> This is TinyCC v0.1.0, on the board. `tcc --version`. Now a C file — written here, compiled here, linked here, run here. No host, no cross compiler, no SD card shuffling. Just this board and a terminal.
>
> Now the suite. Over four thousand test files, every one compiled on the microcontroller. This is the minus O0 leg — the one I run every day.
>
> And the clock. Ten minutes, thirty-six seconds. All three optimization levels together is fifty-eight minutes, and that's the run I leave going while I eat.
>
> Now, self-hosting — let me be precise, because it's the question I get most and I don't want to overstate it. Two things are true today. The cross compiler compiles TinyCC's own source tree, so the compiler can ingest itself. And the native compiler, running on the device, compiles and correctly runs test programs, checked against the cross-compiled reference. What I have not done yet is build the whole compiler on the board and then use *that* binary to build itself again.
>
> So: close, and closer than I expected six months ago. Not done. When it's done, you'll hear about it.
>
> And one thing that surprised me, watching this run for the first time. This isn't a demo binary. It's the compiler the whole userland is built with, and it's the same source tree that produces the cross compiler on my desktop. One compiler, two hosts.

**B-ROLL / overlay changes:**
- CUT overlay: `SDIO storage` → replace with `-O0 / -O1 / -O2`
- CUT card: "All tests passed in 52 minutes" → real line is 636.60 s, 4,467 passed / 87 skipped
- ADD: `-O0` visible in the run header on the timer shot
- ADD card: `one source tree → host cross compiler + on-device compiler`
- The tuned MSPCv2 must be both the board on the desk and the board producing the timer, in shot.

---

### SCENE 11 → **11** · EDIT

Content is accurate — keep it. Changes: slot 0:50 → 1:45 (copy was ~1:45 of speech), and **move to after the scorecard and the demo**. Following "here is exactly how far off GCC I am, and here are my nineteen open bugs" with "and I used AI heavily" reads as confidence; before the demo it reads as a disclaimer.

Minor tightening in the read (optional): "Six months ago this was still Fabrice Bellard's TinyCC…" → "Six months ago this was Fabrice Bellard's TinyCC…"; "over 2100 test files passing" → "over two thousand one hundred test files" (2,148, correct).

---

### SCENE 12 → **12** · REPLACE

Draft described the system as it was at v0.0.8. Corrected, then compressed to a hand-off — the OS gets its own episode. Slot 2:00 → **1:45**.

> So where does that leave the system?
>
> There's a shell running the toybox userland, a VFS on a real SD card, pipes — real `pipe(2)`, so `ls | grep` works on a Cortex-M33 — both cores scheduling, an MPU, and every pointer userspace hands the kernel now validated in code. That's a whole video's worth of kernel work and it's getting one. Next episode. I'll keep it to that here.
>
> Some things are designed and not shipped, and I'd rather say so than let you find out. Virtual terminals: there's a four-hundred-line design document, the driver files exist, and the initialization call in `main.zig` is commented out. PTY and multiplexing: a plan, nothing more.
>
> For the compiler specifically, the honest list is shorter and I've already given you most of it. Nineteen open codegen failures. No full on-device bootstrap yet. And a gap to GCC that is eight percent on average and much worse in places I know about.
>
> Next up functionally: VGA output, and keyboard and mouse through a USB hub. The risk there is real — USB host on the RP2350 is buggy, and this might fail in a way that forces a board revision. We'll see.
>
> Then Doom. Compiled with TinyCC, on the board, like everything else in the rootfs. One thing at a time — video and input first, then Doom. If USB host misbehaves badly enough, everything shifts to a board revision. I'm hoping it doesn't come to that.

**B-ROLLS — replace the whole table:**

| Description | Timing | Source |
| --- | --- | --- |
| `ls \| grep` on the board — a quick flash, no explanation | 0:12-0:22 | to record on hardware |
| Card `next episode — the OS` over a fast montage: `/proc/cpus`, a lock diagram, `pipe(2)` | 0:22-0:35 | to animate |
| `initialize_virtual_terminals()` commented out in `source/main.zig` | 0:35-0:50 | screen capture |
| Top-down macro of the board with USB hub cable and VGA card connections | 0:55-1:20 | to record |
| Roadmap timeline: current → VGA + USB keyboard/mouse → Doom, red risk marker on USB host | 1:20-1:45 | to animate |

**Held for the OS episode** — do not spend it here: the `uaccess` header's own argument (*"Syscall handlers run privileged, so an unchecked pointer is an arbitrary read/write primitive for any process. **The MPU is no defence**: PRIVDEFENA plus the background map means it only ever restricted *unprivileged* access"*), which `v0.1.0_yasos_changes.md` calls "the best 30 seconds of the video"; the borrowed-XIP-`.rodata` wrinkle that makes a flash pointer a legitimate user pointer; `pipe(2)` as two ordinary `IFile`s; the `SMP=n` panic. Syscalls went 47 → 53 (`pipe`, `ftruncate`, `mremap`, `prlimit`, `klog_ctl`, `perf_dump`).

The "scaffolded but not shipped" beat stays — the changelog recommends it explicitly, and after Scene 09's nineteen open bugs it reads as consistent rather than deflating.

---

### SCENE 13 → **13** · REPLACE

Slot 2:00 → 1:15 (draft was 94 words, ~37 s).

> That's the deep dive.
>
> Six months ago this was a single-pass translator that couldn't finish a test run. It's now an optimizing compiler with a three-address IR, SSA, a register allocator and around a hundred and eighty pass files — running on a microcontroller, within eight percent of GCC's instruction count, getting through four thousand test files at three optimization levels in fifty-eight minutes. And the daily loop went from fifty-four minutes to ten and a half in one week.
>
> And the thing I'll actually remember from it isn't any of that. It's that almost every real win came from measuring something I was sure I already understood. The overclock didn't matter. The syscall path didn't matter. Two cores made it slower. And the biggest single fix in the whole six months was a chip-select timing value read off the wrong row of a datasheet.
>
> Thanks for sticking through the miscompilations, the XIP bottleneck, the SMP dead end, and the week I spent profiling something that turned out to be one percent.
>
> Next time: VGA and keyboard. See you then.

**CUT**: "the compiler can compile itself without manifesting bugs" (G6).
**ADD** B-roll: rapid cutaways incl. the datasheet row circled — lands that story a second time.

---

## 4. MSPC tuning — required before the shoot

`configs/mspc_defconfig` is currently a different machine from the rig every number came off:

| Setting | `mspc_v2` | `pico_plus2` | Blocks |
|---|---|---|---|
| `CPU_CLOCK_FREQUENCY_MHZ` | **150** | 532 | 05, 10 |
| `FLASH_XIP_DESELECT_NS` | **absent** | 12 | 05 |
| `FLASH_XIP_CONTINUOUS_READ` | **absent** | y | 05 |
| `PSRAM_CE_MIN_DESELECT_NS` | **50** | 22 | — |
| `PROCESS_SMP` | **not set** | y | **07** |
| `MMC_BUS_MODE` | **SPI** | SDIO | card path |
| `PSRAM_CS_PIN` | 0 | 47 | keep MSPC's |

1. **`PROCESS_SMP=y` is blocking.** MSPC boots single-core today — wrong for Scene 07, and the arm documented as panicking on the 4th `prun -j1` compile. Verify with `cat /proc/cpus`, **not** the boot banner ("Cores: 2" is the hardware count).
2. **`FLASH_XIP_DESELECT_NS=12` names a part.** It is the W25Q128JV read row (tSHSL1). Check MSPC's own flash AC table before copying.
3. **150 → 532 MHz is a bring-up, not an edit.** Different VREG point and PLL/QMI switch; MSPC already needs different PSRAM timings. Budget a soak — 618 MHz failures were ~80% intermittent.
4. **Confirm MSPCv2 wires DAT0–3 for 4-bit SDIO.** The changelog records "MSPC v2 stays on SPI", so `MMC_BUS_MODE_SDIO=y` may be a schematic question.
5. **Re-measure on the tuned MSPC**, or keep Scene 01's fallback caveat. A 10:36 timer over MSPC footage with no caption invites a defconfig diff.

---

## 5. Open items

| # | Item | Scene |
|---|---|---|
| V1 | Time one full `-O0 -O1 -O2` run → the 58-minute figure gets an artifact | 01, 02, 10 |
| V2 | The "killed at ~25% after 1 h" run — find a log or narrate as recollection | 02 |
| V3 | MSPCv2 PSRAM size (8 MB is the Pico Plus 2's part) | 01 |
| V4 | The Falbesoner citation — correct, replace, or cut | 01 |
| V5 | `oop.zig` dispatch work — evidence, or it stays cut (and belongs in the OS video regardless) | — |
| V6 | Re-run the 19 open codegen failures; the count will have moved | 09 |
| V7 | Full on-device bootstrap — if it landed, Scene 10 becomes the headline | 10 |

**Repo hygiene** (visible if you screen-record the tree): `configs/mspc_defconfig_{BACKUP,BASE,LOCAL,REMOTE}_86736` are merge-conflict leftovers, one still containing `>>>>>>>` markers.

**Source docs to correct**: `docs/smp_plan.md`'s status header and phase table say phase 7 is "not started" while line 269 records it done; `docs/video/v0.1.0_yasos_changes.md` inherited that stale claim ("core 1 boots and parks; it does not yet schedule work") — which understates the best result in the OS half.

---

## 6. Timing

Final shape, measured from the voiceover copy at 150 wpm:

| Scene | Slot | Speech | | Scene | Slot | Speech |
|---|---|---|---|---|---|---|
| 01 Intro | 2:15 | 1:59 | | 08 QEMU + linker scripts | 2:15 | 2:03 |
| 02 The suite that forced it | 2:30 | 2:17 | | 09 The scorecard | 2:30 | 2:28 |
| 03 IR / SSA / passes | 4:00 | 3:43 | | 10 Live demo | 1:50 | 1:35 |
| 04 The bug class | 2:30 | 2:22 | | 11 AI as co-developer | 1:45 | 1:39 |
| 05 The clock wasn't it | 3:45 | 3:45 | | 12 Roadmap | 1:45 | 1:37 |
| 06 Zeroing and the floor | 1:30 | 1:28 | | 13 Outro | 1:15 | 1:12 |
| 07 Two cores | 2:15 | 1:55 | | **Total** | **30:05** | **28:08** |

**Correction: my earlier note said these four cuts land "~24:30". That was wrong arithmetic — they land at 30:05.** For reference the draft was 24:20 of slots, but the slots were fiction: old Scene 09 held 2:10 of speech in a 0:45 slot, Scene 11 held 0:50 in 1:50, Scene 13 held 0:37 in 2:00. Against *speech*, the draft was 20:51 and this is 28:08. What accounts for the difference: the scorecard scene (2:28, new), the real bug story (2:22 vs the fabricated one), and the datasheet round (3:45 vs 1:25).

**To reach ~25:00 from here**, cheapest first:

1. **Scene 05 → 2:45** (−1:00). Drop the rescued "measure first" paragraph and the SD-card detour. Keeps the datasheet fix, which is the point.
2. **Scene 03 → 3:15** (−0:45). Cut the pass-family list to four examples; drop the CFG paragraph if the animation carries it.
3. **Scene 02 → 2:00** (−0:30). Merge the two "decision point" paragraphs.

That lands **25:50** — or 24:50 if you also drop Scene 07, though I'd keep it: 0.61x is the only place a viewer learns why more cores didn't fix this.

---

## 7. What moved to the OS episode

Cut from this script and **held, not lost**:

| Material | Where it was |
|---|---|
| Synchronization inventory (`source/kernel/sync/`, ~1,900 lines) | old 08 |
| **Ranked locks** — runtime-enforced, mutexes before spinlocks, console innermost, sparse numbering | old 08 |
| `block_context_switch` deleted across 37 sites + CI grep | old 08 |
| **48% syscall tax** — 20.1 → 29.7 µs/char on the echo path | old 08 |
| Syscall-path negative result (≈1%), stub into `.time_critical` (0.11 → 0.02 ms) | old 07 (cut) |
| **`uaccess` / "the MPU is no defence"** + the borrowed-XIP-`.rodata` wrinkle | old 12 |
| **`pipe(2)` as two ordinary `IFile`s** — why redirects and the vfork fd-table copy need no special cases | old 12 |
| **SDIO over PIO + CMD25** — 4 KiB `406 → 2,139`, 32 KiB `412 → 3,514`, 512 B unchanged | old 06 |
| Hybrid `/tmp` — ≤64 KB RAM-backed under an arena budget, spill to card | old 06 |
| `CONFIG_PROCESS_SMP=n` deterministic panic | old 08 / 12 |
| `54:20 → 10:36` told in full as measure → attack → re-measure | throughout |

That is comfortably its own 25 minutes, with a better spine than this episode has. This script keeps exactly **three** OS touches, each earning its place by being about compiling: the 0.61x result, the datasheet fix, and a fifteen-second hand-off in the roadmap.

**Plus one standalone short:** the floating-point material (two knobs, DCP on coprocessor 4, AAPCS-VFP doubles in `d0-d7` on a chip with no double FPU, `.ARM.attributes` matching GCC byte-for-byte, the FTZ limit). Teased in one paragraph in Scene 03, scripted in that scene's notes. Self-contained, visual, ~4 minutes.
