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
const Process = process.Process;
const log = std.log.scoped(.process_manager);
const dynamic_loader = @import("modules.zig");
const SymbolEntry = @import("yasld").SymbolEntry;
const system_call = @import("interrupts/system_call.zig");
const c = @import("libc_imports").c;
const handlers = @import("interrupts/syscall_handlers.zig");

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

extern fn reload_current_task() void;

extern var sp_call_fpu: bool;

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
            };
        }

        pub fn schedule_next(self: *Self) kernel.scheduler.Action {
            if (self.processes.first) |first| {
                return self._scheduler.schedule_next(first);
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
            return self._pid_map;
        }

        fn get_next_pid(self: *Self) ?c.pid_t {
            const maybe_index = self._pid_map.findFirstSet();
            if (maybe_index) |index| {
                self._pid_map.unset(index);
                return @intCast(index + 1);
            }
            log.err("No more PIDs available", .{});
            return null;
        }

        fn release_pid(self: *Self, pid: c.pid_t) void {
            if (pid > 0 and pid < config.process.max_pid_value) {
                self._pid_map.set(@intCast(pid - 1));
            }
        }

        pub fn create_process(self: *Self, stack_size: u32, process_entry: anytype, args: anytype, cwd: []const u8) !void {
            const maybe_pid = self.get_next_pid();
            if (maybe_pid) |pid| {
                var new_process = try Process.init(self.allocator, stack_size, process_entry, args, cwd, &self._process_memory_pool, null, pid);
                self.processes.append(&new_process.node);
                return;
            }
            return kernel.errno.ErrnoSet.TryAgain;
        }

        pub fn get_process_memory_pool(self: *Self) *kernel.memory.heap.ProcessMemoryPool {
            return &self._process_memory_pool;
        }

        pub fn delete_process(self: *Self, pid: c.pid_t, return_code: i32) void {
            var next = self.processes.first;
            var should_restore_parent = false;
            defer if (should_restore_parent) {
                hal.irq.trigger(.pendsv);
                //reload_current_task();
            };
            while (next) |node| {
                const p: *Process = @alignCast(@fieldParentPtr("node", node));
                next = node.next;
                if (p.pid == pid) {
                    const has_shared_stack = p.has_stack_shared_with_parent();
                    self.release_pid(pid);
                    p.unblock_all(return_code);
                    if (has_shared_stack) {
                        _ = p.release_parent_after_getting_freedom();
                        should_restore_parent = true;
                    }
                    self.processes.remove(&p.node);
                    dynamic_loader.release_executable(pid);
                    p.deinit();
                    // self.allocator.destroy(p);
                    self._scheduler.remove_process(&p.node);
                    if (self.processes.first == null) {
                        var data: u32 = 0;
                        _ = handlers.sys_stop_root_process(&data) catch {
                            @panic("ProcessManager: can't get back to main");
                        };
                    }

                    hal.irq.trigger(.pendsv);
                    break;
                }
            }
        }

        pub fn vfork(self: *Self, context: *const volatile c.vfork_context) !i32 {
            const maybe_current_process = self._scheduler.get_current();
            if (maybe_current_process) |current_process| {
                const maybe_pid = self.get_next_pid();
                if (maybe_pid == null) {
                    return kernel.errno.ErrnoSet.TryAgain;
                }
                const new_process = current_process.vfork(&self._process_memory_pool, context, maybe_pid.?) catch {
                    return -1;
                };

                const Action = struct {
                    pub fn on_process_unblock(ctx: ?*anyopaque, rc: i32) void {
                        _ = ctx;
                        _ = rc;
                    }
                };

                current_process.wait_for_process(new_process, &Action.on_process_unblock, new_process) catch {
                    return -1;
                };

                self.processes.append(&new_process.node);
                context.pid.* = 0;
                hal.irq.trigger(.pendsv);
                return 0;
            }
            return -1;
        }

        // load executable into process

        pub const ExecuteContext = struct {
            symbol: usize,
            argc: i32,
            argv: [*c][*c]u8,
            envp: [*c][*c]u8,
            envpc: i32,
        };

        pub fn prepare_exec(self: *Self, path: []const u8, argv: [*c][*c]u8, envp: [*c][*c]u8) !i32 {
            var should_restore_parent = false;
            defer if (should_restore_parent) {
                hal.irq.trigger(.pendsv);
                // reload_current_task();
            };
            const maybe_current_process = self._scheduler.get_current();
            if (maybe_current_process) |p| {
                // TODO: move loader to struct, pass allocator to loading functions
                const executable = try dynamic_loader.load_executable(path, p.get_process_memory_allocator(), p.pid);
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
                    return -1;
                }

                _ = p.release_parent_after_getting_freedom();
                p.reinitialize_stack(&call_main, argc, @intFromPtr(argv), symbol.address, symbol.target_got_address, sp_call_fpu);
                should_restore_parent = true;
                return 0;
            }
            return -1;
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
            const maybe_current_process = self.get_current_process();
            if (maybe_current_process) |current_process| {
                const maybe_process = self.get_process_for_pid(pid);
                if (maybe_process) |p| {
                    const Action = struct {
                        pub fn on_process_finished(context: ?*anyopaque, rc: i32) void {
                            const s: *i32 = @ptrCast(@alignCast(context));
                            s.* = rc;
                        }
                    };
                    current_process.wait_for_process(p, &Action.on_process_finished, status) catch {
                        return -1;
                    };
                    hal.irq.trigger(.pendsv);
                }
            }

            return 0;
        }

        pub fn get_current_process(self: *const Self) ?*Process {
            return self._scheduler.get_current();
        }

        pub fn initialize_context_switching(_: Self) void {
            process.initialize_context_switching();
        }

        pub fn is_empty(self: Self) bool {
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

pub export fn get_next_task() *const u8 {
    if (instance._scheduler.get_next()) |task| {
        instance._scheduler.update_current();
        return task.stack_pointer();
    }

    @panic("Context switch called without tasks available");
}

export fn get_stack_bottom() *const u8 {
    if (instance._scheduler.get_current()) |task| {
        return task.get_stack_bottom();
    }

    @panic("Context switch called without tasks available");
}

export fn get_current_task() *const u8 {
    if (instance._scheduler.get_current()) |task| {
        return task.stack_pointer();
    }

    @panic("Context switch called without tasks available");
}

export fn update_stack_pointer(ptr: *u8) void {
    if (instance._scheduler.get_current()) |task| {
        task.set_stack_pointer(ptr);
    }
}

const StubScheduler = @import("scheduler/stub.zig").StubScheduler;

test "ProcessManager.ShouldInitializeGlobalInstance" {
    initialize_process_manager(std.testing.allocator);
    defer deinitialize_process_manager();

    try std.testing.expect(instance.is_empty());
    try std.testing.expectEqual(.NoAction, instance.schedule_next());
    try std.testing.expect(instance.get_current_process() == null);
}

test "ProcessManager.ShouldReactCorrectlyWhenIsEmpty" {
    var sut = ProcessManagerGenerator(StubScheduler).init(std.testing.allocator);
    defer sut.deinit();

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.NoAction, sut.schedule_next());
    try std.testing.expectEqual(null, sut.get_current_process());
    try std.testing.expectEqual(1, sut.get_next_pid().?);
    try std.testing.expectEqual(null, sut.get_process_for_pid(1));
    try std.testing.expectEqual(config.process.max_pid_value - 1, sut.get_pidmap().count());
}

fn test_entry() void {}

test "ProcessManager.ShouldCreateProcesses" {
    var sut = ProcessManagerGenerator(StubScheduler).init(std.testing.allocator);
    defer sut.deinit();

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.NoAction, sut.schedule_next());

    const arg = "argument";
    try sut.create_process(4096, &test_entry, &arg, "/test");
}

test "ProcessManager.ShouldRejectProcessCreationWhenNoPIDsAvailable" {
    initialize_process_manager(std.testing.allocator);
    var sut = &instance;
    defer deinitialize_process_manager();

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.NoAction, sut.schedule_next());

    const arg = "argument";

    for (0..config.process.max_pid_value) |i| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/proc/{d}", .{i});
        defer std.testing.allocator.free(path);
        try sut.create_process(4096, &test_entry, &arg, path);
    }

    for (1..config.process.max_pid_value + 1) |i| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "/proc/{d}", .{i - 1});
        defer std.testing.allocator.free(path);
        const proc = sut.get_process_for_pid(@intCast(i));
        try std.testing.expect(proc != null);
        try std.testing.expectEqualStrings(path, proc.?.get_current_directory());
    }

    try std.testing.expectError(kernel.errno.ErrnoSet.TryAgain, sut.create_process(4096, &test_entry, &arg, "/test"));
    try std.testing.expectEqual(null, sut.get_next_pid());
    var pid: c.pid_t = 0;
    var vfork_context = c.vfork_context{
        .pid = &pid,
    };
    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = get_next_task();
    try std.testing.expectError(kernel.errno.ErrnoSet.TryAgain, sut.vfork(&vfork_context));
}

test "ProcessManager.ShouldScheduleProcesses" {
    initialize_process_manager(std.testing.allocator);
    kernel.dynamic_loader.init(std.testing.allocator);
    defer kernel.dynamic_loader.deinit();
    defer deinitialize_process_manager();
    var sut = &instance;

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.NoAction, sut.schedule_next());

    const arg = "argument";
    inline for (0..3) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i});
        try sut.create_process(4096, &test_entry, &arg, path);
    }

    inline for (1..4) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i - 1});
        const proc = sut.get_process_for_pid(i);
        try std.testing.expect(proc != null);
        try std.testing.expectEqualStrings(path, proc.?.get_current_directory());
    }

    for (1..4) |i| {
        try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
        _ = get_next_task();
        try std.testing.expect(sut.get_current_process() != null);
        try std.testing.expectEqual(@as(c_int, @intCast(i)), sut.get_current_process().?.pid);
    }
    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = get_next_task();
    try std.testing.expect(sut.get_current_process() != null);
    try std.testing.expectEqual(1, sut.get_current_process().?.pid);

    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = get_next_task();
    try std.testing.expect(sut.get_current_process() != null);
    try std.testing.expectEqual(2, sut.get_current_process().?.pid);

    sut.delete_process(2, 0);
    try std.testing.expectEqual(null, sut.get_current_process());

    for (1..4) |i| {
        if (i == 2) continue;
        try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
        _ = get_next_task();
        try std.testing.expect(sut.get_current_process() != null);
        try std.testing.expectEqual(@as(c_int, @intCast(i)), sut.get_current_process().?.pid);
    }
}

test "ProcessManager.ShouldForkProcess" {
    initialize_process_manager(std.testing.allocator);
    defer deinitialize_process_manager();
    var sut = &instance;

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.NoAction, sut.schedule_next());

    const arg = "argument";
    inline for (0..3) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i});
        try sut.create_process(4096, &test_entry, &arg, path);
    }

    var pid: c.pid_t = 0;
    var vfork_context = c.vfork_context{
        .pid = &pid,
    };

    try std.testing.expectEqual(-1, sut.vfork(&vfork_context));
    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = get_next_task();
    try std.testing.expect(sut.get_current_process() != null);
    try std.testing.expectEqual(1, sut.get_current_process().?.pid);

    var child = sut.get_process_for_pid(4);
    try std.testing.expect(child == null);

    try std.testing.expectEqual(0, try sut.vfork(&vfork_context));
    try std.testing.expectEqual(0, pid);

    // new process was created with new pid
    child = sut.get_process_for_pid(4);
    try std.testing.expect(child != null);

    const current = sut.get_current_process().?;
    try std.testing.expect(current._blocked_by.first != null);
    const blocked_data: *const Process.BlockedByProcess = @fieldParentPtr("node", current._blocked_by.first.?);
    try std.testing.expect(blocked_data.waiting_for == child.?);

    try std.testing.expect(child.?._blocks.first != null);
    const block_data: *const Process.BlockedProcessAction = @fieldParentPtr("node", child.?._blocks.first.?);
    try std.testing.expect(block_data.blocked == current);

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
    _ = get_next_task();
    _ = sut.schedule_next();
    _ = get_next_task();
    _ = sut.schedule_next();
    _ = get_next_task();

    _ = try sut.prepare_exec("/test", argv, envp);

    const p = sut.get_process_for_pid(4).?;
    p.unblock_parent();
}

test "ProcessManager.ShouldReturnStackForExternalUse" {
    var sut = ProcessManagerGenerator(StubScheduler).init(std.testing.allocator);
    defer sut.deinit();

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.NoAction, sut.schedule_next());

    const arg = "argument";
    try sut.create_process(4096, &test_entry, &arg, "/test");
    _ = sut.schedule_next();
    var stack_pointer: u8 = 123;
    update_stack_pointer(&stack_pointer);
    const task_ptr = get_current_task();
    try std.testing.expectEqual(task_ptr, &stack_pointer);
    const stack_bottom = get_stack_bottom();
    try std.testing.expectEqual(@as(*const u8, @ptrFromInt(@intFromPtr(task_ptr) + 0x1000)), stack_bottom);
}

test "ProcessManager.ShouldWaitForProcess" {
    initialize_process_manager(std.testing.allocator);
    defer deinitialize_process_manager();
    var sut = &instance;

    try std.testing.expect(sut.is_empty());
    try std.testing.expectEqual(.NoAction, sut.schedule_next());

    const arg = "argument";
    inline for (0..3) |i| {
        const path = std.fmt.comptimePrint("/proc/{d}", .{i});
        try sut.create_process(4096, &test_entry, &arg, path);
    }

    var pid: c.pid_t = 0;
    var vfork_context = c.vfork_context{
        .pid = &pid,
    };

    try std.testing.expectEqual(.StoreAndSwitch, sut.schedule_next());
    _ = get_next_task();
    try std.testing.expectEqual(0, try sut.vfork(&vfork_context));
    var status: i32 = 3;
    try std.testing.expectEqual(0, try sut.waitpid(4, &status));
    const p = sut.get_process_for_pid(4).?;
    p.unblock_parent();
    try std.testing.expectEqual(0, status);
}
