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

const c = @import("libc_imports").c;

const config = @import("config");
const kernel = @import("kernel.zig");

const log = std.log.scoped(.@"kernel/process");

const arch_process = @import("arch").process;

const Semaphore = @import("semaphore.zig").Semaphore;
const IFile = kernel.fs.IFile;
const IDirectoryIterator = @import("fs/ifilesystem.zig").IDirectoryIterator;
const system_call = @import("interrupts/system_call.zig");
const systick = @import("interrupts/systick.zig");
const arch = @import("arch");

const hal = @import("hal");

var pid_counter: u32 = 0;

pub fn init() void {
    arch_process.init();
}

fn exit_handler_impl() void {
    system_call.trigger(c.sys_exit, null, null);
}

pub fn ProcessInterface(comptime ProcessType: type, comptime ProcessMemoryPoolType: anytype) type {
    return struct {
        const Self = @This();
        const FileHandle = struct {
            file: IFile,
            path: [config.fs.max_path_length]u8,
            diriter: ?IDirectoryIterator,
        };
        pub const ImplType = ProcessType;
        pub const UnblockAction = *const fn (context: ?*anyopaque, rc: i32) void;
        const ProcessMemoryAllocator = kernel.memory.heap.ProcessPageAllocator(ProcessMemoryPoolType);

        const BlockedByProcess = struct {
            waiting_for: *const Self,
            node: std.DoublyLinkedList.Node,
        };

        const BlockedProcessAction = struct {
            blocked: *Self,
            context: ?*anyopaque = null,
            action: UnblockAction,
            node: std.DoublyLinkedList.Node,
        };

        state: State,
        priority: u8,
        impl: ImplType,
        pid: u32,
        _kernel_allocator: std.mem.Allocator,
        current_core: u8,
        waiting_for: ?*const Semaphore = null,
        fds: std.AutoHashMap(u16, FileHandle),
        cwd: []u8,
        node: std.DoublyLinkedList.Node,
        _process_memory_allocator: ProcessMemoryAllocator,
        _parent: ?*Self = null,
        _blocked_by: std.DoublyLinkedList,
        _blocks: std.DoublyLinkedList,
        _stack_shared_with_parent: bool,
        _vfork_context: ?*const volatile c.vfork_context = null,
        _initialized: bool = false,

        pub const State = enum(u3) {
            Initialized,
            Ready,
            Blocked,
            Running,
            Terminated,
        };

        pub fn init(kernel_allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, arg: anytype, cwd: []const u8, process_memory_pool: *ProcessMemoryPoolType, parent: ?*Self) !*Self {
            pid_counter += 1;
            const process = try kernel_allocator.create(Self);
            kernel.log.debug("initializing memory allocator for pid: {d}", .{pid_counter});
            var process_memory_allocator = ProcessMemoryAllocator.init(pid_counter, process_memory_pool);
            const cwd_handle = try kernel_allocator.alloc(u8, cwd.len + 1);
            @memcpy(cwd_handle[0..cwd.len], cwd);
            cwd_handle[cwd.len] = 0;
            const args = [_]usize{
                @intFromPtr(arg),
            };
            process.* = .{
                .state = State.Ready,
                .priority = 0,
                .impl = try ImplType.init(process_memory_allocator.allocator(), stack_size, process_entry, exit_handler_impl, args[0..]),
                .pid = pid_counter,
                ._kernel_allocator = kernel_allocator,
                .current_core = 0,
                .fds = std.AutoHashMap(u16, FileHandle).init(kernel_allocator),
                .cwd = cwd_handle,
                .node = .{},
                ._process_memory_allocator = process_memory_allocator,
                ._parent = parent,
                ._blocked_by = std.DoublyLinkedList{},
                ._blocks = std.DoublyLinkedList{},
                ._stack_shared_with_parent = false,
                ._vfork_context = null,
            };
            return process;
        }

        pub fn clear_fds(self: *Self) void {
            var it = self.fds.iterator();
            while (it.next()) |*n| {
                if (n.value_ptr.diriter) |*d| {
                    d.interface.delete();
                }
                n.value_ptr.file.interface.delete();
            }
            self.fds.deinit();
        }

        fn dupe_filehandle(handle: *FileHandle) FileHandle {
            return .{
                .diriter = handle.diriter,
                .file = handle.file.share(),
                .path = handle.path,
            };
        }
        fn dupe_fds(self: *Self) !std.AutoHashMap(u16, FileHandle) {
            var fds = std.AutoHashMap(u16, FileHandle).init(self._kernel_allocator);
            var it = self.fds.iterator();
            while (it.next()) |*n| {
                try fds.put(n.key_ptr.*, dupe_filehandle(n.value_ptr));
            }
            return fds;
        }

        pub fn deinit(self: *Self) void {
            self.impl.deinit(self._process_memory_allocator.allocator());
            self.clear_fds();
            self._kernel_allocator.free(self.cwd);
            self._process_memory_allocator.deinit();
        }

        pub fn get_memory_allocator(self: *Self) std.mem.Allocator {
            return self._kernel_allocator;
        }

        pub fn get_process_memory_allocator(self: *Self) std.mem.Allocator {
            return self._process_memory_allocator.allocator();
        }
        // this is full copy of the process, so it shares the same stack
        // stack relocation impossible without MMU
        pub fn vfork(self: *Self, process_memory_pool: *ProcessMemoryPoolType, context: *const volatile c.vfork_context) !*Self {
            // allocate stack copy
            const process = try self._kernel_allocator.create(Self);
            pid_counter += 1;
            var memory_pool = ProcessMemoryAllocator.init(pid_counter, process_memory_pool);
            log.debug("vfork process memory allocator created for pid {d}", .{pid_counter});
            const cwd_handle = try self._kernel_allocator.alloc(u8, self.cwd.len);
            @memcpy(cwd_handle, self.cwd);
            self._vfork_context = context;

            process.* = .{
                .state = State.Ready,
                .priority = self.priority,
                .impl = try self.impl.vfork(memory_pool.allocator()),
                .pid = pid_counter,
                ._kernel_allocator = self._kernel_allocator,
                .current_core = 0,
                .fds = try self.dupe_fds(),
                .cwd = cwd_handle,
                .node = .{},
                ._process_memory_allocator = memory_pool,
                ._parent = self,
                ._blocked_by = std.DoublyLinkedList{},
                ._blocks = std.DoublyLinkedList{},
                ._stack_shared_with_parent = true,
                ._vfork_context = context,
                ._initialized = false,
            };

            return process;
        }

        pub fn has_stack_shared_with_parent(self: *Self) bool {
            return self._stack_shared_with_parent;
        }

        pub fn release_parent_after_getting_freedom(self: *Self) *std.DoublyLinkedList.Node {
            self.restore_parent_stack();
            self.unblock_parent();
            self.set_vfork_pid(@intCast(self.pid));
            if (self._parent) |p| {
                return &p.node;
            }
            @panic("Process has no parent to release after vfork");
        }

        pub fn change_directory(self: *Self, path: []const u8) !void {
            const cwd_handle = try std.fs.path.resolvePosix(self._kernel_allocator, &.{path});
            self._kernel_allocator.free(self.cwd);
            self.cwd = cwd_handle;
        }

        pub fn get_current_directory(self: Self) []const u8 {
            return self.cwd;
        }

        pub fn stack_pointer(self: Self) *const u8 {
            return self.impl.stack_pointer();
        }

        pub fn get_stack_bottom(self: Self) *const u8 {
            return self.impl.get_stack_bottom();
        }

        pub fn set_stack_pointer(self: *Self, ptr: *u8) void {
            var blocked_by_process: ?*ImplType = null;
            if (self._stack_shared_with_parent) {
                if (self._parent) |p| {
                    blocked_by_process = &p.impl;
                }
            }
            self.impl.set_stack_pointer(ptr, blocked_by_process);
        }

        pub fn stack_usage(self: Self) usize {
            return @intFromPtr(&self.stack[self.stack.len - 1]) - @intFromPtr(self.stack_position);
        }

        pub fn block_semaphore(self: *Self, semaphore: *const Semaphore) void {
            self.waiting_for = semaphore;
            self.reevaluate_state();
        }

        pub fn blocks_process(self: *Self, blocked_process: *Self, action: UnblockAction, context: ?*anyopaque) !void {
            const blocked_data = try self._kernel_allocator.create(BlockedProcessAction);
            blocked_data.* = .{
                .blocked = blocked_process,
                .context = context,
                .action = action,
                .node = std.DoublyLinkedList.Node{},
            };
            self._blocks.append(&blocked_data.node);
        }

        pub fn wait_for_process(self: *Self, process: *Self, action: UnblockAction, context: ?*anyopaque) !void {
            // this process will be unblocked until other processes are finished
            const blocked_data = try self._kernel_allocator.create(BlockedByProcess);
            try process.blocks_process(self, action, context);
            blocked_data.* = .{
                .waiting_for = process,
                .node = std.DoublyLinkedList.Node{},
            };
            self._blocked_by.append(&blocked_data.node);
            self.reevaluate_state();
        }

        // swap stack with the process that is waiting for us, only if was swapped before
        pub fn restore_parent_stack(self: *Self) void {
            if (!self._stack_shared_with_parent) {
                return;
            }

            if (self._parent) |p| {
                self.impl.restore_parent_stack(&p.impl);
                self._stack_shared_with_parent = false;
            }
        }

        pub fn set_vfork_pid(self: *Self, pid: c.pid_t) void {
            if (self._vfork_context) |context| {
                context.pid.* = pid;
            } else {
                log.err("Process {d} vfork context is null, cannot set pid", .{self.pid});
            }
        }

        pub fn reevaluate_state(self: *Self) void {
            if (self.waiting_for != null) {
                self.state = Process.State.Blocked;
                return;
            }

            if (self._blocked_by.len() != 0) {
                self.state = Process.State.Blocked;
                return;
            }
            self.state = Process.State.Ready;
        }

        pub fn is_blocked_by(self: Self, semaphore: *const Semaphore) bool {
            if (self.waiting_for) |blocker| {
                return blocker == semaphore;
            }
            return false;
        }

        pub fn unblock_semaphore(self: *Self, semaphore: *const Semaphore) void {
            if (self.waiting_for) |blocker| {
                if (blocker == semaphore) {
                    self.waiting_for = null;
                    self.reevaluate_state();
                }
            }
        }

        pub fn unblock_parent(self: *Self) void {
            var it = self._blocks.first;
            while (it) |blocks| : (it = blocks.next) {
                const action: *BlockedProcessAction = @fieldParentPtr("node", blocks);
                if (action.blocked == self._parent.?) {
                    action.action(action.context, 0);
                    self._blocks.remove(&action.node);
                    self._kernel_allocator.destroy(action);
                }
            }

            if (self._parent) |p| {
                p.unblock_from(self);
            }
            self.reevaluate_state();
        }

        pub fn unblock_from(self: *Self, blocking_process: *const Self) void {
            var it = self._blocked_by.first;
            while (it) |blocks| : (it = blocks.next) {
                const blocker: *BlockedByProcess = @fieldParentPtr("node", blocks);
                if (blocker.waiting_for == blocking_process) {
                    self._blocked_by.remove(blocks);
                    self._kernel_allocator.destroy(blocker);
                }
            }
            self.reevaluate_state();
        }

        pub fn unblock_all(self: *Self, result: i32) void {
            var next = self._blocks.pop();
            while (next) |node| {
                const action: *BlockedProcessAction = @fieldParentPtr("node", node);
                action.action(action.context, result);
                action.blocked.unblock_from(self);
                self._kernel_allocator.destroy(action);
                next = self._blocks.pop();
            }
        }

        pub fn set_core(self: *Self, coreid: u8) void {
            self.current_core = coreid;
        }

        pub fn mmap(self: *Self, addr: ?*anyopaque, length: i32, _: i32, _: i32, _: i32, _: i32) !*anyopaque {
            if (addr == null) {
                var number_of_pages = @divTrunc(length, ProcessMemoryPoolType.page_size);
                if (@rem(length, ProcessMemoryPoolType.page_size) != 0) {
                    number_of_pages += 1;
                }
                const maybe_address = self._process_memory_allocator.allocate_pages(number_of_pages);
                if (maybe_address) |address| {
                    return address.ptr;
                }
            }
            return std.posix.MMapError.OutOfMemory;
        }

        pub fn munmap(self: *Self, maybe_address: ?*anyopaque, length: i32) void {
            if (maybe_address) |addr| {
                var number_of_pages = @divTrunc(length, ProcessMemoryPoolType.page_size);
                if (@rem(length, ProcessMemoryPoolType.page_size) != 0) {
                    number_of_pages += 1;
                }

                self._process_memory_allocator.release_pages(addr, number_of_pages);
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

        pub fn get_parent(self: Self) ?*Self {
            return self._parent;
        }

        pub fn sleep_for_us(self: *Self, us: u64) void {
            const start = systick.get_system_ticks();
            var elapsed: u64 = 0;
            const ptr: *volatile u64 = &elapsed;
            while (ptr.* < us / 1000) {
                // context switch, we are waiting for condition
                hal.irq.trigger(.pendsv);
                ptr.* = systick.get_system_ticks() - start;
            }
            _ = self;
        }

        pub fn sleep_for_ms(self: *Self, ms: u32) void {
            self.sleep_for_us(@as(u64, @intCast(ms)) * 1000);
        }

        pub fn reinitialize_stack(self: *Self, process_entry: anytype, argc: usize, argv: usize, symbol: usize, got: usize, use_fpu: bool) void {
            self.impl.reinitialize_stack(process_entry, argc, argv, symbol, got, exit_handler_impl, use_fpu);
            self._initialized = false;
        }

        pub fn is_initialized(self: *const Self) bool {
            return self._initialized;
        }
    };
}

pub fn initialize_context_switching() void {
    arch_process.initialize_context_switching();
}

pub const Process = ProcessInterface(arch.HardwareProcess, kernel.memory.heap.ProcessMemoryPool);

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
