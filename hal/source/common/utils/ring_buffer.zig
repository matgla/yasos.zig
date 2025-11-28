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

const std = @import("std");

const log = std.log.scoped(.@"hal/uart");

pub fn RingBuffer(BufferType: type, BufferSize: usize) type {
    return struct {
        const Self = @This();

        buffer: [BufferSize]BufferType,
        head: usize,
        tail: usize,

        pub fn init() linksection(".time_critical") Self {
            return Self{
                .buffer = [_]u8{0} ** BufferSize,
                .head = 0,
                .tail = 0,
            };
        }

        pub fn push(self: *Self, data: u8) linksection(".time_critical") void {
            const next_head = (self.head + 1) % BufferSize;
            if (next_head == self.tail) {
                log.warn("RingBuffer overflow, dropping oldest data", .{});
                _ = self.pop();
            }
            self.buffer[self.head] = data;
            self.head = next_head;
        }

        pub fn pop(self: *Self) linksection(".time_critical") ?BufferType {
            if (self.head == self.tail) {
                return null;
            }
            const data = self.buffer[self.tail];
            self.tail = (self.tail + 1) % BufferSize;
            return data;
        }

        pub fn read(self: *Self, buffer: []BufferType) linksection(".time_critical") usize {
            var count: usize = 0;
            while (count < buffer.len and self.head != self.tail) {
                buffer[count] = self.buffer[self.tail];
                self.tail = @intCast((self.tail + 1) % self.buffer.len);
                count += 1;
            }
            return count;
        }

        pub fn size(self: *const Self) linksection(".time_critical") usize {
            if (self.head >= self.tail) {
                return self.head - self.tail;
            } else {
                return BufferSize - (self.tail - self.head);
            }
        }

        pub fn is_empty(self: *const Self) linksection(".time_critical") bool {
            return self.head == self.tail;
        }

        pub fn clear(self: *Self) linksection(".time_critical") void {
            self.head = self.tail;
        }
    };
}
