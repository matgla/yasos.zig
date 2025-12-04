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
            };
        }

        pub fn schedule_next(self: *Self) kernel.scheduler.Action {
            var next = self.terminate_list.first;
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                self._scheduler.remove_process(&p.node);
                self.terminate_list.remove(&p.node);
                self.release_pid(p.pid);
                p.deinit();
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
                var new_process = try Process.init(self.allocator, stack_size, process_entry, args, cwd, &self._process_memory_pool, null, pid, false);

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
                var new_process = try Process.init(self.allocator, stack_size, process_entry, args, cwd, &self._process_memory_pool, null, pid, true);
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
            while (true) {
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
            const new_process = current_process.vfork(&self._process_memory_pool, maybe_pid.?) catch {
                arch.enable_interrupts();
                return -1;
            };

            const Action = struct {
                pub fn on_process_unblock(ctx: ?*anyopaque, rc: i32) void {
                    _ = ctx;
                    _ = rc;
                }
            };

            current_process.wait_for_process(new_process, &Action.on_process_unblock, new_process) catch {
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

        // TODO: exec on currently running process is not supported yet
        pub fn prepare_exec(self: *Self, path: []const u8, argv: [*c][*c]u8, envp: [*c][*c]u8) !i32 {
            kernel.process.block_context_switch();
            const current_process = self.get_current_process();
            // TODO: move loader to struct, pass allocator to loading functions
            const executable = try dynamic_loader.load_executable(path, current_process.get_process_memory_allocator(), current_process.pid);
            var argc: usize = 0;
            while (argv[argc] != null) : (argc += 1) {}

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

            try current_process.reinitialize_stack(&call_main, argc, @intFromPtr(argv), symbol.address, symbol.target_got_address);
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

    _ = try sut.prepare_exec("/test", argv, envp);

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
