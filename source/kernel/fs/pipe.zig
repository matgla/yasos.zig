//
// pipe.zig
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

// `pipe(2)`: a byte stream between two processes, presented as two ordinary
// `IFile`s, so dup2/close/redirects and the fd table copy a `vfork` makes all
// work with no special cases. The ends share a ring buffer plus the count of
// ends open for reading and writing, which is what makes EOF on a readerless
// write and a writerless read decidable.
//
// Blocking is the sleeping mutex's yield loop -- `block_on` under the guard,
// then trigger PendSV until woken -- not a spin: the process on the other end
// only runs if this one gives up the core. Marking the waiter blocked under the
// lock is what stops the wake-up being lost.

const std = @import("std");

const c = @import("libc_imports").c;
const hal = @import("hal");
const interface = @import("interface");

const kernel = @import("../kernel.zig");
const locks = @import("../sync/locks.zig");
const preempt = @import("../sync/preempt.zig");

const IFile = @import("ifile.zig").IFile;
const FileType = @import("ifile.zig").FileType;
const PollMask = @import("ifile.zig").PollMask;
const poll_readable = @import("ifile.zig").poll_readable;
const poll_writable = @import("ifile.zig").poll_writable;
const FileMemoryMapAttributes = @import("ifile.zig").FileMemoryMapAttributes;
const IoctlCommonCommands = @import("ifile.zig").IoctlCommonCommands;
const Node = @import("node.zig").Node;

const log = std.log.scoped(.pipe);

/// Rank 40, a leaf, `spin_irq`. One lock for every pipe rather than one per
/// pipe: the critical sections are a bounded `memcpy` and a few counters, and a
/// `Ranked` lock is padded to the 32-byte reservation granule -- worth paying
/// once, not once per pipe. Below `proctable` (50), so the process-table walk
/// that wakes waiters happens after this is dropped.
var pipe_lock: locks.Ranked(.pipe) = .{};

pub const Pipe = struct {
    /// How much a writer can get ahead of its reader. One page: enough that a
    /// line-at-a-time shell pipeline never blocks, small enough not to be a
    /// notable draw on the kernel heap.
    pub const capacity = 4096;

    /// Bytes copied per acquisition of `pipe_lock`, which bounds how long a
    /// transfer keeps interrupts masked against a console that overruns in tens
    /// of microseconds. Stopping at a chunk boundary is always legal -- the
    /// caller gets a short count, as it would from a pipe that full.
    const chunk = 512;

    _allocator: std.mem.Allocator,
    _buffer: []u8,
    /// Ring: `_length` bytes live, starting at `_read_at`.
    _read_at: usize = 0,
    _length: usize = 0,
    /// Ends still open in each direction. Zero is what read and write report
    /// EOF and "nobody is listening" from, so these are the pipe's real state,
    /// not bookkeeping.
    _readers: u32 = 0,
    _writers: u32 = 0,
    /// Live end objects. The pipe outlives neither, and is freed by the last.
    _ends: u32 = 0,

    /// Waited on by readers with nothing to read, posted by a writer or by the
    /// last writer closing. Only their addresses are used, as blocker tokens.
    _data_available: u8 = 0,
    _space_available: u8 = 0,

    pub fn create(allocator: std.mem.Allocator) !*Pipe {
        const self = try allocator.create(Pipe);
        errdefer allocator.destroy(self);
        self.* = .{
            ._allocator = allocator,
            ._buffer = try allocator.alloc(u8, capacity),
        };
        return self;
    }

    fn destroy(self: *Pipe) void {
        const allocator = self._allocator;
        allocator.free(self._buffer);
        allocator.destroy(self);
    }

    fn free_space(self: *const Pipe) usize {
        return capacity - self._length;
    }

    /// Readiness of one end, for `poll`. POLLHUP and POLLERR are reported
    /// whether or not the caller asked for them, as POSIX requires: a reader
    /// whose last writer is gone is at EOF, and a writer whose last reader is
    /// gone can only ever get EPIPE.
    pub fn poll(self: *Pipe, writable: bool, events: PollMask) PollMask {
        const flags = pipe_lock.lock_irqsave();
        defer pipe_lock.unlock_irqrestore(flags);
        var revents: PollMask = 0;
        if (writable) {
            if (self.free_space() > 0) revents |= events & poll_writable;
            if (self._readers == 0) revents |= c.POLLERR;
        } else {
            if (self._length > 0) revents |= events & poll_readable;
            if (self._writers == 0) revents |= c.POLLHUP;
        }
        return revents;
    }

    /// Copy out of the ring, caller holds `pipe_lock`. Returns bytes taken.
    fn take(self: *Pipe, out: []u8) usize {
        const count = @min(@min(out.len, self._length), chunk);
        if (count == 0) return 0;
        const until_wrap = capacity - self._read_at;
        const first = @min(count, until_wrap);
        @memcpy(out[0..first], self._buffer[self._read_at .. self._read_at + first]);
        if (first < count) {
            @memcpy(out[first..count], self._buffer[0 .. count - first]);
        }
        self._read_at = (self._read_at + count) % capacity;
        self._length -= count;
        return count;
    }

    /// Copy into the ring, caller holds `pipe_lock`. Returns bytes stored.
    fn put(self: *Pipe, data: []const u8) usize {
        const count = @min(@min(data.len, self.free_space()), chunk);
        if (count == 0) return 0;
        const write_at = (self._read_at + self._length) % capacity;
        const until_wrap = capacity - write_at;
        const first = @min(count, until_wrap);
        @memcpy(self._buffer[write_at .. write_at + first], data[0..first]);
        if (first < count) {
            @memcpy(self._buffer[0 .. count - first], data[first..count]);
        }
        self._length += count;
        return count;
    }

    /// Park until somebody posts `token`. The caller must already have marked
    /// itself blocked while holding `pipe_lock`, and must have released it: this
    /// yields, and a lock held across a yield is one the waker cannot take.
    fn wait(token: *const anyopaque) void {
        const process = kernel.process.process_manager.instance.get_current_process();
        while (process.is_blocked_on(token)) {
            hal.irq.trigger(.pendsv);
            process.reevaluate_state();
        }
    }

    /// Mark this process blocked on `token`. Caller holds `pipe_lock`, which is
    /// what makes the decision to wait and the waiting itself one step as far
    /// as a waker is concerned.
    fn prepare_wait(token: *const anyopaque) bool {
        if (!kernel.process.process_manager.is_initialized()) return false;
        kernel.process.process_manager.instance.get_current_process().block_on(token);
        return true;
    }

    /// Wake everything waiting on `token`. Must NOT be called under
    /// `pipe_lock`: the walk takes the process table's own lock, which is a
    /// lower rank, and taking it inside this one would invert the hierarchy.
    fn post(token: *const anyopaque) void {
        if (!kernel.process.process_manager.is_initialized()) return;
        kernel.process.process_manager.instance.wake_all_blocked_on(token);
    }

    /// Read into `out`, blocking until at least one byte arrives or the last
    /// writer goes away. Returns 0 for end of stream, as `read(2)` does.
    pub fn read(self: *Pipe, out: []u8, nonblocking: bool) isize {
        if (out.len == 0) return 0;

        var taken: usize = 0;
        while (true) {
            var waiting = false;
            {
                const flags = pipe_lock.lock_irqsave();
                defer pipe_lock.unlock_irqrestore(flags);

                taken = self.take(out);
                if (taken == 0) {
                    // Nothing to take. Only a live writer makes it worth
                    // waiting for; without one this is the end of the stream.
                    if (self._writers == 0) return 0;
                    if (nonblocking) return -1;
                    waiting = prepare_wait(&self._data_available);
                    if (!waiting) return 0;
                }
            }

            if (taken != 0) break;
            wait(&self._data_available);
        }

        // Somebody may be blocked waiting for the space just freed.
        post(&self._space_available);
        return @intCast(taken);
    }

    /// Write all of `data`, blocking while the pipe is full. Returns the number
    /// of bytes written, or -1 if no reader is left to receive them.
    pub fn write(self: *Pipe, data: []const u8, nonblocking: bool) isize {
        if (data.len == 0) return 0;

        var written: usize = 0;
        while (written < data.len) {
            var stored: usize = 0;
            var waiting = false;
            {
                const flags = pipe_lock.lock_irqsave();
                defer pipe_lock.unlock_irqrestore(flags);

                // POSIX raises SIGPIPE here as well; this kernel has no signal
                // delivery, so the failed write is all the caller gets.
                if (self._readers == 0) {
                    return if (written == 0) -1 else @intCast(written);
                }
                stored = self.put(data[written..]);
                if (stored == 0) {
                    if (nonblocking) {
                        return if (written == 0) -1 else @intCast(written);
                    }
                    waiting = prepare_wait(&self._space_available);
                    if (!waiting) return @intCast(written);
                }
            }

            if (stored != 0) {
                written += stored;
                // Woken here rather than after the whole transfer: a reader
                // waiting on the first chunk should start on it while this
                // writer is still producing the rest.
                post(&self._data_available);
                continue;
            }
            wait(&self._space_available);
        }

        return @intCast(written);
    }

    fn open_end(self: *Pipe, writable: bool) void {
        {
            const flags = pipe_lock.lock_irqsave();
            defer pipe_lock.unlock_irqrestore(flags);
            self._ends += 1;
            if (writable) self._writers += 1 else self._readers += 1;
        }
    }

    fn close_end(self: *Pipe, writable: bool) void {
        var last = false;
        {
            const flags = pipe_lock.lock_irqsave();
            defer pipe_lock.unlock_irqrestore(flags);
            if (writable) self._writers -= 1 else self._readers -= 1;
            self._ends -= 1;
            last = self._ends == 0;
        }

        // Whichever side just lost its counterpart is waiting for something that
        // can never arrive, so let it go; both re-check the counts on waking and
        // return EOF or failure.
        post(if (writable) &self._data_available else &self._space_available);

        if (last) self.destroy();
    }
};

/// One end of a pipe. `_writable` decides which; everything else is the pipe.
pub const PipeFile = interface.DeriveFromBase(IFile, struct {
    const Self = @This();

    _pipe: *Pipe,
    _writable: bool,
    _nonblocking: bool,
    _allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, pipe: *Pipe, writable: bool, nonblocking: bool) PipeFile {
        pipe.open_end(writable);
        return PipeFile.init(.{
            ._pipe = pipe,
            ._writable = writable,
            ._nonblocking = nonblocking,
            ._allocator = allocator,
        });
    }

    /// A duplicate is another end, not another reference: the fd table copy a
    /// `vfork` makes goes through here, and the child's copy has to keep the
    /// pipe open on its own account.
    pub fn __clone(self: *Self, other: *Self) void {
        self._pipe = other._pipe;
        self._writable = other._writable;
        self._nonblocking = other._nonblocking;
        self._allocator = other._allocator;
        self._pipe.open_end(self._writable);
    }

    pub fn create_node(allocator: std.mem.Allocator, pipe: *Pipe, writable: bool, nonblocking: bool) anyerror!Node {
        const file = try create(allocator, pipe, writable, nonblocking).interface.new(allocator);
        return Node.create_file(file);
    }

    pub fn read(self: *Self, buffer: []u8) isize {
        if (self._writable) return -1;
        return self._pipe.read(buffer, self._nonblocking);
    }

    pub fn write(self: *Self, data: []const u8) isize {
        if (!self._writable) return -1;
        return self._pipe.write(data, self._nonblocking);
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) anyerror!i64 {
        _ = self;
        _ = offset;
        _ = whence;
        return kernel.errno.ErrnoSet.IllegalSeek;
    }

    pub fn sync(self: *Self) i32 {
        _ = self;
        return 0;
    }

    pub fn tell(self: *Self) i64 {
        _ = self;
        return -1;
    }

    pub fn size(self: *const Self) u64 {
        return self._pipe._length;
    }

    pub fn poll(self: *Self, events: PollMask) PollMask {
        return self._pipe.poll(self._writable, events);
    }

    pub fn truncate(self: *Self, length: u64) anyerror!void {
        _ = self;
        _ = length;
        return kernel.errno.ErrnoSet.InvalidArgument;
    }

    pub fn name(self: *const Self) []const u8 {
        return if (self._writable) "pipe:[write]" else "pipe:[read]";
    }

    pub fn ioctl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        switch (cmd) {
            @intFromEnum(IoctlCommonCommands.GetMemoryMappingStatus) => {
                if (data == null) return -1;
                var attr: *FileMemoryMapAttributes = @ptrCast(@alignCast(data.?));
                _ = self;
                attr.is_memory_mapped = false;
                attr.mapped_address_r = null;
            },
            else => return -1,
        }
        return 0;
    }

    /// `F_GETFL`/`F_SETFL` carry O_NONBLOCK, the one flag that changes what this
    /// file does. `F_GETFD`/`F_SETFD` (FD_CLOEXEC) are accepted and ignored:
    /// this kernel keeps the descriptor table across exec.
    pub fn fcntl(self: *Self, cmd: i32, data: ?*anyopaque) i32 {
        switch (cmd) {
            c.F_GETFL => {
                var flags: i32 = if (self._writable) c.O_WRONLY else c.O_RDONLY;
                if (self._nonblocking) flags |= c.O_NONBLOCK;
                return flags;
            },
            c.F_SETFL => {
                // The argument arrives as a pointer-shaped value (see
                // sys_fcntl), so truncate rather than @intCast, which would
                // panic on a value that does not fit.
                const flags: i32 = @bitCast(@as(u32, @truncate(@intFromPtr(data))));
                self._nonblocking = (flags & c.O_NONBLOCK) != 0;
                return 0;
            },
            else => return 0,
        }
    }

    pub fn filetype(self: *const Self) FileType {
        _ = self;
        return .Fifo;
    }

    pub fn delete(self: *Self) void {
        self._pipe.close_end(self._writable);
    }
});

const testing = std.testing;

// These exercise the ring with no process behind it, so nothing here blocks.
// The blocking cases need two processes and are covered on target, in
// tests/smoke/pipe_test.py.
test "Pipe.ShouldCarryBytesThroughInOrder" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.read.delete();
    defer ends.write.delete();

    var read_end = ends.read.instance.file;
    var write_end = ends.write.instance.file;

    try testing.expectEqual(@as(isize, 5), write_end.interface.write("hello"));
    try testing.expectEqual(@as(isize, 5), write_end.interface.write("world"));

    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(isize, 10), read_end.interface.read(&buffer));
    try testing.expectEqualStrings("helloworld", buffer[0..10]);
}

test "Pipe.ShouldWrapAroundTheEndOfTheRing" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.read.delete();
    defer ends.write.delete();

    var read_end = ends.read.instance.file;
    var write_end = ends.write.instance.file;

    // Walk the read and write positions right up to the end of the buffer, so
    // the payload below is the one that straddles it.
    const filler: [256]u8 = @splat('.');
    var buffer: [512]u8 = undefined;
    var pushed: usize = 0;
    while (pushed + filler.len < Pipe.capacity) : (pushed += filler.len) {
        try testing.expectEqual(@as(isize, filler.len), write_end.interface.write(&filler));
        try testing.expectEqual(@as(isize, filler.len), read_end.interface.read(buffer[0..filler.len]));
    }

    const payload = "straddles the end of the ring";
    try testing.expectEqual(@as(isize, payload.len), write_end.interface.write(payload));
    try testing.expectEqual(@as(isize, payload.len), read_end.interface.read(&buffer));
    try testing.expectEqualStrings(payload, buffer[0..payload.len]);
}

test "Pipe.ShouldReportEndOfStreamOnceTheWriterIsGone" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.read.delete();

    var read_end = ends.read.instance.file;
    var write_end = ends.write.instance.file;

    try testing.expectEqual(@as(isize, 4), write_end.interface.write("tail"));
    // Buffered bytes outlive the writer: EOF is what a reader gets after it has
    // drained them, not the moment the far end closes.
    ends.write.delete();

    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, 4), read_end.interface.read(&buffer));
    try testing.expectEqual(@as(isize, 0), read_end.interface.read(&buffer));
    try testing.expectEqual(@as(isize, 0), read_end.interface.read(&buffer));
}

test "Pipe.ShouldFailAWriteWithNoReaderLeft" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.write.delete();

    var write_end = ends.write.instance.file;
    ends.read.delete();

    try testing.expectEqual(@as(isize, -1), write_end.interface.write("nobody is listening"));
}

test "Pipe.PollShouldReportReadableOnlyOnceThereIsSomethingToRead" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.read.delete();
    defer ends.write.delete();

    var read_end = ends.read.instance.file;
    var write_end = ends.write.instance.file;

    const want: PollMask = c.POLLIN | c.POLLOUT;
    // An empty pipe with both ends open: the reader would block, the writer
    // would not.
    try testing.expectEqual(@as(PollMask, 0), read_end.interface.poll(want));
    try testing.expectEqual(@as(PollMask, c.POLLOUT), write_end.interface.poll(want));

    _ = write_end.interface.write("data");
    try testing.expectEqual(@as(PollMask, c.POLLIN), read_end.interface.poll(want));
}

test "Pipe.PollShouldReportHangupToAReaderWhoseWriterIsGone" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.read.delete();

    var read_end = ends.read.instance.file;
    _ = ends.write.instance.file.interface.write("last words");
    ends.write.delete();

    // Both at once, and POLLHUP even though it was never asked for: the pending
    // bytes are still readable, and end-of-stream follows them.
    try testing.expectEqual(
        @as(PollMask, c.POLLIN | c.POLLHUP),
        read_end.interface.poll(c.POLLIN),
    );
}

test "Pipe.PollShouldReportErrorToAWriterWithNoReaderLeft" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.write.delete();

    var write_end = ends.write.instance.file;
    ends.read.delete();

    // Still has room, so it is writable -- but every write from here can only
    // fail, which is what POLLERR says. Reported unasked, as POSIX requires.
    try testing.expectEqual(
        @as(PollMask, c.POLLOUT | c.POLLERR),
        write_end.interface.poll(c.POLLOUT),
    );
}

test "Pipe.PollShouldStopReportingWritableOnceTheRingIsFull" {
    var ends = try create_pair(testing.allocator, true);
    defer ends.read.delete();
    defer ends.write.delete();

    var write_end = ends.write.instance.file;
    // Non-blocking, and `write` moves at most one chunk per call, so fill it in
    // chunk-sized steps until the pipe stops accepting.
    const block: [Pipe.capacity]u8 = @splat('x');
    while (write_end.interface.write(&block) > 0) {}

    try testing.expectEqual(@as(PollMask, 0), write_end.interface.poll(c.POLLOUT));
}

test "Pipe.ShouldRefuseTheWrongDirectionOnEachEnd" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.read.delete();
    defer ends.write.delete();

    var read_end = ends.read.instance.file;
    var write_end = ends.write.instance.file;

    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(isize, -1), read_end.interface.write("no"));
    try testing.expectEqual(@as(isize, -1), write_end.interface.read(&buffer));
}

test "Pipe.ShouldKeepTheStreamOpenForADuplicatedEnd" {
    var ends = try create_pair(testing.allocator, false);
    defer ends.read.delete();

    var read_end = ends.read.instance.file;

    // What a vfork does to the descriptor table. The duplicate is a writer in
    // its own right, so the original closing must not look like end-of-stream.
    var duplicate = try ends.write.clone();
    ends.write.delete();

    var writer = duplicate.instance.file;
    try testing.expectEqual(@as(isize, 3), writer.interface.write("yes"));

    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(isize, 3), read_end.interface.read(&buffer));

    duplicate.delete();
    try testing.expectEqual(@as(isize, 0), read_end.interface.read(&buffer));
}

/// Make a pipe and hand back its two ends, read end first.
pub fn create_pair(allocator: std.mem.Allocator, nonblocking: bool) !struct { read: Node, write: Node } {
    const pipe = try Pipe.create(allocator);
    // No end exists yet, so nothing would free the pipe if the first
    // `create_node` succeeded and the second failed.
    errdefer if (pipe._ends == 0) pipe.destroy();

    var read_end = try PipeFile.InstanceType.create_node(allocator, pipe, false, nonblocking);
    errdefer read_end.delete();
    const write_end = try PipeFile.InstanceType.create_node(allocator, pipe, true, nonblocking);

    return .{ .read = read_end, .write = write_end };
}
