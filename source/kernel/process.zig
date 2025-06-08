//
// process.zig
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

const c = @import("../libc_imports.zig").c;
const log = &@import("../log/kernel_log.zig").kernel_log;

const config = @import("config");
const arch_process = @import("../arch/arch.zig").process;

const Semaphore = @import("semaphore.zig").Semaphore;
const IFile = @import("fs/ifile.zig").IFile;
const process_memory_pool = @import("process_memory_pool.zig");
const ProcessPageAllocator = @import("malloc.zig").ProcessPageAllocator;
const system_call = @import("interrupts/system_call.zig");

var pid_counter: u32 = 0;

pub fn init() void {
    arch_process.init();
}

extern fn context_switch_return_pop_single() void;

fn exit_handler() void {
    system_call.trigger(c.sys_exit, null, null);
}

extern fn reload_current_task() void;

pub fn ProcessInterface(comptime implementation: anytype) type {
    return struct {
        const Self = @This();
        const stack_marker: u32 = 0xdeadbeef;
        const FileHandle = struct {
            file: IFile,
            path: [config.fs.max_path_length]u8,
            diriter: ?IFile,
        };

        state: State,
        priority: u8,
        impl: implementation,
        pid: u32,
        stack: []align(8) u8,
        stack_position: *u8,
        _allocator: std.mem.Allocator,
        current_core: u8,
        waiting_for: ?*const Semaphore = null,
        fds: std.AutoHashMap(u16, FileHandle),
        blocked_by_process: ?*Self = null,
        blocks_process: ?*Self = null,
        memory_pool_allocator: ProcessPageAllocator,
        has_own_stack: bool = true,
        cwd: []u8,
        node: std.DoublyLinkedList.Node,

        pub const State = enum(u2) {
            Ready,
            Blocked,
            Running,
            Terminated,
        };

        pub fn create(allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, _: anytype, cwd: []const u8) !*Self {
            pid_counter += 1;
            const process = try allocator.create(Self);

            var memory_pool = ProcessPageAllocator.create(pid_counter);
            const stack: []align(8) u8 = try memory_pool.std_allocator().alignedAlloc(u8, .@"8", stack_size);

            if (comptime config.process.use_stack_overflow_detection) {
                @memcpy(stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
            }
            const stack_position = implementation.prepare_process_stack(stack, &exit_handler, process_entry, null);
            const cwd_handle = try allocator.alloc(u8, cwd.len + 1);
            @memcpy(cwd_handle[0..cwd.len], cwd);
            cwd_handle[cwd.len] = 0;

            process.* = .{
                .state = State.Ready,
                .priority = 0,
                .impl = .{},
                .pid = pid_counter,
                .stack = stack,
                .stack_position = stack_position,
                ._allocator = allocator,
                .current_core = 0,
                .fds = std.AutoHashMap(u16, FileHandle).init(allocator),
                .blocked_by_process = null,
                .blocks_process = null,
                .memory_pool_allocator = memory_pool,
                .has_own_stack = true,
                .cwd = cwd_handle,
                .node = .{},
            };
            return process;
        }

        // this is full copy of the process, so it shares the same stack
        // stack relocation impossible without MMU
        pub fn vfork(self: *Self, lr: usize, result: usize) !*Self {
            _ = lr;
            _ = result;
            // allocate stack copy
            const process = try self._allocator.create(Self);
            pid_counter += 1;
            var memory_pool = ProcessPageAllocator.create(pid_counter);
            const stack: []align(8) u8 = try memory_pool.std_allocator().alignedAlloc(u8, .@"8", self.stack.len);

            const stack_position = self.stack_position;
            // _ = arch_process.dump_registers_on_stack(result, pid_counter, lr, @intFromPtr(&context_switch_return_pop_single));
            @memcpy(stack, self.stack);
            const parent_stack = self.stack;
            self.stack = stack;
            self.has_own_stack = false;
            const cwd_handle = try self._allocator.alloc(u8, self.cwd.len);
            @memcpy(cwd_handle, self.cwd);
            process.* = .{
                .state = State.Ready,
                .priority = self.priority,
                .impl = .{},
                .pid = pid_counter,
                .stack = parent_stack,
                .stack_position = stack_position,
                ._allocator = self._allocator,
                .current_core = 0,
                .fds = try self.fds.clone(),
                .blocked_by_process = self.blocked_by_process,
                .blocks_process = self.blocks_process,
                .memory_pool_allocator = memory_pool,
                .has_own_stack = false,
                .cwd = cwd_handle,
                .node = .{},
            };
            return process;
        }

        pub fn deinit(self: *Self) void {
            self.memory_pool_allocator.std_allocator().free(self.stack);
            self.memory_pool_allocator.release_pages();
            self.fds.deinit();
            self._allocator.free(self.cwd);
        }

        pub fn change_directory(self: *Self, path: []const u8) !void {
            const cwd_handle = try std.fs.path.resolvePosix(self._allocator, &.{path});
            self._allocator.free(self.cwd);
            self.cwd = cwd_handle;
        }

        pub fn get_current_directory(self: Self) []const u8 {
            return self.cwd;
        }

        pub fn reinitialize_stack(self: *Self, process_entry: anytype, argc: usize, argv: usize, symbol: usize, got: usize) void {
            if (comptime config.process.use_stack_overflow_detection) {
                @memcpy(self.stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
            }
            const args = [_]usize{
                argc,
                argv,
                symbol,
                got,
            };
            self.stack_position = implementation.prepare_process_stack(self.stack, &exit_handler, process_entry, args[0..4]);
        }

        pub fn validate_stack(self: Self) bool {
            if (!config.process.use_stack_overflow_detection) @compileError("Stack overflow detection is disabled in config!");
            return std.mem.eql(u8, self.stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
        }

        pub fn stack_pointer(self: Self) *const u8 {
            if (config.process.use_stack_overflow_detection) {
                if (!self.validate_stack()) {
                    if (!config.process.use_mpu_stack_protection) {
                        @panic("Stack overlflow occured, please reset");
                    } else {
                        @panic("TODO: implement process kill here");
                    }
                }
            }
            return self.stack_position;
        }

        pub fn set_stack_pointer(self: *Self, ptr: *u8) void {
            // if the process is using its parent stack, then we have to copy stack to parent
            // and set stack position to the freshly pushed registers
            if (!self.has_own_stack) {
                // temporary hack
                if (self.blocked_by_process) |p| {
                    const diff = @intFromPtr(ptr) - @intFromPtr(p.stack_position);
                    self.stack_position = @ptrFromInt(@intFromPtr(self.stack_position) + diff);
                    @memcpy(self.stack, p.stack);
                    p.stack_position = ptr;
                }
            } else {
                self.stack_position = ptr;
            }
        }

        pub fn stack_usage(self: Self) usize {
            return @intFromPtr(&self.stack[self.stack.len - 1]) - @intFromPtr(self.stack_position);
        }

        pub fn block(self: *Self, semaphore: *const Semaphore) void {
            self.waiting_for = semaphore;
            self.state = Process.State.Blocked;
        }

        pub fn wait_for_process(self: *Self, process: *Self) !void {
            self.state = Process.State.Blocked;
            self.blocked_by_process = process;
            process.blocks_process = self;
        }

        // swap stack with the process that is waiting for us, only if was swapped before
        pub fn restore_stack(self: *Self) void {
            if (self.blocks_process) |p| {
                if (!p.has_own_stack) {
                    @memcpy(self.stack, p.stack);
                    const stack = p.stack;
                    p.stack = self.stack;
                    self.stack = stack;
                    p.has_own_stack = true;
                    self.has_own_stack = true;
                }
            }
        }

        pub fn unblock_parent(self: *Self) void {
            if (self.blocks_process) |p| {
                p.blocked_by_process = null;
                // stack must be restored when parent is unblocked
                self.restore_stack();
                p.reevaluate_state();
                self.blocks_process = null;
                // reload_current_task();
            }
        }

        pub fn reevaluate_state(self: *Self) void {
            if (self.waiting_for != null) {
                self.state = Process.State.Blocked;
                return;
            }
            if (self.blocked_by_process != null) {
                self.state = Process.State.Blocked;
                return;
            }
            self.state = Process.State.Ready;
        }

        pub fn unblock_process(self: *Self, process: *const Self) void {
            for (self.blocked_by) |node| {
                if (node.data == process) {
                    self.blocked_by.remove(node);

                    break;
                }
            }
            self.blocked_by.remove(process);
        }

        pub fn is_blocked_by(self: Self, semaphore: *const Semaphore) bool {
            if (self.waiting_for) |blocker| {
                return blocker == semaphore;
            }
            return false;
        }

        pub fn unblock(self: *Self) void {
            self.waiting_for = null;
            self.state = Process.State.Ready;
        }

        pub fn set_core(self: *Self, coreid: u8) void {
            self.current_core = coreid;
        }

        pub fn mmap(self: *Self, addr: ?*anyopaque, length: i32, _: i32, _: i32, _: i32, _: i32) !*anyopaque {
            if (addr == null) {
                var number_of_pages = @divTrunc(length, process_memory_pool.ProcessMemoryPool.page_size);
                if (@rem(length, process_memory_pool.ProcessMemoryPool.page_size) != 0) {
                    number_of_pages += 1;
                }
                const maybe_address = process_memory_pool.instance.allocate_pages(number_of_pages, self.pid);
                if (maybe_address) |address| {
                    return address.ptr;
                }
            }
            return std.posix.MMapError.OutOfMemory;
        }

        pub fn munmap(self: *Self, maybe_address: ?*anyopaque, length: i32) void {
            if (maybe_address) |addr| {
                var number_of_pages = @divTrunc(length, process_memory_pool.ProcessMemoryPool.page_size);
                if (@rem(length, process_memory_pool.ProcessMemoryPool.page_size) != 0) {
                    number_of_pages += 1;
                }

                process_memory_pool.instance.free_pages(addr, number_of_pages, self.pid);
            }
        }

        pub fn get_free_fd(self: *Self) u16 {
            var fd: u16 = 0;
            while (true) {
                if (self.fds.get(fd) == null) {
                    break;
                }
                fd += 1;
            }
            return fd;
        }

        pub fn sleep_for_us(self: *Self, us: u32) void {
            _ = self;
            _ = us;
        }
    };
}

pub fn initialize_context_switching() void {
    arch_process.initialize_context_switching();
}

pub const Process = ProcessInterface(arch_process);

fn process_init() void {}

test "initialize process" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("Test Failed");
    }
    const stack_size = 1024;
    const process = try Process.create(allocator, stack_size, process_init);
    try std.testing.expectEqual(process.pid, 1);
    try std.testing.expectEqual(process.state, Process.State.Ready);
    try std.testing.expectEqual(process.priority, 0);
    try std.testing.expectEqual(process.stack.len, stack_size);
    defer process.deinit();

    const second_process = try Process.create(allocator, stack_size, process_init);
    try std.testing.expectEqual(second_process.pid, 2);
    try std.testing.expectEqual(second_process.state, Process.State.Ready);
    try std.testing.expectEqual(second_process.priority, 0);
    try std.testing.expectEqual(second_process.stack.len, stack_size);

    defer second_process.deinit();
}

test "detect stack overflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) std.testing.expect(false) catch @panic("Test Failed");
    }
    const stack_size = 1024;
    const process = try Process.create(allocator, stack_size, process_init);
    defer process.deinit();
    try std.testing.expect(process.validate_stack());
    process.stack[0] = 0x12;
    try std.testing.expect(!process.validate_stack());
}
