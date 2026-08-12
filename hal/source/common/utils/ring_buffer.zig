// Copyright (c) 2025 Mateusz Stadnik
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

// A single-producer, single-consumer byte ring. `head` and `tail` are atomic so
// `size`/`is_empty` can be polled without a lock from a third core, and so a
// byte stored into `buffer` is visible before the index publishing it. That is
// the whole contract: it does NOT make the structure multi-producer or
// multi-consumer. Both indices are read-modify-write, so two concurrent pushes
// still lose a byte. Callers with more than one producer -- the RP2350 UART --
// serialise each side themselves.

const std = @import("std");

pub fn RingBuffer(BufferType: type, BufferSize: usize) type {
    return struct {
        const Self = @This();

        buffer: [BufferSize]BufferType,
        /// Written only by `push` (and `clear`). Read by everyone.
        head: std.atomic.Value(usize),
        /// Written only by `pop`/`read`. Read by everyone.
        tail: std.atomic.Value(usize),
        /// Producer-side loss count. Atomic because `get_rx_stats` samples it
        /// from whichever core asked for `/proc/uart`, not because two producers
        /// may increment it -- they may not.
        dropped: std.atomic.Value(usize),

        pub fn init() linksection(".time_critical") Self {
            return Self{
                .buffer = @splat(0),
                .head = .init(0),
                .tail = .init(0),
                .dropped = .init(0),
            };
        }

        /// A full buffer drops *data* and counts it, rather than making room by
        /// discarding the oldest byte. The only caller is the UART RX
        /// interrupt, where the buffer holds a byte stream: dropping the tail
        /// costs the bytes that have not been looked at yet, while dropping the
        /// head corrupts a message the reader is part way through.
        ///
        /// It also must not log. push() runs in the RX interrupt, a log write
        /// goes out over the same UART, and that write drains the RX FIFO
        /// inline (see Uart.write) -- straight back into push(), which can
        /// overflow again. Overflow is exactly when that recursion is live, so
        /// the count is left for a caller outside the interrupt to report.
        pub fn push(self: *Self, data: u8) linksection(".time_critical") void {
            // Monotonic: nobody but the producer writes `head`, so this load
            // cannot be stale in any way that matters.
            const head = self.head.load(.monotonic);
            const next_head = (head + 1) % BufferSize;
            // Acquire against the consumer's release of `tail`, so a slot it has
            // just freed is seen as free rather than spuriously counted a drop.
            if (next_head == self.tail.load(.acquire)) {
                self.dropped.store(self.dropped.load(.monotonic) +% 1, .monotonic);
                return;
            }
            self.buffer[head] = data;
            // Release: the byte must be visible to a consumer on the other core
            // before the index that tells it the byte is there.
            self.head.store(next_head, .release);
        }

        pub fn pop(self: *Self) linksection(".time_critical") ?BufferType {
            const tail = self.tail.load(.monotonic);
            if (self.head.load(.acquire) == tail) {
                return null;
            }
            const data = self.buffer[tail];
            self.tail.store((tail + 1) % BufferSize, .release);
            return data;
        }

        pub fn read(self: *Self, buffer: []BufferType) linksection(".time_critical") usize {
            var tail = self.tail.load(.monotonic);
            // Sampled once rather than per byte: one acquire is enough to see
            // every byte published before it, and re-loading each iteration
            // would only pick up bytes that the next call will hand over anyway.
            const head = self.head.load(.acquire);
            var count: usize = 0;
            while (count < buffer.len and head != tail) {
                buffer[count] = self.buffer[tail];
                tail = (tail + 1) % BufferSize;
                count += 1;
            }
            self.tail.store(tail, .release);
            return count;
        }

        /// Bytes available right now. Lock-free and therefore approximate, but
        /// never over-reports: `head` is published after its byte, so a caller
        /// sizing a copy from it is safe.
        pub fn size(self: *const Self) linksection(".time_critical") usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.monotonic);
            if (head >= tail) {
                return head - tail;
            } else {
                return BufferSize - (tail - head);
            }
        }

        pub fn is_empty(self: *const Self) linksection(".time_critical") bool {
            return self.head.load(.acquire) == self.tail.load(.monotonic);
        }

        /// Discard everything buffered. Writes `head`, so this is a producer-side
        /// operation despite reading like a consumer one: callers must hold
        /// whatever lock serialises their producers.
        pub fn clear(self: *Self) linksection(".time_critical") void {
            self.head.store(self.tail.load(.monotonic), .release);
        }
    };
}

const testing = std.testing;

test "Hal.Utils.RingBuffer.PushPopRoundTripsInOrder" {
    var ring = RingBuffer(u8, 8).init();
    try testing.expect(ring.is_empty());
    try testing.expectEqual(@as(usize, 0), ring.size());
    try testing.expectEqual(null, ring.pop());

    for ("abc") |byte| ring.push(byte);
    try testing.expectEqual(@as(usize, 3), ring.size());
    try testing.expect(!ring.is_empty());

    try testing.expectEqual(@as(u8, 'a'), ring.pop().?);
    try testing.expectEqual(@as(u8, 'b'), ring.pop().?);
    try testing.expectEqual(@as(u8, 'c'), ring.pop().?);
    try testing.expectEqual(null, ring.pop());
}

test "Hal.Utils.RingBuffer.FullBufferDropsTheNewestAndCountsIt" {
    // Capacity is BufferSize - 1: head must never catch tail, or a full ring
    // would be indistinguishable from an empty one.
    var ring = RingBuffer(u8, 4).init();
    for (0..3) |index| ring.push(@intCast(index));
    try testing.expectEqual(@as(usize, 3), ring.size());
    try testing.expectEqual(@as(usize, 0), ring.dropped.load(.monotonic));

    ring.push(99);
    try testing.expectEqual(@as(usize, 1), ring.dropped.load(.monotonic));
    // The *oldest* bytes survive; the overflowing one is what was lost. A reader
    // part way through a line keeps its line.
    try testing.expectEqual(@as(u8, 0), ring.pop().?);
}

test "Hal.Utils.RingBuffer.ReadDrainsUpToTheBufferLength" {
    var ring = RingBuffer(u8, 16).init();
    for ("hello") |byte| ring.push(byte);

    var small: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), ring.read(&small));
    try testing.expectEqualStrings("he", &small);

    var rest: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), ring.read(&rest));
    try testing.expectEqualStrings("llo", rest[0..3]);
    try testing.expectEqual(@as(usize, 0), ring.read(&rest));
}

test "Hal.Utils.RingBuffer.IndicesWrapWithoutLosingBytes" {
    // Push far more than the capacity through a small ring, draining as we go,
    // so every index wraps many times. The modulo is the whole implementation;
    // an off-by-one there is silent until a burst happens to straddle the wrap.
    var ring = RingBuffer(u8, 4).init();
    var expected: u8 = 0;
    for (0..100) |index| {
        ring.push(@truncate(index));
        try testing.expectEqual(expected, ring.pop().?);
        expected +%= 1;
        try testing.expect(ring.is_empty());
    }
    try testing.expectEqual(@as(usize, 0), ring.dropped.load(.monotonic));
}

test "Hal.Utils.RingBuffer.ClearDiscardsWithoutDisturbingTheConsumer" {
    var ring = RingBuffer(u8, 8).init();
    for ("abcd") |byte| ring.push(byte);
    _ = ring.pop();

    ring.clear();
    try testing.expect(ring.is_empty());
    try testing.expectEqual(@as(usize, 0), ring.size());
    try testing.expectEqual(null, ring.pop());

    // And it stays usable afterwards -- clear leaves head == tail at whatever
    // position the consumer had reached, not at zero.
    ring.push('z');
    try testing.expectEqual(@as(u8, 'z'), ring.pop().?);
}

test "Hal.Utils.RingBuffer.SpscHandsEveryByteOverExactlyOnceInOrder" {
    // One producer, one consumer, no lock between them. Without the
    // release/acquire pair on head this passes on x86 and fails on the M33.
    const Shared = struct {
        ring: RingBuffer(u8, 64) = RingBuffer(u8, 64).init(),
        produced: std.atomic.Value(usize) = .init(0),
        done: std.atomic.Value(bool) = .init(false),

        const Self = @This();
        const total = 100_000;

        fn produce(self: *Self) void {
            var sent: usize = 0;
            while (sent < total) {
                // Retry rather than accept a drop: the test is about ordering
                // and exactly-once delivery, so it must not tolerate loss.
                const before = self.ring.dropped.load(.monotonic);
                self.ring.push(@truncate(sent));
                if (self.ring.dropped.load(.monotonic) != before) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                sent += 1;
            }
            self.produced.store(sent, .release);
            self.done.store(true, .release);
        }
    };

    var shared = Shared{};
    const producer = try std.Thread.spawn(.{}, Shared.produce, .{&shared});

    var received: usize = 0;
    var expected: u8 = 0;
    while (received < Shared.total) {
        if (shared.ring.pop()) |byte| {
            try testing.expectEqual(expected, byte);
            expected +%= 1;
            received += 1;
        } else {
            if (shared.done.load(.acquire) and shared.ring.is_empty() and
                received >= shared.produced.load(.acquire)) break;
            std.atomic.spinLoopHint();
        }
    }
    producer.join();

    try testing.expectEqual(Shared.total, received);
    try testing.expect(shared.ring.is_empty());
}
