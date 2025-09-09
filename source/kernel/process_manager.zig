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
else
    @compileError("Unsupported scheduler type");

extern fn switch_to_next_task() void;
extern fn call_main(argc: i32, argv: [*c][*c]u8, address: usize, got: *const anyopaque) i32;

extern fn reload_current_task() void;

extern var sp_call_fpu: bool;

fn ProcessManagerGenerator(comptime SchedulerGeneratorType: anytype) type {
    return struct {
        pub const ContainerType = std.DoublyLinkedList;
        pub const ProcessType = Process;
        const Self = @This();
        const SchedulerType = SchedulerGeneratorType(Self);

        processes: ContainerType,
        allocator: std.mem.Allocator,
        scheduler: SchedulerType,
        _process_memory_pool: kernel.memory.heap.ProcessMemoryPool,

        pub fn init(allocator: std.mem.Allocator) Self {
            log.debug("Using scheduler '{s}'", .{SchedulerGeneratorType(Self).Name});
            const processes_memory_pool = kernel.memory.heap.ProcessMemoryPool.init(allocator) catch |err| {
                log.err("Processes memory pool initialization failed: '{s}'", .{@errorName(err)});
                unreachable;
            };

            return Self{
                .processes = .{},
                .allocator = allocator,
                .scheduler = SchedulerType{},
                ._process_memory_pool = processes_memory_pool,
            };
        }

        pub fn deinit(self: *Self) void {
            self._process_memory_pool.deinit();
            var next = self.processes.first;
            while (next) |node| {
                const p: *Process = @fieldParentPtr("node", node);
                p.deinit();
                next = node.next;
            }
        }

        pub fn create_process(self: *Self, stack_size: u32, process_entry: anytype, args: anytype, cwd: []const u8) !void {
            var new_process = try Process.init(self.allocator, stack_size, process_entry, args, cwd, &self._process_memory_pool, null);
            self.processes.append(&new_process.node);
        }

        pub fn get_process_memory_pool(self: Self) kernel.memory.heap.ProcessMemoryPool {
            return self._process_memory_pool;
        }

        pub fn delete_process(self: *Self, pid: u32, return_code: i32) void {
            var next = self.processes.first;
            var should_restore_parent = false;
            defer if (should_restore_parent) {
                hal.irq.trigger(.pendsv);
                //reload_current_task();
            };
            while (next) |node| {
                const p: *Process = @fieldParentPtr("node", node);
                next = node.next;
                if (p.pid == pid) {
                    const has_shared_stack = p.has_stack_shared_with_parent();
                    p.unblock_all(return_code);
                    if (has_shared_stack) {
                        _ = p.release_parent_after_getting_freedom();
                        should_restore_parent = true;
                    }
                    self.processes.remove(&p.node);
                    dynamic_loader.release_executable(pid);
                    p.deinit();
                    self.allocator.destroy(p);
                    if (self.scheduler.current == &p.node) {
                        self.scheduler.current = null;
                        if (self.processes.len() == 0) {
                            var data: u32 = 0;
                            _ = handlers.sys_stop_root_process(&data) catch {
                                @panic("ProcessManager: can't get back to main");
                            };
                        }

                        // if (self.scheduler.schedule_next()) {
                        //     switch_to_next_task();
                        // } else {
                        //     @panic("ProcessManager: No process to schedule");
                        // }
                        hal.irq.trigger(.pendsv);
                    }
                    break;
                }
            }
        }

        pub fn dump_processes(self: Self, out_stream: anytype) void {
            var it = self.processes.first;
            out_stream.print("  PID     STATE      PRIO     STACK    CPU  \n", .{});
            while (it) |node| : (it = node.next) {
                const active = if (node == self.scheduler.current) "*" else " ";
                out_stream.print("{d: >5}{s}   {s: <8}   {d: <4}  {d}/{d} B   {d}\n", .{
                    node.data.pid,
                    active,
                    std.enums.tagName(Process.State, node.data.state) orelse "?",
                    node.data.priority,
                    node.data.stack_usage(),
                    node.data.stack.len,
                    node.data.current_core,
                });
            }
        }

        pub fn reevaluate_state(_: *Self, p: *Process) void {
            if (p.waiting_for != null) {
                p.state = Process.State.Blocked;
                return;
            }
            if (p.blocked_by_process != null) {
                p.state = Process.State.Blocked;
                return;
            }
            p.state = Process.State.Ready;
        }

        pub fn vfork(self: *Self, context: *const volatile c.vfork_context) !i32 {
            const maybe_current_process = self.scheduler.get_current();
            if (maybe_current_process) |current_process| {
                const new_process = current_process.vfork(&self._process_memory_pool, context) catch {
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
            const maybe_current_process = self.scheduler.get_current();
            if (maybe_current_process) |p| {
                // TODO: move loader to struct, pass allocator to loading functions
                const executable = try dynamic_loader.load_executable(path, p.get_memory_allocator(), p.get_process_memory_allocator(), p.pid);
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
                const p: *Process = @fieldParentPtr("node", node);
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
                    // switch_to_next_task();
                    hal.irq.trigger(.pendsv);
                }
            }

            return 0;
        }

        // This must take asking core into consideration since, more than one processes are going in the parallel
        pub fn get_current_process(self: *const Self) ?*Process {
            return self.scheduler.get_current();
        }

        pub fn initialize_context_switching(_: Self) void {
            process.initialize_context_switching();
        }

        pub fn is_empty(self: Self) bool {
            return self.processes.len() == 0;
        }
    };
}
pub const ProcessManager = ProcessManagerGenerator(Scheduler);

pub var instance: ProcessManager = undefined;

pub fn initialize_process_manager(allocator: std.mem.Allocator) void {
    log.info("Process manager initialization...", .{});
    process.init();
    instance = ProcessManager.init(allocator);
    instance.scheduler.manager = &instance;
}

pub fn deinitialize_process_manager() void {
    instance.deinit();
}

export fn get_next_task() *const u8 {
    if (instance.scheduler.get_next()) |task| {
        instance.scheduler.update_current();
        return task.stack_pointer();
    }

    @panic("Context switch called without tasks available");
}

export fn get_stack_bottom() *const u8 {
    if (instance.scheduler.get_current()) |task| {
        return task.get_stack_bottom();
    }

    @panic("Context switch called without tasks available");
}

export fn get_current_task() *const u8 {
    if (instance.scheduler.get_current()) |task| {
        return task.stack_pointer();
    }

    @panic("Context switch called without tasks available");
}

export fn update_stack_pointer(ptr: *u8) void {
    if (instance.scheduler.get_current()) |task| {
        task.set_stack_pointer(ptr);
    }
}
