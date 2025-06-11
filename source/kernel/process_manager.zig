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
        mutex: kernel.sync.Mutex,
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
                ._pid_map = std.StaticBitSet(config.process.max_pid_value).initFull(),
                .core = undefined,
                .mutex = .{},
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

        pub fn schedule_next(self: *Self) kernel.scheduler.Action {
            var next = self.terminate_list.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                const pool = self.get_process_memory_pool();
                log.info("schedule_next: reaping pid={d} kernel_used={d} process_pages={d} alloc_count={d}", .{ p.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size(), kernel.memory.heap.malloc.get_counter() });
                self._scheduler.remove_process(&p.node);
                self.terminate_list.remove(&p.node);
                self.release_pid(p.pid);
                p.deinit();
                log.info("schedule_next: reaped pid={d} kernel_used={d} process_pages={d} alloc_count={d}", .{ p.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size(), kernel.memory.heap.malloc.get_counter() });
                next = node.next;
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
            kernel.process.block_context_switch();
            defer kernel.process.unblock_context_switch();
            return self._pid_map;
        }

        fn get_next_pid(self: *Self) ?c.pid_t {
            kernel.process.block_context_switch();
            defer kernel.process.unblock_context_switch();
            const maybe_index = self._pid_map.findFirstSet();
            if (maybe_index) |index| {
                self._pid_map.unset(index);
                return @intCast(index + 1);
            }
            log.err("No more PIDs available", .{});
            return null;
        }

        fn release_pid(self: *Self, pid: c.pid_t) void {
            kernel.process.block_context_switch();
            defer kernel.process.unblock_context_switch();
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

                kernel.process.block_context_switch();
                defer kernel.process.unblock_context_switch();
                self.processes.append(&new_process.node);
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
                self.processes.append(&new_process.node);
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
            // writable sections that may have been corrupted
            dynamic_loader.restore_parent_writable_sections();

            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                if (p.pid == pid) {
                    // fix me
                    const ctx = p._vfork_context;

                    // i can't remove myself on my on stack
                    dynamic_loader.release_executable(pid);
                    p.unblock_parent();
                    p.schedule_removal();
                    p.unblock_all(return_code);
                    self.processes.remove(&p.node);
                    self.terminate_list.append(&p.node);

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
            if (!std.mem.eql(u8, "host", config.cpu.arch)) {
                while (true) {
                    kernel.process.unblock_context_switch();
                    arch.memory_barrier_release();
                    hal.irq.trigger(.pendsv);
                }
            } else {
                kernel.process.unblock_context_switch();
                arch.memory_barrier_release();
                hal.irq.trigger(.pendsv);
            }
        }

        pub fn vfork(self: *Self, context: *const volatile c.vfork_context) !i32 {
            kernel.process.block_context_switch();
            errdefer kernel.process.unblock_context_switch();

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
            dynamic_loader.save_parent_writable_sections(current_process.pid);

            self.processes.append(&new_process.node);
            self._scheduler.set_next(&new_process.node);
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

        fn clone_exec_args(allocator: std.mem.Allocator, argv: [*c][*c]u8) !struct {
            argc: usize,
            argv: [*c][*c]u8,
        } {
            var argc: usize = 0;
            while (argv[argc] != null) : (argc += 1) {}

            const argv_copy = try allocator.alloc([*c]u8, argc + 1);
            errdefer allocator.free(argv_copy);

            var cloned: usize = 0;
            errdefer {
                var i: usize = 0;
                while (i < cloned) : (i += 1) {
                    allocator.free(std.mem.span(argv_copy[i].?));
                }
            }

            while (cloned < argc) : (cloned += 1) {
                const source = std.mem.span(argv[cloned]);
                argv_copy[cloned] = @ptrCast(try allocator.dupeZ(u8, source));
            }
            argv_copy[argc] = null;

            return .{
                .argc = argc,
                .argv = @ptrCast(argv_copy.ptr),
            };
        }

        // TODO: exec on currently running process is not supported yet
        pub fn prepare_exec(self: *Self, path: []const u8, argv: [*c][*c]u8, envp: [*c][*c]u8, path_allocator: ?std.mem.Allocator) !i32 {
            kernel.process.block_context_switch();
            const current_process = self.get_current_process();

            // Restore parent's writable sections that may have been corrupted
            // by the vfork child running on shared memory before exec
            dynamic_loader.restore_parent_writable_sections();

            // TODO: move loader to struct, pass allocator to loading functions
            const executable = try dynamic_loader.load_executable(path, current_process.get_process_memory_allocator(), current_process.pid);

            // Free the path now — it's no longer needed, and this function may
            // not return normally (process_get_back_to_parent_vfork bypasses
            // all defers in the caller).
            if (path_allocator) |alloc| {
                alloc.free(path);
            }
            const exec_allocator = current_process.get_process_memory_allocator();
            const argv_copy = try clone_exec_args(exec_allocator, argv);
            const argc = argv_copy.argc;

            var envpc: usize = 0;
            while (envp[envpc] != null) : (envpc += 1) {}

            var symbol: SymbolEntry = undefined;
            if (executable.module.entry) |entry| {
                symbol = entry;
            } else if (executable.module.find_symbol("_start")) |entry| {
                symbol = entry;
            } else {
                kernel.process.unblock_context_switch();
                return -1;
            }

            try current_process.reallocate_stack();

            try current_process.reinitialize_stack(&call_main, argc, @intFromPtr(argv_copy.argv), symbol.address, symbol.target_got_address);
            self._scheduler.set_next(&current_process._parent.?.node);
            self.core[hal.cpu.coreid()] = current_process._parent.?;

            if (current_process._vfork_context != null) {
                const ctx = current_process._vfork_context.?;
                current_process._vfork_context = null;
                current_process.unblock_parent();
                arch.disable_interrupts();
                kernel.process.unblock_context_switch();
                return process_get_back_to_parent_vfork(current_process.pid, ctx.sp, ctx.lr);
            }
            return 0;
        }

        pub fn get_process_for_pid(self: *Self, pid: i32) ?*Process {
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
            kernel.process.block_context_switch();
            const current_process = self.get_current_process();
            const maybe_process = self.get_process_for_pid(pid);
            if (maybe_process) |p| {
                if (p.state == Process.State.Terminated) {
                    status.* = current_process.child_exit_code;
                    kernel.process.unblock_context_switch();
                    return pid;
                }
                const Action = struct {
                    pub fn on_process_finished(context: ?*anyopaque, rc: i32) void {
                        const s: *i32 = @ptrCast(@alignCast(context));
                        s.* = rc;
                    }
                };
                current_process.wait_for_process(p, &Action.on_process_finished, status) catch {
                    kernel.process.unblock_context_switch();
                    return -1;
                };

                while (current_process.state == Process.State.Blocked) {
                    kernel.process.unblock_context_switch();
                    hal.irq.trigger(.pendsv);
                    current_process.reevaluate_state();
                }
            }
            status.* = current_process.child_exit_code;
            return pid;
        }

        // Synchronization
        // core access - secure, different memory regions
        // interrupts - disabled during access
        pub fn get_current_process(self: *const Self) *Process {
            kernel.process.block_context_switch();
            defer kernel.process.unblock_context_switch();
            return self.core[hal.cpu.coreid()];
        }

        // Synchronization
        // no data access
        pub fn initialize_context_switching(_: Self) void {
            process.initialize_context_switching();
        }

        // Synchronization
        // this must be synchronized across interrupts and cores
        pub fn is_empty(self: *Self) bool {
            return self.processes.first == null;
        }
    };
}
pub const ProcessManager = ProcessManagerGenerator(Scheduler);

pub var instance: ProcessManager = undefined;

pub fn initialize_process_manager(allocator: std.mem.Allocator) void {
    log.info("Process manager initialization...", .{});
    process.init();
    instance = ProcessManager.init(allocator);
}

pub fn deinitialize_process_manager() void {
    instance.deinit();
}

pub export fn process_set_next_task() *const u8 {
    // The first invocation is from switch_to_the_first_task; from here on PendSV
    // is allowed to drive context switches (see system_call.scheduler_running).
    system_call.mark_scheduler_running();
    if (instance._scheduler.get_next()) |task| {
        instance._scheduler.update_current();
        instance.core[hal.cpu.coreid()] = task;
        return task.stack_pointer();
    }
    @panic("Context switch called without tasks available");
}

export fn get_stack_bottom() *const u8 {
    return instance.core[hal.cpu.coreid()].get_stack_bottom();
}

export fn get_stack_top() *const u8 {
    return instance.core[hal.cpu.coreid()].get_stack_top();
}

export fn update_stack_pointer(ptr: *u8, uses_fpu: u32) void {
    _ = uses_fpu;
    instance.core[hal.cpu.coreid()].set_stack_pointer(ptr);
}

export fn arch_store_vfork_back_point(back_point: usize, stack_pointer: usize) void {
    kernel.process.block_context_switch();
    instance.set_vfork_back_point(back_point, stack_pointer);
    kernel.process.unblock_context_switch();
}

export fn process_unblock_context_switch() void {
    kernel.process.unblock_context_switch();
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
    try std.testing.expectEqual(@as(c.rlim_t, 32 * 1024), stack_limit.rlim_max);
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

    // Create argv - array of C string pointers
    var args_storage = [_][*:0]const u8{
        "arg0",
        "arg1",
    };
    const argv: [*c][*c]u8 = @ptrCast(@constCast(&args_storage));

    // Create envp - array of environment variable pointers
    var envp_storage = [_][*:0]const u8{
        "ENV0=VALUE0",
        "ENV1=VALUE1",
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
        pub fn call(ctx: ?*const anyopaque, args: std.meta.Tuple(&[_]type{ i32, ?*anyopaque })) !i32 {
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
