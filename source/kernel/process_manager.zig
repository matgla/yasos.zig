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

const RoundRobinScheduler = @import("round_robin.zig").RoundRobin;
const process = @import("process.zig");
const Process = process.Process;
const config = @import("config");

const yasld = @import("yasld");

var log = &@import("../log/kernel_log.zig").kernel_log;

const fs = @import("fs/vfs.zig");
const IFile = @import("fs/fs.zig").IFile;
const FileMemoryMapAttributes = @import("fs/ifile.zig").FileMemoryMapAttributes;
const IoctlCommonCommands = @import("fs/ifile.zig").IoctlCommonCommands;

extern fn switch_to_next_task() void;
extern fn call_main(argc: i32, argv: [*c][*c]u8, address: usize, got: *const anyopaque) i32;

extern fn reload_current_task() void;

const ModuleContext = struct {
    path: []const u8,
    address: ?*const anyopaque,
};

fn traverse_directory(file: *IFile, context: *anyopaque) bool {
    var module_context: *ModuleContext = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, module_context.path, file.name())) {
        var attr: FileMemoryMapAttributes = .{
            .is_memory_mapped = false,
            .mapped_address_r = null,
            .mapped_address_w = null,
        };
        _ = file.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);
        if (attr.mapped_address_r) |address| {
            module_context.address = address;
            return false;
        }
    }
    return true;
}

fn file_resolver(name: []const u8) ?*const anyopaque {
    log.print("searching for dependency: {s}\n", .{name});
    var context: ModuleContext = .{
        .path = name,
        .address = null,
    };
    _ = fs.ivfs().traverse("/lib", traverse_directory, &context);
    if (context.address) |address| {
        return address;
    }
    return null;
}

pub const ProcessManager = struct {
    pub const ContainerType = std.DoublyLinkedList(Process);
    pub const ProcessType = Process;
    const Self = @This();

    processes: ContainerType,
    scheduler: RoundRobinScheduler(Self),
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) Self {
        return Self{
            .processes = .{},
            .scheduler = .{},
            .allocator = allocator,
        };
    }

    pub fn set_scheduler(self: *Self, scheduler: RoundRobinScheduler(Self)) void {
        self.scheduler = scheduler;
    }

    pub fn create_process(self: *Self, stack_size: u32, process_entry: anytype, args: anytype) !void {
        var node = try self.allocator.create(ContainerType.Node);
        node.data = try Process.create(self.allocator, stack_size, process_entry, args);
        return self.processes.append(node);
    }

    pub fn delete_process(self: *Self, pid: u32) void {
        var it = self.processes.first;
        while (it) |p| : (it = p.next) {
            if (p.data.pid == pid) {
                p.data.unblock_parent();
                const allocator = p.data._allocator;
                p.data.deinit();
                self.processes.remove(p);
                allocator.destroy(p);
                if (self.scheduler.schedule_next()) {
                    switch_to_next_task();
                } else {
                    @panic("ProcessManager: No process to schedule\n");
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

    pub fn vfork(self: *Self, lr: usize, result: usize) i32 {
        var node = self.allocator.create(ContainerType.Node) catch {
            return -1;
        };
        const maybe_current_process = self.scheduler.get_current();
        if (maybe_current_process) |current_process| {
            node.data = current_process.vfork(lr, result) catch {
                return -1;
            };

            log.print("current process pid: {d}\n", .{current_process.pid});
            current_process.wait_for_process(&node.data) catch {
                return -1;
            };
            self.processes.append(node);
            self.dump_processes(log);
            // switch without context switch
            self.scheduler.current = node;
            self.dump_processes(log);

            return 0; //@intCast(node.data.pid);
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

    pub fn prepare_exec(self: *Self, path: []const u8, argv: [*c][*c]u8, envp: [*c][*c]u8) i32 {
        const symbols = [_]yasld.SymbolEntry{};
        const environment = yasld.Environment{
            .symbols = &symbols,
        };
        const maybe_current_process = self.scheduler.get_current();
        if (maybe_current_process) |p| {
            // TODO: move loader to struct, pass allocator to loading functions
            const loader = yasld.Loader.create(p.memory_pool_allocator.std_allocator(), environment, &file_resolver);
            const maybe_file = fs.ivfs().get(path);
            if (maybe_file) |f| {
                var attr: FileMemoryMapAttributes = .{
                    .is_memory_mapped = false,
                    .mapped_address_r = null,
                    .mapped_address_w = null,
                };
                _ = f.ioctl(@intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus), &attr);

                const executable = loader.load_executable(attr.mapped_address_r.?, log) catch |err| {
                    log.print("Executable loading failed with error: {s}\n", .{@errorName(err)});
                    return -1;
                };
                var argc: usize = 0;
                while (argv[argc] != null) : (argc += 1) {}

                var envpc: usize = 0;
                while (envp[envpc] != null) : (envpc += 1) {}

                var symbol: usize = 0;
                if (executable.module.entry) |entry| {
                    symbol = entry;
                } else if (executable.module.find_symbol("_start")) |entry| {
                    symbol = entry;
                } else {
                    return -1;
                }

                p.unblock_parent();
                p.reinitialize_stack(&call_main, argc, @intFromPtr(argv), symbol);
                self.dump_processes(log);

                // switch to me
                reload_current_task();

                return 0;
            } else {
                return -1;
            }
        }
        return -1;
    }

    pub fn waitpid(_: Self, _: i32, _: *i32) i32 {
        return -1;
    }

    // This must take asking core into consideration since, more than one processes are going in the parallel
    pub fn get_current_process(self: Self) ?*Process {
        return self.scheduler.get_current();
    }

    pub fn initialize_context_switching(_: Self) void {
        process.initialize_context_switching();
    }
};

extern fn context_switch_get_psp() usize;
extern fn context_switch_push_registers_to_stack(stack_pointer: *u8) *u8;

pub var instance: ProcessManager = undefined;

pub fn initialize_process_manager(allocator: std.mem.Allocator) void {
    instance = ProcessManager.create(allocator);
}

export fn get_next_task() *const u8 {
    if (instance.scheduler.get_next()) |task| {
        instance.scheduler.update_current();
        return task.stack_pointer();
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
