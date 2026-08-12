"""
 Copyright (c) 2025 Mateusz Stadnik

 This program is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
 """

# SMP bring-up. These run on every board the suite targets, single-core ones
# included: /proc/cpus is asserted to be consistent with the build, so the
# mps2-an505 leg checks that a single-core kernel says so rather than skipping.
# "smp 0" on the mps3-an524 leg is the regression worth catching.

import time

from .conftest import session_key


def read_cpus(session):
    """Parse /proc/cpus into a dict of str -> int, with 'selftest' left a str."""
    session.write_command("cat /proc/cpus")
    lines = session.wait_for_prompt_except_logs()

    values = {}
    for line in lines:
        parts = line.split()
        if len(parts) != 2:
            continue
        key, raw = parts
        values[key] = raw if key == "selftest" else int(raw)

    assert "cpus" in values, f"/proc/cpus did not report a core count: {lines}"
    return values


def test_every_core_is_online(request):
    session = request.node.stash[session_key]
    cpus = read_cpus(session)

    assert cpus["cpus"] >= 1
    # An SMP build must have brought up more than one core; a non-SMP build must
    # not be pretending to have done so.
    if cpus["smp"]:
        assert cpus["cpus"] > 1, "CONFIG_PROCESS_SMP is on but the build has one core"
    else:
        assert cpus["cpus"] == 1

    # Every core the kernel counts must have reached kernel code. A core that is
    # released and never arrives is the bring-up failure this catches, and it is
    # silent everywhere else -- the kernel keeps booting on the cores it has.
    assert cpus["online"] == cpus["cpus"], f"only {cpus['online']} of {cpus['cpus']} cores came up"
    for core in range(cpus["cpus"]):
        assert cpus[f"cpu{core}_online"] == 1, f"core {core} is not online"


def test_cross_core_exclusives_hold(request):
    """The load-bearing one: every lock in the kernel rests on this.

    A second core whose exclusive monitor does not reach the other core fails
    nothing visibly -- the acquire succeeds locally and both cores enter the
    critical section. The kernel runs a bounded two-core mutual-exclusion test
    before the scheduler starts precisely so that failure has somewhere to show
    up, and this is where it is read.
    """
    session = request.node.stash[session_key]
    cpus = read_cpus(session)

    if not cpus["smp"]:
        assert cpus["selftest"] == "skipped", "a single-core build cannot have run a cross-core test"
        return

    assert cpus["selftest"] == "pass", (
        f"cross-core mutual exclusion failed: atomic "
        f"{cpus['selftest_atomic_counted']}/{cpus['selftest_atomic_expected']}, "
        f"guarded {cpus['selftest_guarded']}/{cpus['selftest_sections']} sections, "
        f"{cpus['selftest_overlaps']} overlaps"
    )

    # Asserted separately from the verdict, so reporting one without the other
    # cannot pass quietly. Stage 1 is the exclusive monitor itself: a lost
    # increment means one core's ldrex/strex did not see the other's.
    assert cpus["selftest_atomic_expected"] > 0
    assert cpus["selftest_atomic_counted"] == cpus["selftest_atomic_expected"]

    # Stage 2 is the SpinLock built on it. Sections are counted rather than
    # predicted, so the check is that the guarded counter agrees with them --
    # and that some happened at all, since zero == zero would test nothing.
    assert cpus["selftest_sections"] > 0
    assert cpus["selftest_guarded"] == cpus["selftest_sections"]
    assert cpus["selftest_overlaps"] == 0


def test_every_core_enters_the_scheduler(request):
    """Phase 7. Being online is not the same as scheduling.

    Through phase 6 a secondary core booted, proved the locks worked and parked
    in WFI -- online, ticking, and running nothing. `cpuN_scheduling` is the flag
    the core sets when it takes its own first context switch
    (`smp.mark_core_entered_scheduler`), so this is what separates "core 1 is up"
    from "core 1 is in the scheduler".
    """
    session = request.node.stash[session_key]
    cpus = read_cpus(session)

    for core in range(cpus["cpus"]):
        assert cpus[f"cpu{core}_scheduling"] == 1, f"core {core} never entered the scheduler"
        # It has a process, and on an idle core that process is its own idle
        # process rather than a stale or garbage slot.
        assert cpus[f"cpu{core}_pid"] > 0, f"core {core} reports no current process"
        assert cpus[f"cpu{core}_idle_pid"] > 0, f"core {core} has no idle process"


def test_secondary_core_actually_runs_processes(request):
    """The one that would have caught a silent no-op.

    Everything else in this file passes just as happily when core 1 boots and
    then does nothing -- which is exactly what it did before phase 7, and what a
    regression here would look like. Switch counts are cumulative and per-core,
    so running a workload with more runnable processes than cores and watching
    core 1's counter move is the direct evidence that the second core took work.

    Single-core builds have nothing to assert here, so they skip rather than
    pretend: `cpus > 1` is checked by `test_every_core_is_online` against the
    build's own `smp` flag.
    """
    session = request.node.stash[session_key]
    before = read_cpus(session)
    if before["cpus"] < 2:
        return

    # The workload is the difficulty here. Three things have to hold at once:
    # two processes runnable at the same instant (a pipeline is not enough --
    # `cat | cat` alternates by construction); no backgrounding, since `cmd &`
    # returns the prompt early and desynchronises every later read on this shared
    # console; and a run longer than the scheduler's 100 ms preempt period, which
    # on a board with no doorbell is how an idle core discovers work.
    #
    # `prun -j2` satisfies all three. Absolute paths because it execs each line
    # directly rather than borrowing the shell.
    session.write_command("mkdir -p /tmp/smpj")
    session.wait_for_prompt_except_logs(timeout=30)
    # Four independent CPU-bound jobs, each hashing the 1.6 MB `tcc`. The size is
    # deliberate: with a 100 ms discovery period and no doorbell, a batch that
    # finishes inside one period proves nothing.
    session.write_command(
        "echo '/usr/bin/sha256sum /usr/bin/tcc' > /tmp/smpj/jobs; "
        "echo '/usr/bin/sha256sum /usr/bin/tcc' >> /tmp/smpj/jobs; "
        "echo '/usr/bin/sha256sum /usr/bin/tcc' >> /tmp/smpj/jobs; "
        "echo '/usr/bin/sha256sum /usr/bin/tcc' >> /tmp/smpj/jobs"
    )
    session.wait_for_prompt_except_logs(timeout=30)

    # Run the batch more than once if it takes that, and pass as soon as core 1
    # has taken anything. Without a doorbell an idle core looks for work once per
    # 100 ms preempt period, so whether it catches a given batch is a sampling
    # question -- one sample hits ~2 rounds in 10. Several batches make a miss
    # unlikely while still failing outright if core 1 never schedules at all.
    after = before
    for _ in range(4):
        session.write_command("prun -j 2 -o /tmp/smpj /tmp/smpj/jobs")
        session.wait_for_prompt_except_logs(timeout=120)
        after = read_cpus(session)
        if after["cpu1_switches"] > before["cpu1_switches"]:
            break

    assert after["cpu1_switches"] > before["cpu1_switches"], (
        f"core 1 performed no context switches across four concurrent workloads "
        f"({before['cpu1_switches']} -> {after['cpu1_switches']}): it is online "
        f"but the scheduler never put anything on it"
    )


def test_cores_are_still_running(request):
    """Liveness, which the online flag cannot answer.

    A core that came up and then wedged -- faulted, or spun on a lock nobody
    releases -- still reads back online forever. Its tick count does not move,
    so two reads a moment apart are what separate "started once" from "running
    now".
    """
    session = request.node.stash[session_key]

    first = read_cpus(session)
    time.sleep(1.0)
    second = read_cpus(session)

    for core in range(first["cpus"]):
        before = first[f"cpu{core}_ticks"]
        after = second[f"cpu{core}_ticks"]
        assert after > before, (
            f"core {core} stopped ticking ({before} -> {after}): it is online but not running"
        )
