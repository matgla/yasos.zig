# Recording plan — TinyCC episode

18 scenes, ~33 min speech. All motion clips are already rendered — only the
rows below need to be shot. Order is by **setup**, not by scene: five sessions,
each with one lighting/rig state.

## 0. Before the shoot (blocking)

- [ ] `configs/mspc_defconfig`: 150 → 532 MHz, XIP deselect/continuous-read, `PROCESS_SMP=y`. Verify with `cat /proc/cpus`, not the boot banner.
- [ ] Delete `configs/mspc_defconfig_{BACKUP,BASE,LOCAL,REMOTE}_86736` (visible in any tree screen-record).
- [ ] One full `-O0/-O1/-O2` suite run, **keep the log** (V1 — the ~50 min figure).
- [ ] Decide: the "killed at 25% after 1 h" run — find a log, or narrate as recollection (V2).
- [ ] VO: record each scene's voiceover in **one continuous session**, plus 30 s room tone. No later pickups.
- [ ] Scorecard VO (scene 15): the `-O0` figures changed on 2026-08-30 — optimizer **2.37x**, `-O0` vs gcc **2.70x**, doubles gain **1.80x**. Read the corrected lines; the "the optimizer bought them nothing / one point zero zero" take was an artifact and must not ship (`changes.md` G11).
- [ ] Scorecard VO (scene 15), instruction-count beat: the median line was rewritten on 2026-08-30. Read "**and the median moves with them — one point zero zero across the whole corpus, one point one zero once those five are gone**". The old ending, "the median function is exactly one point zero zero", quoted a figure the five generated files manufacture and must not ship (`changes.md` G12).
- [ ] Scene 16 is **new as of 2026-08-30** and entirely unrecorded — both motion cards are rendered, but the whole voiceover and the closing A-roll need takes. It pays off scene 15's "a wide instruction that replaces two narrow ones is free", so record it in the same session as scene 15's corrected beats or the two will not match in tone.
- [ ] Read §7 before the VO session — the multi-layer beat is a change request in the script, not yet in the recorded lines.

## 1. Session A — Talking head (Cam A, desk, 4K)

One setup, one lighting, shoot in script order. 3 s handles head+tail on every take.
Subject right third, left third empty (overlays build there). Cam B = 2× crop in post, not a second shoot.

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | A1 | 01 Intro | Wide, welcome + stack overview; then same take reframed for the punch-in | 0:32 |
| ☐ | A1b | 02 The rig | Three takes, one setup: the confession (every number came off a board that is not MSPC), the MSPC button ("the cheaper board to be wrong on"), the close ("the only part of this that is not remote") | 0:35 |
| ☐ | A2 | 05 Linear scan | Why TAC needs a CFG, live intervals, cheap allocator | 1:00 |
| ☐ | A3 | 06 SSA | Open (compare to GCC) + long block: SSA → register pressure → payoff | 2:25 |
| ☐ | A4 | 07 Writing a pass | "The bottleneck moved" open + closing "right split" button | 0:22 |
| ☐ | A5 | 11 SMP | Honest/reflective: two cores didn't help | 1:30 |
| ☐ | A6 | 13 Live demo | Intro to the native compile, pointing at the terminal | 0:25 |
| ☐ | A7 | 17 Roadmap | Open + roadmap block | 1:00 |
| ☐ | A8 | 18 Outro | Sign-off, warm, direct to camera | 1:40 |
| ☐ | A9 | 14 AI co-dev | Insert: hands at keyboard, close-up | 0:05 |
| ☐ | A10 | 16 Shorter isn't faster | Closing limit to camera — bytes are charged for, just not by the pipeline | 0:17 |

## 2. Session B — Top-down macro (boards)

Same rig for all: overhead, one soft key, no RGB wash. Shoot every board angle back to back.

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | M1 | 01 | MSPCv2 left, Pico Plus 2 + VGA Base right; Pico stack angled 10–15°; hold 3 s clean for labels | 0:10 |
| ☐ | M2 | 01 | Same pair, macro, held still (context shot) | 0:16 |
| ☐ | M3 | 05 | Macro of the RP2350 / QSPI flash area | 0:07 |
| ☐ | M4 | 11 | Board close-up with USB attached, RGB on | 0:05 |
| ☐ | M5 | 13 | MSPCv2 with USB + SD card inserted, RGB backlight | 0:15 |
| ☐ | M6 | 17 | Board with USB hub cable + VGA connections, wiring close-up | 0:25 |
| ☐ | M7 | 02 | **The rig where it lives, not staged on the desk** — Pi 5, the 4-port hub, the debug probe, the Pico Plus 2 on the VGA base, and the SWD/UART leads between the last two. The shot's whole point is that it is on a shelf | 0:15 |

## 3. Session C — Board terminal capture

Start the long runs first, capture the short ones while they run.

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | T1 | 10/13 | **Start first:** full suite `-O0/-O1/-O2` + own tests → final summary + PASS counts (~50 min run) | 0:25+0:10 |
| ☐ | T2 | 03 | Native TinyCC crash log on target, cross-compiler build log above it | 0:15 |
| ☐ | T3 | 03 | Legacy run: failures scrolling, progress stuck ~25%, timer past 1 h, aborted (one take, not two rows) | 0:16 |
| ☐ | T4 | 03 | Optimized run streaming, progress filling, timer under target | 0:30 |
| ☐ | T5 | 08 | GNU Make failing as soon as a test touches floating point | 0:12 |
| ☐ | T6 | 08 | Torture FP tests running on the board | 0:20 |
| ☐ | T7 | 11 | Two compiles launched with `&` + `time` output — parallel loses to single-core | 0:08 |
| ☐ | T8 | 12 | Split screen: QEMU left, MSPCv2 right, same prompt, same binary name | 0:45 |
| ☐ | T9 | 12 | Edit → QEMU test → hardware verify workflow pass | 0:30 |
| ☐ | T10 | 13 | Native tcc compiling itself, output scrolling | 0:30 |
| ☐ | T11 | 13 | Torture suite with PASS counters and test names | 0:40 |
| ☐ | T12 | 18 | Short outro capture: self-compile + torture passing | 0:15 |
| ☐ | T13 | 16 | `run_width_demo.py` on the board: the four cases with their `sum=` columns and `verdict: MATCH`, ending on `WIDTH DEMO: PASS`. Terminal **100 columns** or the table wraps and the MATCH verdict is what makes the timings mean anything | 0:18 |
| ☐ | T14 | 02 | **Scripted, not typed by hand:** `scripts/rig_shot.sh rig_full` — one command builds locally, rsyncs to the Pi, flashes over SWD, then resets, attaches gdb, breaks in the kernel and prints a backtrace. Plays at the same cadence every take and fails itself if a step did not really happen. Runs **here**, not on the rig | 1:30 |
| ☐ | T15 | 02 | The SRAM proof, three commands in one take: `mww 0x20010000 0xdeadbeef`, `uhubctl -l 1 -p 2 -a off` then `on`, `mdw 0x20010000` still reading `deadbeef` — then an insert of a hand physically unplugging the board | 0:18 |

**T14/T15 hold the board.** A rig take refuses to start while anything on the
Pi already holds it, but nothing stops the reverse — so do not start a CI job
or a smoke run during one. And **never interrupt T14 mid-flash**: OpenOCD has
the probe, and killing it there is how the board ends up wedged
(`yasos-remote-smoke-board-recovery`). Let it finish or let `--rig-timeout`
expire.

## 4. Session D — Desktop screen capture (no board)

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | G1 | 09 | Grafana, blurred, trend line dropping over weeks | 0:10 |
| ☐ | G2 | 09 | One red spike on a commit, green trend after the fix | 0:10 |
| ☐ | G3 | 11 | Profiling graph: XIP cache misses rising under SMP | 0:25 |
| ☐ | G4 | 15 | Grafana scrub across the six months (size / compile time / cycles) | 0:15 |
| ☐ | G5 | 14 | AI chat window with a TinyCC diff visible, dark theme | 0:06 |

## 5. Session E — Instruments

| ☐ | ID | Scene | Shot | Len |
|---|---|---|---|---|
| ☐ | L1 | 10 | Thermal camera over MSPCv2 under compile load, temp readout climbing | 0:15 |
| ☐ | L2 | 10 | Scope/log: clean PSRAM read vs corrupted read >600 MHz, bad byte highlighted | 0:30 |

## 6. Do NOT shoot — already rendered

`motion/` holds a finished `.mp4` for every C/D-roll and for several rows the
script still marks "to record" or "to animate":

- Scene 02 the rig chain and the inversion → `s01b_b0_four-machines-one-wire`, `s01b_b1_the-terminal-is-the-fast-one`
- Scene 03 split-screen "compiler = complex self-test" → `s02_b4_the-richest-test`
- Scene 04 whiteboard TAC / basic blocks / CFG / C→records → `s03_b0`, `s03_b1`, `s03_b3`, `s03_b5`
- Scene 06 GCC-vs-TinyCC disassembly split → `s05_b0_the-gap-that-started-it`
- Scene 15 all six scorecard cards → `s13_b0`…`s13_b5`
- Scene 16 both width-experiment cards → `s13b_b1_shorter-and-slower`, `s13b_b2_three-rankings` (prefix is `s13b_` because the scorecard owns `s13_` and the roadmap owns `s14_`, the same device as `s06_dsl_`)

**Numbering drift:** motion filenames use the 13-scene numbering from
`tinycc-closing-gap-to-tcc.changes.md`; the script is now on 18. Reconcile the
`Source` column before the edit, or clips get pulled into the wrong scene. The
rig scene's clips are `s01b_` for the same reason `s13b_` exists: the intro
owns `s01_` and the GCC suite owns `s02_`.

## 7. Talking points to land (VO)

**The speedup was multi-layer.** Fifty-four minutes to ten thirty-six is four
things stacked, and saying so is a better story than the number alone. Change
requests are filed in the script (scene 03 sets it up, scene 13 pays it off) —
they need to be worked into the lines before the VO session, since VO is one
take with no pickups.

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
