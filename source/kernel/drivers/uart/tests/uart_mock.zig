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

// Mock UART for testing
pub const MockUart = struct {
    pub var read_buffer: [256]u8 = undefined;
    pub var read_index: usize = 0;
    pub var read_length: usize = 0;
    pub var write_buffer: [256]u8 = undefined;
    pub var write_index: usize = 0;
    pub var readable: bool = true;
    pub var baudrate: u32 = 0;

    pub fn init(config: anytype) !void {
        baudrate = config.baudrate;
    }

    pub fn flush() void {}

    pub fn reset() void {
        read_index = 0;
        read_length = 0;
        write_index = 0;
        readable = true;
        @memset(&read_buffer, 0);
        @memset(&write_buffer, 0);
    }

    pub fn set_read_data(data: []const u8) void {
        @memcpy(read_buffer[0..data.len], data);
        read_length = data.len;
        read_index = 0;
    }

    pub fn read(buffer: []u8) !usize {
        if (read_index >= read_length) {
            return 0;
        }
        const to_read = @min(buffer.len, read_length - read_index);
        @memcpy(buffer[0..to_read], read_buffer[read_index .. read_index + to_read]);
        read_index += to_read;
        return to_read;
    }

    pub fn write_some(data: []const u8) !usize {
        const to_write = @min(data.len, write_buffer.len - write_index);
        @memcpy(write_buffer[write_index .. write_index + to_write], data[0..to_write]);
        write_index += to_write;
        return to_write;
    }

    pub fn is_readable() bool {
        return readable;
    }

    pub fn get_written_data() []const u8 {
        return write_buffer[0..write_index];
    }

    pub fn bytes_to_read() usize {
        return read_length - read_index;
    }
};
