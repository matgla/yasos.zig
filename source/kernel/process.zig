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
const preempt = @import("sync/preempt.zig");

const log = std.log.scoped(.@"kernel/process");

const arch_process = @import("arch").process;

const Semaphore = @import("semaphore.zig").Semaphore;
const IDirectoryIterator = @import("fs/idirectory.zig").IDirectoryIterator;
const system_call = @import("interrupts/system_call.zig");
const arch = @import("arch");

const hal = @import("hal");

const default_nofile_limit: c.rlim_t = 256;

/// One system tick, in microseconds: SysTick is programmed at
/// `hal.cpu.frequency() / 1000` on every core (`source/arch/arm-m/process.zig`).
/// It is the finest deadline a yield can serve, so `sleep_for_us` spins the
/// remainder out rather than yielding it away.
const tick_us: u64 = 1000;

pub fn create_default_resource_limits(stack_size: u32) [c.RLIM_NLIMITS]c.rlimit {
    const max_stack_size = @max(stack_size, config.process.max_stack_size);
    var limits: [c.RLIM_NLIMITS]c.rlimit = undefined;
    for (&limits) |*limit| {
        limit.* = .{
            .rlim_cur = c.RLIM_INFINITY,
            .rlim_max = c.RLIM_INFINITY,
        };
    }

    limits[c.RLIMIT_NOFILE] = .{
        .rlim_cur = default_nofile_limit,
        .rlim_max = default_nofile_limit,
    };
    limits[c.RLIMIT_NPROC] = .{
        .rlim_cur = config.process.max_pid_value - 1,
        .rlim_max = config.process.max_pid_value - 1,
    };
    limits[c.RLIMIT_STACK] = .{
        .rlim_cur = stack_size,
        .rlim_max = max_stack_size,
    };

    return limits;
}

var pid_counter: u32 = 0;

pub fn init() void {
    arch_process.init();
}

fn exit_handler_impl() void {
    c.exit(0);
}

pub const VForkContext = struct {
    lr: usize,
    sp: usize,
    fp: usize,
    /// Whether the parent's frames were copied out for this vfork. False means
    /// `save_vfork_stack` declined and the child was released *below* them, so
    /// they are still live and the hand-off must not expect a restore. Without
    /// this the two cases are both "`_vfork_stack_len == 0`" and a lost restore
    /// is indistinguishable from a legitimate one.
    saved: bool = false,
};

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

        /// A child that has exited and is waiting to be collected by `waitpid`.
        /// One slot per child rather than a single code, so concurrent exits do
        /// not overwrite each other -- which is the point of `waitpid(-1)`.
        pub const ExitedChild = struct {
            pid: c.pid_t,
            status: i32,
            node: std.DoublyLinkedList.Node = .{},
        };

        state: State,
        priority: u8,
        impl: ImplType,
        pid: c.pid_t,
        _kernel_allocator: std.mem.Allocator,
        current_core: u8,
        // Whether this process runs as a privileged thread. The root/init process
        // runs kernel code (file descriptor setup, the dynamic loader, logging) in
        // thread mode and must stay privileged; all spawned user processes run
        // unprivileged so the MPU can keep them out of the kernel heap and stack.
        privileged: bool,
        // Live thread privilege (CONTROL.nPRIV == 0) captured when this process's
        // context was last stored by a context switch. A process preempted INSIDE
        // the privileged thread-mode phase of a syscall must be resumed privileged
        // — restoring from the static `privileged` flag resumes it unprivileged
        // mid-syscall and the next kernel access (e.g. a UART register in
        // sys_read's polling loop) takes a MemManage DACCVIOL HardFault. Written
        // by update_stack_pointer() on every context store; read by the PendSV
        // resume path via process_resume_is_privileged().
        resume_privileged: bool,
        /// What this process is blocked on, or null when it is not. An opaque
        /// token rather than `?*const Semaphore`, so the sleeping mutex can
        /// reuse the same machinery; its identity is all the wake-up scan needs.
        waiting_for: ?*const anyopaque = null,
        _fds: std.AutoHashMap(u16, FileHandle),
        /// See `clear_fds`: it runs at exit *and* from `deinit`, and must not
        /// tear the map down twice.
        _fds_cleared: bool = false,
        cwd: []u8,
        node: std.DoublyLinkedList.Node,
        _process_memory_allocator: ProcessMemoryAllocator,
        _parent: ?*Self = null,
        _child: ?*Self = null,
        _blocked_by: std.DoublyLinkedList,
        _blocks: std.DoublyLinkedList,
        /// Children of this process that have exited and not yet been collected.
        /// Also the token this process blocks on in `waitpid(-1)`, which is what
        /// makes "wake me when *any* child finishes" expressible at all: the
        /// per-child wait list can only name one child up front.
        _exited_children: std.DoublyLinkedList = .{},
        _stack_shared_with_parent: bool,
        _vfork_context: ?VForkContext = null,
        /// The slice of this process's stack a vfork child is running over.
        ///
        /// A vfork child continues from the parent's `vfork()` call site, the
        /// only stack pointer the caller's frame offsets are valid against, so
        /// everything below it is the child's to reuse -- and is also where the
        /// parent's suspended kernel frames live. Those bytes are copied out
        /// when the child starts and put back when it execs or exits.
        ///
        /// Kept on the parent and reused across vforks: a process parked in
        /// vfork cannot reach `vfork()` again until its child is gone.
        _vfork_stack: ?[]u8 = null,
        /// Address the saved bytes came from, and how many are live (0 = none).
        _vfork_stack_base: usize = 0,
        _vfork_stack_len: usize = 0,
        /// The parent's stack pointer at its `vfork()` call site: the exclusive
        /// upper bound of the region above.
        _vfork_stack_top: usize = 0,
        _initialized: bool = false,
        /// Sleeping-mutex ranks this process holds, parked here while it is not
        /// running. lockdep's held-set is per-core, which is right for the
        /// `spin_irq` locks but wrong for a `RankedMutex`, whose holder can
        /// block and resume on the other core. Saved and restored by
        /// `RoundRobin.update_current`; see `sync/locks.zig:migrating_ranks`.
        _held_lock_ranks: u16 = 0,
        _start_time: u64,
        // Wall-clock (us) captured right after this process's exec'd image is
        // loaded and relocated. Used to separate dynamic-load time from real
        // execution time when perf profiling is enabled. 0 means the process was
        // never exec'd (e.g. a forked process that did not call execve).
        _exec_loaded_time: u64 = 0,
        // How long (us) the dynamic loader spent producing this process's
        // image: path lookup, image copy for a non-XIP file, relocation and
        // every library it pulled in. A process cannot measure this itself, so
        // it is handed back through sys_perf_dump. 0 = never exec'd.
        _load_us: u64 = 0,
        vfork_return: usize = 0,
        vfork_sp: usize = 0,
        vfork_fp: usize = 0,
        child_exit_code: i32 = 0,
        _last_tty_output_fd: ?u16 = null,
        _pending_tty_newline_on_exit: bool = false,
        resource_limits: [c.RLIM_NLIMITS]c.rlimit,

        pub const State = enum(u3) {
            Initialized,
            Ready,
            Blocked,
            Running,
            Terminated,
        };

        pub fn init(kernel_allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, arg: ?*const anyopaque, cwd: []const u8, process_memory_pool: *ProcessMemoryPoolType, parent: ?*Self, pid: c.pid_t, is_root: bool) !*Self {
            const process = try kernel_allocator.create(Self);
            kernel.log.debug("initializing memory allocator for pid: {d}", .{pid});
            const cwd_handle = try kernel_allocator.alloc(u8, cwd.len);
            @memcpy(cwd_handle[0..cwd.len], cwd);
            var args: [1]usize = [_]usize{0};
            if (arg) |a| {
                args[0] = @intFromPtr(a);
            }
            process.* = .{
                .state = State.Ready,
                .priority = 0,
                .impl = undefined,
                .pid = pid,
                ._kernel_allocator = kernel_allocator,
                .current_core = 0,
                .privileged = is_root,
                .resume_privileged = is_root,
                ._fds = std.AutoHashMap(u16, FileHandle).init(kernel_allocator),
                .cwd = cwd_handle,
                .node = .{},
                ._process_memory_allocator = ProcessMemoryAllocator.init(pid, process_memory_pool),
                ._parent = parent,
                ._blocked_by = std.DoublyLinkedList{},
                ._blocks = std.DoublyLinkedList{},
                ._stack_shared_with_parent = false,
                ._vfork_context = null,
                ._start_time = hal.time.get_time_us(),
                .resource_limits = create_default_resource_limits(stack_size),
            };
            process.impl = try ImplType.init(process._process_memory_allocator.allocator(), stack_size, process_entry, exit_handler_impl, args[0..], is_root);
            return process;
        }

        /// Close every open file descriptor. Thread context only: closing a
        /// descriptor is filesystem I/O and takes the sleeping `fs_lock`, so it
        /// cannot run from an exception handler. Called from `delete_process`,
        /// and idempotent because `deinit` still calls it for the paths that
        /// destroy a process without going through it (a failed spawn).
        pub fn clear_fds(self: *Self) void {
            if (self._fds_cleared) return;
            self._fds_cleared = true;
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

        pub fn schedule_removal(self: *Self) void {
            self.state = State.Terminated;
        }

        pub fn deinit(self: *Self) void {
            const pool = self._process_memory_allocator.get_pool();
            log.info("deinit pid={d}: kernel_used={d} process_pages={d}", .{ self.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size() });
            self.impl.deinit(self._process_memory_allocator.allocator());
            log.info("deinit pid={d}: after impl.deinit kernel_used={d} process_pages={d}", .{ self.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size() });
            self.clear_fds();
            log.info("deinit pid={d}: after clear_fds kernel_used={d} process_pages={d} alloc_count={d}", .{ self.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size(), kernel.memory.heap.malloc.get_counter() });
            if (self._vfork_stack) |buffer| {
                self._kernel_allocator.free(buffer);
                self._vfork_stack = null;
            }
            self.drop_exited_children();
            self._kernel_allocator.free(self.cwd);
            self._process_memory_allocator.deinit();
            log.info("deinit pid={d}: after proc_mem.deinit kernel_used={d} process_pages={d}", .{ self.pid, kernel.memory.heap.malloc.get_usage(), pool.get_used_size() });
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

        /// Bound this process's heap to `heap_bytes` beyond its current footprint
        /// (the image + stack already resident at exec time). Enforces the YAFF
        /// heap_size profile: once set, dynamic allocations that would exceed the
        /// ceiling fail (user malloc returns NULL) instead of growing the shared
        /// paged pool without bound. 0xFFFFFFFF = unbounded. Call after the stack
        /// is reallocated so the baseline captures the fixed sections.
        pub fn set_heap_limit_bytes(self: *Self, heap_bytes: u32) void {
            self._process_memory_allocator.set_heap_limit_bytes(heap_bytes);
        }
        // this is full copy of the process, so it shares the same stack
        // stack relocation impossible without MMU
        pub fn vfork(self: *Self, process_memory_pool: *ProcessMemoryPoolType, pid: c.pid_t) !*Self {
            // allocate stack copy
            const process = try self._kernel_allocator.create(Self);
            const cwd_handle = try self._kernel_allocator.alloc(u8, self.cwd.len);
            @memcpy(cwd_handle, self.cwd);

            process.* = .{
                .state = State.Ready,
                .priority = self.priority,
                .impl = undefined,
                .pid = pid,
                ._kernel_allocator = self._kernel_allocator,
                .current_core = 0,
                // A vfork child is a user process on its way to exec; it must run
                // unprivileged regardless of whether its parent (e.g. the init
                // process) is privileged.
                .privileged = false,
                .resume_privileged = false,
                ._fds = try self.dupe_fds(),
                .cwd = cwd_handle,
                .node = .{},
                ._process_memory_allocator = ProcessMemoryAllocator.init(pid, process_memory_pool),
                ._parent = self,
                ._blocked_by = std.DoublyLinkedList{},
                ._blocks = std.DoublyLinkedList{},
                ._stack_shared_with_parent = true,
                ._vfork_context = null,
                ._initialized = false,
                ._start_time = hal.time.get_time_us(),
                .resource_limits = self.resource_limits,
            };
            process.impl = try self.impl.vfork(process._process_memory_allocator.allocator());
            self._child = process;

            return process;
        }

        pub fn has_stack_shared_with_parent(self: *Self) bool {
            return self._stack_shared_with_parent;
        }

        /// Make room to save the stack a vfork child is about to run over.
        /// Called before the child exists, so a heap that cannot spare the
        /// buffer fails `vfork()` rather than the hand-off. `top` is the
        /// parent's stack pointer at its call site; `capacity` must reach down
        /// to where the child is released, deeper than this caller's frame.
        pub fn reserve_vfork_stack(self: *Self, top: usize, capacity: usize) !void {
            self._vfork_stack_top = top;
            self._vfork_stack_len = 0;
            if (self._vfork_stack) |buffer| {
                if (buffer.len >= capacity) return;
                self._kernel_allocator.free(buffer);
                self._vfork_stack = null;
            }
            self._vfork_stack = try self._kernel_allocator.alloc(u8, capacity);
        }

        /// Copy [`low`, call site) out of the stack. Returns false when there is
        /// nowhere to put it, which means the child must NOT be given its
        /// caller's stack pointer.
        ///
        /// Must run with the stack pointer at or below `low`, or it would copy
        /// its own frame over the parent's.
        pub fn save_vfork_stack(self: *Self, low: usize) bool {
            const buffer = self._vfork_stack orelse return false;
            if (low >= self._vfork_stack_top) return false;
            const length = self._vfork_stack_top - low;
            if (length > buffer.len) return false;
            const source: [*]const u8 = @ptrFromInt(low);
            @memcpy(buffer[0..length], source[0..length]);
            self._vfork_stack_base = low;
            self._vfork_stack_len = length;
            return true;
        }

        /// Diagnostic: the state of this process's vfork save, and the `lr` word
        /// inside it. `process_vfork_child` pushes `{r4-r12, lr}` for the parent
        /// and `process_vfork_back_here` pops it back as `{r4-r12, pc}`, so that
        /// word -- 40-byte frame, `lr` last, hence offset 36 -- is the address
        /// the parent resumes at. Reading it here says whether a zero `pc` was
        /// already in the buffer at save time or arrived after the restore.
        pub const VForkSaveState = struct {
            base: usize,
            len: usize,
            top: usize,
            resume_pc: ?u32,
        };

        pub fn vfork_save_state(self: *const Self) VForkSaveState {
            var resume_pc: ?u32 = null;
            if (self._vfork_stack) |buffer| {
                if (self._vfork_stack_len >= 40) {
                    resume_pc = std.mem.readInt(u32, buffer[36..40][0..4], .little);
                }
            }
            return .{
                .base = self._vfork_stack_base,
                .len = self._vfork_stack_len,
                .top = self._vfork_stack_top,
                .resume_pc = resume_pc,
            };
        }

        /// The stack pointer this process had at its `vfork()` call site, while
        /// the frames below it are saved and can be scribbled on. Null once they
        /// are not -- with no backup, those frames are the parent's only copy.
        pub fn vfork_stack_ceiling(self: *const Self) ?usize {
            if (self._vfork_stack_len == 0) return null;
            return self._vfork_stack_top;
        }

        /// Put the saved bytes back, so the parent can resume on them. Must run
        /// with the stack pointer below `_vfork_stack_base`, which
        /// `process_get_back_to_parent_vfork` guarantees by switching to the
        /// parent's resume position first.
        /// False when there was nothing to put back. Legitimate only when
        /// `save_vfork_stack` declined for this vfork -- the context's `saved`
        /// flag records which case it is. Returning it, rather than no-opping,
        /// is what makes a lost restore reportable instead of showing up later
        /// as a branch through an unrestored frame.
        pub fn restore_vfork_stack(self: *Self) bool {
            const buffer = self._vfork_stack orelse return false;
            const length = self._vfork_stack_len;
            if (length == 0) return false;
            self._vfork_stack_len = 0;
            const destination: [*]u8 = @ptrFromInt(self._vfork_stack_base);
            @memcpy(destination[0..length], buffer[0..length]);
            return true;
        }

        pub fn release_parent_after_getting_freedom(self: *Self) *std.DoublyLinkedList.Node {
            self.unblock_parent();
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

        pub fn is_privileged(self: Self) bool {
            return self.privileged;
        }

        pub fn get_stack_bottom(self: Self) *const u8 {
            return self.impl.get_stack_bottom();
        }

        pub fn get_stack_top(self: Self) *const u8 {
            return self.impl.get_stack_top();
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
            self.block_on(semaphore);
        }

        /// Mark this process blocked on an arbitrary blocker. The caller must
        /// hold whatever guards the blocker, or a racing unlock can decide there
        /// is nobody to wake between the decision to block and the state change.
        pub fn block_on(self: *Self, blocker: *const anyopaque) void {
            self.waiting_for = blocker;
            self.reevaluate_state();
        }

        /// Whether this process is blocked on `blocker`.
        pub fn is_blocked_on(self: Self, blocker: *const anyopaque) bool {
            if (self.waiting_for) |current| return current == blocker;
            return false;
        }

        /// Release this process from `blocker`, if that is what it is waiting on.
        /// Clears `waiting_for`; `unblock_from` below is the different
        /// relationship on `_blocked_by`.
        pub fn wake_from(self: *Self, blocker: *const anyopaque) void {
            if (self.waiting_for) |current| {
                if (current == blocker) {
                    self.waiting_for = null;
                    self.reevaluate_state();
                }
            }
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
            //
            // Preemption is refused rather than a lock taken: the two wait lists
            // spliced here are also reached from `delete_process` and the
            // semaphore wake-up scan, both already under `proctable_lock`, so
            // taking it here would be a same-rank nesting.
            preempt.preempt_disable();
            defer preempt.preempt_enable();
            const blocked_data = try self._kernel_allocator.create(BlockedByProcess);
            try process.blocks_process(self, action, context);
            blocked_data.* = .{
                .waiting_for = process,
                .node = std.DoublyLinkedList.Node{},
            };
            self._blocked_by.append(&blocked_data.node);
            self.reevaluate_state();
        }

        /// Recompute this process's state from what it is waiting on.
        ///
        /// `Running` is sticky, and that is a correctness rule: every waker in
        /// the tree calls this on *other* processes, and publishing a process
        /// the other core is running as `Ready` would let this core claim it and
        /// have both resume the same context off the same stack pointer. The
        /// only `Running -> Ready` transition is `release_from_core`, on the
        /// core that owns the claim and after the context has been stored.
        /// `Running -> Blocked` stays allowed -- it is always a process blocking
        /// itself.
        pub fn reevaluate_state(self: *Self) void {
            if (self.state == State.Terminated) {
                return;
            }
            if (self.waiting_for != null) {
                self.state = Process.State.Blocked;
                return;
            }

            if (self._blocked_by.first != null) {
                self.state = Process.State.Blocked;
                return;
            }
            if (self.state == State.Running) {
                return;
            }
            self.state = Process.State.Ready;
        }

        /// Give up the claim a core holds on this process -- the counterpart to
        /// `RoundRobin.try_claim`, and the only place a `Running` process
        /// becomes schedulable again. Called with `proctable_lock` held and
        /// after the outgoing context has been written to its stack; any earlier
        /// and the other core could resume it from a stale stack pointer.
        pub fn release_from_core(self: *Self) void {
            if (self.state == State.Running) {
                self.state = State.Ready;
            }
            // It may have blocked itself while it was running, so the wait lists
            // still get the final word.
            self.reevaluate_state();
        }

        pub fn is_blocked_by(self: Self, semaphore: *const Semaphore) bool {
            return self.is_blocked_on(semaphore);
        }

        pub fn unblock_semaphore(self: *Self, semaphore: *const Semaphore) void {
            self.wake_from(semaphore);
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

        /// Note that a child has exited, for a later `waitpid` to collect. Best
        /// effort: if the record cannot be allocated the exit is still reported
        /// through `child_exit_code`.
        pub fn record_child_exit(self: *Self, child_pid: c.pid_t, status: i32) void {
            const entry = self._kernel_allocator.create(ExitedChild) catch {
                log.err("no room to record the exit of pid={d}", .{child_pid});
                return;
            };
            entry.* = .{ .pid = child_pid, .status = status };
            self._exited_children.append(&entry.node);
            // Anything parked in waitpid(-1) is waiting on exactly this list.
            self.wake_from(&self._exited_children);
        }

        /// Collect an exited child: `pid` of -1 takes the oldest, any other
        /// value takes that child only. Null when there is nothing to collect.
        pub fn take_exited_child(self: *Self, pid: c.pid_t) ?ExitedChild {
            var it = self._exited_children.first;
            while (it) |node| {
                const entry: *ExitedChild = @fieldParentPtr("node", node);
                it = node.next;
                if (pid != -1 and entry.pid != pid) continue;
                const collected = entry.*;
                self._exited_children.remove(node);
                self._kernel_allocator.destroy(entry);
                return collected;
            }
            return null;
        }

        /// The token `waitpid(-1)` blocks on; see `_exited_children`.
        pub fn any_child_blocker(self: *Self) *const anyopaque {
            return &self._exited_children;
        }

        fn drop_exited_children(self: *Self) void {
            while (self._exited_children.pop()) |node| {
                const entry: *ExitedChild = @fieldParentPtr("node", node);
                self._kernel_allocator.destroy(entry);
            }
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
            // Preemptible; see the syscall wrappers. The pool guards itself.
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

        pub fn reallocate_stack(self: *Self) !void {
            const stack_limit = try self.get_resource_limit(c.RLIMIT_STACK);
            const requested_stack_size = std.math.cast(u32, stack_limit.rlim_cur) orelse return kernel.errno.ErrnoSet.InvalidArgument;
            log.debug("Reallocating stack to new size: {d}", .{requested_stack_size});
            try self.impl.reallocate_stack(requested_stack_size);
        }

        pub fn munmap(self: *Self, maybe_address: ?*anyopaque, length: i32) void {
            // Preemptible; see the syscall wrappers. The pool guards itself.
            if (maybe_address) |addr| {
                var number_of_pages = @divTrunc(length, ProcessMemoryPoolType.page_size);
                if (@rem(length, ProcessMemoryPoolType.page_size) != 0) {
                    number_of_pages += 1;
                }
                self._process_memory_allocator.release_pages(addr, number_of_pages);
            }
        }

        /// Try to extend an existing mmap allocation in-place.
        /// Returns the same address on success (with extended size), or error.
        pub fn mremap(self: *Self, addr: *anyopaque, old_length: i32, new_length: i32, flags: i32) !*anyopaque {
            // Preemptible; see the syscall wrappers. The pool guards itself.
            _ = flags;
            var old_pages = @divTrunc(old_length, ProcessMemoryPoolType.page_size);
            if (@rem(old_length, ProcessMemoryPoolType.page_size) != 0) {
                old_pages += 1;
            }
            var new_pages = @divTrunc(new_length, ProcessMemoryPoolType.page_size);
            if (@rem(new_length, ProcessMemoryPoolType.page_size) != 0) {
                new_pages += 1;
            }
            if (self._process_memory_allocator.try_extend_pages(addr, old_pages, new_pages)) |extended| {
                return extended.ptr;
            }
            return kernel.errno.ErrnoSet.OutOfMemory;
        }

        fn can_allocate_fd(self: *const Self, fd: u16) bool {
            const limit = self.resource_limits[c.RLIMIT_NOFILE].rlim_cur;
            if (limit == c.RLIM_INFINITY) {
                return true;
            }

            return @as(c.rlim_t, fd) < limit;
        }

        pub fn get_resource_limit(self: *const Self, resource: i32) !c.rlimit {
            if (resource < 0 or resource >= c.RLIM_NLIMITS) {
                return kernel.errno.ErrnoSet.InvalidArgument;
            }

            return self.resource_limits[@intCast(resource)];
        }

        pub fn set_resource_limit(self: *Self, resource: i32, limit: c.rlimit) !void {
            if (resource < 0 or resource >= c.RLIM_NLIMITS) {
                return kernel.errno.ErrnoSet.InvalidArgument;
            }

            if (limit.rlim_cur > limit.rlim_max) {
                return kernel.errno.ErrnoSet.InvalidArgument;
            }

            self.resource_limits[@intCast(resource)] = limit;
        }

        pub fn set_resource_limits(self: *Self, limits: [c.RLIM_NLIMITS]c.rlimit) void {
            self.resource_limits = limits;
        }

        pub fn get_free_fd(self: *Self) ?u16 {
            var fd: u16 = 0;
            while (true) {
                if (!self.can_allocate_fd(fd)) {
                    return null;
                }
                if (self._fds.get(fd) == null) {
                    return fd;
                }
                if (fd == std.math.maxInt(u16)) {
                    return null;
                }
                fd += 1;
            }
        }

        pub fn get_parent(self: Self) ?*Self {
            return self._parent;
        }

        /// Sleep for at least `us` microseconds: a yield-spin against the
        /// microsecond wall clock, not the millisecond tick, so a sub-tick
        /// request is not truncated to a no-op.
        ///
        /// The last tick is spun through rather than yielded away, because a
        /// yield cannot resolve a sub-tick deadline -- whoever runs next holds
        /// the CPU for its own 100-tick quantum.
        ///
        /// Not a real sleep: the process stays `Ready` and burns quanta until
        /// the deadline passes. Blocking would need a `wake_at` in the
        /// scheduler.
        pub fn sleep_for_us(self: *Self, us: u64) void {
            _ = self;
            // Saturating, so an absurd request cannot overflow the deadline into
            // the past. Plain comparisons below: the qemu boards' `get_time_us`
            // accumulates its 32-bit timer non-atomically, so it can step
            // backwards, which wrapping arithmetic would read as "long passed".
            const deadline = hal.time.get_time_us() +| us;
            while (true) {
                const now = hal.time.get_time_us();
                if (now >= deadline) return;
                if (deadline - now >= tick_us) {
                    // Context switch, we are waiting for the deadline.
                    hal.irq.trigger(.pendsv);
                }
            }
        }

        pub fn sleep_for_ms(self: *Self, ms: u32) void {
            self.sleep_for_us(@as(u64, @intCast(ms)) * 1000);
        }

        pub fn reinitialize_stack(self: *Self, process_entry: anytype, argc: usize, argv: usize, symbol: usize, got: usize) !void {
            try self.impl.reinitialize_stack(process_entry, argc, argv, symbol, got, exit_handler_impl);
            self._initialized = false;
        }

        pub fn is_initialized(self: *const Self) bool {
            return self._initialized;
        }

        pub fn get_uptime(self: *const Self) u64 {
            return hal.time.get_time_us() - self._start_time;
        }

        pub fn attach_file(self: *Self, path: []const u8, node: kernel.fs.Node) !i32 {
            const fd = self.get_free_fd() orelse return kernel.errno.ErrnoSet.TooManyOpenFiles;
            return try self.attach_file_with_fd(@intCast(fd), path, node);
        }

        pub fn attach_file_with_fd(self: *Self, fd: i16, path: []const u8, node: kernel.fs.Node) !i32 {
            if (fd < 0) {
                return kernel.errno.ErrnoSet.InvalidArgument;
            }

            if (!self.can_allocate_fd(@intCast(fd))) {
                return kernel.errno.ErrnoSet.TooManyOpenFiles;
            }

            const handle = try FileHandle.create(self._kernel_allocator, path, node);
            try self._fds.put(@intCast(fd), handle);
            return @intCast(fd);
        }

        pub fn release_file(self: *Self, fd: i32) void {
            const maybe_handle = self._fds.getPtr(@intCast(fd));
            if (maybe_handle) |handle| {
                if (self._last_tty_output_fd != null and self._last_tty_output_fd.? == @as(u16, @intCast(fd))) {
                    self._last_tty_output_fd = null;
                    self._pending_tty_newline_on_exit = false;
                }
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

        pub fn record_tty_output(self: *Self, fd: i32, data: []const u8) void {
            if (fd < 0 or data.len == 0) {
                return;
            }
            self._last_tty_output_fd = @intCast(fd);
            self._pending_tty_newline_on_exit = data[data.len - 1] != '\n';
        }

        pub fn should_append_tty_newline_on_exit(self: *const Self) bool {
            return self._last_tty_output_fd != null and self._pending_tty_newline_on_exit;
        }

        pub fn append_tty_newline_on_exit(self: *Self) void {
            if (!self.should_append_tty_newline_on_exit()) {
                return;
            }

            const fd = self._last_tty_output_fd.?;
            const maybe_handle = self._fds.getPtr(fd);
            if (maybe_handle) |handle| {
                if (handle.node.is_file()) {
                    var maybe_file = handle.node.as_file();
                    if (maybe_file) |*file| {
                        if (file.interface.filetype() == kernel.fs.FileType.CharDevice) {
                            _ = file.interface.write("\n");
                        }
                    }
                }
            }

            self._pending_tty_newline_on_exit = false;
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

    pub fn used_pages_for(self: *const Self, pid: c.pid_t) usize {
        _ = self;
        _ = pid;
        return 0;
    }

    pub fn get_used_size(self: *const Self) usize {
        _ = self;
        return 0;
    }

    /// Mirrors the real pool's signature; the test stub does not care which
    /// accounting bucket a run belongs to.
    pub fn allocate_pages_from(self: *Self, number_of_pages: i32, pid: c.pid_t, source: anytype) ?[]u8 {
        _ = source;
        return self.allocate_pages(number_of_pages, pid);
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

    /// The reuse cache asks before parking a run. These tests assert what the
    /// process forwarded to the pool, so nothing may be swallowed by the cache
    /// on the way -- refusing every run keeps free_pages observable.
    pub fn owns_mapping(self: *const Self, pid: c.pid_t, address: *const anyopaque, bytes: usize) bool {
        _ = self;
        _ = pid;
        _ = address;
        _ = bytes;
        return false;
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
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, cwd_for_process, &pool, null, pid_for_process, false);
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
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 20, false);
    defer sut.deinit();

    try sut.change_directory("/home/user");
    try std.testing.expectEqualStrings("/home/user", sut.get_current_directory());
}

test "Process.ShouldAttachAndReleaseFile" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 30, false);
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
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 40, false);
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
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 50, false);
    defer sut.deinit();

    hal.time.impl.set_time(2500);
    try std.testing.expectEqual(@as(u64, 2000), sut.get_uptime());
}

test "Process.ShouldSetCurrentCore" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 60, false);
    defer sut.deinit();

    sut.set_core(2);
    try std.testing.expectEqual(@as(u8, 2), sut.current_core);
}

const irq_systick = @import("interrupts/systick.zig").irq_systick;
test "Process.ShouldSleepForMilliseconds" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 70, false);
    defer sut.deinit();

    const PendSvAction = struct {
        pub fn call() void {
            // One second per switch, on both clocks. The wall clock is the one
            // `sleep_for_us` waits on now, and the stub only moves when
            // something moves it -- without this line the sleep never ends.
            hal.time.impl.set_time(hal.time.get_time_us() + 1000 * 1000);
            hal.time.systick.set_ticks(hal.time.systick.get_system_tick() + 1000);
            for (0..1000) |_| irq_systick();
        }
    };

    hal.irq.impl().set_irq_action(.pendsv, &PendSvAction.call);
    sut.sleep_for_ms(10);
}

test "Process.ShouldSleepForSubMillisecondDelay" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 71, false);
    defer sut.deinit();

    // A sub-tick sleep deliberately does not yield, so there is no PendSV
    // action to advance the stub clock from: let it run on its own instead.
    hal.time.impl.set_auto_advance_us(10);
    defer hal.time.impl.set_auto_advance_us(0);

    const start = hal.time.get_time_us();
    sut.sleep_for_us(500);
    // The whole point: `us / 1000` used to truncate to zero ticks here and
    // return with the clock untouched.
    try std.testing.expect(hal.time.get_time_us() - start >= 500);
}

test "Process.ShouldForkProcess" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);
    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 80, false);
    try std.testing.expectEqual(null, parent._parent);
    defer parent.deinit();

    var child = try parent.vfork(&pool, 81);
    defer child.deinit();

    try std.testing.expect(child.get_parent() == parent);
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
    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 90, false);
    defer parent.deinit();

    var child1 = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, parent, 91, false);
    defer child1.deinit();

    var child2 = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, parent, 92, false);
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
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 100, false);
    defer sut.deinit();

    var sem = Semaphore.create(1);

    sut.block_semaphore(&sem);
    try std.testing.expectEqual(ProcessUnderTest.State.Blocked, sut.state);
    try std.testing.expect(sut.is_blocked_by(&sem));
}

test "Process.ShouldUnblockSemaphoreAndUpdateState" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 110, false);
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

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 120, false);
    defer parent.deinit();

    const parent_stack_before = parent.stack_pointer();

    var child = try parent.vfork(&pool, 121);
    defer child.deinit();

    try std.testing.expect(child.has_stack_shared_with_parent());

    try std.testing.expectEqual(parent_stack_before, child.stack_pointer());
    const new_child_sp_addr = @intFromPtr(child.get_stack_bottom()) + 64;
    const new_child_sp = @as(*u8, @ptrFromInt(new_child_sp_addr));
    child.set_stack_pointer(new_child_sp);

    // try std.testing.expect(parent.stack_pointer() != parent_stack_before);
    try std.testing.expectEqual(new_child_sp, child.stack_pointer());
}

test "Process.ShouldCollectEachExitedChildOnce" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 130, false);
    defer parent.deinit();

    // Two children exiting before either is waited for: the single
    // `child_exit_code` slot this replaced would report the second one twice.
    parent.record_child_exit(131, 0x100);
    parent.record_child_exit(132, 0x200);

    // -1 takes them oldest first, and each entry only once.
    const first = parent.take_exited_child(-1).?;
    try std.testing.expectEqual(@as(c.pid_t, 131), first.pid);
    try std.testing.expectEqual(@as(i32, 0x100), first.status);

    const second = parent.take_exited_child(-1).?;
    try std.testing.expectEqual(@as(c.pid_t, 132), second.pid);
    try std.testing.expectEqual(@as(i32, 0x200), second.status);

    try std.testing.expect(parent.take_exited_child(-1) == null);
}

test "Process.ShouldCollectAnExitedChildByPid" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 140, false);
    defer parent.deinit();

    parent.record_child_exit(141, 0x100);
    parent.record_child_exit(142, 0x200);

    try std.testing.expect(parent.take_exited_child(143) == null);

    const picked = parent.take_exited_child(142).?;
    try std.testing.expectEqual(@as(c.pid_t, 142), picked.pid);
    try std.testing.expectEqual(@as(i32, 0x200), picked.status);

    // The one that was skipped is still there, and nothing else is.
    try std.testing.expectEqual(@as(c.pid_t, 141), parent.take_exited_child(-1).?.pid);
    try std.testing.expect(parent.take_exited_child(-1) == null);
}

test "Process.ShouldWakeAWaitForAnyChildWhenOneExits" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 150, false);
    defer parent.deinit();

    // What waitpid(-1) does: park on the collection list rather than on a
    // named child, because which child finishes first is not known yet.
    parent.block_on(parent.any_child_blocker());
    try std.testing.expectEqual(ProcessUnderTest.State.Blocked, parent.state);

    parent.record_child_exit(151, 0x300);
    try std.testing.expectEqual(ProcessUnderTest.State.Ready, parent.state);
}

test "Process.ShouldFreeUncollectedChildrenOnExit" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);

    // A parent that exits without waiting still has to hand the records back;
    // the testing allocator fails this test if `deinit` leaks them.
    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 160, false);
    parent.record_child_exit(161, 0x100);
    parent.record_child_exit(162, 0x200);
    parent.deinit();
}

test "Process.ShouldMmapMemory" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 1;
    hal.time.impl.set_time(0);

    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 120, false);
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

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 200, false);
    var child = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, parent, 201, false);

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

    var parent = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &parent_pool, null, 210, false);
    defer parent.deinit();

    const file_mock1 = try FileMock.create(std.testing.allocator);
    defer file_mock1.delete();
    const node1 = kernel.fs.Node.create_file(file_mock1.interface);

    const file_mock2 = try FileMock.create(std.testing.allocator);
    defer file_mock2.delete();
    const node2 = kernel.fs.Node.create_file(file_mock2.interface);

    const fd0 = try parent.attach_file("/dev/test0", node1);
    const fd1 = try parent.attach_file("/dev/test1", node2);

    var child = try parent.vfork(&child_pool, 211);
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

test "Process.ShouldTrackPendingTtyNewlineOnExit" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 0;
    hal.time.impl.set_time(0);

    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 220, false);
    defer sut.deinit();

    sut.record_tty_output(1, "17");
    try std.testing.expect(sut.should_append_tty_newline_on_exit());

    sut.record_tty_output(1, "\n");
    try std.testing.expect(!sut.should_append_tty_newline_on_exit());
}

test "Process.ShouldClearPendingTtyNewlineWhenFdReleased" {
    var pool = ProcessMemoryPoolForTests{};
    var arg: usize = 0;
    hal.time.impl.set_time(0);

    var sut = try ProcessUnderTest.init(std.testing.allocator, 1024, &process_init, &arg, "/", &pool, null, 221, false);
    defer sut.deinit();

    var file_mock = try FileMock.create(std.testing.allocator);
    defer file_mock.delete();
    const node = kernel.fs.Node.create_file(file_mock.interface);

    const fd = try sut.attach_file("/dev/stdout", node);
    sut.record_tty_output(fd, "17");
    try std.testing.expect(sut.should_append_tty_newline_on_exit());

    sut.release_file(fd);
    try std.testing.expect(!sut.should_append_tty_newline_on_exit());
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
