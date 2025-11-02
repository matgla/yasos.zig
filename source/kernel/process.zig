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
const IDirectoryIterator = @import("fs/idirectory.zig").IDirectoryIterator;
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
            allocator: std.mem.Allocator,
            node: kernel.fs.Node,
            path: []u8,
            diriter: ?IDirectoryIterator,

            pub fn create(allocator: std.mem.Allocator, path: []const u8, node: kernel.fs.Node) !FileHandle {
                return FileHandle{
                    .allocator = allocator,
                    .node = node,
                    .path = try allocator.dupe(u8, path),
                    .diriter = null,
                };
            }

            pub fn close(self: *FileHandle) void {
                if (self.diriter) |*d| {
                    d.interface.delete();
                    self.diriter = null;
                }
                self.allocator.free(self.path);
                self.node.delete();
            }

            pub fn get_iterator(self: *FileHandle) !*IDirectoryIterator {
                if (self.diriter) |*d| {
                    return d;
                } else {
                    const maybe_directory = self.node.as_directory();
                    if (maybe_directory) |*dir| {
                        self.diriter = try dir.interface.iterator();
                        return &self.diriter.?;
                    }
                }

                return error.NotADirectory;
            }

            pub fn remove_iterator(self: *FileHandle) void {
                if (self.diriter) |*d| {
                    d.interface.delete();
                    self.diriter = null;
                }
            }
        };
        pub const ImplType = ProcessType;
        pub const UnblockAction = *const fn (context: ?*anyopaque, rc: i32) void;
        const ProcessMemoryAllocator = kernel.memory.heap.ProcessPageAllocator(ProcessMemoryPoolType);

        pub const BlockedByProcess = struct {
            waiting_for: *const Self,
            node: std.DoublyLinkedList.Node,
        };

        pub const BlockedProcessAction = struct {
            blocked: *Self,
            context: ?*anyopaque = null,
            action: UnblockAction,
            node: std.DoublyLinkedList.Node,
        };

        state: State,
        priority: u8,
        impl: ImplType,
        pid: c.pid_t,
        _kernel_allocator: std.mem.Allocator,
        current_core: u8,
        waiting_for: ?*const Semaphore = null,
        _fds: std.AutoHashMap(u16, FileHandle),
        cwd: []u8,
        node: std.DoublyLinkedList.Node,
        _process_memory_allocator: ProcessMemoryAllocator,
        _parent: ?*Self = null,
        _blocked_by: std.DoublyLinkedList,
        _blocks: std.DoublyLinkedList,
        _stack_shared_with_parent: bool,
        _vfork_context: ?*const volatile c.vfork_context = null,
        _initialized: bool = false,
        _start_time: u64,

        pub const State = enum(u3) {
            Initialized,
            Ready,
            Blocked,
            Running,
            Terminated,
        };

        pub fn init(kernel_allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, arg: anytype, cwd: []const u8, process_memory_pool: *ProcessMemoryPoolType, parent: ?*Self, pid: c.pid_t) !*Self {
            const process = try kernel_allocator.create(Self);
            kernel.log.debug("initializing memory allocator for pid: {d}", .{pid});
            var process_memory_allocator = ProcessMemoryAllocator.init(pid, process_memory_pool);
            const cwd_handle = try kernel_allocator.alloc(u8, cwd.len);
            @memcpy(cwd_handle[0..cwd.len], cwd);
            const args = [_]usize{
                @intFromPtr(arg),
            };
            process.* = .{
                .state = State.Ready,
                .priority = 0,
                .impl = try ImplType.init(process_memory_allocator.allocator(), stack_size, process_entry, exit_handler_impl, args[0..]),
                .pid = pid,
                ._kernel_allocator = kernel_allocator,
                .current_core = 0,
                ._fds = std.AutoHashMap(u16, FileHandle).init(kernel_allocator),
                .cwd = cwd_handle,
                .node = .{},
                ._process_memory_allocator = process_memory_allocator,
                ._parent = parent,
                ._blocked_by = std.DoublyLinkedList{},
                ._blocks = std.DoublyLinkedList{},
                ._stack_shared_with_parent = false,
                ._vfork_context = null,
                ._start_time = hal.time.get_time_us(),
            };
            return process;
        }

        pub fn clear_fds(self: *Self) void {
            var it = self._fds.iterator();
            while (it.next()) |*n| {
                n.value_ptr.close();
            }
            self._fds.deinit();
        }

        fn dupe_filehandle(handle: *FileHandle) !FileHandle {
            return .{
                .allocator = handle.allocator,
                .diriter = handle.diriter,
                .node = try handle.node.clone(),
                .path = try handle.allocator.dupe(u8, handle.path),
            };
        }
        fn dupe_fds(self: *Self) !std.AutoHashMap(u16, FileHandle) {
            var fds = std.AutoHashMap(u16, FileHandle).init(self._kernel_allocator);
            var it = self._fds.iterator();
            while (it.next()) |*n| {
                try fds.put(n.key_ptr.*, try dupe_filehandle(n.value_ptr));
            }
            return fds;
        }

        pub fn deinit(self: *Self) void {
            self.impl.deinit(self._process_memory_allocator.allocator());
            self.clear_fds();
            self._kernel_allocator.free(self.cwd);
            self._process_memory_allocator.deinit();
            var it = self._blocked_by.first;
            while (it) |blocked| {
                const blocker: *BlockedByProcess = @fieldParentPtr("node", blocked);
                it = blocked.next;
                self._kernel_allocator.destroy(blocker);
            }

            it = self._blocks.first;
            while (it) |blocks| {
                const action: *BlockedProcessAction = @fieldParentPtr("node", blocks);
                it = blocks.next;
                self._kernel_allocator.destroy(action);
            }
            self._kernel_allocator.destroy(self);
        }

        pub fn get_memory_allocator(self: *Self) std.mem.Allocator {
            return self._kernel_allocator;
        }

        pub fn get_process_memory_allocator(self: *Self) std.mem.Allocator {
            return self._process_memory_allocator.allocator();
        }
        // this is full copy of the process, so it shares the same stack
        // stack relocation impossible without MMU
        pub fn vfork(self: *Self, process_memory_pool: *ProcessMemoryPoolType, context: *const volatile c.vfork_context, pid: c.pid_t) !*Self {
            // allocate stack copy
            const process = try self._kernel_allocator.create(Self);
            var memory_pool = ProcessMemoryAllocator.init(pid, process_memory_pool);
            log.debug("vfork process memory allocator created for pid {d}", .{pid});
            const cwd_handle = try self._kernel_allocator.alloc(u8, self.cwd.len);
            @memcpy(cwd_handle, self.cwd);
            self._vfork_context = context;

            process.* = .{
                .state = State.Ready,
                .priority = self.priority,
                .impl = try self.impl.vfork(memory_pool.allocator()),
                .pid = pid,
                ._kernel_allocator = self._kernel_allocator,
                .current_core = 0,
                ._fds = try self.dupe_fds(),
                .cwd = cwd_handle,
                .node = .{},
                ._process_memory_allocator = memory_pool,
                ._parent = self,
                ._blocked_by = std.DoublyLinkedList{},
                ._blocks = std.DoublyLinkedList{},
                ._stack_shared_with_parent = true,
                ._vfork_context = context,
                ._initialized = false,
                ._start_time = hal.time.get_time_us(),
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
            self._kernel_allocator.free(self.cwd);
            self.cwd = try self._kernel_allocator.dupe(u8, path);
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

            if (self._blocked_by.first != null) {
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
            while (it) |blocks| {
                const action: *BlockedProcessAction = @fieldParentPtr("node", blocks);
                it = blocks.next;
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
            while (it) |blocks| {
                const blocker: *BlockedByProcess = @fieldParentPtr("node", blocks);
                it = blocks.next;
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
            return kernel.errno.ErrnoSet.OutOfMemory;
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
                if (self._fds.get(fd) == null) {
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
            const start = systick.get_system_ticks().*;
            var elapsed: u64 = 0;
            const ptr: *volatile u64 = &elapsed;
            while (ptr.* < us / 1000) {
                // context switch, we are waiting for condition
                hal.irq.trigger(.pendsv);
                ptr.* = systick.get_system_ticks().* - start;
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

        pub fn get_uptime(self: *const Self) u64 {
            return hal.time.get_time_us() - self._start_time;
        }

        pub fn attach_file(self: *Self, path: []const u8, node: kernel.fs.Node) !i32 {
            const fd = self.get_free_fd();
            return try self.attach_file_with_fd(@intCast(fd), path, node);
        }

        pub fn attach_file_with_fd(self: *Self, fd: i16, path: []const u8, node: kernel.fs.Node) !i32 {
            const handle = try FileHandle.create(self._kernel_allocator, path, node);
            try self._fds.put(@intCast(fd), handle);
            return @intCast(fd);
        }

        pub fn release_file(self: *Self, fd: i32) void {
            const maybe_handle = self._fds.getPtr(@intCast(fd));
            if (maybe_handle) |handle| {
                handle.close();
                _ = self._fds.remove(@intCast(fd));
            }
        }

        pub fn get_file_handle(self: *Self, fd: i32) ?*FileHandle {
            const maybe_handle = self._fds.getPtr(@intCast(fd));
            if (maybe_handle) |handle| {
                return handle;
            }
            return null;
        }
    };
}

pub fn initialize_context_switching() void {
    arch_process.initialize_context_switching();
}

pub const Process = ProcessInterface(arch.HardwareProcess, kernel.memory.heap.ProcessMemoryPool);

fn process_init() void {}

const ProcessMemoryPoolForTests = struct {
    const Self = @This();
    pub const page_size = 4096;
    buffer_to_return: ?[]u8 = null,
    caller_pid: c.pid_t = 0,
    caller_number_of_pages: i32 = 0,
    release_address: ?*anyopaque = null,
    release_pages: i32 = 0,
    release_pid: c.pid_t = 0,

    pub fn release_pages_for(self: *Self, pid: c.pid_t) void {
        _ = self;
        _ = pid;
    }

    pub fn allocate_pages(self: *Self, number_of_pages: i32, pid: c.pid_t) ?[]u8 {
        self.caller_pid = pid;
        self.caller_number_of_pages = number_of_pages;
        return self.buffer_to_return;
    }

    pub fn free_pages(self: *Self, address: *anyopaque, number_of_pages: i32, pid: c.pid_t) void {
        self.release_address = address;
        self.release_pages = number_of_pages;
        self.release_pid = pid;
    }

    pub fn will_return(self: *Self, buffer: []u8) void {
        self.buffer_to_return = buffer;
    }
};
const ProcessUnderTest = ProcessInterface(arch.HardwareProcess, ProcessMemoryPoolForTests);

test "Process.ShouldBeCreated" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    const cwd_for_process = "/some/path";
    const pid_for_process = 10;
    hal.time.impl.set_time(1000);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, cwd_for_process, &pool, null, pid_for_process);
    defer sut.deinit();

    try std.testing.expectEqual(pid_for_process, sut.pid);
    try std.testing.expectEqualStrings(cwd_for_process, sut.get_current_directory());
    try std.testing.expectEqual(1000, sut._start_time);
}

const FileMock = @import("fs/tests/file_mock.zig").FileMock;

test "Process.ShouldChangeDirectory" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 20);
    defer sut.deinit();

    try sut.change_directory("/home/user");
    try std.testing.expectEqualStrings("/home/user", sut.get_current_directory());
}

test "Process.ShouldAttachAndReleaseFile" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 30);
    defer sut.deinit();

    var file_mock = try FileMock.create(std.testing.allocator);
    defer file_mock.delete();
    const node = kernel.fs.Node.create_file(file_mock.interface);

    var file_mock2 = try FileMock.create(std.testing.allocator);
    defer file_mock2.delete();
    const node2 = kernel.fs.Node.create_file(file_mock2.interface);

    const fd = try sut.attach_file("/tmp/test.txt", node);
    try std.testing.expectEqual(@as(i32, 0), fd);

    const fd2 = try sut.attach_file("/var/log/syslog", node2);
    try std.testing.expectEqual(@as(i32, 1), fd2);

    const handle = sut.get_file_handle(fd);
    try std.testing.expect(handle != null);
    try std.testing.expectEqualStrings("/tmp/test.txt", handle.?.path);

    sut.release_file(fd);
    try std.testing.expect(sut.get_file_handle(fd) == null);
}

test "Process.ShouldReuseReleasedFileDescriptor" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 40);
    defer sut.deinit();

    var file_mock1 = try FileMock.create(std.testing.allocator);
    defer file_mock1.delete();
    const node1 = kernel.fs.Node.create_file(file_mock1.interface);
    const fd1 = try sut.attach_file("/tmp/file1", node1);
    try std.testing.expectEqual(@as(i32, 0), fd1);

    sut.release_file(fd1);

    var file_mock2 = try FileMock.create(std.testing.allocator);
    defer file_mock2.delete();
    const node2 = kernel.fs.Node.create_file(file_mock2.interface);
    const fd2 = try sut.attach_file("/tmp/file2", node2);

    try std.testing.expectEqual(fd1, fd2);
}

test "Process.ShouldReturnUptime" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(500);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 50);
    defer sut.deinit();

    hal.time.impl.set_time(2500);
    try std.testing.expectEqual(@as(u64, 2000), sut.get_uptime());
}

test "Process.ShouldSetCurrentCore" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 60);
    defer sut.deinit();

    sut.set_core(2);
    try std.testing.expectEqual(@as(u8, 2), sut.current_core);
}

const irq_systick = @import("interrupts/systick.zig").irq_systick;
test "Process.ShouldSleepForMilliseconds" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 70);
    defer sut.deinit();

    const PendSvAction = struct {
        pub fn call() void {
            hal.time.systick.set_ticks(hal.time.systick.get_system_tick() + 1000);
            for (0..1000) |_| irq_systick();
        }
    };

    hal.irq.impl().set_irq_action(.pendsv, &PendSvAction.call);
    sut.sleep_for_ms(10);
}

test "Process.ShouldForkProcess" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 80);
    try std.testing.expectEqual(null, parent._parent);
    defer parent.deinit();

    var pid: c.pid_t = -1;
    const vfork_context = c.vfork_context{
        .pid = &pid,
    };

    var child = try parent.vfork(&pool, &vfork_context, 81);
    defer child.deinit();

    try std.testing.expect(child.get_parent() == parent);
    try std.testing.expectEqual(-1, pid);

    child.set_vfork_pid(123);
    try std.testing.expectEqual(123, pid);
}

const MultiProcessUnblock = struct {
    pub const Context = struct {
        count: usize = 0,
        last_rc: i32 = 0,
    };

    pub fn action(ctx: ?*anyopaque, rc: i32) void {
        const context_ptr = @as(*Context, @ptrCast(@alignCast(ctx.?)));
        context_ptr.count += 1;
        context_ptr.last_rc = rc;
    }
};

test "Process.ShouldWaitForMultipleProcessesAndUnblock" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;

    hal.time.impl.set_time(0);
    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 90);
    defer parent.deinit();

    var child1 = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, parent, 91);
    defer child1.deinit();

    var child2 = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, parent, 92);
    defer child2.deinit();

    var context = MultiProcessUnblock.Context{};
    const ctx_ptr: ?*anyopaque = &context;

    try parent.wait_for_process(child1, &MultiProcessUnblock.action, ctx_ptr);
    try std.testing.expectEqual(ProcessUnderTest.State.Blocked, parent.state);

    try parent.wait_for_process(child2, &MultiProcessUnblock.action, ctx_ptr);
    try std.testing.expectEqual(ProcessUnderTest.State.Blocked, parent.state);

    {
        var count: usize = 0;
        var it = parent._blocked_by.first;
        while (it) |node| {
            count += 1;
            it = node.next;
        }
        try std.testing.expectEqual(@as(usize, 2), count);
    }

    {
        var count: usize = 0;
        var it = child1._blocks.first;
        while (it) |node| {
            count += 1;
            it = node.next;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }

    child1.unblock_all(11);

    try std.testing.expectEqual(@as(usize, 1), context.count);
    try std.testing.expectEqual(@as(i32, 11), context.last_rc);
    try std.testing.expectEqual(ProcessUnderTest.State.Blocked, parent.state);

    {
        var count: usize = 0;
        var it = parent._blocked_by.first;
        while (it) |node| {
            count += 1;
            it = node.next;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }

    {
        const it = child1._blocks.first;
        try std.testing.expect(it == null);
    }

    child2.unblock_all(22);

    try std.testing.expectEqual(@as(usize, 2), context.count);
    try std.testing.expectEqual(@as(i32, 22), context.last_rc);
    try std.testing.expectEqual(ProcessUnderTest.State.Ready, parent.state);

    {
        const it = parent._blocked_by.first;
        try std.testing.expect(it == null);
    }

    {
        const it = child2._blocks.first;
        try std.testing.expect(it == null);
    }
}

test "Process.ShouldBlockOnSemaphore" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 100);
    defer sut.deinit();

    var sem = Semaphore.create(1);

    sut.block_semaphore(&sem);
    try std.testing.expectEqual(ProcessUnderTest.State.Blocked, sut.state);
    try std.testing.expect(sut.is_blocked_by(&sem));
}

test "Process.ShouldUnblockSemaphoreAndUpdateState" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 110);
    defer sut.deinit();

    var sem = Semaphore.create(1);

    sut.block_semaphore(&sem);
    try std.testing.expectEqual(ProcessUnderTest.State.Blocked, sut.state);

    sut.unblock_semaphore(&sem);
    try std.testing.expectEqual(ProcessUnderTest.State.Ready, sut.state);
    try std.testing.expect(!sut.is_blocked_by(&sem));
}

test "Process.ShouldRestoreParentStack" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 120);
    defer parent.deinit();

    const parent_stack_before = parent.stack_pointer();

    var pid: c.pid_t = -1;
    const vfork_ctx = c.vfork_context{ .pid = &pid };

    var child = try parent.vfork(&pool, &vfork_ctx, 121);
    defer child.deinit();

    try std.testing.expect(child.has_stack_shared_with_parent());

    try std.testing.expectEqual(parent_stack_before, child.stack_pointer());
    const new_child_sp_addr = @intFromPtr(child.get_stack_bottom()) + 64;
    const new_child_sp = @as(*u8, @ptrFromInt(new_child_sp_addr));
    child.set_stack_pointer(new_child_sp);

    // try std.testing.expect(parent.stack_pointer() != parent_stack_before);
    try std.testing.expectEqual(new_child_sp, child.stack_pointer());

    child.restore_parent_stack();

    try std.testing.expect(!child.has_stack_shared_with_parent());
    try std.testing.expectEqual(parent_stack_before, parent.stack_pointer());

    child.restore_parent_stack();

    try std.testing.expect(!child.has_stack_shared_with_parent());
    try std.testing.expectEqual(parent_stack_before, parent.stack_pointer());
}

test "Process.ShouldMmapMemory" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);

    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 120);
    defer sut.deinit();

    var addr: usize = 0x10;
    try std.testing.expectError(kernel.errno.ErrnoSet.OutOfMemory, sut.mmap(&addr, 8192 + 10, 0, 0, 0, 0));

    var buffer: [4096 * 3]u8 = undefined;
    pool.will_return(buffer[0..]);
    const allocated = try sut.mmap(null, 8192 + 10, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&buffer)), allocated);

    try std.testing.expectEqual(3, pool.caller_number_of_pages);
    try std.testing.expectEqual(120, pool.caller_pid);

    sut.munmap(allocated, 8192 + 10);
    try std.testing.expectEqual(@as(*anyopaque, &buffer), pool.release_address);
    try std.testing.expectEqual(3, pool.release_pages);
    try std.testing.expectEqual(120, pool.release_pid);
}

test "Process.ShouldDeinitBlockedStructures" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 0;
    hal.time.impl.set_time(0);

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 200);
    var child = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, parent, 201);

    var ctx = MultiProcessUnblock.Context{};
    try parent.wait_for_process(child, &MultiProcessUnblock.action, &ctx);

    try std.testing.expect(parent._blocked_by.first != null);
    try std.testing.expect(child._blocks.first != null);

    child.deinit();
    parent.deinit();
}

test "Process.ShouldDuplicateFileHandlesOnVfork" {
    var parent_pool = ProcessMemoryPoolForTests{};
    var child_pool = ProcessMemoryPoolForTests{};
    var arg: usize = 0;
    hal.time.impl.set_time(0);

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &parent_pool, null, 210);
    defer parent.deinit();

    const file_mock1 = try FileMock.create(std.testing.allocator);
    defer file_mock1.delete();
    const node1 = kernel.fs.Node.create_file(file_mock1.interface);

    const file_mock2 = try FileMock.create(std.testing.allocator);
    defer file_mock2.delete();
    const node2 = kernel.fs.Node.create_file(file_mock2.interface);

    const fd0 = try parent.attach_file("/dev/test0", node1);
    const fd1 = try parent.attach_file("/dev/test1", node2);

    var pid: c.pid_t = -1;
    const vfork_ctx = c.vfork_context{ .pid = &pid };

    var child = try parent.vfork(&child_pool, &vfork_ctx, 211);
    defer child.deinit();

    const parent_handle0 = parent.get_file_handle(fd0).?;
    const parent_handle1 = parent.get_file_handle(fd1).?;
    const child_handle0 = child.get_file_handle(fd0).?;
    const child_handle1 = child.get_file_handle(fd1).?;

    try std.testing.expectEqualStrings(parent_handle0.path, child_handle0.path);
    try std.testing.expectEqualStrings(parent_handle1.path, child_handle1.path);

    child.release_file(fd0);
    try std.testing.expect(child.get_file_handle(fd0) == null);
    try std.testing.expect(parent.get_file_handle(fd0) != null);

    parent.release_file(fd1);
    try std.testing.expect(parent.get_file_handle(fd1) == null);
    try std.testing.expect(child.get_file_handle(fd1) != null);
}

const DirectoryMock = @import("fs/tests/directory_mock.zig").DirectoryMock;
const DirectoryIteratorMock = @import("fs/tests/directory_mock.zig").DirectoryIteratorMock;

test "FileHandle.ShouldCreateIterator" {
    var directory_mock = try DirectoryMock.create(std.testing.allocator);
    defer directory_mock.delete();
    const dir_node = kernel.fs.Node.create_directory(directory_mock.interface);

    var handle = try Process.FileHandle.create(std.testing.allocator, "/some/dir", dir_node);
    defer handle.close();

    var iterator_mock = try DirectoryIteratorMock.create(std.testing.allocator);
    defer iterator_mock.delete();

    const iterator = iterator_mock.get_interface();
    _ = directory_mock
        .expectCall("iterator")
        .willReturn(iterator);

    const sut_iterator = try handle.get_iterator();
    _ = iterator_mock
        .expectCall("next")
        .willReturn(null);
    _ = sut_iterator.interface.next();

    // next call should return the same iterator
    const sut_iterator2 = try handle.get_iterator();
    _ = iterator_mock
        .expectCall("next")
        .willReturn(null);
    _ = sut_iterator2.interface.next();
}

test "FileHandle.ShouldRemoveIterator" {
    var directory_mock = try DirectoryMock.create(std.testing.allocator);
    defer directory_mock.delete();
    const dir_node = kernel.fs.Node.create_directory(directory_mock.interface);

    var handle = try Process.FileHandle.create(std.testing.allocator, "/some/dir", dir_node);
    defer handle.close();

    var iterator_mock = try DirectoryIteratorMock.create(std.testing.allocator);
    defer iterator_mock.delete();

    const iterator = iterator_mock.get_interface();
    _ = directory_mock
        .expectCall("iterator")
        .willReturn(iterator);

    const sut_iterator = try handle.get_iterator();
    _ = iterator_mock
        .expectCall("next")
        .willReturn(null);
    _ = sut_iterator.interface.next();

    try std.testing.expect(handle.diriter != null);
    handle.remove_iterator();
    try std.testing.expectEqual(null, handle.diriter);
}

test "FileHandle.ShouldRejectIteratorForFileDescriptor" {
    var file_mock = try FileMock.create(std.testing.allocator);
    defer file_mock.delete();
    const file_node = kernel.fs.Node.create_file(file_mock.interface);

    var handle = try Process.FileHandle.create(std.testing.allocator, "/some/file", file_node);
    defer handle.close();

    try std.testing.expectError(kernel.errno.ErrnoSet.NotADirectory, handle.get_iterator());
}
