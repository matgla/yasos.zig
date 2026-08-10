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

/// Rank 70, a leaf, and `spin_irq` rather than a sleeping mutex on purpose:
/// `release_pid` is called from `schedule_next`, which runs in PendSV, where
/// blocking is not allowed. The critical sections are a bitset scan and a bit
/// flip -- microseconds -- so masking interrupts across them costs nothing
/// against the ~93 us console budget.
///
/// This replaced a `block_context_switch` window, which is not a lock: it stops
/// *this* core rescheduling and does nothing at all about a second one.
var pidmap_lock: kernel.sync.Ranked(.pidmap) = .{};

/// Rank 50: the process table itself -- `processes`, `terminate_list`, and the
/// scheduler's cursor into them.
///
/// The inventory calls this "the entire process world, read unlocked from
/// PendSV, HardFault, SVC and thread mode", and that is the reason it is
/// `spin_irq`: PendSV walks the list on every context switch, so a lock that can
/// block is not available here.
///
/// It is taken *outside* `pidmap` (70), `pagepool` (80) and `kheap` (90), which
/// is what lets `schedule_next` reap a process -- releasing its pid, its pages
/// and its kernel allocations -- with the table held. It is taken *inside*
/// `fs` (20) and `dev` (30), which is the rule that keeps filesystem work off
/// this path: `clear_fds` had to move to `delete_process` before that could be
/// true.
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
extern fn call_main(argc: i32, argv: [*c][*c]u8, address: usize, got: *const anyopaque) i32;
extern fn arch_push_hardware_registers_on_stack(lr: usize, pc: usize) void;

extern fn process_vfork_child(sp: usize, got: usize, lr: usize, is_fpu_used: usize) i32;
extern fn process_get_back_to_parent_vfork(pid: i32, sp: usize, lr: usize) i32;

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

        /// Reap the terminate list and pick the next process.
        ///
        /// `assert_held` at the head of the functions this reaches is what
        /// catches the bug review cannot: one correct only because *some*
        /// caller was believed to hold the table, and one caller does not.
        pub fn schedule_next(self: *Self) kernel.scheduler.Action {
            // Held across the reap *and* the pick: they are one decision about
            // the table, and a second core allowed between them could schedule
            // a process this one is in the middle of freeing.
            //
            // The masked window is a list walk in the common case. It is longer
            // when there is something to reap -- bitmap and heap frees, tens of
            // microseconds -- but that happens once per process death, not per
            // switch.
            const flags = proctable_lock.lock_irqsave();
            defer proctable_lock.unlock_irqrestore(flags);
            var next = self.terminate_list.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                const pool = self.get_process_memory_pool();
                log.info("schedule_next: reaping pid={d} kernel_used={d} process_pages={d} alloc_count={d}", .{ p.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size(), kernel.memory.heap.malloc.get_counter() });
                // Advance BEFORE deinit: `node` lives inside the Process struct
                // that deinit frees, so reading node.next afterwards is a
                // use-after-free that walks a dead list when two or more
                // processes are reaped in one pass.
                next = node.next;
                ctx_trace(.reap, p.pid, @intFromPtr(p.get_stack_bottom()), @intFromPtr(p.get_stack_top()));
                self._scheduler.remove_process(&p.node);
                self.terminate_list.remove(&p.node);
                self.release_pid(p.pid);
                p.deinit();
                log.info("schedule_next: reaped pid={d} kernel_used={d} process_pages={d} alloc_count={d}", .{ p.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size(), kernel.memory.heap.malloc.get_counter() });
            }

            if (self.processes.first) |first| {
                return self._scheduler.schedule_next(first);
            } else {
                return .ReturnToMain;
            }

            return .NoAction;
        }

        pub fn deinit(self: *Self) void {
            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                p.deinit();
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

        pub fn get_process_memory_pool(self: *Self) *kernel.memory.heap.ProcessMemoryPool {
            return &self._process_memory_pool;
        }

        pub fn delete_process(self: *Self, pid: c.pid_t, return_code: i32) void {

            // If a vfork child exits without calling exec, restore parent's
            // writable sections that may have been corrupted. Keyed by the
            // exiting (child) pid; a no-op if it wasn't a vfork child.
            dynamic_loader.restore_parent_writable_sections(pid);

            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                if (p.pid == pid) {
                    // fix me
                    const ctx = p._vfork_context;

                    // Close this process's files here, in its own thread
                    // context, rather than leaving them to `deinit` -- which the
                    // reaper calls from PendSV, where taking the filesystem's
                    // sleeping mutex is not allowed. See Process.clear_fds.
                    p.clear_fds();

                    // i can't remove myself on my on stack
                    dynamic_loader.release_executable(pid);
                    p.unblock_parent();
                    p.schedule_removal();
                    p.unblock_all(return_code);
                    {
                        const flags = proctable_lock.lock_irqsave();
                        defer proctable_lock.unlock_irqrestore(flags);
                        self.processes.remove(&p.node);
                        self.terminate_list.append(&p.node);
                    }

                    if (ctx != null) {
                        const parent = p._parent.?;
                        self._scheduler.set_next(&parent.node);
                        self.core[hal.cpu.coreid()] = parent;
                        arch.disable_interrupts();
                        _ = process_get_back_to_parent_vfork(pid, ctx.?.sp, ctx.?.lr);
                        return;
                    }

                    break;
                }
            }
            // Closes the window `sys_exit` / `sys_kill` opened. Released once
            // and then spun on: the release used to sit *inside* the loop, so
            // every iteration after the first was an unmatched release that the
            // old clamp absorbed. This process is never scheduled again, so the
            // loop is only here to keep re-pending the switch that takes us off
            // this stack for good.
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

        pub fn vfork(self: *Self, context: *const volatile c.vfork_context) !i32 {
            preempt.preempt_disable();
            errdefer preempt.preempt_enable();

            const current_process = self.get_current_process();
            const maybe_pid = self.get_next_pid();
            if (maybe_pid == null) {
                arch.enable_interrupts();
                return kernel.errno.ErrnoSet.TryAgain;
            }
            const new_process = current_process.vfork(&self._process_memory_pool, maybe_pid.?) catch |err| {
                log.err("vfork failed creating child for pid={d}: {s}", .{ current_process.pid, @errorName(err) });
                arch.enable_interrupts();
                return -1;
            };

            const Action = struct {
                pub fn on_process_unblock(ctx: ?*anyopaque, rc: i32) void {
                    _ = ctx;
                    _ = rc;
                }
            };

            current_process.wait_for_process(new_process, &Action.on_process_unblock, new_process) catch |err| {
                log.err("vfork failed registering wait for parent pid={d} child pid={d}: {s}", .{ current_process.pid, new_process.pid, @errorName(err) });
                arch.enable_interrupts();
                return -1;
            };

            var got: usize = 0;
            if (dynamic_loader.get_executable_for_pid(current_process.pid)) |exec| {
                if (exec.module.unique_data) |ud| {
                    if (ud.got) |got_ptr| {
                        got = @intFromPtr(got_ptr.ptr);
                    }
                }
            }
            context.pid.* = new_process.pid;

            // Save parent's writable sections before child runs on shared memory
            dynamic_loader.save_parent_writable_sections(current_process.pid, new_process.pid);

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

        pub fn set_vfork_back_point(self: *Self, back_point: usize, stack_pointer: usize) void {
            const current_process = self.core[hal.cpu.coreid()];
            const ctx = VForkContext{
                .fp = 0,
                .sp = stack_pointer,
                .lr = back_point,
            };
            current_process._vfork_context = ctx;
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

            // The window starts *here*, not at the top of the function.
            //
            // What follows rewrites this process's own stack and then hands the
            // core to its parent -- category (C): PendSV must not fire inside
            // it. Everything above is the image load, which is long (milliseconds
            // of card I/O), allocates, and reads the filesystem, and which
            // refusing to be preempted across bought nothing once the loader
            // tables, the process table and the heap each got a lock of their
            // own. Holding it up there also made a *sleeping* `loader_lock`
            // impossible: blocking with preemption disabled is a hang, so
            // `RankedMutex` refuses it.
            //
            // A plain `defer` would be wrong, and a plain manual release was
            // what the old code did and got wrong the other way: the vfork tail
            // hands off through `process_get_back_to_parent_vfork`, which never
            // returns, so a `defer` there would never run -- while every `try`
            // and the ordinary `return 0` leaked the window outright. The flag
            // covers both.
            preempt.preempt_disable();
            var preempt_held = true;
            defer if (preempt_held) preempt.preempt_enable();

            try current_process.reallocate_stack();

            // Apply the per-image heap profile now that the image + stack are
            // resident: bound dynamic growth to heap_size beyond this baseline.
            // 0xFFFFFFFF = free to grow in the shared paged pool (the default).
            current_process.set_heap_limit_bytes(executable.module.heap_size);

            try current_process.reinitialize_stack(&call_main, argc, @intFromPtr(argv_copy.argv), symbol.address, symbol.target_got_address);
            self._scheduler.set_next(&current_process._parent.?.node);
            self.core[hal.cpu.coreid()] = current_process._parent.?;

            if (current_process._vfork_context != null) {
                const ctx = current_process._vfork_context.?;
                current_process._vfork_context = null;
                current_process.unblock_parent();
                arch.disable_interrupts();
                // `process_get_back_to_parent_vfork` issues the matching
                // release itself (`bl process_unblock_context_switch` in
                // context_switch.S) once it is on the parent's stack, which is
                // also how `delete_process`'s hand-off works. Releasing here as
                // well made this the one caller that released twice.
                preempt_held = false;
                return process_get_back_to_parent_vfork(current_process.pid, ctx.sp, ctx.lr);
            }
            return 0;
        }

        pub fn get_process_for_pid(self: *Self, pid: i32) ?*Process {
            const flags = proctable_lock.lock_irqsave();
            defer proctable_lock.unlock_irqrestore(flags);
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

        pub fn waitpid(self: *Self, pid: i32, status: *i32) !i32 {
            const current_process = self.get_current_process();

            // Registration runs with preemption refused; the wait itself must
            // not, and the two used to be tangled. The old shape blocked once
            // and released inside the wait loop, so it leaked the block
            // entirely when the pid was unknown or the child had already
            // finished registering -- and released one time per loop iteration
            // when it did wait. The leak left preemption refused for the rest
            // of the process's life, which the clamp in the old
            // `unblock_context_switch` then papered over.
            {
                preempt.preempt_disable();
                defer preempt.preempt_enable();

                const maybe_process = self.get_process_for_pid(pid);
                if (maybe_process == null) {
                    status.* = current_process.child_exit_code;
                    return pid;
                }
                const p = maybe_process.?;
                if (p.state == Process.State.Terminated) {
                    status.* = current_process.child_exit_code;
                    return pid;
                }

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

            // Preemption is enabled here, which is the point: yielding is the
            // only way the child ever runs.
            while (current_process.state == Process.State.Blocked) {
                hal.irq.trigger(.pendsv);
                current_process.reevaluate_state();
            }

            status.* = current_process.child_exit_code;
            return pid;
        }

        /// The process running on this core.
        ///
        /// No window: `core[]` is per-CPU (one slot per core, written only by
        /// its own core's context switch) and a pointer-sized aligned load
        /// cannot tear. The old `block_context_switch()` pair here was two
        /// PRIMASK round-trips on one of the most-called functions in the
        /// kernel, protecting a single load.
        ///
        /// The value is stable for the caller that matters: a syscall handler
        /// asking who it is *is* the current process, and if a switch happens
        /// it is not running to observe the change.
        pub fn get_current_process(self: *const Self) *Process {
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

/// Whether the global `instance` has been initialized. Code that reads global
/// process/memory-pool state from contexts that may run before the process
/// manager exists (e.g. /proc files constructed during early filesystem setup,
/// or unit tests that don't spin up the manager) must guard on this — `instance`
/// is `undefined` until initialize_process_manager runs.
pub fn is_initialized() bool {
    return instance_initialized;
}

pub export fn process_set_next_task() *const u8 {
    // The first invocation is from switch_to_the_first_task; from here on PendSV
    // is allowed to drive context switches (see system_call.scheduler_running).
    system_call.mark_scheduler_running();
    if (instance._scheduler.get_next()) |task| {
        instance._scheduler.update_current();
        instance.core[hal.cpu.coreid()] = task;
        ctx_trace(.load, task.pid, @intFromPtr(task.stack_pointer()), @intFromPtr(task.get_stack_bottom()));
        return task.stack_pointer();
    }
    @panic("Context switch called without tasks available");
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
// Written only from handler context on one core, so a plain ring suffices.
const CtxEventKind = enum(u8) { store, load, reap };

const CtxEvent = struct {
    seq: u32 = 0,
    kind: CtxEventKind = .store,
    pid: c.pid_t = 0,
    a: usize = 0,
    b: usize = 0,
};

var ctx_ring: [24]CtxEvent = @splat(.{});
var ctx_seq: u32 = 0;

fn ctx_trace(kind: CtxEventKind, pid: c.pid_t, a: usize, b: usize) void {
    ctx_seq +%= 1;
    ctx_ring[ctx_seq % ctx_ring.len] = .{ .seq = ctx_seq, .kind = kind, .pid = pid, .a = a, .b = b };
}

// Called from the HardFault handler; oldest first. log.err so it is visible in
// the normal smoke configuration (log_info is off there).
export fn dump_ctx_ring() void {
    log.err("context-switch ring (oldest first, seq={d}):", .{ctx_seq});
    var i: usize = 1;
    while (i <= ctx_ring.len) : (i += 1) {
        const e = ctx_ring[(ctx_seq +% i) % ctx_ring.len];
        if (e.seq == 0) continue;
        log.err("  [{d}] {s} pid={d} a=0x{X:0>8} b=0x{X:0>8}", .{ e.seq, @tagName(e.kind), e.pid, e.a, e.b });
    }
}

export fn get_current_pid() c.pid_t {
    return instance.core[hal.cpu.coreid()].pid;
}

export fn get_stack_top() *const u8 {
    return instance.core[hal.cpu.coreid()].get_stack_top();
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

export fn arch_store_vfork_back_point(back_point: usize, stack_pointer: usize) void {
    preempt.preempt_disable();
    instance.set_vfork_back_point(back_point, stack_pointer);
    preempt.preempt_enable();
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

    // `delete_process` closes a preemption window it does not open -- `sys_exit`
    // and `sys_kill` are its only real callers and both open one. Calling it
    // bare would release a window nobody took, which is now a panic rather than
    // a silently clamped counter.
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
    try std.testing.expectEqual(4, try sut.waitpid(4, &status));
    const p = sut.get_process_for_pid(4).?;
    p.unblock_parent();
    try std.testing.expectEqual(0, status);
}
