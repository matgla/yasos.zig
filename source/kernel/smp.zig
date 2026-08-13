// Copyright (c) 2026 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// Secondary-core bring-up. `run_selftest` runs before the scheduler starts,
// because a core that forgets `ACTLR.EXTEXCLALL` silently degrades every
// spinlock to a local-monitor lock, with no fault and no log line.

const std = @import("std");

const arch = @import("arch");
const config = @import("config");
const hal = @import("hal");

const sync = @import("sync/sync.zig");
const process_manager = @import("process_manager.zig");
const log = @import("kernel_log.zig").log;

/// Whether this build brings up more than one core -- `CONFIG_PROCESS_SMP`.
pub const enabled: bool = sync.percpu.smp;

/// Cores this build schedules on. One unless SMP is on; see `sync/percpu.zig`.
pub const core_count: usize = sync.percpu.core_count;

/// Cores that have performed their first task switch, as a bitmask: "may PendSV
/// switch on this core yet?". Per-core rather than global because a secondary
/// core enables its own SysTick in `arch.process.init_secondary()` while still
/// on MSP with no context of its own, and a PendSV there would store the
/// outgoing context through a PSP that has never been set.
var scheduling_mask: sync.Atomic(u32) = .init(0);

/// Record that this core has switched into its first task. Release ordering, so
/// everything set up before the first switch is visible to whoever sees the bit.
pub fn mark_core_entered_scheduler() void {
    _ = scheduling_mask.fetchOr(core_bit(sync.percpu.current_core()), .release);
}

/// Whether the calling core may take a context switch.
pub inline fn current_core_schedules() bool {
    return scheduling_mask.load(.acquire) & core_bit(sync.percpu.current_core()) != 0;
}

pub fn core_schedules(core: usize) bool {
    if (core >= core_count) return false;
    return scheduling_mask.load(.acquire) & core_bit(core) != 0;
}

/// Set once the process manager, the root process and the idle processes exist.
/// A secondary core comes up long before any of that and waits on this.
var scheduler_ready: sync.Atomic(u32) = .init(0);

pub fn mark_scheduler_ready() void {
    scheduler_ready.store(1, .release);
}

pub fn is_scheduler_ready() bool {
    return scheduler_ready.load(.acquire) != 0;
}

/// How long the boot core waits on a handshake before giving up. Wall clock, not
/// an iteration budget: under emulation an iteration's cost is a property of the
/// host, not the guest. `hal.time.get_time_us()` runs this early, off a
/// free-running timer independent of SysTick.
const handshake_timeout_us: u64 = 2_000_000;

/// The same bound for a secondary core, which cannot read the clock: doing so
/// mutates `Time`'s wrap-tracking state, which is core 0's to touch. Both
/// outcomes of an inexact count are safe here.
const secondary_handshake_spins: u32 = 100_000_000;

/// Increments each core adds to the shared atomic in stage 1.
const selftest_atomic_iterations: u32 = 4096;

/// Section *attempts* each core makes in stage 2. Attempts, not acquisitions:
/// a try-lock that loses is skipped rather than retried, so the number of
/// sections actually taken is lower and is counted rather than assumed.
const selftest_iterations: u32 = 1024;

/// Length of the delay held *inside* the critical section, in loop iterations.
/// See the module comment: this is the window a broken lock falls into.
const selftest_hold_spins: u32 = 128;

/// A delay the compiler may not remove. Not `spinLoopHint()`, which is `yield`
/// on ARM and a vCPU exit under QEMU; the point is to stay in the section.
inline fn delay_barrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

pub const Verdict = enum {
    /// No second core to test against -- single core, or bring-up failed.
    skipped,
    pass,
    fail,
};

/// Bitmask of cores that have reached kernel code and marked themselves in. A
/// mask rather than a per-CPU flag because core 0 reads other cores' state.
var online_mask: sync.Atomic(u32) = .init(0);

const CoreTicks = sync.PerCpu(sync.Atomic(u32));

/// SysTick count per core, the liveness evidence `/proc/cpus` exports. Only the
/// owning core writes its slot; the atomic is so a reader on another core gets a
/// whole value rather than a compiler-cached one.
var core_ticks: CoreTicks = CoreTicks.init(sync.Atomic(u32).init(0));

/// Context switches each core has completed. Separate from `core_ticks`, which
/// only says the core takes interrupts: this says it is running the scheduler.
/// Same ownership rule -- only the owning core writes its slot.
var core_switches: CoreTicks = CoreTicks.init(sync.Atomic(u32).init(0));

/// The one genuinely cross-core-contended lock here. `Isolated` so its lock word
/// owns its reservation granule and a neighbouring store cannot clear a
/// contender's reservation, which would show up as unexplained slowness.
var selftest_lock: sync.Isolated(sync.SpinLock) = .{};

/// Guarded by `selftest_lock`. A plain word behind a volatile pointer, not an
/// atomic: an atomic increment would be correct without the lock and test
/// nothing.
var selftest_counter: u32 = 0;

/// Stage 1's shared counter: `fetchAdd` from both cores at once, no lock. If a
/// core's exclusives do not reach the other, an increment vanishes.
var selftest_atomic: sync.Atomic(u32) = .init(0);

/// Sections actually entered in stage 2, summed across cores. A losing try-lock
/// is skipped, so neither side is predictable, but they must agree.
var selftest_sections: sync.Atomic(u32) = .init(0);

/// Written inside the critical section and read back before leaving it: catches
/// overlap, where the counter catches lost updates.
var selftest_marker: sync.Atomic(u32) = .init(0);
var selftest_failures: sync.Atomic(u32) = .init(0);
var selftest_go: sync.Atomic(u32) = .init(0);
var selftest_done: sync.Atomic(u32) = .init(0);
var selftest_participants: u32 = 0;
var selftest_verdict: Verdict = .skipped;
var selftest_duration_us: u64 = 0;

inline fn counter() *volatile u32 {
    return &selftest_counter;
}

inline fn core_bit(core: usize) u32 {
    return @as(u32, 1) << @intCast(core);
}

fn mark_online(core: usize) void {
    // Release: everything this core set up before announcing itself has to be
    // visible to whoever sees the bit.
    _ = online_mask.fetchOr(core_bit(core), .release);
}

/// Wait on the boot core until `predicate` holds, or `handshake_timeout_us`
/// passes. A bare spin: `cpu_relax()` is WFE and nothing here sends an event,
/// and `spinLoopHint` is a vCPU exit under emulation. The deadline is what
/// bounds it.
fn wait_on_boot_core(word: *sync.Atomic(u32), comptime satisfied: fn (u32, u32) bool, argument: u32) bool {
    const deadline = hal.time.get_time_us() + handshake_timeout_us;
    while (true) {
        if (satisfied(word.load(.acquire), argument)) return true;
        if (hal.time.get_time_us() >= deadline) return false;
    }
}

fn all_bits_set(value: u32, mask: u32) bool {
    return value & mask == mask;
}

fn at_least(value: u32, target: u32) bool {
    return value >= target;
}

/// The secondary core's counterpart, bounded by iterations rather than the
/// clock -- see `secondary_handshake_spins` for why it may not read the timer.
fn wait_on_secondary_core(word: *sync.Atomic(u32), mask: u32) bool {
    var budget: u32 = secondary_handshake_spins;
    while (budget > 0) : (budget -= 1) {
        if (word.load(.acquire) & mask == mask) return true;
    }
    return false;
}

/// One core's share of the self-test: the primitive first, then the lock built
/// on it. Nothing here blocks -- a losing try-lock skips its turn -- so the test
/// is bounded by its own loop counts however the cores are scheduled.
fn selftest_participate(marker: u32) void {
    // Stage 1: the exclusive monitor itself, no lock involved.
    var atomic_iteration: u32 = 0;
    while (atomic_iteration < selftest_atomic_iterations) : (atomic_iteration += 1) {
        _ = selftest_atomic.fetchAdd(1, .monotonic);
    }

    // Stage 2 -- the SpinLock built on that primitive really does exclude.
    var taken: u32 = 0;
    var iteration: u32 = 0;
    while (iteration < selftest_iterations) : (iteration += 1) {
        const flags = selftest_lock.value.try_lock_irqsave() orelse continue;

        const observed = counter().*;
        selftest_marker.store(marker, .monotonic);

        var spin: u32 = 0;
        while (spin < selftest_hold_spins) : (spin += 1) delay_barrier();

        counter().* = observed + 1;
        if (selftest_marker.load(.monotonic) != marker) {
            _ = selftest_failures.fetchAdd(1, .monotonic);
        }

        taken += 1;
        selftest_lock.value.unlock_irqrestore(flags);
    }

    _ = selftest_sections.fetchAdd(taken, .release);
    _ = selftest_done.fetchAdd(1, .release);
}

fn run_selftest(participants: u32) void {
    selftest_participants = participants;
    counter().* = 0;
    selftest_atomic.store(0, .monotonic);
    selftest_sections.store(0, .monotonic);
    selftest_failures.store(0, .monotonic);
    selftest_done.store(0, .monotonic);

    // Release, so a secondary core that sees the go flag also sees the counters
    // zeroed above rather than the previous run's values.
    selftest_go.store(1, .release);

    // Timed and reported through /proc/cpus: this is the one part of boot whose
    // cost is contention, which an emulator makes unrepresentative.
    const started_us = hal.time.get_time_us();
    selftest_participate(core_bit(sync.percpu.current_core()));

    if (!wait_on_boot_core(&selftest_done, at_least, participants)) {
        selftest_duration_us = hal.time.get_time_us() -% started_us;
        selftest_verdict = .fail;
        log.err("smp: self-test timed out with {d}/{d} cores finished", .{
            selftest_done.load(.acquire),
            participants,
        });
        return;
    }

    selftest_duration_us = hal.time.get_time_us() -% started_us;

    const atomic_expected = selftest_atomic_iterations * participants;
    const atomic_total = selftest_atomic.load(.acquire);
    const sections = selftest_sections.load(.acquire);
    const guarded = counter().*;
    const failures = selftest_failures.load(.acquire);

    // `sections > 0` matters: every try-lock losing would otherwise satisfy
    // `guarded == sections` with both at zero, a test that checked nothing.
    if (atomic_total == atomic_expected and guarded == sections and sections > 0 and failures == 0) {
        selftest_verdict = .pass;
        log.info("smp: cross-core exclusives verified -- {d} atomic increments, {d} locked sections", .{
            atomic_total, sections,
        });
        return;
    }

    selftest_verdict = .fail;
    // Loud on purpose: every lock in the kernel rests on this working, so a
    // kernel that reaches this line is one whose spinlocks do not exclude.
    log.err("smp: CROSS-CORE MUTUAL EXCLUSION IS BROKEN -- atomic {d}/{d}, guarded {d}/{d} sections, overlaps {d}", .{
        atomic_total, atomic_expected, guarded, sections, failures,
    });
}

/// Release every secondary core and verify the locks work across them. Runs on
/// core 0 before the process manager exists. Failure is never fatal -- the
/// kernel keeps running on the cores it does have and says so.
pub fn start_secondary_cores() void {
    // Recorded before the SMP gate, so a single-core build reports itself the
    // same way an SMP one does.
    mark_online(sync.percpu.current_core());

    if (comptime !enabled) return;

    // Install once for both cores (the vector table is shared) and enable this
    // core's own NVIC line; the NVIC is banked, so core 1 enables its own.
    hal.cpu.install_doorbell_handler(&irq_doorbell);
    hal.cpu.enable_doorbell();

    var participants: u32 = 1;
    for (1..core_count) |core| {
        if (!hal.cpu.start_core(@intCast(core))) {
            log.err("smp: this board has no bring-up path for core {d}", .{core});
            continue;
        }

        if (!wait_on_boot_core(&online_mask, all_bits_set, core_bit(core))) {
            log.err("smp: core {d} was released but never reached kernel code", .{core});
            continue;
        }
        participants += 1;
    }

    if (participants < 2) {
        log.err("smp: no secondary core came up; running on core 0 only", .{});
        return;
    }

    run_selftest(participants);
}

/// Entry point for a secondary core, called by the board's core-N reset path
/// once the per-core state (MSP, MSPLIM, VTOR, CPACR) is set up. The order of
/// the handshake matters: announce, self-test, and only then start a timer, so
/// the tick cannot perturb the measurement.
pub export fn kernel_secondary_core_entry() noreturn {
    const core = sync.percpu.current_core();

    mark_online(core);

    // Skipped rather than run alone if core 0 gave up waiting: a core running
    // the sections by itself would satisfy an expectation nobody set.
    if (wait_on_secondary_core(&selftest_go, 1)) {
        selftest_participate(core_bit(core));
    }

    // SysTick is per-core hardware and a fresh core's is dead until it programs
    // it. Until this core takes its first switch it drives only the liveness
    // counter, since `current_core_schedules` is false there.
    arch.process.init_secondary();

    // The handler is already installed (shared vector table); this is the banked
    // NVIC line, which only this core can unmask for itself.
    hal.cpu.enable_doorbell();

    // The MPU is banked per core, and `main.zig` enables kernel protection on
    // core 0 only -- an unprivileged process on a core with no MPU has the run
    // of the kernel heap and stack. After the self-test, mirroring where core
    // 0's own call sits, so the exclusives test runs with the MPU off on both.
    //
    // No EXTEXCLALL hazard: it stops helping only once an enabled MPU region
    // covers the address, and `enable_kernel_protection` does not map kernel
    // RAM, which is where every lock word lives.
    enable_kernel_protection_on_this_core();

    // Nothing to schedule until core 0 has built the process manager, the root
    // process and this core's idle process, all after `start_secondary_cores()`
    // returns. WFI rather than a spin; the core's own SysTick wakes it.
    while (!is_scheduler_ready()) {
        park();
    }

    // Never returns: it switches into this core's idle process and from there
    // the core is driven by PendSV like any other.
    process_manager.enter_scheduler_on_secondary_core();
}

/// Whether this build locks the kernel heap and stack away from unprivileged
/// processes. Mirrors the gate in `main.zig`.
const mpu_kernel_protection = if (@hasDecl(config.process, "use_mpu_kernel_protection"))
    config.process.use_mpu_kernel_protection
else
    false;

/// Program this core's MPU with the same kernel protection `main.zig` gives
/// core 0. `@hasDecl`-guarded so the boards and host targets with no MPU module
/// still build.
fn enable_kernel_protection_on_this_core() void {
    if (comptime !mpu_kernel_protection) return;
    if (comptime !@hasDecl(arch, "mpu")) return;
    arch.mpu.enable_kernel_protection();
}

/// Halt until the next interrupt. WFI rather than a spin: under emulation a
/// spinning core burns a whole host CPU.
fn park() void {
    if (comptime @hasDecl(arch.sync, "wait_for_interrupt")) {
        arch.sync.wait_for_interrupt();
    } else {
        std.atomic.spinLoopHint();
    }
}

/// Count this core's system tick. Called from `irq_systick` on every core.
pub fn note_tick() void {
    _ = core_ticks.current().fetchAdd(1, .monotonic);
}

pub fn is_online(core: usize) bool {
    if (core >= core_count) return false;
    return online_mask.load(.acquire) & core_bit(core) != 0;
}

pub fn ticks_of(core: usize) u32 {
    if (core >= core_count) return 0;
    return core_ticks.of(core).load(.monotonic);
}

/// Count a completed context switch on this core. Called from
/// `process_set_next_task`, i.e. once per switch on whichever core made it.
pub fn note_context_switch() void {
    _ = core_switches.current().fetchAdd(1, .monotonic);
}

pub fn switches_of(core: usize) u32 {
    if (core >= core_count) return 0;
    return core_switches.of(core).load(.monotonic);
}

/// Cores currently running their idle process, as a bitmask, so `kick_idle_core`
/// can answer "is anyone free?" with one atomic load and no lock. A hint only:
/// it can be stale either way, and both a spurious and a missed doorbell are
/// harmless.
var idle_mask: sync.Atomic(u32) = .init(0);

pub fn mark_core_idle() void {
    _ = idle_mask.fetchOr(core_bit(sync.percpu.current_core()), .release);
}

pub fn mark_core_busy() void {
    _ = idle_mask.fetchAnd(~core_bit(sync.percpu.current_core()), .release);
}

/// Whether this board can interrupt another core at all, rather than leaving it
/// to notice new work on its next tick.
pub fn has_doorbell() bool {
    if (comptime !enabled) return false;
    return hal.cpu.has_doorbell();
}

pub fn is_core_idle(core: usize) bool {
    if (core >= core_count) return false;
    return idle_mask.load(.acquire) & core_bit(core) != 0;
}

/// Ask an idle core to come and look for work, when a process becomes runnable.
/// Correctness does not depend on it -- an idle core re-enters the scheduler on
/// its own SysTick, which is what the doorbell-less QEMU board relies on -- it
/// only buys latency. Rings at most one core, and never this one.
pub fn kick_idle_core() void {
    if (comptime !enabled) return;

    const self = sync.percpu.current_core();
    const mask = idle_mask.load(.acquire);
    for (0..core_count) |core| {
        if (core == self) continue;
        if (mask & core_bit(core) == 0) continue;
        _ = hal.cpu.ring_doorbell(@intCast(core));
        return;
    }
}

/// Handle a doorbell on the calling core. Acknowledge first, then pend a
/// reschedule: the bell is level-held, and clearing it after pending PendSV
/// would lose a bell rung in between.
pub fn handle_doorbell() void {
    hal.cpu.clear_doorbell();
    if (!current_core_schedules()) return;
    hal.irq.trigger(.pendsv);
}

/// The doorbell vector. Exported because it is reached from the vector table,
/// which nothing in Zig references.
export fn irq_doorbell() callconv(.c) void {
    handle_doorbell();
}

pub fn online_count() usize {
    var total: usize = 0;
    for (0..core_count) |core| {
        if (is_online(core)) total += 1;
    }
    return total;
}

pub const SelftestReport = struct {
    verdict: Verdict,
    /// Stage 1: increments issued between the participating cores, and the value
    /// the shared atomic reached. A short total means an increment was lost.
    atomic_expected: u32,
    atomic_counted: u32,
    /// Stage 2: sections actually entered, and the lock-guarded counter that
    /// must equal them. Counted rather than predicted -- a losing try-lock is
    /// skipped, not retried.
    sections: u32,
    guarded: u32,
    /// Times a core found another core's marker in the section it held.
    overlaps: u32,
    /// Wall time the run took. Reported because it is the one boot cost that
    /// depends on how the *host* schedules the emulated cores.
    duration_us: u64,
};

pub fn selftest_report() SelftestReport {
    const ran = selftest_verdict != .skipped;
    return .{
        .verdict = selftest_verdict,
        .atomic_expected = if (ran) selftest_atomic_iterations * selftest_participants else 0,
        .atomic_counted = if (ran) selftest_atomic.load(.monotonic) else 0,
        .sections = if (ran) selftest_sections.load(.monotonic) else 0,
        .guarded = if (ran) counter().* else 0,
        .overlaps = selftest_failures.load(.monotonic),
        .duration_us = selftest_duration_us,
    };
}

const testing = std.testing;

test "Smp.SingleCoreBuildReportsItself" {
    // With SMP off the whole secondary path is compiled out, and the accessors
    // still have to answer sensibly rather than index past their one slot.
    if (comptime !enabled) {
        try testing.expectEqual(@as(usize, 1), core_count);
        try testing.expect(!is_online(1));
        try testing.expectEqual(@as(u32, 0), ticks_of(1));
    }
    try testing.expect(!core_schedules(core_count));
}

test "Smp.ACoreDoesNotScheduleUntilItHasTakenItsFirstSwitch" {
    // The false answer is the load-bearing one: a secondary core has its SysTick
    // running from `init_secondary()` while still on MSP with no PSP of its own,
    // and both `irq_systick` and `do_context_switch` refuse to switch there.
    const restore = scheduling_mask.load(.acquire);
    defer scheduling_mask.store(restore, .release);

    scheduling_mask.store(0, .release);
    try testing.expect(!current_core_schedules());
    for (0..core_count) |core| try testing.expect(!core_schedules(core));

    mark_core_entered_scheduler();
    try testing.expect(current_core_schedules());
    try testing.expect(core_schedules(sync.percpu.current_core()));

    // ...and marking one core must not speak for the other.
    if (core_count > 1) {
        const other = (sync.percpu.current_core() + 1) % core_count;
        try testing.expect(!core_schedules(other));
    }
}

test "Smp.SchedulerReadyGatesTheSecondaryCore" {
    // The handshake a secondary core parks on: bring-up runs before the process
    // manager and the idle processes exist, so entering the scheduler early
    // would claim an idle process that is still null.
    const restore = scheduler_ready.load(.acquire);
    defer scheduler_ready.store(restore, .release);

    scheduler_ready.store(0, .release);
    try testing.expect(!is_scheduler_ready());
    mark_scheduler_ready();
    try testing.expect(is_scheduler_ready());
}

test "Smp.StartSecondaryCoresIsSafeWithoutABoardPath" {
    // The host and unit-test targets have no `start_core`, so bring-up must
    // degrade to "core 0 only" rather than hang on a handshake nobody answers.
    start_secondary_cores();
    try testing.expect(is_online(sync.percpu.current_core()));
}

test "Smp.SelftestReportIsEmptyUntilItRuns" {
    // A skipped test reports zeros rather than the shape of a run that never
    // happened, which `/proc/cpus` readers would take for a pass.
    if (selftest_verdict == .skipped) {
        const report = selftest_report();
        try testing.expectEqual(@as(u32, 0), report.atomic_expected);
        try testing.expectEqual(@as(u32, 0), report.atomic_counted);
        try testing.expectEqual(@as(u32, 0), report.sections);
        try testing.expectEqual(@as(u32, 0), report.guarded);
    }
}
