# Recording plan — TinyCC, two episodes

**Split into two parts on 2026-09-03.** 22 scenes across two episodes, ~39 min
of speech. The seam is between the SSA scene and Writing a
Pass: part one proves the compiler is *correct* and ends on the self-host, part
two proves it is *fast* and opens by turning the bootstrap loop.

**Part one completed 2026-09-04.** The split left it building a compiler across
three scenes and never showing it being made *right* — the intro promised
"hundreds of bugs that manifested on the board" and nothing paid it off. P1/07,
**The Bug Class I Found Five Times**, is that payoff and is new; the richest-test
close moves to **P1/08**. The same edit puts the reason for the split in part
one's own mouth: a bug costs two runs of the suite, so the compiler could not be
stabilised until it was fast enough to test. That beat closes P1/07 and is
echoed in one sentence of the intro — it is the only place either part states
the dependency as cause and effect, so it does not get cut for time.

| | Part one — *How a Translator Became a Compiler* | Part two — *Closing the Gap to GCC* |
|---|---|---|
| 01 | Intro & project overview | Cold open: the loop, and the clock |
| 02 | The rig | Writing a pass |
| 03 | GCC torture suite | Floating point |
| 04 | Single-pass to multi-pass: IR | Grafana |
| 05 | Linear scan | XIP bottleneck |
| 06 | SSA | SMP vs XIP reality |
| 07 | **The bug class I found five times** *(new)* | QEMU |
| 08 | **Part one ends on the richest test** *(new)* | Live demo |
| 09 | | AI as co-developer |
| 10 | | The scorecard |
| 11 | | Shorter isn't faster |
| 12 | | Where the doubles go |
| 13 | | Roadmap |
| 14 | | Outro |

Every row below is tagged `P1/NN` or `P2/NN` with that scene number. **The
shoot is still one shoot** — the sessions are by setup, not by episode, and the
VO for both parts is recorded in one sitting. Splitting the shoot is how the
two halves end up not matching.

All motion clips are already rendered except the two the split added — part
one's bug-family card (P1/07) and the bootstrap loop (P1/08 → P2/01). Everything
else in the rows below needs to be shot, not drawn.
Sessions are by **setup**, not by scene — five of them, each with one
lighting/rig state — and inside a session the rows run in **script order**, so a
table can be read down alongside the script.

## 0. Before the shoot (blocking)

- [ ] `configs/mspc_defconfig`: 150 → 532 MHz, XIP deselect/continuous-read, `PROCESS_SMP=y`. Verify with `cat /proc/cpus`, not the boot banner.
- [ ] Delete `configs/mspc_defconfig_{BACKUP,BASE,LOCAL,REMOTE}_86736` (visible in any tree screen-record).
- [ ] One full `-O0/-O1/-O2` suite run, **keep the log** (V1 — the ~50 min figure).
- [ ] Decide: the "killed at 25% after 1 h" run — find a log, or narrate as recollection (V2).
- [ ] VO: record each scene's voiceover in **one continuous session**, plus 30 s room tone. No later pickups. **Both parts in that one session**, including all three new scenes (P1/07 bug class, P1/08 self-host close and P2/01 cold open) and both endings — they are two halves of one hand-off and recorded weeks apart they will not match.
- [ ] The two figures part two opens on — **54:00 → 10:36** — come from a full on-board run that has not been made since 2026-08-20. That run is take T1. If the number moves it moves in P2/01, P2/08 and P2/10 together.
- [ ] Scorecard VO (scene 15): the `-O0` figures changed on 2026-08-30 — optimizer **2.37x**, `-O0` vs gcc **2.70x**, doubles gain **1.80x**. Read the corrected lines; the "the optimizer bought them nothing / one point zero zero" take was an artifact and must not ship (`changes.md` G11).
- [ ] Scorecard VO (scene 15), instruction-count beat: the median line was rewritten on 2026-08-30. Read "**and the median moves with them — one point zero zero across the whole corpus, one point one zero once those five are gone**". The old ending, "the median function is exactly one point zero zero", quoted a figure the five generated files manufacture and must not ship (`changes.md` G12).
- [ ] Scorecard VO (scene 15), the census card: `motion/s13_b4_every-benchmark.py` is **new as of 2026-09-03** and has no narration. It runs 24 s at 1:40 — all 29 benchmarks, first against `tcc -O0` and then re-based on `gcc -O2` — and everything after it in that scene's B-roll table has been moved by its length. Either record a beat for it (the scene's Notes carry a line that fits) or shorten the card and put the timings back.
- [ ] Scene 16 is **new as of 2026-08-30** and entirely unrecorded — both motion cards are rendered, but the whole voiceover and the closing A-roll need takes. It pays off scene 15's "a wide instruction that replaces two narrow ones is free", so record it in the same session as scene 15's corrected beats or the two will not match in tone.
- [ ] Scene 17 (`Where the Doubles Go`) is **new as of 2026-09-03, re-based 2026-09-04** and entirely unrecorded — voiceover and all four motion cards. It is the payoff for scene 15's "losing badly on doubles" and it hands into the roadmap, so it wants the same session as scene 15's corrected doubles beat. Its figures are instruction counts under QEMU, not rig cycles; the VO says so in its last line and that line must not be cut. **All four `s13c_` cards and the VO were re-measured and re-rendered 2026-09-04 at tinycc `f6cec118` (branch `dadd-fixes`, worktree `/home/mateusz/repos/tcc-dadd`, three commits, NOT merged to `mob`)**: 127.6 vs 75.9 a call, 52 extra (9 arithmetic / 42 bookkeeping), 84.1%, tcc 352 / 1,018 B. The card that closed on "three things to write" now closes on **one landed, one disproven, one still to write** — fix 1 is in, fix 2 turned out to be a plain spill whose eviction bought 0.01 a call and exposed a shipping wrong-code bug in the allocator (fixed in the same branch), fix 3 is the roadmap's. The 2026-09-03 cards are kept in `motion/_803a2f25/`. **Decide the recorded commit before the VO session**: if part two is recorded at `803a2f25`, restore those and the 2026-09-03 VO.
- [x] The rig run for scene 17 is done (2026-09-04, `arm5_tcc_O2_dadd_fixes_f6cec118.json` beside the other arms in `/home/mateusz/repos/tcc-fpo0/measurements/`, gcc arm unchanged, image size-matched): `double_add` alone **1.81x** gcc, doubles **1.62x** (was 1.64x), everything else 1.075x unchanged, all 1.138x — still "one point one four". The scene's last VO line now quotes it.
- [ ] **Scorecard VO (scene 15) and cards must move with scene 17 or they contradict each other on camera**, if the recorded compiler is `dadd-fixes`: "doubles one point six four" → "one point six two", honest -O0 doubles gain "one point eight" → "one point eight two" (1.824x); optimizer stays "two point three seven" (2.372x), vs-gcc stays "one point one four" (1.138x). Cards drawing the doubles bar (`s13_b0`, `s13_b1`, `s13_b2`, `s13_b4`, `s07_b0`) still carry arm1's 8,390,567 and need arm5's 8,277,300. Not done — it waits on the merge decision.
- [ ] Scene P1/07 (`The Bug Class I Found Five Times`) is **new as of 2026-09-04** and entirely unrecorded — three A-roll beats, four screen/board captures (T16–T19) and one card to animate. It is the scene that makes part one an arc about stability rather than a tour of compiler architecture, and its last beat is the only place either part says outright that the compiler could not be stabilised until it was fast enough to test. Record it in the same session as A12 and A13 — the three of them carry the hand-off between the parts.
- [ ] T17 needs a **deliberately mis-built rootfs** (a tcc without the `irop_op_is_lval` guard) plus `build_rootfs.sh -c`, or the broken redirect will not reproduce on the shipped toybox. Build both images before the shoot day; this is the one take that cannot be improvised.
- [ ] Read §7 before the VO session — the multi-layer beat is a change request in the script, not yet in the recorded lines.

## 1. Session A — Talking head (Cam A, desk, 4K)

One setup, one lighting, shoot in script order. 3 s handles head+tail on every take.
Subject right third, left third empty (overlays build there). Cam B = 2× crop in post, not a second shoot.

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | A1 | P1/01 Intro | **Cold-open beat first** — "six months ago it could not do that", straight to camera, no welcome, shot before the greeting so the two never get cut together; then wide, welcome + stack overview, then the same take reframed for the punch-in | 0:40 |
| ☐ | A1b | P1/02 The rig | Three takes, one setup: the confession (every number came off a board that is not MSPC), the MSPC button ("the cheaper board to be wrong on"), the close ("the only part of this that is not remote") | 0:35 |
| ☐ | A2 | P1/05 Linear scan | Why TAC needs a CFG, live intervals, cheap allocator | 1:00 |
| ☐ | A3 | P1/06 SSA | Open (compare to GCC) + long block: SSA → register pressure → payoff | 2:25 |
| ☐ | A4 | P2/02 Writing a pass | "The bottleneck moved" open + closing "right split" button | 0:22 |
| ☐ | A5 | P2/06 SMP | Honest/reflective: two cores didn't help | 1:30 |
| ☐ | A6 | P2/08 Live demo | Intro to the native compile, pointing at the terminal | 0:25 |
| ☐ | A9 | P2/09 AI co-dev | Insert: hands at keyboard, close-up | 0:05 |
| ☐ | A10 | P2/11 Shorter isn't faster | Closing limit to camera — bytes are charged for, just not by the pipeline | 0:17 |
| ☐ | A11 | P2/12 Where the doubles go | Closing caveat to camera — these are instructions executed, not cycles; the board is where the 1.64x came from | 0:14 |
| ☐ | A7 | P2/13 Roadmap | Open + roadmap block | 1:00 |
| ☐ | A8 | P2/14 Outro | Sign-off, warm, direct to camera | 1:40 |
| ☐ | A12 | P1/08 Self-host close | Two beats: the short hand-off into the terminal, then the loop and "bring a stopwatch" straight to camera | 0:32 |
| ☐ | A14 | P1/07 Bug class | Three beats, one setup: the thesis ("every optimization is also a new way to be wrong"), "the fifth time I have fixed that bug" delivered flat, and the close — two runs of the suite per bug, stability gated on speed. The third beat hands to part two and must be shot with A12 and A13 | 0:50 |
| ☐ | A13 | P2/01 Cold open | Two beats: "here is the thing I left hanging" picked up mid-thought with **no welcome**, then the two timings and the four-layers promise | 0:38 |

## 2. Session B — Top-down macro (boards)

Same rig for all: overhead, one soft key, no RGB wash. Shoot every board angle back to back.

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | M1 | P1/01 | MSPCv2 left, Pico Plus 2 + VGA Base right; Pico stack angled 10–15°; hold 3 s clean for labels | 0:10 |
| ☐ | M2 | P1/01 | Same pair, macro, held still (context shot) | 0:16 |
| ☐ | M7 | P1/02 | **The rig where it lives, not staged on the desk** — Pi 5, the 4-port hub, the debug probe, the Pico Plus 2 on the VGA base, and the SWD/UART leads between the last two. The shot's whole point is that it is on a shelf | 0:15 |
| ☐ | M3 | P1/05 | Macro of the RP2350 / QSPI flash area | 0:07 |
| ☐ | M4 | P2/06 | Board close-up with USB attached, RGB on | 0:05 |
| ☐ | M5 | P2/08 | MSPCv2 with USB + SD card inserted, RGB backlight | 0:15 |
| ☐ | M6 | P2/13 | Board with USB hub cable + VGA connections, wiring close-up | 0:25 |

## 3. Session C — Board terminal capture

Rows are in script order, but T1 is the long one: **launch it first** and
capture the rest while it runs.

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | T14 | P1/02 | **Scripted, not typed by hand:** `scripts/rig_shot.sh rig_full` — one command builds locally, rsyncs to the Pi, flashes over SWD, then resets, attaches gdb, breaks in the kernel and prints a backtrace. Plays at the same cadence every take and fails itself if a step did not really happen. Runs **here**, not on the rig | 1:30 |
| ☐ | T15 | P1/02 | The SRAM proof, three commands in one take: `mww 0x20010000 0xdeadbeef`, `uhubctl -l 1 -p 2 -a off` then `on`, `mdw 0x20010000` still reading `deadbeef` — then an insert of a hand physically unplugging the board | 0:18 |
| ☐ | T2 | P1/03 | Native TinyCC crash log on target, cross-compiler build log above it | 0:15 |
| ☐ | T3 | P1/03 | Legacy run: failures scrolling, progress stuck ~25%, timer past 1 h, aborted (one take, not two rows) | 0:16 |
| ☐ | T4 | P1/03 | Optimized run streaming, progress filling, timer under target | 0:30 |
| ☐ | T5 | P2/03 | GNU Make failing as soon as a test touches floating point | 0:12 |
| ☐ | T6 | P2/03 | Torture FP tests running on the board | 0:20 |
| ☐ | T1 | P2/05/P2/08 | **Start first:** full suite `-O0/-O1/-O2` + own tests → final summary + PASS counts (~50 min run) | 0:25+0:10 |
| ☐ | T7 | P2/06 | Two compiles launched with `&` + `time` output — parallel loses to single-core | 0:08 |
| ☐ | T8 | P2/07 | Split screen: QEMU left, MSPCv2 right, same prompt, same binary name | 0:45 |
| ☐ | T9 | P2/07 | Edit → QEMU test → hardware verify workflow pass | 0:30 |
| ☑ | T10 | P1/01, P1/08 | **Shot 2026-09-04 — `scripts/rig_shot.sh crosstcc`, 90 s, 10/10 checks.** A host build, as re-specified 2026-09-03: the sources counted on camera (622 files, 235,165 non-blank lines), the two native stamps cleared, then `./build_rootfs.sh` with configure naming `armv8m-tcc` as the C compiler and `armv8m-tcc -o armv8m-source/… -c source/…` scrolling — tcc compiling tcc. Closes on a cleared screen: 1,526,463 B of ARM `.text`, and `rootfs/usr/bin/tcc` at 1,653,552 B. Master: `part1-becoming-a-compiler/recordings/crosstcc-20260904-114106.mov`. TinyCC does **not** rebuild itself on the board (no make, does not fit in RAM, architecture split ahead), so the old brief — "native tcc compiling itself" on target — could not have been shot | 1:30 |
| ☐ | T11 | P2/08 | Torture suite with PASS counters and test names | 0:40 |
| ☐ | T13 | P2/11 | `run_width_demo.py` on the board: the four cases with their `sum=` columns and `verdict: MATCH`, ending on `WIDTH DEMO: PASS`. Terminal **100 columns** or the table wraps and the MATCH verdict is what makes the timings mean anything | 0:18 |
| ☐ | T12 | P2/14 | Short outro capture: the cross compiler building tcc on the host, then the torture suite passing on the board | 0:15 |
| ☐ | T11c | P1/01 | The board working through the suite for the **cold open**, PASS counters climbing, **no elapsed timer**. First frames of part one, so shoot it clean | 0:18 |
| ☐ | T11b | P1/08 | Torture suite with PASS counters and test names — **no elapsed timer in frame** | 0:16 |
| ☑ | T20 | P1/03 | **Shot 2026-09-04 — `scripts/demo_shot.sh tests`, 63 s, 6/6 checks.** The tests compiled and run *by hand* on the board: the corpus where CI left it (`/root/ci/sources/v2`), one shard listed, `pr93402.c` read out, `tcc -O2` on it, `rc=0`, then one shell loop over all 48 tests in the shard — a wall of green PASS and no failures. No timer in frame. Master: `part1-becoming-a-compiler/recordings/tests-on-board-20260904-104809.mov`, with keyboard sound and a blinking cursor. Re-shootable at the same cadence: the shot checks itself and names the shard, so a retake after a compiler change is one command | 1:03 |
| ☐ | T16 | P1/07 | The miscompile, in two captures cut together: `-dump-ir` of the 8-line reduction with `V***DEREF*** <- T [STORE]` on screen, then the emitted `str.w r5, [r1, r2, lsl #2]` with the base register annotated — r1 is the loop counter, not the pointer. Static, no timer | 0:36 |
| ☐ | T17 | P1/07 | **On hardware:** `echo hello > file` on the broken build — the redirect failing and the shell losing its stdin — then the same command on the fixed build. Needs a deliberately mis-built rootfs *and* `build_rootfs.sh -c`, because toybox ships at -O2 and a codegen fix does not reach it otherwise. Plan this one ahead of the shoot day | 0:16 |
| ☐ | T18 | P1/07 | The one-line diff, `if (irop_op_is_lval(dest)) return 0;`, beside the guard the same pass already had on its source operand | 0:10 |
| ☐ | T19 | P1/07 | **The live bisect, and it ends honestly.** A failing test, `TCC_DISABLE_PASS` taking half the list at a time, arms narrowing to one name — then cut to the per-pass IR dumps diffed against each other, first changed operand lit. Shoot the bisect on a case where it actually converges; the 439 bug is *not* one, and the scene says so | 0:24 |
| | | | *T10 and T11b/T11c carry part one at both ends: the cold open of P1/01 (0:00-0:18) and the closing scene P1/08. Same setups, shot once — but they are the first frames of the episode, so shoot them clean.* | |

**T10's figures have drifted from the cards, and the VO covers it.** The take
shows 235,165 lines and 1,526,463 B of `.text`; `s02_b6`/`s02_b4` were measured
at tinycc `803a2f25` and say 235,045 and 1,494.8 KiB. "Two hundred and thirty-five
thousand lines … one and a half megabytes" is true of both, but do not put a
card and a legible frame of the take on screen together without re-rendering the
card at the filmed commit. Also: the build's tail prints toybox warnings and
`armv8m-tstrip: No such file or directory` / `strip failed, using unstripped` —
the take types `clear` before its closing commands so none of that is in the
payoff frame, and the missing `tstrip` is worth fixing in the tree.

**T20 is the manual version of T11, and the shard it runs is load-bearing.**
`03` is 48 tests and all 48 pass; `00` and `01` each hold one test that asks for
a stack this board does not hand out by default (`dg-require-stack-size`, which
the real harness reads and a shell loop cannot), so a switch of shard puts a
failure on screen that has nothing to do with codegen. `--tests-shard` /
`--tests-cat` change both. Also: `/dev/null` on this board is on a read-only
filesystem, so no take may redirect to it.

**What the board can and cannot be filmed doing.** It compiles and runs the
4,398-test suite natively — that is T11/T11b/T11c, and T20 by hand. It does **not** rebuild
TinyCC itself: no make on target, the source does not fit in the RAM available,
and the architecture split is future work. Every "compiling itself" shot is
therefore a **host** build with the cross compiler (T10), and part one's closing
scene says so on camera.

**The clock rule, and it is the whole split.** Part one shows no elapsed timer
anywhere. T11 is shot for part two with the timer visible and again for part one
(T11b/T11c) without it — or shot once in 4K framed so the timer can be
cropped, which is cheaper but has to be decided at the camera: a timer cropped
out is fine, a timer that was never on screen cannot be added. **T3** (legacy
run aborted at 25%) is part one's only performance footage and it is a
*failure*, which is the point. **T4** (optimized run, timer under target) is
part two's opening evidence and must not appear in part one.

**T14/T15 hold the board.** A rig take refuses to start while anything on the
Pi already holds it, but nothing stops the reverse — so do not start a CI job
or a smoke run during one. And **never interrupt T14 mid-flash**: OpenOCD has
the probe, and killing it there is how the board ends up wedged
(`yasos-remote-smoke-board-recovery`). Let it finish or let `--rig-timeout`
expire.

## 4. Session D — Desktop screen capture (no board)

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | G1 | P2/04 | Grafana, blurred, trend line dropping over weeks | 0:10 |
| ☐ | G2 | P2/04 | One red spike on a commit, green trend after the fix | 0:10 |
| ☐ | G3 | P2/06 | Profiling graph: XIP cache misses rising under SMP | 0:25 |
| ☐ | G5 | P2/09 | AI chat window with a TinyCC diff visible, dark theme | 0:06 |
| ☐ | G4 | P2/10 | Grafana scrub across the six months (size / compile time / cycles) | 0:15 |

## 5. Session E — Instruments

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | L1 | P2/05 | Thermal camera over MSPCv2 under compile load, temp readout climbing | 0:15 |
| ☐ | L2 | P2/05 | Scope/log: clean PSRAM read vs corrupted read >600 MHz, bad byte highlighted | 0:30 |

## 6. Do NOT shoot — already rendered

`motion/` holds a finished `.mp4` for every C/D-roll and for several rows the
script still marks "to record" or "to animate":

- Scene 02 the rig chain and the inversion → `s01b_b0_four-machines-one-wire`, `s01b_b1_the-terminal-is-the-fast-one`
- Scene 03 split-screen "compiler = complex self-test" → `s02_b4_the-richest-test`
- Scene 04 whiteboard TAC / basic blocks / CFG / C→records → `s03_b0`, `s03_b1`, `s03_b3`, `s03_b5`
- Scene 06 GCC-vs-TinyCC disassembly split → `s05_b0_the-gap-that-started-it`
- Scene 15 all ten scorecard cards → `s13_b0`…`s13_b9` (renumbered 2026-09-03: the census card went in at `s13_b4` and the five encoding cards after it each moved up one)
- Scene 16 both width-experiment cards → `s13b_b1_shorter-and-slower`, `s13b_b2_three-rankings` (prefix is `s13b_` because the scorecard owns `s13_` and the roadmap owns `s14_`, the same device as `s06_dsl_`)
- Scene 17 all four dadd cards → `s13c_b0_one-object-file`, `s13c_b1_smaller-and-slower`, `s13c_b2_fifty-five-instructions`, `s13c_b3_three-things-to-write` (`s13c_` continues the same device — the scene sits between `s13b_` and `s14_`); **re-rendered 2026-09-04 at `f6cec118`** — the filenames still say fifty-five / three-things, the frames say fifty-two and one-landed-one-disproven; the 803a2f25 renders are in `motion/_803a2f25/`

- P1/07's bug-family card is **new and not rendered**: the same mistake drawn
  five times — phi construction, parameter entry definitions, round-trip
  elimination, the LEA handling and `var_tmp_fwd` — each a pass reading the
  destination of a store and calling it a definition, with the house rule under
  it. Prefix it `s06_` (the scenes it follows own `s05_`/`s06_`); reconcile
  against the drift note below before the edit.
- Part one's closing scene and part two's cold open share **one new card** —
  the bootstrap loop as a two-node cycle, drawn in P1/08 and *turned* in
  P2/01. It is the only clip the split adds and it is not rendered yet.
- Moved with the split: `s02_b7_the-whole-userland` now plays in **P2/10**
  (the scorecard), not in the torture-suite scene. `s01_c3_old-vs-new-run` and
  `s01_c4_three-labels-teaser` moved to **P2/01**; `s01_c3` now needs the two
  timings on it.

**Numbering drift:** motion filenames use the 13-scene numbering from
`tinycc-closing-gap-to-tcc.changes.md`; the script is now on 21 across two parts, and the drive is filed by each part's
own numbering (`part1-becoming-a-compiler/animations/s04_…`). Reconcile the
`Source` column before the edit, or clips get pulled into the wrong scene. The
rig scene's clips are `s01b_` for the same reason `s13b_` exists: the intro
owns `s01_` and the GCC suite owns `s02_`.

## 7. Talking points to land (VO)

**The speedup was multi-layer.** Fifty-four minutes to ten thirty-six is four
things stacked, and saying so is a better story than the number alone. This is
now part two's spine: **P2/01 promises the four layers**, and P2/08 pays them
off. The bootstrap-loop bullet below is no longer one of four bullets — it is
the cliffhanger P1/08 ends on and the first thing P2/01 turns, so it gets its
own beat in both.

- **OS layer** — 532 MHz + XIP continuous-read, memory and filesystem paths.
  (SMP is scene 10 and it *didn't* help — one clause, don't re-argue it.)
- **Compiler compile-time** — startup, predefines, the -O0 pipeline. How fast
  tcc gets through a file, independent of what it emits.
- **The bootstrap loop** — the cross-compiler's optimizer compiles the native
  compiler, so every pass makes the on-board binary itself faster. TinyCC
  optimizes itself into a faster TinyCC. This is the beat people don't expect;
  give it room.
- **Silicon-tuned passes** — addressing modes and costs measured on the M33 and
  validated on the rig, not a generic cost model.

Close on the compounding: any one layer alone is modest, they multiply.

**Do not quote a split** across the four layers. Nothing attributes the 54 →
10:36 to them individually; that figure is end-to-end only. Qualitative unless
someone measures it layer by layer first.
