"""What does the smoke suite's one-command-at-a-time shape actually cost?

The harness drives one shell over one console and waits for the prompt between
commands, so a test costs a full round trip whatever the device is doing. Two
different things could be paid for that, and they need separating before either
is built on:

  * **the round trip itself** -- the command bytes out, the echo back, the
    prompt. `prun` (apps/prun) removes it for a whole batch: it takes a file of
    commands and runs them from a single round trip.
  * **the serialisation** -- one command in flight means one process running.
    `prun -j N` removes that too, by keeping N children in flight.

So each workload below is run four ways: the way the suite does it today (one
console command per job), then batched at -j1, -j2 and -j4. The -j1 batch is the
one that isolates the round trip, because it changes nothing else.

Six workloads, because they answer different questions:

  * **compile** -- four tcc runs, each in the range of the corpus median. This
    is what a suite run is made of, and what any speedup has to move.
  * **compile-small** -- the same, on a quarter-size source. Same compiler, same
    file operations, a third of the work: it separates a penalty that scales
    with the job from one that is a fixed cost per job.
  * **compute** -- a tight ALU loop from a RAM-resident binary, with no
    allocation and no I/O. The control: it is the arm that says whether two
    cores can add throughput on this silicon at all.
  * **mixed** / **mixed-io** -- one compile overlapped with the work the suite
    does *around* a compile, never with another compile. This is the pipelining
    question: core X compiles while core Y runs the previous test and removes
    its artifacts. `mixed` overlaps near-pure computation, `mixed-io` overlaps
    the syscall traffic of an execute-and-clean step -- which matters separately
    because the kernel is in XIP flash too, so a RAM-resident binary can still
    evict tcc by way of the syscalls it makes.
  * **spawn** -- many trivial programs. A compile is long enough to hide a round
    trip inside measurement noise; this is short enough to expose it, and the
    per-job difference between its lockstep and -j1 arms *is* the round trip.

WHAT THIS MEASURED, on the phase-7 SMP kernel where both cores really schedule
(2026-08-12, rig at 618 MHz; `test_secondary_core_actually_runs_processes`
passes on the same build, so the second core is genuinely running processes):

    workload        lockstep      -j1     -j2
    compile         511 ms/job   0.96x   0.61x
    compile-small   167 ms/job   0.92x   0.59x
    compute         200 ms/job   1.01x   1.64x
    spawn           3.4 ms/job   1.81x   1.90x

**The cores are not the problem and memory is not the problem.** Pure ALU work
gets 1.64x from a second core. Compiles *lose* 40%, and lose the same fraction
on a quarter-size source -- so it is not the process pool spilling into PSRAM,
which would have shrunk with the footprint. The absolute penalty tracks compute
time rather than file-operation count (+325 ms/job on a 511 ms job, +118 ms on a
167 ms job), which rules out a fixed per-job lock or syscall cost too.

What is left is the resource a compile uses continuously and the compute binary
never touches: instruction fetch through the single 16 KiB XIP cache that both
cores share. tcc executes in place from romfs in XIP flash; the compute binary
runs from /tmp in RAM. That is measured rather than inferred -- /proc/xip
carries the cache's own hit and access counters, and the arms below read them:

    workload        arm    hit rate   accesses   misses vs -j1   wall vs -j1
    compile         -j1       95.5%       179M              --            --
    compile         -j2       94.6%       215M            +44%          +50%
    compile-small   -j1       95.6%        62M              --            --
    compile-small   -j2       94.2%        72M            +53%          +55%
    compute         -j1       97.8%       5.1M              --            --
    compute         -j2       97.7%       5.1M              0%           -38%

**The extra misses account for the lost time almost exactly**, and the control
arm is what makes that causal rather than correlated: the compute job does 35x
less XIP traffic than a compile of similar length, its counters do not move when
a second copy runs beside it, and it is the one arm that speeds up. Concurrency
costs two tcc instances 20% more accesses at a lower hit rate -- they evict each
other from a cache neither can fit in -- and every extra miss is a QMI fetch on
an instruction-fetch-bound workload.

The practical consequence: **device-side concurrency cannot speed up the tcc
suite**, whatever order the tests are run in and whatever their memory
footprints are, because the contention is in the compiler's own instruction
fetch. Nothing schedulable fixes that: the cache is 16 KiB of fixed hardware,
PSRAM sits behind the same QMI so relocating tcc's text does not escape it, and
tcc's 1.4 MiB of .text does not fit the 388 KiB of fast SRAM. Concurrency does
pay for RAM-resident workloads, which is what the compute arm is showing.

AND THE PIPELINING VARIANT -- overlap a compile with the *non*-compile work
around it, so two compiles are never in flight:

    workload    lockstep     -j1     -j2   XIP acc -j1 -> -j2
    mixed         0.71 s   0.97x   1.32x   46.5M -> 46.5M (flat)
    mixed-io      0.52 s   0.95x   0.95x   48.0M -> 46.6M (flat)

**The mechanism is free and the scale is wrong.** `mixed` hides 200 ms of
RAM-resident work behind a 511 ms compile for ~29 ms, with the cache counters
flat -- overlapping non-compile work disturbs nothing. `mixed-io` gains nothing,
and not because it disturbs: the io job and the `rm` are ~10 ms against a 511 ms
compile, so there is nothing there to hide. That is the suite's real shape --
execute is 2.1 ms/test and cleanup 5.8 ms/test against a 111 ms compile -- and
prun-shaped orchestration charges 9-23 ms/job to hide 8 ms of work. Attack the
orchestration cost first (the -j1 arm of any workload *is* that number); the
pipeline is only worth building once it is below ~8 ms/test.

Measurement, not an assertion -- it prints and never fails, so a full suite run
neither pays for it nor can be failed by it:

    scripts/remote_smoke_tui.py --pytest-args \\
        "tests/smoke/prun_scaling_test.py -m measure -s"
"""

import os
import re
import time

import pytest

from .conftest import session_key


pytestmark = pytest.mark.measure


# Where the generated source, the batch files and prun's per-job logs live.
# /tmp is the tiered ramfs, so this stays off the SD card and out of the way of
# the write path a compile already exercises.
WORK_DIR = "/tmp/pscal"
SOURCE = WORK_DIR + "/scal.c"
SMALL_SOURCE = WORK_DIR + "/small.c"
COMPUTE_SOURCE = WORK_DIR + "/comp.c"
COMPUTE_BINARY = WORK_DIR + "/comp"
IO_SOURCE = WORK_DIR + "/io.c"
IO_BINARY = WORK_DIR + "/io"

# -j values to measure, in the order they run. -j1 appears twice, first and
# last: the pair brackets the batched arms, and a gap between them is drift
# (thermal, SD state, arena fill) that would otherwise be charged to the arms
# between them.
#
# -j4 is NOT in the default list, and that is a finding rather than a tuning
# choice: on the compile workload it wedged the board -- two of the four jobs
# reported and the other two never did, twice in a row, with /tmp at 8.7 KiB so
# not an arena exhaustion. It also measured 0.80x on the run that did complete,
# so nothing is lost by leaving it out of a routine measurement. Put it back
# with YASOS_SMOKE_PRUN_SCALING_ARMS=1,2,4,1 when investigating that hang.
ARMS = tuple(
    int(value)
    for value in os.environ.get("YASOS_SMOKE_PRUN_SCALING_ARMS", "1,2,1").split(",")
    if value.strip()
)

# Idle timeout, not a deadline. prun prints a line per job as it finishes, so a
# live batch keeps feeding the reader; this only elapses if the device stops
# talking entirely.
BATCH_TIMEOUT = float(os.environ.get("YASOS_SMOKE_PRUN_SCALING_TIMEOUT", "120"))

# How many compiles per arm. The binding constraint is not RAM for the processes
# but the /tmp arena for their *outputs*: all of them exist at once, because prun
# runs a whole batch before anything can be removed, and the arena is 32 KiB
# (`temp_ram`, hal/source/raspberry/rp2350/linker_script.ld) with 8 KiB of that
# reserved for metadata. The first cut asked for six objects of a 100-function
# source, ran the arena out, and the remaining compiles could not open their
# source. The report prints /tmp usage either side of each workload's cleanup so
# this stays visible.
COMPILE_JOBS = int(os.environ.get("YASOS_SMOKE_PRUN_SCALING_COMPILE_JOBS", "4"))

# How many trivial spawns per arm. Enough that a per-job cost of a few
# milliseconds is clear of the noise, and no more, because prun keeps one log
# file per job and the /tmp arena holds fewer of those than it looks: every
# allocation rounds up to a 256-byte page and a file needs about seven of them
# (body, node, name, two refcounters, the interface object, the entry), so a
# 14-byte log costs ~1.8 KiB. 24 of them ran the arena out mid-batch, which
# measures the exhaustion rather than the spawn.
SPAWN_JOBS = int(os.environ.get("YASOS_SMOKE_PRUN_SCALING_SPAWN_JOBS", "10"))

# Command lengths for the round-trip anatomy, in characters. 3 is the floor --
# the round trip with essentially nothing to echo -- and 232 is what the suite's
# compile command actually measures (`tcc <source> -O0 -o <out>; compile_status=
# $?; if ...; fi; echo __COMPILE_STATUS__:$compile_status`). The difference over
# the character difference is the per-character cost of the echo.
ROUND_TRIP_LENGTHS = tuple(
    int(value)
    for value in os.environ.get(
        "YASOS_SMOKE_PRUN_SCALING_LENGTHS", "3,232"
    ).split(",")
    if value.strip()
)

# Repeats per length. The window is a couple of milliseconds, so this needs
# enough samples to be clear of the host's own scheduling jitter.
ROUND_TRIP_REPEATS = int(
    os.environ.get("YASOS_SMOKE_PRUN_SCALING_ROUND_TRIP_REPEATS", "30")
)

# The source every compile job compiles. Written a line at a time (the device
# shell has no here-documents), so it earns its size with macros rather than
# with lines: each T() expands to 10 functions, and the four of them put the
# compile in the same range as the corpus median (223 ms) rather than measuring
# a spawn with a `main` attached.
SOURCE_LINES = (
    "#include <stdio.h>",
    "#define F(n) static int f##n(int x){int a=x;int i;"
    "for(i=0;i<n%17+3;i++){a=a*3+i;a^=a>>2;}return a;}",
    "#define T(p) F(p##0) F(p##1) F(p##2) F(p##3) F(p##4)"
    " F(p##5) F(p##6) F(p##7) F(p##8) F(p##9)",
    "T(10) T(11) T(12) T(13)",
    "#define C(n) s+=f##n(s);",
    "#define CT(p) C(p##0) C(p##1) C(p##2) C(p##3) C(p##4)"
    " C(p##5) C(p##6) C(p##7) C(p##8) C(p##9)",
    "int main(void){int s=1;CT(10) CT(11) CT(12) CT(13)"
    "printf(\"%d\\n\",s);return 0;}",
)

# A quarter-size source: T() once rather than four times, so 10 functions
# instead of 40. Same compiler, same code path, same job count -- the *only*
# thing that changes against SOURCE_LINES is how much memory the compile needs.
#
# That is what makes it a discriminator rather than another data point. If the
# -j2 penalty is contention for a fixed resource (a kernel lock, the console,
# prun itself) it costs the same here as on the big source; if it is the memory
# path, it shrinks with the footprint. See the `compute` workload below for the
# other half of the same question.
SMALL_SOURCE_LINES = (
    "#include <stdio.h>",
    "#define F(n) static int f##n(int x){int a=x;int i;"
    "for(i=0;i<n%17+3;i++){a=a*3+i;a^=a>>2;}return a;}",
    "#define T(p) F(p##0) F(p##1) F(p##2) F(p##3) F(p##4)"
    " F(p##5) F(p##6) F(p##7) F(p##8) F(p##9)",
    "T(10)",
    "#define C(n) s+=f##n(s);",
    "#define CT(p) C(p##0) C(p##1) C(p##2) C(p##3) C(p##4)"
    " C(p##5) C(p##6) C(p##7) C(p##8) C(p##9)",
    "int main(void){int s=1;CT(10)"
    "printf(\"%d\\n\",s);return 0;}",
)

# The control arm, and the most important one here: pure ALU work in a tight
# loop, with no allocation, no file I/O and one printf at the very end.
#
# Every other workload confounds "can two cores run at once on this silicon"
# with "what happens when two processes want memory". This one cannot: its
# working set is a handful of registers and its code is small enough to sit in
# the XIP cache. So if -j2 does NOT reach ~2x here, no memory-aware scheduling
# can rescue concurrency, because the cores are not adding throughput in the
# first place -- and if it DOES, the compile penalty is about memory and the
# footprint is the lever.
#
# The iteration count is argv rather than a macro so it can be retuned without
# recompiling on the device; prun splits batch lines on whitespace and execs
# them directly, so an argument costs nothing.
COMPUTE_SOURCE_LINES = (
    "#include <stdio.h>",
    "#include <stdlib.h>",
    "int main(int argc,char**argv){",
    "long n=(argc>1)?atol(argv[1]):20000000L;",
    "long i;int a=1;",
    "for(i=0;i<n;i++){a=a*3+(int)i;a^=a>>2;}",
    "printf(\"%d\\n\",a);return 0;}",
)

# The overlap candidate: what the suite does *around* a compile, as a program.
#
# The pipelining idea this measures is "core X compiles while core Y runs the
# previous test and removes its artifacts" -- no two compiles ever in flight, so
# the XIP thrash that kills -j2 never happens. The question it has to answer is
# whether the overlapped work is genuinely free, and the `compute` arm does not
# answer it: that job is nearly syscall-free, and **the kernel is in XIP flash
# too**. Every open, write and unlink executes kernel code through the same
# 16 KiB cache tcc is competing for, so a RAM-resident binary can still disturb
# a compile by way of its syscalls.
#
# So this one is deliberately syscall-heavy and compute-light: small writes to a
# file in /tmp, then remove it. That is the shape of a test's execute-plus-clean
# step, which is the 35 s of a 677 s run the pipeline would be trying to hide.
IO_SOURCE_LINES = (
    "#include <stdio.h>",
    "#include <stdlib.h>",
    "#include <string.h>",
    "int main(int argc,char**argv){",
    "int n=(argc>1)?atoi(argv[1]):64;",
    "char buf[64];int i;FILE*f;",
    "memset(buf,65,sizeof(buf));",
    "f=fopen(\"/tmp/pscal/io.dat\",\"w\");",
    "if(!f)return 1;",
    "for(i=0;i<n;i++){if(fwrite(buf,1,sizeof(buf),f)!=sizeof(buf)){fclose(f);return 2;}}",
    "fclose(f);remove(\"/tmp/pscal/io.dat\");return 0;}",
)

# Writes per io job, at 64 bytes each. Kept small because the file exists inside
# the 24 KiB usable /tmp arena while it is being written, and an io job that
# runs the arena out measures the exhaustion instead of the overlap.
IO_WRITES = int(os.environ.get("YASOS_SMOKE_PRUN_SCALING_IO_WRITES", "64"))

# Iterations per compute job. Picked to land the job in the same few-hundred-ms
# range as a compile job, so the arms are read side by side rather than across
# two different noise floors. Retune from the reported per-job time.
COMPUTE_ITERATIONS = int(
    os.environ.get("YASOS_SMOKE_PRUN_SCALING_COMPUTE_ITERATIONS", "8000000")
)

# How many compute jobs per arm. Matches COMPILE_JOBS so the two workloads'
# per-job numbers are directly comparable.
COMPUTE_JOBS = int(os.environ.get("YASOS_SMOKE_PRUN_SCALING_COMPUTE_JOBS", "4"))

_PRUN_RESULT_RE = re.compile(r"^PRUN (\d+) (-?\d+)$")
_PRUN_DONE_RE = re.compile(r"^PRUN_DONE (\d+)$")


class Workload:
    """A set of jobs, and everything needed to run them either way.

    `commands` are plain argv lines: prun execs each directly (it cannot borrow
    the shell -- spawning /bin/sh from a vforked child faults this kernel), so
    no redirection, quoting or variables may appear in them. The lockstep arm
    runs the very same strings as shell commands, which is what makes the two
    arms comparable.
    """

    def __init__(self, name, commands, outputs, retire=(), prepare=None):
        self.name = name
        self.commands = commands
        self.outputs = outputs
        # Run just before this workload's arms rather than during setup, for
        # anything that would otherwise occupy the arena while *earlier*
        # workloads run. The compute binary is ~8 KiB of a 24 KiB budget, and it
        # is of no use to the compile arms that precede it.
        self.prepare = prepare
        # Setup files this workload was the last user of. Dropped as soon as its
        # arms are done, because the /tmp arena is 24 KiB of usable space and
        # anything still sitting in it is space a later workload's jobs need.
        self.retire = tuple(retire)
        self.batch_path = f"{WORK_DIR}/{name}.txt"

    @property
    def jobs(self):
        return len(self.commands)


def _run(session, command, timeout=None):
    session.write_command(command)
    return session.wait_for_prompt_except_logs(timeout=timeout)


def _write_file(session, path, lines):
    """Write `lines` to `path` on the device, one echo per line.

    Single-quoted so the shell hands the text through untouched -- the C source
    below keeps clear of single quotes for that reason. Setup cost only: this
    runs once and every arm reuses what it wrote.
    """
    for index, line in enumerate(lines):
        redirect = ">" if index == 0 else ">>"
        _run(session, f"echo '{line}' {redirect} {path}")


def _clean(session, workload):
    """Remove everything an arm produced, so every arm starts from the same /tmp.

    Split across commands because the argument list would otherwise outgrow a
    console line on the spawn workload, and a truncated command is a desync
    rather than an error.
    """
    paths = list(workload.outputs) + [
        f"{WORK_DIR}/{job}.log" for job in range(workload.jobs)
    ]
    for start in range(0, len(paths), 8):
        _run(session, "rm -f " + " ".join(paths[start:start + 8]))


def _time_lockstep(session, workload):
    """The jobs the way the suite issues them: one console command each.

    The status marker mirrors compile_testcase's, so the arm pays for the same
    shape of command the harness actually sends rather than a bare invocation.
    """
    _clean(session, workload)
    started = time.monotonic()
    statuses = {}
    for job, command in enumerate(workload.commands):
        session.write_command(f"{command}; echo __C__:$?")
        for line in session.wait_for_prompt_except_logs(timeout=BATCH_TIMEOUT):
            if line.startswith("__C__:"):
                statuses[job] = int(line.split(":", 1)[1])
    elapsed = time.monotonic() - started
    return elapsed, statuses


def _time_batch(session, workload, parallel):
    """The same jobs through prun at -j `parallel`, from one round trip.

    The window is the whole command, prompt to prompt, which is exactly what the
    harness would pay per batch -- the prun spawn included.
    """
    _clean(session, workload)
    session.write_command(
        f"prun -j {parallel} -o {WORK_DIR} {workload.batch_path}"
    )
    started = time.monotonic()
    lines = session.wait_for_prompt_except_logs(timeout=BATCH_TIMEOUT)
    elapsed = time.monotonic() - started

    statuses = {}
    completed = None
    for line in lines:
        result = _PRUN_RESULT_RE.match(line)
        if result is not None:
            statuses[int(result.group(1))] = int(result.group(2))
            continue
        done = _PRUN_DONE_RE.match(line)
        if done is not None:
            completed = int(done.group(1))

    if completed != workload.jobs:
        pytest.skip(
            f"prun -j {parallel} reported {completed} of {workload.jobs} jobs: {lines}"
        )
    return elapsed, statuses


def _time_round_trip(session, length, repeats=ROUND_TRIP_REPEATS):
    """Time an inert command of `length` characters, echo wait and prompt wait apart.

    A shell variable assignment is the payload because it is the only thing that
    reliably costs nothing on both sides: it produces no output, spawns no
    process, and toysh needs no comment or quoting support for it. So what is
    left in the window is the round trip itself.

    The split matters more than the total. `write_command` returns when the
    device has echoed the command back, and `compile_testcase` starts its
    compile timer *after* that call -- so the echo wait is charged to no bucket
    in tcc_timing_report.json, and a run's wall time exceeds the sum of its
    parts by however much this costs. The suite sends 316 characters of command
    per test (cd /, cd /tmp, the 232-character compile line, the run line and
    the rm), so a per-character cost here multiplies by 316 x 4453.
    """
    command = "x=" + "a" * max(0, length - 2)
    echo_seconds = 0.0
    prompt_seconds = 0.0
    for _ in range(repeats):
        started = time.monotonic()
        session.write_command(command)
        echoed = time.monotonic()
        session.wait_for_prompt_except_logs()
        prompted = time.monotonic()
        echo_seconds += echoed - started
        prompt_seconds += prompted - echoed
    return echo_seconds / repeats, prompt_seconds / repeats


def _tmp_used(session):
    """MemTmpUsed from /proc/meminfo, as the device prints it.

    Reported beside the arms because the /tmp arena is what bounds the job
    counts here, and an arm that silently ran out of it produces failed jobs
    whose timings look like a speedup (a compile that dies early is fast).
    """
    for line in _run(session, "cat /proc/meminfo"):
        if line.startswith("MemTmpUsed:"):
            return line.split(":", 1)[1].strip()
    return "?"


def _core_summary(session):
    """A one-line description of what the kernel is scheduling on.

    The -j arms are about work spread over cores, so a report that does not say
    how many cores were schedulable is unreadable a week later.
    """
    values = {}
    for line in _run(session, "cat /proc/cpus"):
        parts = line.split()
        if len(parts) == 2:
            values[parts[0]] = parts[1]
    return (
        f"cpus={values.get('cpus', '?')} online={values.get('online', '?')}"
        f" smp={values.get('smp', '?')}"
    )


def _core_counters(session):
    """Per-core tick and switch counters from /proc/cpus, as integers.

    Bracketed around each arm, these separate the two ways an arm can fail to go
    faster, which the wall clock alone cannot tell apart:

      * the work never spread -- core 1's counters barely move, so -j only
        interleaved processes on core 0 and the second core sat in its idle
        process. The cost is then prun's spawn and nothing else.
      * the work spread and contended -- both cores took real ticks and the
        wall time still went up. That is a resource being fought over, and the
        footprint arms say which resource.

    Missing keys come back absent rather than zero: a kernel built without SMP
    prints no cpu1_* lines at all, and reporting a delta of 0 for a counter that
    does not exist would read as "core 1 did nothing".
    """
    values = {}
    for line in _run(session, "cat /proc/cpus"):
        parts = line.split()
        if len(parts) == 2 and (
            parts[0].endswith("_ticks") or parts[0].endswith("_switches")
        ):
            try:
                values[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return values


def _counter_delta(before, after):
    """What each core did across one arm. Keys present in both only."""
    return {
        key: after[key] - before[key]
        for key in sorted(after)
        if key in before and after[key] >= before[key]
    }


def _xip_counters(session):
    """Hit/access totals for the XIP cache from /proc/xip.

    This is the instrument that separates "two cores cannot help here" from
    "two cores are fighting over the one thing this workload does constantly".
    Every instruction outside SRAM and every PSRAM data access crosses this
    cache, and there is exactly one of it for both cores -- so if concurrency
    costs what a thrashed cache costs, the hit rate is where it shows.

    Read as totals since boot and differenced per arm. `xip_saturated` is
    carried through because a saturated sample has dropped an unknown number of
    accesses, and a hit rate computed across one is not a measurement.
    """
    values = {}
    for line in _run(session, "cat /proc/xip"):
        parts = line.split()
        if len(parts) == 2 and parts[0].startswith("xip_"):
            try:
                values[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return values


def _format_xip(delta):
    """Hit rate and access count across one arm, or "" if /proc/xip is absent."""
    hit = delta.get("xip_hit")
    acc = delta.get("xip_acc")
    if hit is None or acc is None:
        return ""
    if acc == 0:
        return "xip acc=0"
    rate = f"{100.0 * hit / acc:.1f}%"
    note = " SATURATED" if delta.get("xip_saturated") else ""
    return f"xip hit={rate} acc={acc / 1e6:.1f}M{note}"


def _measure(session, workload):
    """Run every arm of one workload.

    Returns [(arm name, seconds, failed jobs, per-core counter deltas)]. The
    counters are read outside the timed window on purpose -- two extra console
    round trips inside it would be charged to the arm.
    """
    measurements = []

    def _bracket(name, run_arm):
        cores_before = _core_counters(session)
        xip_before = _xip_counters(session)
        elapsed, statuses = run_arm()
        cores = _counter_delta(cores_before, _core_counters(session))
        xip = _counter_delta(xip_before, _xip_counters(session))
        measurements.append((name, elapsed, statuses, cores, xip))

    _bracket("lockstep", lambda: _time_lockstep(session, workload))
    for parallel in ARMS:
        _bracket(
            f"prun -j{parallel}",
            lambda p=parallel: _time_batch(session, workload, p),
        )

    return [
        (
            arm,
            elapsed,
            sorted(job for job, code in statuses.items() if code != 0),
            cores,
            xip,
        )
        for arm, elapsed, statuses, cores, xip in measurements
    ]


def test_batching_and_concurrency(request):
    session = request.node.stash[session_key]

    # ls prints the path when it exists and an error naming it when it does not,
    # so the presence of the name proves nothing -- the error text is the tell.
    listing = " ".join(_run(session, "ls /bin/prun"))
    if "/bin/prun" not in listing or "No such" in listing or "not found" in listing:
        pytest.skip(f"prun is not in this rootfs: {listing}")

    cores = _core_summary(session)

    compile_workload = Workload(
        "compile",
        [
            f"/bin/tcc -O0 -c {SOURCE} -o {WORK_DIR}/{job}.o"
            for job in range(COMPILE_JOBS)
        ],
        [f"{WORK_DIR}/{job}.o" for job in range(COMPILE_JOBS)],
    )
    compile_small_workload = Workload(
        "compile-small",
        [
            f"/bin/tcc -O0 -c {SMALL_SOURCE} -o {WORK_DIR}/{job}.o"
            for job in range(COMPILE_JOBS)
        ],
        [f"{WORK_DIR}/{job}.o" for job in range(COMPILE_JOBS)],
        retire=(SMALL_SOURCE,),
    )
    def _build_compute(session):
        """Compile the compute job, with the same tcc the compile arms measure.

        Checked rather than assumed: a compute arm whose binary is missing would
        run four instant failures, and four jobs that die on exec look exactly
        like a very fast arm.
        """
        _run(session, f"rm -f {COMPUTE_SOURCE} {COMPUTE_BINARY}")
        _write_file(session, COMPUTE_SOURCE, COMPUTE_SOURCE_LINES)
        build = " ".join(
            _run(session, f"/bin/tcc -O0 {COMPUTE_SOURCE} -o {COMPUTE_BINARY}")
        )
        _run(session, f"rm -f {COMPUTE_SOURCE}")
        listing = " ".join(_run(session, f"ls {COMPUTE_BINARY}"))
        if COMPUTE_BINARY not in listing or "No such" in listing:
            pytest.skip(f"could not build the compute workload: {build} / {listing}")

    compute_workload = Workload(
        "compute",
        [
            f"{COMPUTE_BINARY} {COMPUTE_ITERATIONS}"
            for _ in range(COMPUTE_JOBS)
        ],
        [],
        retire=(COMPUTE_BINARY,),
        prepare=_build_compute,
    )
    def _build_io(session):
        """Compile the io job. Same check as the compute job, same reason."""
        _run(session, f"rm -f {IO_SOURCE} {IO_BINARY}")
        _write_file(session, IO_SOURCE, IO_SOURCE_LINES)
        build = " ".join(_run(session, f"/bin/tcc -O0 {IO_SOURCE} -o {IO_BINARY}"))
        _run(session, f"rm -f {IO_SOURCE}")
        listing = " ".join(_run(session, f"ls {IO_BINARY}"))
        if IO_BINARY not in listing or "No such" in listing:
            pytest.skip(f"could not build the io workload: {build} / {listing}")

    # The pipeline proposal, as two jobs that are never both compiles: one tcc
    # run overlapped with the work the suite does around a compile. -j1 runs
    # them back to back and -j2 overlaps them, so the -j2/-j1 ratio is the whole
    # answer -- if overlapping is free, -j2 costs what the compile alone costs
    # and the other job has been hidden.
    #
    # Two variants because the disturbance they can cause is different in kind:
    # `mixed` overlaps a compile with near-pure computation, `mixed-io` overlaps
    # it with the syscall traffic of an execute-and-clean step, which reaches
    # kernel code that is itself in XIP.
    mixed_workload = Workload(
        "mixed",
        [
            f"/bin/tcc -O0 -c {SOURCE} -o {WORK_DIR}/0.o",
            f"{COMPUTE_BINARY} {COMPUTE_ITERATIONS}",
        ],
        [f"{WORK_DIR}/0.o"],
        retire=(COMPUTE_BINARY,),
        prepare=_build_compute,
    )
    mixed_io_workload = Workload(
        "mixed-io",
        [
            f"/bin/tcc -O0 -c {SOURCE} -o {WORK_DIR}/0.o",
            f"{IO_BINARY} {IO_WRITES}",
            f"/bin/rm -f {WORK_DIR}/stale.o",
        ],
        [f"{WORK_DIR}/0.o"],
        retire=(IO_BINARY, SOURCE),
        prepare=_build_io,
    )
    spawn_workload = Workload(
        "spawn",
        ["/bin/hello" for _ in range(SPAWN_JOBS)],
        [],
    )

    # Each section prints as soon as it has been measured rather than from one
    # report at the end, because on this target a later section can wedge the
    # board -- /tmp filling is unrecoverable in place, and `prun -j4` hung it
    # outright. A report built at the end loses every number taken before the
    # wedge, which is how two runs of this were spent re-measuring what had
    # already been measured.
    results = {}
    with session.timeout(BATCH_TIMEOUT):
        _run(session, f"mkdir -p {WORK_DIR}")
        _run(session, f"rm -f {SOURCE}")
        _write_file(session, SOURCE, SOURCE_LINES)
        _run(session, f"rm -f {SMALL_SOURCE}")
        _write_file(session, SMALL_SOURCE, SMALL_SOURCE_LINES)

        workloads = (
            compile_workload,
            compile_small_workload,
            compute_workload,
            mixed_workload,
            mixed_io_workload,
            spawn_workload,
        )

        print(f"\n  {cores}")
        print(f"  /tmp used: {_tmp_used(session)} before the arms")

        round_trips = [
            (length,) + _time_round_trip(session, length)
            for length in ROUND_TRIP_LENGTHS
        ]
        _report_round_trips(round_trips)

        for workload in workloads:
            # Batch files are written per workload and removed with it, rather
            # than all four up front. The arena is 32 KiB with 8 KiB reserved,
            # and a file costs about 1.8 KiB of it whatever its body: every
            # allocation rounds up to a 256-byte page and a file needs about
            # seven (body, node, name, two refcounters, the interface object,
            # the entry). Four batch files held for the whole test is ~7 KiB
            # standing, which is what made a compile-small job fail with the
            # arena at 18944 B before its arms had even started -- a failure
            # that reads as a slow arm rather than as an out-of-space.
            if workload.prepare is not None:
                workload.prepare(session)
            _write_file(session, workload.batch_path, workload.commands)
            before = _tmp_used(session)
            measurements = _measure(session, workload)
            results[workload.name] = measurements
            _report_workload(workload, measurements)
            # Bracketed around the workload's own cleanup, which is the only way
            # this reading means anything. Read *before* cleaning -- as an
            # earlier version did -- it counts the outputs still legitimately
            # sitting there and looks exactly like a leak: 8704 -> 25856 B, all
            # of it four object files and their logs. Read after, a difference
            # is a real one.
            _clean(session, workload)
            _run(session, f"rm -f {workload.batch_path}")
            for path in workload.retire:
                _run(session, f"rm -f {path}")
            print(f"    /tmp used: {before} before, {_tmp_used(session)} after cleanup")
            if any(failed for _, _, failed, _, _ in measurements):
                # A job that failed here has most likely exhausted the /tmp
                # arena. Removal is allocation-free now, so `rm` should get the
                # space back where it used to answer ENOMEM -- but a target that
                # got there is not one to keep measuring on, and every later arm
                # would measure the recovery rather than the thing it is named
                # after. Hand the next test a rebooted target and stop.
                type(session).target_needs_reset = True
                print(f"    stopping after {workload.name}: see FAILED jobs above")
                return

        _run(session, f"rm -f {SOURCE} {SMALL_SOURCE} {COMPUTE_SOURCE}"
             f" {COMPUTE_BINARY} {IO_SOURCE} {IO_BINARY}")
        for workload in workloads:
            _run(session, f"rm -f {workload.batch_path}")


def _report_round_trips(round_trips):
    print("\n  round trip anatomy (inert command, nothing spawned)")
    print(f"    {'chars':>6}  {'echo wait':>10}  {'prompt wait':>12}  {'total':>8}")
    for length, echo_seconds, prompt_seconds in round_trips:
        print(
            f"    {length:>6}  {echo_seconds * 1000:>9.2f}ms"
            f"  {prompt_seconds * 1000:>11.2f}ms"
            f"  {(echo_seconds + prompt_seconds) * 1000:>7.2f}ms"
        )
    if len(round_trips) >= 2:
        short, long = round_trips[0], round_trips[-1]
        span = long[0] - short[0]
        if span > 0:
            per_char_ms = (long[1] - short[1]) / span * 1000.0
            # 316 characters per test is what a gcc-torture case sends today,
            # and 4453 is what a default remote run collects.
            print(
                f"    per character of command echoed: {per_char_ms:.4f} ms"
                f"  ->  {per_char_ms * 316:.1f} ms/test"
                f"  ->  {per_char_ms * 316 * 4453 / 1000.0:.0f} s over a 4453-test run"
            )
def _format_core_deltas(cores):
    """Per-core counter deltas across the arm, as a compact string.

    **`ticks` is elapsed time, not utilisation, and it is reported here only
    because reading it as utilisation is the mistake worth pre-empting.** Every
    online core takes its own SysTick whatever it is running -- idle included --
    so the two cores print near-identical tick deltas in every arm, and that
    figure tracks the arm's wall time (2182 ticks for a 2.14 s arm) rather than
    the work done on either core. Switches are shown beside it for the same
    reason: a core parked in its idle process barely switches, but so does a
    core running one long compile, so neither number settles whether the work
    spread.
    The `compute` workload is what settles it -- see its comment.
    """
    if not cores:
        return ""
    return " ".join(f"{key}={value}" for key, value in sorted(cores.items()))


def _report_workload(workload, measurements):
    # Everything is reported against the lockstep arm, because that is what the
    # suite does today and therefore what any of this has to beat.
    baseline = next(
        (elapsed for arm, elapsed, _, _, _ in measurements if arm == "lockstep"), None
    )
    print(f"\n  {workload.name}: {workload.jobs} x `{workload.commands[0]}`")
    print(
        f"    {'arm':>12}  {'wall':>8}  {'per job':>9}  {'vs lockstep':>11}"
        f"  XIP cache"
    )
    for arm, elapsed, failed, cores, xip in measurements:
        speedup = f"{baseline / elapsed:.2f}x" if baseline else "-"
        note = f"   FAILED jobs {failed}" if failed else ""
        print(
            f"    {arm:>12}  {elapsed:>7.2f}s  {elapsed / workload.jobs * 1000:>8.1f}ms"
            f"  {speedup:>11}  {_format_xip(xip)}{note}"
        )
        if os.environ.get("YASOS_SMOKE_PRUN_SCALING_CORE_COUNTERS"):
            print(f"    {'':>12}  {_format_core_deltas(cores)}")

    # The number this workload exists for: the per-job difference between
    # running each job as its own console command and running the same jobs
    # from one. -j1 rather than -j2 because it changes nothing else.
    batched = next(
        (elapsed for arm, elapsed, _, _, _ in measurements if arm == "prun -j1"), None
    )
    if baseline is not None and batched is not None:
        per_job_ms = (baseline - batched) / workload.jobs * 1000.0
        print(
            f"    round trip removed by batching: {per_job_ms:+.2f} ms/job"
            " (prun's own spawn is charged to the batch)"
        )

    ones = [elapsed for arm, elapsed, _, _, _ in measurements if arm == "prun -j1"]
    if len(ones) >= 2 and ones[0]:
        drift = (ones[-1] - ones[0]) / ones[0] * 100.0
        print(f"    prun -j1 drift across the workload: {drift:+.1f}%")
