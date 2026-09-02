//
// process_manager.zig
//
// Copyright (C) 2025 Mateusz Stadnik <matgla@live.com>
//
// This program is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation, either version
// 3 of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General
// Public License along with this program. If not, see
// <https://www.gnu.org/licenses/>.
//
const std = @import("std");
const builtin = @import("builtin");

const hal = @import("hal");

const config = @import("config");
const kernel = @import("kernel.zig");
const process = kernel.process;
const VForkContext = process.VForkContext;
const Process = process.Process;
const log = std.log.scoped(.process_manager);
const dynamic_loader = @import("modules.zig");
const SymbolEntry = @import("yasld").SymbolEntry;
const system_call = @import("interrupts/system_call.zig");
const c = @import("libc_imports").c;
const handlers = @import("interrupts/syscall_handlers.zig");
const perf = @import("interrupts/perf_profile.zig");
const preempt = @import("sync/preempt.zig");
const smp = @import("smp.zig");

/// Rank 70, a leaf. `spin_irq` rather than a sleeping mutex because
/// `release_pid` is called from `schedule_next`, which runs in PendSV.
var pidmap_lock: kernel.sync.Ranked(.pidmap) = .{};

/// Rank 50: the process table itself -- `processes`, `terminate_list`, and the
/// scheduler's cursor into them. `spin_irq`, since PendSV walks the list on
/// every context switch. Outside `pidmap`, `pagepool` and `kheap`, so a reap can
/// hold the table; inside `fs` and `dev`, which keeps filesystem work off it.
var proctable_lock: kernel.sync.Ranked(.proctable) = .{};

const arch = @import("arch");

const Scheduler = if (config.scheduler.round_robin)
    @import("scheduler/round_robin.zig").RoundRobin
else if (config.scheduler.osthread)
    @import("scheduler/osthread.zig").OSThread
else if (config.scheduler.stub)
    @import("scheduler/stub.zig").StubScheduler
else
    @compileError("Unsupported scheduler type");

extern fn switch_to_next_task() void;
extern fn switch_to_the_first_task(with_fpu: usize) void;
extern fn call_main(argc: i32, argv: [*c][*c]u8, address: usize, got: *const anyopaque) i32;
extern fn arch_push_hardware_registers_on_stack(lr: usize, pc: usize) void;

extern fn process_vfork_child(sp: usize, got: usize, lr: usize, is_fpu_used: usize) i32;
extern fn process_get_back_to_parent_vfork(pid: i32, sp: usize, lr: usize, stack_bottom: usize) i32;

/// Size of the register frame `libs/libc/arm/vfork.S` leaves for the kernel:
/// `push {r4-r11, lr}`, plus `vpush {s0-s31}` when `is_fpu_used`. `context.sp`
/// points at its base, so the caller's own stack pointer is just past the top.
const vfork_frame_bytes: usize = 9 * @sizeOf(usize);
const vfork_fpu_frame_bytes: usize = 32 * @sizeOf(u32);

/// Headroom between this kernel frame and the point the child is released from
/// (`process_vfork_child`, one call deeper). The only guessed part of the
/// reservation; a ReleaseSafe build saves 848 B into the 1064 B reserved here,
/// and `save_vfork_stack` refuses rather than overrun if that is ever too tight.
const vfork_stack_slack: usize = 256;

/// `WNOHANG` from `libs/libc/sys/wait.h`. Spelled out because it is a macro
/// there, so it does not survive into the imported declarations.
const wnohang: i32 = 0x1;

/// Stack for a core's idle process. 8 KB, matching the secondary core's MSP: the
/// idle body itself needs almost none of it, but `reap_terminated` unwinds
/// through `Process.deinit` into the page pool and the kernel heap, and the
/// fault handler's module-map dump alone wants a 4 KB buffer.
const idle_stack_size: u32 = 8 * 1024;

/// The body of every core's idle process. A process rather than a bare WFI loop
/// because `reap_terminated` must run in thread context -- it frees to the
/// kernel heap. WFI rather than a spin: under emulation a spinning idle core
/// burns a whole host CPU. Woken by SysTick, or by the other core's doorbell.
export fn idle_process_entry() void {
    // Close the window `enter_scheduler_on_secondary_core` opened: a raw-entry
    // frame is reached by `bx r0`, not an exception return, so nothing restores
    // PRIMASK for us. Harmless on a core that arrived with interrupts enabled.
    arch.enable_interrupts();

    while (true) {
        instance.reap_terminated();
        if (comptime @hasDecl(arch.sync, "wait_for_interrupt")) {
            arch.sync.wait_for_interrupt();
        } else {
            std.atomic.spinLoopHint();
        }
    }
}

fn current_stack_pointer() usize {
    if (comptime !builtin.cpu.arch.isThumb()) return 0;
    return asm volatile ("mov %[out], sp"
        : [out] "=r" (-> usize),
    );
}

fn vfork_caller_stack_pointer(context: *const volatile c.vfork_context) usize {
    const frame = @intFromPtr(context.sp.?);
    const fpu_bytes: usize = if (context.is_fpu_used == 1) vfork_fpu_frame_bytes else 0;
    return frame + vfork_frame_bytes + fpu_bytes;
}

fn reserve_vfork_stack_for(parent: *Process, context: *const volatile c.vfork_context) !void {
    if (comptime !builtin.cpu.arch.isThumb()) return;
    const top = vfork_caller_stack_pointer(context);
    const here = current_stack_pointer();
    // `context.sp` is userspace-supplied and bounds a copy out of the caller's
    // stack, so it has to be confined to that stack. `here` is this handler's
    // own stack pointer, inside it by construction, so it pins the lower end.
    if (top <= here) return error.InvalidVforkFrame;
    if (top > @intFromPtr(parent.get_stack_top())) return error.InvalidVforkFrame;
    if (here < @intFromPtr(parent.get_stack_bottom())) return error.InvalidVforkFrame;
    try parent.reserve_vfork_stack(top, top - here + vfork_stack_slack);
}

pub const RuntimeConfiguration = struct {
    default_stack_size: u32,
    default_resource_limits: [c.RLIM_NLIMITS]c.rlimit,

    pub fn init() RuntimeConfiguration {
        const default_stack_size = config.process.default_stack_size;
        return .{
            .default_stack_size = default_stack_size,
            .default_resource_limits = process.create_default_resource_limits(default_stack_size),
        };
    }

    pub fn resolve_stack_size(self: RuntimeConfiguration, requested_stack_size: u32) u32 {
        if (requested_stack_size == 0) {
            return self.default_stack_size;
        }
        return requested_stack_size;
    }

    pub fn create_process_limits(self: RuntimeConfiguration, stack_size: u32) [c.RLIM_NLIMITS]c.rlimit {
        var limits = self.default_resource_limits;
        limits[c.RLIMIT_STACK] = .{
            .rlim_cur = stack_size,
            .rlim_max = @max(stack_size, limits[c.RLIMIT_STACK].rlim_max),
        };
        return limits;
    }

    pub fn set_default_stack_size(self: *RuntimeConfiguration, stack_size: u32) void {
        self.default_stack_size = stack_size;
        self.default_resource_limits[c.RLIMIT_STACK] = .{
            .rlim_cur = stack_size,
            .rlim_max = @max(stack_size, self.default_resource_limits[c.RLIMIT_STACK].rlim_max),
        };
    }

    pub fn set_default_resource_limit(self: *RuntimeConfiguration, resource: i32, limit: c.rlimit) !void {
        if (resource < 0 or resource >= c.RLIM_NLIMITS) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }
        if (limit.rlim_cur > limit.rlim_max) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }

        self.default_resource_limits[@intCast(resource)] = limit;
        if (resource == c.RLIMIT_STACK) {
            self.default_stack_size = @intCast(limit.rlim_cur);
        }
    }

    pub fn get_default_resource_limit(self: RuntimeConfiguration, resource: i32) !c.rlimit {
        if (resource < 0 or resource >= c.RLIM_NLIMITS) {
            return kernel.errno.ErrnoSet.InvalidArgument;
        }

        return self.default_resource_limits[@intCast(resource)];
    }
};

fn ProcessManagerGenerator(comptime SchedulerType: anytype) type {
    return struct {
        pub const ContainerType = std.DoublyLinkedList;
        pub const ProcessType = Process;
        const Self = @This();

        pub const PidMap = std.StaticBitSet(config.process.max_pid_value);
        pub const PidIterator = PidMap.Iterator(.{
            .kind = .unset,
        });

        processes: ContainerType,
        allocator: std.mem.Allocator,
        _scheduler: SchedulerType,
        _process_memory_pool: kernel.memory.heap.ProcessMemoryPool,
        _pid_map: std.StaticBitSet(config.process.max_pid_value),
        core: [hal.cpu.number_of_cores()]*ProcessType,
        /// What each core runs when the table holds nothing runnable. Not in
        /// `processes`, because everything that walks that list -- `ps`,
        /// `is_empty`, `has_live_child`, the other core's scan -- has no
        /// business with an idle process. Reached only through this array, so
        /// exactly one core can run it and no claim can contend.
        idle: [hal.cpu.number_of_cores()]?*ProcessType,
        terminate_list: std.DoublyLinkedList,
        runtime_configuration: RuntimeConfiguration,

        pub fn init(allocator: std.mem.Allocator) Self {
            log.debug("Using scheduler '{s}'", .{SchedulerType.Name});
            const processes_memory_pool = kernel.memory.heap.ProcessMemoryPool.init(allocator) catch |err| {
                log.err("Processes memory pool initialization failed: '{s}'", .{@errorName(err)});
                unreachable;
            };

            return Self{
                .processes = .{},
                .allocator = allocator,
                ._scheduler = SchedulerType.init(),
                ._process_memory_pool = processes_memory_pool,
                ._pid_map = std.StaticBitSet(config.process.max_pid_value).full,
                .core = undefined,
                .idle = @splat(null),
                .terminate_list = .{},
                .runtime_configuration = RuntimeConfiguration.init(),
            };
        }

        pub fn get_default_stack_size(self: *const Self) u32 {
            return self.runtime_configuration.default_stack_size;
        }

        pub fn set_default_stack_size(self: *Self, stack_size: u32) void {
            self.runtime_configuration.set_default_stack_size(stack_size);
        }

        pub fn get_runtime_configuration(self: *Self) *RuntimeConfiguration {
            return &self.runtime_configuration;
        }

        /// Pick what this core runs next. Runs in PendSV; reaping happens in
        /// `reap_terminated` from thread context instead. The lock is held
        /// across the whole scan because the scan *is* the claim -- a second
        /// core allowed between the test and `try_claim`'s store to `Running`
        /// would pick the same node.
        pub fn schedule_next(self: *Self) kernel.scheduler.Action {
            const flags = proctable_lock.lock_irqsave();
            defer proctable_lock.unlock_irqrestore(flags);

            if (self.processes.first) |first| {
                const action = self._scheduler.schedule_next(first);
                if (action != .NoAction) return action;
                return self.fall_back_to_idle();
            }
            // An empty table on the boot core is shutdown: `switch_to_main_task`
            // pops the frame `switch_to_the_first_task` left. A secondary core
            // has no such frame, and an empty table is normal for it, so it
            // idles instead.
            if (hal.cpu.coreid() == 0) return .ReturnToMain;
            return self.fall_back_to_idle();
        }

        /// Nothing in the table is runnable on this core, so park it in the idle
        /// process. Leaving a blocked process on the core instead would have it
        /// spin on `hal.irq.trigger(.pendsv)`, re-entering `schedule_next` and
        /// taking `proctable_lock` as fast as the core can issue it -- which
        /// throttles real work on the other core.
        ///
        /// Caller holds `proctable_lock`.
        fn fall_back_to_idle(self: *Self) kernel.scheduler.Action {
            const idle_process = self.idle[hal.cpu.coreid()] orelse return .NoAction;
            const current = self._scheduler.get_current() orelse return self._scheduler.claim(&idle_process.node);
            // Already parked, or still holding a process that can run: stay.
            if (current == idle_process) return .NoAction;
            if (current.state == Process.State.Running) return .NoAction;
            return self._scheduler.claim(&idle_process.node);
        }

        /// Free every terminated process no core is still standing on. Thread
        /// context only: it releases a pid and frees the process's pages and the
        /// `Process` itself, so it takes `pagepool` (80) and `kheap` (90).
        ///
        /// `is_claimed_by_any_core` is what keeps a process on the terminate
        /// list until no core's cursor points at it -- an exiting process is
        /// still its own core's `current` while that core switches away, and
        /// freeing its stack there is a use-after-free of the context the switch
        /// is about to store.
        pub fn reap_terminated(self: *Self) void {
            while (true) {
                const victim = blk: {
                    const flags = proctable_lock.lock_irqsave();
                    defer proctable_lock.unlock_irqrestore(flags);

                    var next = self.terminate_list.first;
                    while (next) |node| {
                        const p: *Process = @alignCast(@fieldParentPtr("node", node));
                        next = node.next;
                        if (self._scheduler.is_claimed_by_any_core(&p.node)) continue;
                        self._scheduler.remove_process(&p.node);
                        self.terminate_list.remove(&p.node);
                        break :blk p;
                    }
                    break :blk null;
                };

                const p = victim orelse return;
                // Outside the lock: it is off both lists and no core is on it,
                // so nothing can reach it, and the frees below are the long part.
                const pool = self.get_process_memory_pool();
                // `deinit` destroys the process, so the pid it is keyed by has to
                // be read out first -- the trailing log line used to read it back
                // out of the freed struct.
                const dead_pid = p.pid;
                log.info("reap: pid={d} kernel_used={d} process_pages={d} alloc_count={d}", .{ dead_pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size(), kernel.memory.heap.malloc.get_counter() });
                ctx_trace(.reap, dead_pid, @intFromPtr(p.get_stack_bottom()), @intFromPtr(p.get_stack_top()));
                // Teardown first, pid second. Everything `deinit` still has to
                // give back -- the stack, and every page-pool run through
                // `release_pages_for` -- is keyed by pid alone, and the pid map
                // hands out the lowest free pid, so releasing it first publishes
                // this pid while its mappings are still in the pool.
                //
                // The other core is normally running the shell right here (this
                // runs in the idle process, and the shell was just woken by the
                // exit), so it spawns the next command into the pid this reap is
                // still unwinding. Both processes then share one `memory_map`
                // entry, and `release_pages_for` marks the *new* process's live
                // runs free and destroys their records: its modules get handed
                // out again a few allocations later, which is one process
                // finding another's data inside its own .data. It went unseen
                // with 32 KiB stacks and became reproducible at `ulimit -s 1024`
                // (tests2/119_random_stuff), where freeing and re-zeroing a 1 MiB
                // PSRAM stack stretches both sides of the window by ~40 ms each.
                p.deinit();
                self.release_pid(dead_pid);
                log.info("reap: reaped pid={d} kernel_used={d} process_pages={d} alloc_count={d}", .{ dead_pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size(), kernel.memory.heap.malloc.get_counter() });
            }
        }

        pub fn deinit(self: *Self) void {
            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                p.deinit();
            }
            // `reap_terminated` may never have been reached, so anything still
            // on the terminate list here is a process nobody collected.
            next = self.terminate_list.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                p.deinit();
            }
            self.terminate_list = .{};
            for (&self.idle) |*slot| {
                if (slot.*) |idle_process| idle_process.deinit();
                slot.* = null;
            }
            self._process_memory_pool.deinit();
        }

        pub fn get_pidmap(self: *const Self) std.StaticBitSet(config.process.max_pid_value) {
            const flags = pidmap_lock.lock_irqsave();
            defer pidmap_lock.unlock_irqrestore(flags);
            return self._pid_map;
        }

        fn get_next_pid(self: *Self) ?c.pid_t {
            const flags = pidmap_lock.lock_irqsave();
            defer pidmap_lock.unlock_irqrestore(flags);
            // find-then-clear is a read-modify-write across two operations: two
            // contexts can both see the same first free bit and both take it,
            // handing one pid to two processes.
            const maybe_index = self._pid_map.findFirstSet();
            if (maybe_index) |index| {
                self._pid_map.unset(index);
                return @intCast(index + 1);
            }
            log.err("No more PIDs available", .{});
            return null;
        }

        fn release_pid(self: *Self, pid: c.pid_t) void {
            const flags = pidmap_lock.lock_irqsave();
            defer pidmap_lock.unlock_irqrestore(flags);
            if (pid > 0 and pid < config.process.max_pid_value) {
                self._pid_map.set(@intCast(pid - 1));
            }
        }

        pub fn create_process(self: *Self, stack_size: u32, process_entry: anytype, args: ?*const anyopaque, cwd: []const u8) !void {
            // Reclaim before allocating: the idle process is the usual reaper,
            // but it never runs while both cores stay busy.
            self.reap_terminated();
            const maybe_pid = self.get_next_pid();
            if (maybe_pid) |pid| {
                const effective_stack_size = self.runtime_configuration.resolve_stack_size(stack_size);
                var new_process = try Process.init(self.allocator, effective_stack_size, process_entry, args, cwd, &self._process_memory_pool, null, pid, false);
                new_process.set_resource_limits(self.runtime_configuration.create_process_limits(effective_stack_size));

                {
                    const flags = proctable_lock.lock_irqsave();
                    defer proctable_lock.unlock_irqrestore(flags);
                    self.processes.append(&new_process.node);
                }
                // A new runnable process. Outside the lock: ringing is an atomic
                // load and one MMIO store, but there is no reason to do it with
                // interrupts masked.
                smp.kick_idle_core();
                return;
            }
            return kernel.errno.ErrnoSet.TryAgain;
        }

        pub fn create_root_process(self: *Self, stack_size: u32, process_entry: anytype, args: ?*const anyopaque, cwd: []const u8) !void {
            const maybe_pid = self.get_next_pid();
            if (maybe_pid) |pid| {
                const effective_stack_size = self.runtime_configuration.resolve_stack_size(stack_size);
                var new_process = try Process.init(self.allocator, effective_stack_size, process_entry, args, cwd, &self._process_memory_pool, null, pid, true);
                new_process.set_resource_limits(self.runtime_configuration.create_process_limits(effective_stack_size));
                {
                    const flags = proctable_lock.lock_irqsave();
                    defer proctable_lock.unlock_irqrestore(flags);
                    self.processes.append(&new_process.node);
                }
                self.core[hal.cpu.coreid()] = new_process;
                return;
            }
            return kernel.errno.ErrnoSet.TryAgain;
        }

        /// Give every core something to run when the table has nothing for it.
        /// Called after `create_root_process`, so the root keeps pid 1.
        pub fn create_idle_processes(self: *Self) !void {
            for (0..hal.cpu.number_of_cores()) |core| {
                try self.create_idle_process(core);
            }
        }

        fn create_idle_process(self: *Self, core: usize) !void {
            const pid = self.get_next_pid() orelse return kernel.errno.ErrnoSet.TryAgain;

            // `is_root` selects the shape of the initial stack frame, not init
            // status. A secondary core enters its idle process through
            // `switch_to_the_first_task`, which ends in `bx r0` from thread
            // mode, so the frame's LR slot must hold a raw entry address. Core 0
            // is already running the root process, so its idle process is only
            // entered by PendSV and needs a normal EXC_RETURN frame. The
            // distinction lasts one switch.
            const entered_by_first_task_hand_off = core != 0;
            const idle_process = try Process.init(
                self.allocator,
                idle_stack_size,
                &idle_process_entry,
                null,
                "/",
                &self._process_memory_pool,
                null,
                pid,
                entered_by_first_task_hand_off,
            );

            // Privileged regardless of the frame shape: the idle body reaps,
            // which frees to the kernel heap, and with
            // CONFIG_PROCESS_USE_MPU_KERNEL_PROTECTION an unprivileged idle
            // process would take a MemManage DACCVIOL on the first collection.
            idle_process.privileged = true;
            idle_process.resume_privileged = true;

            self.idle[core] = idle_process;

            // Seed the other cores' `core[]` slots, which are `undefined` until
            // their first switch, so every `instance.core[coreid()]` reader gets
            // a real process. This core's slot holds the root process already.
            if (core != hal.cpu.coreid()) {
                self.core[core] = idle_process;
            }

            log.info("idle process for core {d} is pid {d}", .{ core, pid });
        }

        pub fn get_process_memory_pool(self: *Self) *kernel.memory.heap.ProcessMemoryPool {
            return &self._process_memory_pool;
        }

        pub fn delete_process(self: *Self, pid: c.pid_t, return_code: i32) void {

            // Preemptible cleanup. Everything here takes a sleeping mutex --
            // the loader's directly, the filesystem's through `clear_fds` -- and
            // `RankedMutex` panics rather than block with preemption disabled.
            // The window `sys_exit`/`sys_kill` opened is for the tail of this
            // function, where the process hands the core away; it must not cover
            // this.
            preempt.preempt_enable();

            // If a vfork child exits without calling exec, restore parent's
            // writable sections that may have been corrupted. Keyed by the
            // exiting (child) pid; a no-op if it wasn't a vfork child.
            dynamic_loader.restore_parent_writable_sections(pid);

            if (self.get_process_for_pid(pid)) |exiting| {
                // Close this process's files in its own thread context, not in
                // `deinit`, which the reaper calls where the filesystem's
                // sleeping mutex is unavailable. Idempotent, so `deinit` may
                // still call it for the paths that never reach here.
                exiting.clear_fds();
                dynamic_loader.release_executable(pid);
            }

            preempt.preempt_disable();

            // ── The hand-off, which is what the window is actually for ──────
            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                if (p.pid == pid) {
                    // One lock across taking the context, recording the exit,
                    // waking, and leaving the table -- the other half of the pair
                    // `waitpid` describes. Recording the exit makes the condition
                    // true and the wake publishes it; a waiter on the other core
                    // that tests between them sees neither and blocks forever.
                    var handoff: VForkHandoff = .none;
                    {
                        const flags = proctable_lock.lock_irqsave();
                        defer proctable_lock.unlock_irqrestore(flags);

                        // Decided before anything below acts on it, and taken
                        // rather than read: the parent's saved frames can be
                        // restored exactly once, so a second hand-off would reach
                        // `process_vfork_back_here` with nothing left to restore
                        // and resume the parent by popping whatever the child had
                        // scribbled over its frames.
                        handoff = take_vfork_handoff("exit", p);

                        // Leave the status where waitpid can find it. This is the
                        // one funnel every exit path comes through.
                        if (p._parent) |parent| {
                            parent.record_child_exit(pid, return_code);
                        }
                        p.unblock_parent();
                        p.schedule_removal();
                        p.unblock_all(return_code);

                        self.processes.remove(&p.node);
                        self.terminate_list.append(&p.node);

                        // Claim the parent before the lock drops. `unblock_parent`
                        // just published it as `Ready`, and a vfork parent must
                        // not be resumed from its stored context: the hand-off
                        // below re-enters it through `_vfork_context` and
                        // rewrites its stack, so the frame at its
                        // `stack_position` is not where it resumes. Leaving it
                        // claimable lets the other core take it and HardFault.
                        //
                        // Only for a hand-off that is actually going to happen.
                        // The claim is half of a pair, and claiming without the
                        // branch below is the same fault by a slower route; a
                        // `.refused` parent is parked and must stay unclaimed.
                        switch (handoff) {
                            .take => |h| {
                                self._scheduler.set_next(&h.parent.node);
                                self.core[hal.cpu.coreid()] = h.parent;
                            },
                            .none, .refused => {},
                        }
                    }

                    // Outside the lock: an atomic load and one MMIO store, with
                    // no reason to do it masked. A vfork parent is already
                    // claimed above, so it cannot be taken by the woken core.
                    smp.kick_idle_core();

                    switch (handoff) {
                        .take => |h| {
                            arch.disable_interrupts();
                            vfork_restore_target.current().* = h.parent;
                            _ = process_get_back_to_parent_vfork(pid, h.sp, h.lr, @intFromPtr(h.parent.get_stack_bottom()));
                            return;
                        },
                        // Nothing was committed to the parent, so this is the
                        // ordinary exit tail: fall through to the PendSV loop.
                        .none, .refused => {},
                    }

                    break;
                }
            }
            // Closes the window `sys_exit` / `sys_kill` opened. Released once,
            // outside the loop -- this process is never scheduled again, so the
            // loop only keeps re-pending the switch off this stack.
            preempt.preempt_enable();
            arch.memory_barrier_release();
            if (!std.mem.eql(u8, "host", config.cpu.arch)) {
                while (true) {
                    hal.irq.trigger(.pendsv);
                }
            } else {
                hal.irq.trigger(.pendsv);
            }
        }

        /// `vfork(2)`: create a child that runs on its parent's stack until it
        /// execs or exits, and hand this core to it without a context switch.
        ///
        /// The preemption window opens at `wait_for_process`, and neither end is
        /// free to move. Earlier would cover the loader calls, which take a
        /// sleeping mutex and panic if they block with preemption disabled.
        /// Later would let a PendSV switch the parent out after it is marked
        /// Blocked, leaving the child created, unreleased and unreachable.
        pub fn vfork(self: *Self, context: *const volatile c.vfork_context) !i32 {
            const current_process = self.get_current_process();
            const maybe_pid = self.get_next_pid();
            if (maybe_pid == null) {
                return kernel.errno.ErrnoSet.TryAgain;
            }

            // Reserve room for the part of this stack the child will run over
            // before anything else is committed, so a heap too small for it
            // fails the call rather than the hand-off.
            reserve_vfork_stack_for(current_process, context) catch |err| {
                log.err("vfork failed reserving the stack backup for pid={d}: {s}", .{ current_process.pid, @errorName(err) });
                return kernel.errno.ErrnoSet.TryAgain;
            };

            const new_process = current_process.vfork(&self._process_memory_pool, maybe_pid.?) catch |err| {
                log.err("vfork failed creating child for pid={d}: {s}", .{ current_process.pid, @errorName(err) });
                return -1;
            };

            // Both of these take `loader_lock`, so they have to happen up here.
            // Safe to be preempted across: the parent is still `Running` and the
            // child is not in `processes`, so nothing can observe or schedule it.
            var got: usize = 0;
            if (dynamic_loader.get_executable_for_pid(current_process.pid)) |exec| {
                if (exec.module.unique_data) |ud| {
                    if (ud.got) |got_ptr| {
                        got = @intFromPtr(got_ptr.ptr);
                    }
                }
            }
            context.pid.* = new_process.pid;

            // Save parent's writable sections before child runs on shared memory.
            // The child does not run until `process_vfork_child` below, so this
            // is early enough outside the window.
            dynamic_loader.save_parent_writable_sections(current_process.pid, new_process.pid);

            // ── The hand-off. PendSV must not fire from here on ──────────────
            preempt.preempt_disable();
            errdefer preempt.preempt_enable();

            const Action = struct {
                pub fn on_process_unblock(ctx: ?*anyopaque, rc: i32) void {
                    _ = ctx;
                    _ = rc;
                }
            };

            // This is what blocks the parent, and therefore what the window has
            // to cover.
            current_process.wait_for_process(new_process, &Action.on_process_unblock, new_process) catch |err| {
                log.err("vfork failed registering wait for parent pid={d} child pid={d}: {s}", .{ current_process.pid, new_process.pid, @errorName(err) });
                return -1;
            };

            {
                const flags = proctable_lock.lock_irqsave();
                defer proctable_lock.unlock_irqrestore(flags);
                self.processes.append(&new_process.node);
                self._scheduler.set_next(&new_process.node);
            }
            self.core[hal.cpu.coreid()] = new_process;
            // child is now running without context switch, but uses parent stack until exec
            // switch without context switch, just to represent correct state
            arch.disable_interrupts();
            return process_vfork_child(@intFromPtr(context.sp.?), got, @intFromPtr(context.lr.?), context.is_fpu_used);
        }

        // load executable into process

        pub const ExecuteContext = struct {
            symbol: usize,
            argc: i32,
            argv: [*c][*c]u8,
            envp: [*c][*c]u8,
            envpc: i32,
        };

        /// Record where the suspended parent resumes, and save the stack the
        /// child is about to run over. Returns true when the save succeeded,
        /// which is the condition for releasing the child on its caller's stack
        /// pointer rather than the kernel's.
        ///
        /// `stack_pointer` is both the parent's resume position and the bottom
        /// of the region to save; the caller is below it, which makes the copy
        /// safe.
        pub fn set_vfork_back_point(self: *Self, back_point: usize, stack_pointer: usize) bool {
            // The core already runs the child here (`vfork` hands the core over
            // before releasing it), so the context belongs to the child and the
            // stack being saved to its parent.
            const child = self.core[hal.cpu.coreid()];
            const parent = child._parent orelse {
                child._vfork_context = .{ .fp = 0, .sp = stack_pointer, .lr = back_point, .saved = false };
                return false;
            };
            // Save first, then publish the context carrying the outcome. The
            // hand-off reads `saved` to tell "nothing to restore because the
            // child stayed below the frames" from "nothing to restore because
            // the frames were already consumed" -- the second is a lost restore
            // and used to be silent.
            const saved = parent.save_vfork_stack(stack_pointer);
            child._vfork_context = .{
                .fp = 0,
                .sp = stack_pointer,
                .lr = back_point,
                .saved = saved,
            };
            return saved;
        }

        /// Put a suspended parent's stack back, immediately before it resumes.
        /// Called from `process_get_back_to_parent_vfork` once it is on the
        /// parent's resume position, so everything this pushes is below the
        /// region being rewritten.
        /// Restores the process the hand-off named, not whatever this core
        /// happens to hold. `core[coreid()]` is per-core state the scheduler
        /// rewrites on every switch, so inferring the target from it made the
        /// restore silently correct-looking against the wrong process.
        pub fn restore_vfork_back_stack(self: *Self) void {
            _ = self;
            const slot = vfork_restore_target.current();
            const target = slot.* orelse {
                log.err("vfork: restore ran with no hand-off target recorded", .{});
                return;
            };
            slot.* = null;

            const before = target.vfork_save_state();
            const restored = target.restore_vfork_stack();
            var written: usize = 0;
            if (before.len >= 40) {
                const dest: [*]const u8 = @ptrFromInt(before.base);
                written = std.mem.readInt(u32, dest[36..40][0..4], .little);
            }
            ctx_trace(.vrestore, target.pid, before.base, written);
            if (!restored) {
                // Reached only when `saved` said there would be something here;
                // the hand-off check upstream refuses that case, so this is the
                // last line of defence rather than the expected path.
                log.err("vfork: pid={d} resumes with nothing restored at 0x{X}", .{ target.pid, before.base });
            }
        }

        /// Clone the exec argv and envp into a single array owned by the new
        /// process. The layout follows the SysV convention so the C runtime can
        /// recover the environment without extra register plumbing:
        ///
        ///   [ argv0 .. argv(argc-1), NULL, env0 .. env(envc-1), NULL ]
        ///
        /// argv[argc] is the argv terminator; the environment starts at
        /// argv[argc + 1] (crt1 sets `environ = &argv[argc + 1]`). The trailing
        /// NULL is always present (even for an empty environment), so the
        /// derivation is valid regardless of env size.
        fn clone_exec_args(allocator: std.mem.Allocator, argv: [*c][*c]u8, envp: [*c][*c]u8) !struct {
            argc: usize,
            argv: [*c][*c]u8,
        } {
            var argc: usize = 0;
            while (argv[argc] != null) : (argc += 1) {}

            var envc: usize = 0;
            if (envp != null) {
                while (envp[envc] != null) : (envc += 1) {}
            }

            // Lay out the pointer array (argv, NULL, envp, NULL) followed by all
            // string bytes in ONE contiguous block. The exec target's process
            // memory pool is page-granular (4 KiB minimum per allocation), so the
            // old one-dupeZ-per-string scheme burned a whole page on every argv
            // and envp entry — ~14 pages (~56 KiB) for a typical command. Packing
            // them collapses that to a single page. crt1 still recovers `environ`
            // from &argv[argc + 1] because the pointer array stays contiguous.
            const n_ptrs = argc + 1 + envc + 1;
            const ptr_bytes = n_ptrs * @sizeOf([*c]u8);
            var str_bytes: usize = 0;
            {
                var i: usize = 0;
                while (i < argc) : (i += 1) str_bytes += std.mem.span(argv[i]).len + 1;
                i = 0;
                while (i < envc) : (i += 1) str_bytes += std.mem.span(envp[i]).len + 1;
            }

            const block = try allocator.alloc(u8, ptr_bytes + str_bytes);
            errdefer allocator.free(block);
            // The process page allocator returns page-aligned memory, so the
            // pointer array at offset 0 is safely aligned for [*c]u8.
            const ptrs: [*][*c]u8 = @ptrCast(@alignCast(block.ptr));

            var str_off: usize = ptr_bytes;
            var i: usize = 0;
            while (i < argc) : (i += 1) {
                const source = std.mem.span(argv[i]);
                @memcpy(block[str_off .. str_off + source.len], source);
                block[str_off + source.len] = 0;
                ptrs[i] = @ptrCast(block.ptr + str_off);
                str_off += source.len + 1;
            }
            ptrs[argc] = null;

            i = 0;
            while (i < envc) : (i += 1) {
                const source = std.mem.span(envp[i]);
                @memcpy(block[str_off .. str_off + source.len], source);
                block[str_off + source.len] = 0;
                ptrs[argc + 1 + i] = @ptrCast(block.ptr + str_off);
                str_off += source.len + 1;
            }
            ptrs[argc + 1 + envc] = null;

            return .{
                .argc = argc,
                .argv = @ptrCast(ptrs),
            };
        }

        // TODO: exec on currently running process is not supported yet
        pub fn prepare_exec(self: *Self, path: []const u8, argv: [*c][*c]u8, envp: [*c][*c]u8, path_allocator: ?std.mem.Allocator) !i32 {
            const current_process = self.get_current_process();

            // Restore parent's writable sections that may have been corrupted
            // by the vfork child running on shared memory before exec. Keyed by
            // this (child) process's pid — the snapshot save() stored at vfork.
            dynamic_loader.restore_parent_writable_sections(current_process.pid);

            // Pre-exec pool occupancy: how much of each tier is already resident
            // (suspended parent shell + its libs) BEFORE this image's pages load.
            // This is the baseline a new process — e.g. tcc — inherits and must
            // share, so its own headroom before PSRAM spill is cap - this.
            if (perf.enabled) {
                const pool = self.get_process_memory_pool();
                perf.trace("base pid={d} sram_used={d} sram_cap={d} psram_used={d} psram_cap={d}", .{
                    current_process.pid,
                    pool.used_pages(0),
                    pool.region_page_count(0),
                    pool.used_pages(1),
                    pool.region_page_count(1),
                });
            }

            // TODO: move loader to struct, pass allocator to loading functions
            const executable = try dynamic_loader.load_executable(path, current_process.get_process_memory_allocator(), current_process.pid);
            // Taken from inside the loader, not measured around this call: on a
            // profiling build the loader's own trace lines are written before
            // it returns, and billing those to the load overstated it 6x.
            current_process._load_us = dynamic_loader.last_executable_load_us;

            // Mark the load/relocate boundary so process exit can report real
            // execution time separately from dynamic-load time (perf profiling).
            // Also reset the memory-pool peak marks so the run's peak SRAM/PSRAM
            // usage (spill detection) is attributable to this exec'd image.
            if (perf.enabled) {
                current_process._exec_loaded_time = hal.time.get_time_us();
                self.get_process_memory_pool().reset_peaks();
                // The syscall counters are system-wide, so they only mean "this
                // process" if the window starts here. It holds for the smoke
                // suite because the parent shell is blocked in waitpid for the
                // whole run: whatever it was doing before landed in the
                // previous window, and its waitpid is recorded after this
                // image's dump. Concurrent processes would mix.
                perf.reset();
            }

            // Free the path now — it's no longer needed, and this function may
            // not return normally (process_get_back_to_parent_vfork bypasses
            // all defers in the caller).
            if (path_allocator) |alloc| {
                alloc.free(path);
            }
            const exec_allocator = current_process.get_process_memory_allocator();
            // argv_copy holds argv and envp contiguously (see clone_exec_args);
            // crt1 recovers `environ` from &argv[argc + 1].
            const argv_copy = try clone_exec_args(exec_allocator, argv, envp);
            const argc = argv_copy.argc;

            var symbol: SymbolEntry = undefined;
            if (executable.module.entry) |entry| {
                symbol = entry;
            } else if (executable.module.find_symbol("_start")) |entry| {
                symbol = entry;
            } else {
                return -1;
            }

            // An exec'd image is a user program and must run unprivileged so the
            // MPU keeps it out of the kernel heap and stack.
            current_process.privileged = false;

            // Apply the per-image stack hint from the YAFF header so an applet
            // sizes its stack to what it declared (e.g. shell tools want far
            // less than the 32 KiB default that tcc needs). 0xFFFFFFFF means
            // "OS default". An *explicit* RLIMIT_STACK (raised/lowered via
            // setrlimit/ulimit, i.e. differing from the default) always wins so
            // dynamic raises — e.g. the tcc suite's deep-recursion tests,
            // inherited across exec — still take effect. Otherwise the header
            // hint overrides the inherited default.
            const stack_hint = executable.module.stack_size;
            if (stack_hint != 0xFFFFFFFF) {
                const default_stack = self.runtime_configuration.default_stack_size;
                const cur = try current_process.get_resource_limit(c.RLIMIT_STACK);
                if (cur.rlim_cur == default_stack) {
                    var limit = cur;
                    limit.rlim_cur = stack_hint;
                    limit.rlim_max = @max(limit.rlim_max, stack_hint);
                    try current_process.set_resource_limit(c.RLIMIT_STACK, limit);
                }
            }

            // The window starts here, not at the top: what follows rewrites this
            // process's own stack and hands the core to its parent, so PendSV
            // must not fire inside it. Everything above is the image load, which
            // is milliseconds of card I/O and takes the sleeping `loader_lock`.
            //
            // The flag rather than a `defer`: the vfork tail hands off through
            // `process_get_back_to_parent_vfork`, which never returns, so a
            // `defer` would never run -- but every `try` and the ordinary return
            // must still release.
            preempt.preempt_disable();
            var preempt_held = true;
            defer if (preempt_held) preempt.preempt_enable();

            try current_process.reallocate_stack();

            // Apply the per-image heap profile now that the image + stack are
            // resident: bound dynamic growth to heap_size beyond this baseline.
            // 0xFFFFFFFF = free to grow in the shared paged pool (the default).
            current_process.set_heap_limit_bytes(executable.module.heap_size);

            try current_process.reinitialize_stack(&call_main, argc, @intFromPtr(argv_copy.argv), symbol.address, symbol.target_got_address);

            // Under `proctable_lock`, like the identical hand-off in
            // `delete_process`: `set_next` claims the parent and, through
            // `update_current`, releases this process and moves this core's
            // cursor, all of which the other core reads on every scan. Nothing
            // inside takes a sleeping lock, and the image load above has already
            // released the ones it held.
            //
            // The decision comes first and inside the same lock. The claim is
            // only correct paired with the branch that follows it: a parent
            // claimed for a hand-off that then does not happen is left unblocked
            // and never resumed, so the scheduler enters it at its stored
            // context -- the one position a vfork parent must not be entered at.
            const handoff = blk: {
                const flags = proctable_lock.lock_irqsave();
                defer proctable_lock.unlock_irqrestore(flags);
                const decision = take_vfork_handoff("exec", current_process);
                switch (decision) {
                    .take => |h| {
                        self._scheduler.set_next(&h.parent.node);
                        self.core[hal.cpu.coreid()] = h.parent;
                    },
                    // A plain `execve` with no parked parent behind it, left as
                    // it was: `set_next` releases this process through
                    // `update_current`, and its frame is freshly built and
                    // marked uninitialised, so the switch away enters the new
                    // image rather than storing over it.
                    .none => {
                        self._scheduler.set_next(&current_process._parent.?.node);
                        self.core[hal.cpu.coreid()] = current_process._parent.?;
                    },
                    // A parked, unresumable parent. Naming it here is the bug
                    // this split exists to prevent -- the claim would hand it to
                    // the next switch. See the branch below for what settles
                    // this process instead.
                    .refused => {},
                }
                break :blk decision;
            };

            switch (handoff) {
                .take => |h| {
                    current_process.unblock_parent();
                    arch.disable_interrupts();
                    // `process_get_back_to_parent_vfork` issues the matching
                    // release itself, from the parent's stack, so this must not.
                    preempt_held = false;
                    vfork_restore_target.current().* = h.parent;
                    return process_get_back_to_parent_vfork(current_process.pid, h.sp, h.lr, @intFromPtr(h.parent.get_stack_bottom()));
                },
                .refused => {
                    // Nothing was committed to the parent, so the only thing
                    // left to settle is this process. The image is loaded and
                    // its frame rebuilt, but the hand-off was the exec's way of
                    // leaving this stack, so report the failure and let the
                    // caller's own error path run: a vfork child is still on its
                    // parent's stack here, which is where it was before the
                    // call, so returning to it is safe and it normally `_exit`s
                    // straight away. Reported rather than returning 0, which
                    // libc reads as "exec succeeded and came back" and turns
                    // into whatever errno happened to be lying around.
                    //
                    // The pend is for the case where something else is runnable:
                    // this process is uninitialised, so a switch away releases it
                    // without storing, and it is entered at `call_main` if it is
                    // ever picked again. When nothing else is runnable the
                    // scheduler keeps it here (`fall_back_to_idle` holds a
                    // `Running` current), which is why the error return, not the
                    // pend, is what makes this path defined. Released explicitly
                    // rather than through the `defer` so the pend is not swallowed
                    // by the window this opened.
                    preempt_held = false;
                    preempt.preempt_enable();
                    hal.irq.trigger(.pendsv);
                    return kernel.errno.ErrnoSet.TryAgain;
                },
                .none => return 0,
            }
        }

        pub fn get_process_for_pid(self: *Self, pid: i32) ?*Process {
            const flags = proctable_lock.lock_irqsave();
            defer proctable_lock.unlock_irqrestore(flags);
            return self.get_process_for_pid_locked(pid);
        }

        /// `get_process_for_pid` for a caller that already holds
        /// `proctable_lock`. See `has_live_child_locked`.
        fn get_process_for_pid_locked(self: *Self, pid: i32) ?*Process {
            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                if (p.pid == pid) {
                    return p;
                }
                next = node.next;
            }
            return null;
        }

        /// Wake every process parked on `blocker` -- the counterpart to
        /// `Process.block_on`, for a waiter that cannot be named in advance.
        /// The caller must hold no lock ranked below `proctable`, which this
        /// takes.
        pub fn wake_all_blocked_on(self: *Self, blocker: *const anyopaque) void {
            {
                const flags = proctable_lock.lock_irqsave();
                defer proctable_lock.unlock_irqrestore(flags);
                var next = self.processes.first;
                while (next) |node| {
                    const p: *Process = @alignCast(@fieldParentPtr("node", node));
                    next = node.next;
                    p.wake_from(blocker);
                }
            }
            // Anything woken here is runnable now rather than at the woken
            // process's next timer tick, which is the whole point of a doorbell.
            smp.kick_idle_core();
        }

        /// Does this process still have a child that could be waited for?
        pub fn has_live_child(self: *Self, parent: *const Process) bool {
            const flags = proctable_lock.lock_irqsave();
            defer proctable_lock.unlock_irqrestore(flags);
            return self.has_live_child_locked(parent);
        }

        /// `has_live_child` for a caller that already holds `proctable_lock`.
        /// `Ranked` does not recurse, so this is not optional -- see `waitpid`,
        /// which has to hold the lock across the test *and* the block.
        fn has_live_child_locked(self: *Self, parent: *const Process) bool {
            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                if (p._parent != parent) continue;
                if (p.state == Process.State.Terminated) continue;
                return true;
            }
            return false;
        }

        /// `waitpid(2)`. `pid` of -1 means "any child", which is what a shell's
        /// `wait` uses.
        pub fn waitpid(self: *Self, pid: i32, status: *i32, options: i32) !i32 {
            const current_process = self.get_current_process();
            const nohang = (options & wnohang) != 0;

            // Registration runs with preemption refused; the wait itself must
            // not. `proctable_lock` is held across the whole decision, which is
            // what makes it safe on two cores: refusing preemption stops only
            // *this* core switching between the test and the block, and the
            // child is exiting on the other one. Without it the wake lands
            // before `block_on` and is lost, parking a shell forever on
            // `hello & wait`. The exit path takes the same lock across
            // `record_child_exit` and the wake.
            {
                preempt.preempt_disable();
                defer preempt.preempt_enable();

                const flags = proctable_lock.lock_irqsave();
                defer proctable_lock.unlock_irqrestore(flags);

                // A child that has already finished is collected without
                // blocking, whichever form of the call this is.
                if (current_process.take_exited_child(pid)) |exited| {
                    status.* = exited.status;
                    return exited.pid;
                }

                if (pid == -1) {
                    if (!self.has_live_child_locked(current_process)) {
                        return kernel.errno.ErrnoSet.NoChildProcesses;
                    }
                    if (nohang) return 0;
                    // Blocking on the collection list rather than on one child:
                    // whichever child finishes first records its exit there and
                    // wakes this process (`Process.record_child_exit`).
                    current_process.block_on(current_process.any_child_blocker());
                } else {
                    const maybe_process = self.get_process_for_pid_locked(pid);
                    if (maybe_process == null) {
                        status.* = current_process.child_exit_code;
                        return pid;
                    }
                    const p = maybe_process.?;
                    if (p.state == Process.State.Terminated) {
                        status.* = current_process.child_exit_code;
                        return pid;
                    }
                    if (nohang) return 0;

                    const Action = struct {
                        pub fn on_process_finished(context: ?*anyopaque, rc: i32) void {
                            const s: *i32 = @ptrCast(@alignCast(context));
                            s.* = rc;
                        }
                    };
                    current_process.wait_for_process(p, &Action.on_process_finished, status) catch {
                        return -1;
                    };
                }
            }

            // Preemption is enabled here, which is the point: yielding is the
            // only way the child ever runs.
            while (current_process.state == Process.State.Blocked) {
                hal.irq.trigger(.pendsv);
                current_process.reevaluate_state();
            }

            // Woken because a child finished: which one is known only from the
            // record it left, so `waitpid(-1)` reports the pid it collected.
            // Falling past this means the exit could not be recorded at all.
            if (current_process.take_exited_child(pid)) |exited| {
                status.* = exited.status;
                return exited.pid;
            }
            status.* = current_process.child_exit_code;
            return pid;
        }

        /// The process running on this core. The slot needs no lock: `core[]`
        /// is per-CPU, written only by its own core's context switch, and a
        /// pointer-sized aligned load cannot tear.
        ///
        /// The *index* is the hazard. `coreid()` and the slot load are separate
        /// instructions, and a PendSV between them migrates the caller -- so the
        /// load reads the slot of the core it left, returning whatever process
        /// is running there now instead of the caller. Slow-path syscalls run in
        /// thread mode on PSP (`process_syscall_entry` exception-returns with
        /// 0xfffffffd), so every `get_current_process` under one is preemptible
        /// and migratable. The sleeping mutex is where this surfaces first,
        /// because it is the only caller that keeps the answer across a
        /// preemption point and compares it later: a torn read stores the wrong
        /// `owner`, and the panic lands on whichever check gets there first --
        /// "expected to be held by the caller here" or "released by a process
        /// that does not hold it". Every other caller is worse and quieter: a
        /// syscall handler that mis-reads this works on another process's fd
        /// table.
        ///
        /// Masking makes the pair atomic against the switch. Nothing is needed
        /// after it: a migration once the pointer is in hand is harmless,
        /// because the answer is the same process on either core. Same fix, and
        /// the same reason, as `locks.enter_rank`/`leave_rank`.
        ///
        /// Single-core builds fold the masking away -- with one schedulable core
        /// the index is a constant and there is nothing to tear.
        pub fn get_current_process(self: *const Self) *Process {
            if (comptime !kernel.sync.percpu.smp) return self.core[hal.cpu.coreid()];
            const flags = arch.sync.save_and_disable_interrupts();
            defer arch.sync.restore_interrupts(flags);
            return self.core[hal.cpu.coreid()];
        }

        // Synchronization
        // no data access
        pub fn initialize_context_switching(_: Self) void {
            process.initialize_context_switching();
        }

        pub fn is_empty(self: *Self) bool {
            const flags = proctable_lock.lock_irqsave();
            defer proctable_lock.unlock_irqrestore(flags);
            return self.processes.first == null;
        }
    };
}
pub const ProcessManager = ProcessManagerGenerator(Scheduler);

pub var instance: ProcessManager = undefined;
var instance_initialized: bool = false;

pub fn initialize_process_manager(allocator: std.mem.Allocator) void {
    log.info("Process manager initialization...", .{});
    process.init();
    instance = ProcessManager.init(allocator);
    instance_initialized = true;
}

pub fn deinitialize_process_manager() void {
    instance.deinit();
    instance_initialized = false;
}

/// The pid running on `core`, or -1 if that core has not entered the scheduler.
/// For `/proc/cpus`. Reading another core's slot cannot tear, so the worst case
/// is the pid from either side of a switch -- which is what a sample means.
pub fn pid_on_core(core: usize) c.pid_t {
    if (!instance_initialized) return -1;
    if (core >= hal.cpu.number_of_cores()) return -1;
    if (!smp.core_schedules(core)) return -1;
    return instance.core[core].pid;
}

/// The pid of `core`'s idle process, or -1 before the idle processes exist, so a
/// reader can tell a busy core from a parked one.
pub fn idle_pid_on_core(core: usize) c.pid_t {
    if (!instance_initialized) return -1;
    if (core >= hal.cpu.number_of_cores()) return -1;
    const idle_process = instance.idle[core] orelse return -1;
    return idle_process.pid;
}

/// Whether the global `instance` has been initialized. Code that reads global
/// process/memory-pool state from contexts that may run before the process
/// manager exists (e.g. /proc files constructed during early filesystem setup,
/// or unit tests that don't spin up the manager) must guard on this — `instance`
/// is `undefined` until initialize_process_manager runs.
pub fn is_initialized() bool {
    return instance_initialized;
}

/// Adopt the process this core claimed in `schedule_next`, and return the stack
/// pointer the assembly should resume from. Runs after
/// `arch_store_registers_on_stack`, which is what makes the release inside
/// `update_current` safe. The lock is retaken for that release: the other core
/// may be scanning the table at this instant.
pub export fn process_set_next_task() *const u8 {
    // This core's first invocation is from switch_to_the_first_task; from here
    // on PendSV may drive context switches on it. Per-core, because a secondary
    // core reaches its first switch long after core 0 reached its own.
    smp.mark_core_entered_scheduler();
    if (instance._scheduler.get_next()) |task| {
        {
            const flags = proctable_lock.lock_irqsave();
            defer proctable_lock.unlock_irqrestore(flags);
            instance._scheduler.update_current();
        }
        instance.core[hal.cpu.coreid()] = task;
        smp.note_context_switch();
        // Publish whether this core now has anything to do, so the other core
        // knows whether ringing its doorbell is worth an interrupt. Here rather
        // than in the idle body, which is switched away from without running
        // again and so could never clear its own flag.
        if (instance.idle[hal.cpu.coreid()]) |idle_process| {
            if (task == idle_process) smp.mark_core_idle() else smp.mark_core_busy();
        }
        ctx_trace(.load, task.pid, @intFromPtr(task.stack_pointer()), @intFromPtr(task.get_stack_bottom()));
        return task.stack_pointer();
    }
    @panic("Context switch called without tasks available");
}

/// Take a secondary core into the scheduler. Never returns. The mirror of
/// `spawn.root_process` for a core with no root process: it claims this core's
/// idle process and performs the same first switch, after which PendSV drives
/// the core like any other. `switch_to_the_first_task` ends in `bx r0` from
/// thread mode, which is why the idle frame has to be root-shaped.
pub fn enter_scheduler_on_secondary_core() noreturn {
    // Interrupts off across the whole first switch, re-enabled by
    // `idle_process_entry`. `process_set_next_task` marks this core as
    // scheduling part-way through `switch_to_the_first_task`, before PSP is set
    // and before the CONTROL write: a SysTick in that window would have PendSV
    // store this core's context through an unset PSP. Core 0 is safe only
    // because its first switch happens when nothing else is runnable.
    arch.disable_interrupts();

    {
        // `lock_irqsave` saves the already-masked state and restores it, so
        // interrupts stay off across this.
        const flags = proctable_lock.lock_irqsave();
        defer proctable_lock.unlock_irqrestore(flags);
        const idle_process = instance.idle[hal.cpu.coreid()] orelse
            @panic("secondary core entered the scheduler with no idle process");
        _ = instance._scheduler.claim(&idle_process.node);
    }

    switch_to_the_first_task(if (config.cpu.use_fpu) 1 else 0);
    unreachable;
}

export fn get_stack_bottom() *const u8 {
    return instance.core[hal.cpu.coreid()].get_stack_bottom();
}

// Read directly from `core` without locking: this is called from the context
// switch (handler mode) where taking the context-switch lock would be unsafe.
// Returns 1 for a privileged process, 0 for an unprivileged one; the assembly
// switch path uses it to set CONTROL.nPRIV for the resumed thread.
//
// When kernel MPU protection is disabled, every scheduled process runs
// unprivileged (the historical behaviour), so this always reports unprivileged
// and the privilege distinction has no effect.
const mpu_kernel_protection = if (@hasDecl(config.process, "use_mpu_kernel_protection"))
    config.process.use_mpu_kernel_protection
else
    false;

export fn process_current_is_privileged() usize {
    if (!mpu_kernel_protection) {
        return 0;
    }
    return if (instance.core[hal.cpu.coreid()].is_privileged()) 1 else 0;
}

// Privilege to restore when the PendSV switch path RESUMES a stored context —
// the live CONTROL.nPRIV captured at store time (update_stack_pointer), not the
// static per-process flag. A process preempted inside the privileged
// thread-mode phase of a syscall must come back privileged, or its next kernel
// access (e.g. the UART STATE register in sys_read's polling loop) HardFaults
// with a MemManage DACCVIOL and the process is silently killed.
export fn process_resume_is_privileged() usize {
    if (!mpu_kernel_protection) {
        return 0;
    }
    return if (instance.core[hal.cpu.coreid()].resume_privileged) 1 else 0;
}

// Read directly from `core` without locking: this is called from the HardFault
// handler where the system is already wedged and taking the context-switch lock
// would be unsafe.
// ── Context-switch event ring ────────────────────────────────────────────────
// Diagnostic aid for the intermittent user-stack corruption (mibench_dijkstra /
// 20090113-1): the last N scheduler events, dumped by the HardFault handler so
// a crash shows what the switch machinery did just before it. Store events
// carry the PSP the outgoing context was written below; load events carry the
// incoming SP and its stack bottom; reap events carry the freed stack range.
// One ring per core: both cores call `ctx_trace` from `update_stack_pointer` on
// every switch, and a shared ring would interleave and race its counter.
// `vrestore` records a vfork stack restore: `a` is the address it copied to,
// `b` the word left at +36 -- what `process_vfork_back_here` pops into `pc`.
// Ring rather than a log line, so it costs one store and cannot shift the
// timing of the window it is measuring.
const CtxEventKind = enum(u8) { store, load, reap, vrestore };

const CtxEvent = struct {
    seq: u32 = 0,
    kind: CtxEventKind = .store,
    pid: c.pid_t = 0,
    a: usize = 0,
    b: usize = 0,
};

const CtxRing = struct {
    events: [24]CtxEvent = @splat(.{}),
    seq: u32 = 0,
};

var ctx_rings: kernel.sync.PerCpu(CtxRing) = .init(.{});

/// The parent a hand-off is switching to, handed from the Zig side to
/// `arch_restore_vfork_back_stack` across the assembly that has no room for
/// another argument. Per-core, and written with interrupts already masked, so
/// the restore names the same process the hand-off decided on rather than
/// re-deriving it from `core[coreid()]` after the scheduler may have moved on.
var vfork_restore_target: kernel.sync.PerCpu(?*Process) = .init(null);

fn ctx_trace(kind: CtxEventKind, pid: c.pid_t, a: usize, b: usize) void {
    const ring = ctx_rings.current();
    ring.seq +%= 1;
    ring.events[ring.seq % ring.events.len] = .{ .seq = ring.seq, .kind = kind, .pid = pid, .a = a, .b = b };
}

/// True when the parent may be resumed through `process_vfork_back_here`.
///
/// That entry is `pop {r4-r12, pc}` off `ctx.sp`, so it is only safe when the
/// frames there are the parent's own: either still live (the child was released
/// below them, `saved == false`) or about to be copied back. When `saved` says a
/// copy was made and nothing is left to copy, the frames belong to the child and
/// popping them branches somewhere arbitrary -- refuse instead.
///
/// The report distinguishes a frame that was already bad when saved from one
/// clobbered after the restore. Silent on the healthy path.
fn vfork_handoff_ok(site: []const u8, child_pid: c.pid_t, parent: anytype, ctx: anytype) bool {
    if (!ctx.saved) return true;

    const save = parent.vfork_save_state();
    if (save.base == ctx.sp and save.len >= 40) {
        if (save.resume_pc) |pc| {
            if (pc != 0) return true;
        }
    }
    log.err("vfork handoff[{s}]: refusing -- child={d} parent={d} ctx.sp=0x{X} base=0x{X} len={d} top=0x{X} resume_pc=0x{X}", .{
        site,      child_pid, parent.pid, ctx.sp,
        save.base, save.len,  save.top,   save.resume_pc orelse 0,
    });
    return false;
}

/// What a vfork child owes its parent when it stops needing the shared stack.
/// Three outcomes rather than an optional, because "no hand-off" splits into two
/// cases the caller has to treat differently: `.none` is an ordinary `exec` with
/// no parent parked behind it, while `.refused` leaves a parent that must never
/// be handed to the scheduler.
const VForkHandoff = union(enum) {
    /// Not a vfork child, or its context was already taken.
    none,
    /// A vfork child whose parent can no longer be resumed. Already parked by
    /// `take_vfork_handoff`; the caller's only duty is not to claim it.
    refused,
    take: struct {
        parent: *Process,
        sp: usize,
        lr: usize,
    },
};

/// Blocker token for a vfork parent that lost its resume path. Its address is
/// the whole value: `block_on` stores it and only a `wake_from` naming the same
/// address clears it, which nothing does.
var vfork_unresumable: u8 = 0;

/// Decide whether `child` may hand its core back to the parent it vforked from,
/// and take the context when it may.
///
/// Nothing here changes what the scheduler can pick, so the caller can honour a
/// refusal by simply doing nothing. That is the point of separating it: both
/// hand-off sites used to claim the parent first and validate second, and a
/// refusal then left it claimed, unblocked and never resumed -- the scheduler
/// would enter it at its stored context, which for a vfork parent is the one
/// position it must not be entered at.
///
/// Call with `proctable_lock` held. Taking the context is what makes a hand-off
/// happen at most once: `exec` and `exit` both reach for it, and a second one
/// would resume the parent by popping frames the child has since run over.
fn take_vfork_handoff(site: []const u8, child: *Process) VForkHandoff {
    const ctx = child._vfork_context orelse return .none;
    const parent = child._parent orelse {
        // `set_vfork_back_point` records a context even when it cannot find a
        // parent, so this is reachable -- which is why the two call sites no
        // longer unwrap `_parent` themselves.
        log.err("vfork handoff[{s}]: pid={d} carries a vfork context with no parent", .{ site, child.pid });
        child._vfork_context = null;
        return .none;
    };
    child._vfork_context = null;
    if (vfork_handoff_ok(site, child.pid, parent, ctx)) {
        return .{ .take = .{ .parent = parent, .sp = ctx.sp, .lr = ctx.lr } };
    }

    // The hand-off *is* this parent's resume path. `process_vfork_child`
    // suspended it in place rather than through PendSV, so its stored context
    // still names wherever it was last switched out -- a position the child has
    // since run over. With the saved frames gone there is nothing left to enter
    // it at, and the one thing that must not happen is for it to become
    // schedulable: `unblock_parent` on the exiting child would otherwise publish
    // it `Ready` and the next core to scan would resume it into that.
    //
    // So park it out of reach instead. `reevaluate_state` keeps any process with
    // a `waiting_for` Blocked, and only a `wake_from` naming this exact token
    // clears it. The process is lost either way; this makes it a stuck process
    // instead of a wild branch, and keeps its children's `_parent` valid.
    parent.block_on(&vfork_unresumable);
    log.err("vfork handoff[{s}]: parked pid={d} -- no resume path left after child={d}", .{ site, parent.pid, child.pid });
    return .refused;
}

// Called from the HardFault handler; oldest first, and every core's, because the
// interesting history is often the other core's. log.err so it is visible in the
// normal smoke configuration, where log_info is off.
export fn dump_ctx_ring() void {
    for (0..kernel.sync.percpu.core_count) |core| {
        const ring = ctx_rings.of(core);
        log.err("context-switch ring core {d} (oldest first, seq={d}):", .{ core, ring.seq });
        var i: usize = 1;
        while (i <= ring.events.len) : (i += 1) {
            const e = ring.events[(ring.seq +% i) % ring.events.len];
            if (e.seq == 0) continue;
            log.err("  [{d}] {s} pid={d} a=0x{X:0>8} b=0x{X:0>8}", .{ e.seq, @tagName(e.kind), e.pid, e.a, e.b });
        }
    }
}

export fn get_current_pid() c.pid_t {
    return instance.core[hal.cpu.coreid()].pid;
}

export fn get_stack_top() *const u8 {
    return instance.core[hal.cpu.coreid()].get_stack_top();
}

/// The highest address the current process may put a fresh stack frame at: its
/// stack top, except for a vfork child, whose stack is its parent's. Everything
/// above the parent's `vfork()` call site is the parent's live frames. The fault
/// handler builds its `_exit` frame here so a child killed mid-flight unwinds
/// inside its own half instead of over the parent's suspended frames.
export fn get_exit_frame_ceiling() *const u8 {
    const current = instance.core[hal.cpu.coreid()];
    if (current.has_stack_shared_with_parent()) {
        if (current._parent) |parent| {
            if (parent.vfork_stack_ceiling()) |ceiling| return @ptrFromInt(ceiling);
        }
    }
    return current.get_stack_top();
}

export fn update_stack_pointer(ptr: *u8, uses_fpu: u32) void {
    _ = uses_fpu;
    const current = instance.core[hal.cpu.coreid()];
    // Capture the interrupted thread's live privilege (CONTROL.nPRIV) alongside
    // its stored context. This runs in the PendSV handler; exception entry does
    // not modify CONTROL, so bit 0 still reflects the preempted thread. See
    // process_resume_is_privileged() for why the static flag is not enough.
    if (comptime builtin.cpu.arch.isThumb()) {
        var control: u32 = undefined;
        asm volatile ("mrs %[ctl], control"
            : [ctl] "=r" (control),
        );
        current.resume_privileged = (control & 1) == 0;
    }
    ctx_trace(.store, current.pid, @intFromPtr(ptr), @intFromPtr(current.get_stack_top()));
    current.set_stack_pointer(ptr);
}

/// Returns 1 when the parent's stack was saved and the child may be released on
/// its caller's stack pointer, 0 when it must be left below the parent's
/// suspended frames instead.
export fn arch_store_vfork_back_point(back_point: usize, stack_pointer: usize) u32 {
    preempt.preempt_disable();
    const saved = instance.set_vfork_back_point(back_point, stack_pointer);
    preempt.preempt_enable();
    if (!saved) {
        log.err("vfork: could not save the parent's stack; the child keeps a stale frame", .{});
    }
    return @intFromBool(saved);
}

/// Called from `context_switch.S` once it has switched to the resuming parent's
/// stack position. See `ProcessManager.restore_vfork_back_stack`.
export fn arch_restore_vfork_back_stack() void {
    instance.restore_vfork_back_stack();
}

/// Called from `context_switch.S` to close a window opened in `vfork` or
/// `prepare_exec`, both of which hand off through assembly that never returns
/// normally and so cannot use `defer`.
export fn process_unblock_context_switch() void {
    preempt.preempt_enable();
}

const StubScheduler = @import("scheduler/stub.zig").StubScheduler;

test "ProcessManager.ShouldInitializeGlobalInstance" {
    initialize_process_manager(std.testing.allocator);
    defer deinitialize_process_manager();

    try std.testing.expect(instance.is_empty());
    try std.testing.expectEqual(.ReturnToMain, instance.schedule_next());
}

test "ProcessManager.ShouldReactCorrectlyWhenIsEmpty" {
    var sut = ProcessManagerGenerator(StubScheduler).init(std.testing.allocator);
    defer sut.deinit();

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.ReturnToMain, sut.schedule_next());
    try std.testing.expectEqual(1, sut.get_next_pid().?);
    try std.testing.expectEqual(null, sut.get_process_for_pid(1));
    try std.testing.expectEqual(config.process.max_pid_value - 1, sut.get_pidmap().count());
}

fn test_entry() void {}

test "ProcessManager.ShouldCreateProcesses" {
    var sut = ProcessManagerGenerator(StubScheduler).init(std.testing.allocator);
    defer sut.deinit();

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.ReturnToMain, sut.schedule_next());

    const arg = "argument";
    try sut.create_process(4096, &test_entry, @ptrCast(&arg), "/test");
}

test "ProcessManager.ShouldUseRuntimeDefaultStackSizeWhenRequestedStackIsZero" {
    var sut = ProcessManagerGenerator(StubScheduler).init(std.testing.allocator);
    defer sut.deinit();

    sut.set_default_stack_size(32 * 1024);

    const arg = "argument";
    try sut.create_process(0, &test_entry, @ptrCast(&arg), "/test");

    const proc = sut.get_process_for_pid(1).?;
    const stack_limit = try proc.get_resource_limit(c.RLIMIT_STACK);
    try std.testing.expectEqual(@as(c.rlim_t, 32 * 1024), stack_limit.rlim_cur);
    // rlim_max is the hard ceiling (config max_stack_size); lowering the default
    // stack size only changes the soft limit (rlim_cur), never the hard max.
    try std.testing.expectEqual(@as(c.rlim_t, config.process.max_stack_size), stack_limit.rlim_max);
}

test "ProcessManager.ShouldApplyCachedDefaultLimitsToNewProcesses" {
    var sut = ProcessManagerGenerator(StubScheduler).init(std.testing.allocator);
    defer sut.deinit();

    try sut.get_runtime_configuration().set_default_resource_limit(c.RLIMIT_NOFILE, .{
        .rlim_cur = 64,
        .rlim_max = 128,
    });

    const arg = "argument";
    try sut.create_process(0, &test_entry, @ptrCast(&arg), "/test");

    const proc = sut.get_process_for_pid(1).?;
    const nofile_limit = try proc.get_resource_limit(c.RLIMIT_NOFILE);
    try std.testing.expectEqual(@as(c.rlim_t, 64), nofile_limit.rlim_cur);
    try std.testing.expectEqual(@as(c.rlim_t, 128), nofile_limit.rlim_max);
}

test "ProcessManager.ShouldRejectProcessCreationWhenNoPIDsAvailable" {
    initialize_process_manager(std.testing.allocator);
    var sut = &instance;
    defer deinitialize_process_manager();

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.ReturnToMain, sut.schedule_next());

    const arg = "argument";

    for (0..config.process.max_pid_value) |i| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/proc/{d}", .{i});
        defer std.testing.allocator.free(path);
        try sut.create_process(4096, &test_entry, @ptrCast(&arg), path);
    }

    for (1..config.process.max_pid_value + 1) |i| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/proc/{d}", .{i - 1});
        defer std.testing.allocator.free(path);
        const proc = sut.get_process_for_pid(@intCast(i));
        try std.testing.expect(proc != null);
        try std.testing.expectEqualStrings(path, proc.?.get_current_directory());
    }

    try std.testing.expectError(kernel.errno.ErrnoSet.TryAgain, sut.create_process(4096, &test_entry, @ptrCast(&arg), "/test"));
    try std.testing.expectEqual(null, sut.get_next_pid());
    var pid: c.pid_t = 0;
    var sp: usize = 0;
    var lr: usize = 0;
    var vfork_context = c.vfork_context{
        .pid = &pid,
        .sp = &sp,
        .lr = &lr,
        .is_fpu_used = 0,
    };
    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = process_set_next_task();
    try std.testing.expectError(kernel.errno.ErrnoSet.TryAgain, sut.vfork(&vfork_context));
}

test "ProcessManager.ShouldScheduleProcesses" {
    initialize_process_manager(std.testing.allocator);
    kernel.dynamic_loader.init(std.testing.allocator);
    defer kernel.dynamic_loader.deinit();
    defer deinitialize_process_manager();
    var sut = &instance;

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.ReturnToMain, sut.schedule_next());

    const arg = "argument";
    inline for (0..3) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i});
        try sut.create_process(4096, &test_entry, @ptrCast(&arg), path);
    }

    inline for (1..4) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i - 1});
        const proc = sut.get_process_for_pid(i);
        try std.testing.expect(proc != null);
        try std.testing.expectEqualStrings(path, proc.?.get_current_directory());
    }

    for (1..4) |i| {
        try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
        _ = process_set_next_task();
        try std.testing.expectEqual(@as(c_int, @intCast(i)), sut.get_current_process().pid);
    }
    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = process_set_next_task();
    try std.testing.expectEqual(1, sut.get_current_process().pid);

    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = process_set_next_task();
    try std.testing.expectEqual(2, sut.get_current_process().pid);

    // `delete_process` closes a preemption window it does not open: `sys_exit`
    // and `sys_kill` are its only real callers and both open one.
    preempt.preempt_disable();
    sut.delete_process(2, 0);

    for (1..4) |i| {
        if (i == 2) continue;
        try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
        _ = process_set_next_task();
        try std.testing.expectEqual(@as(c_int, @intCast(i)), sut.get_current_process().pid);
    }
}

test "ProcessManager.ShouldForkProcess" {
    kernel.dynamic_loader.init(std.testing.allocator);
    // defer kernel.dynamic_loader.deinit();
    initialize_process_manager(std.testing.allocator);
    defer deinitialize_process_manager();
    var sut = &instance;

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.ReturnToMain, sut.schedule_next());

    const arg = "argument";
    inline for (0..3) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i});
        try sut.create_process(4096, &test_entry, @ptrCast(&arg), path);
    }

    var pid: c.pid_t = 0;
    var lr: usize = 1234;
    var r9: usize = 5678;
    var sp: usize = 91011;
    var vfork_context = c.vfork_context{
        .pid = &pid,
        .lr = &lr,
        .r9 = &r9,
        .sp = &sp,
    };

    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = process_set_next_task();
    try std.testing.expectEqual(1, sut.get_current_process().pid);

    var child = sut.get_process_for_pid(4);
    try std.testing.expect(child == null);

    const parent = sut.get_current_process();
    try std.testing.expectEqual(0, try sut.vfork(&vfork_context));
    try std.testing.expectEqual(4, pid);

    // new process was created with new pid
    child = sut.get_process_for_pid(4);
    try std.testing.expect(child != null);

    try std.testing.expect(parent._blocked_by.first != null);
    const blocked_data: *const Process.BlockedByProcess = @fieldParentPtr("node", parent._blocked_by.first.?);
    try std.testing.expect(blocked_data.waiting_for == child.?);

    try std.testing.expect(child.?._blocks.first != null);
    const block_data: *const Process.BlockedProcessAction = @fieldParentPtr("node", child.?._blocks.first.?);
    try std.testing.expect(block_data.blocked == parent);

    // Create argv - NULL-terminated array of C string pointers (clone_exec_args
    // counts entries until the NULL sentinel, mirroring userspace argv).
    var args_storage = [_]?[*:0]const u8{
        "arg0",
        "arg1",
        null,
    };
    const argv: [*c][*c]u8 = @ptrCast(@constCast(&args_storage));

    // Create envp - NULL-terminated array of environment variable pointers
    var envp_storage = [_]?[*:0]const u8{
        "ENV0=VALUE0",
        "ENV1=VALUE1",
        null,
    };
    const envp: [*c][*c]u8 = @ptrCast(@constCast(&envp_storage));

    const FileSystemMock = @import("fs/tests/filesystem_mock.zig").FileSystemMock;
    const FileMock = @import("fs/tests/file_mock.zig").FileMock;
    const interface = @import("interface");
    kernel.fs.vfs_init(std.testing.allocator);
    defer kernel.fs.vfs_deinit();
    const fs_mock = try FileSystemMock.create(std.testing.allocator);
    const fs = fs_mock.get_interface();
    kernel.dynamic_loader.init(std.testing.allocator);
    defer kernel.dynamic_loader.deinit();

    const IoctlCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: @Tuple(&[_]type{ i32, ?*anyopaque })) !i32 {
            const cmd = args[0];
            try std.testing.expectEqual(cmd, @as(i32, @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)));

            const a = args[1];
            var attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(a.?));
            attr.is_memory_mapped = true;
            attr.mapped_address_r = ctx.?;
            return 0;
        }
    };

    var data: i32 = 10;
    const filemock = try FileMock.create(std.testing.allocator);
    _ = filemock.expectCall("ioctl")
        .invoke(&IoctlCallback.call, &data)
        .willReturn(@as(i32, 0));

    const file = filemock.get_interface();
    _ = fs_mock.expectCall("get")
        .withArgs(.{ "test", interface.mock.any{} })
        .willReturn(kernel.fs.Node.create_file(file));

    try kernel.fs.get_vfs().mount_filesystem("/", fs);
    _ = sut.schedule_next();
    _ = process_set_next_task();
    _ = sut.schedule_next();
    _ = process_set_next_task();
    _ = sut.schedule_next();
    _ = process_set_next_task();

    _ = try sut.prepare_exec("/test", argv, envp, null);

    const p = sut.get_process_for_pid(4).?;
    p.unblock_parent();
}

test "ProcessManager.ShouldWaitForProcess" {
    kernel.dynamic_loader.init(std.testing.allocator);
    initialize_process_manager(std.testing.allocator);
    defer deinitialize_process_manager();
    var sut = &instance;

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.ReturnToMain, sut.schedule_next());

    const arg = "argument";
    inline for (0..3) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i});
        try sut.create_process(4096, &test_entry, @ptrCast(&arg), path);
    }

    var pid: c.pid_t = 0;
    var lr: usize = 1234;
    var r9: usize = 5678;
    var sp: usize = 91011;
    var vfork_context = c.vfork_context{
        .pid = &pid,
        .lr = &lr,
        .r9 = &r9,
        .sp = &sp,
    };

    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = process_set_next_task();
    try std.testing.expectEqual(0, try sut.vfork(&vfork_context));
    var status: i32 = 3;
    const PendSvAction = struct {
        pub fn Call() void {
            instance.get_process_for_pid(4).?.unblock_all(0);
        }
    };
    hal.irq.impl().set_irq_action(.pendsv, PendSvAction.Call);
    try std.testing.expectEqual(4, try sut.waitpid(4, &status, 0));
    const p = sut.get_process_for_pid(4).?;
    p.unblock_parent();
    try std.testing.expectEqual(0, status);
}
