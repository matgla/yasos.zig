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

const hal = @import("hal_interface");
const std = @import("std");

pub const MmcStub = struct {
    _config: hal.mmc.MmcConfig,
    initialized: bool,
    chip_selected: bool,
    current_speed: u32,
    transmit_count: usize,
    receive_count: usize,
    command_count: usize,
    last_command: u6,
    last_argument: u32,
    transmit_buffer: ?std.ArrayList([]u8),
    receive_data: ?std.ArrayList([]u8),
    should_fail_init: bool,
    busy_count: usize,

    pub fn create(config: hal.mmc.MmcConfig) MmcStub {
        return MmcStub{
            ._config = config,
            .initialized = false,
            .chip_selected = false,
            .current_speed = 400000, // Default 400kHz
            .transmit_count = 0,
            .receive_count = 0,
            .command_count = 0,
            .last_command = 0,
            .last_argument = 0,
            .transmit_buffer = null,
            .receive_data = null,
            .should_fail_init = false,
            .busy_count = 0,
        };
    }

    pub fn init(self: *MmcStub) !void {
        std.debug.print("Initializing MmcStub\n", .{});
        if (self.initialized) {
            return;
        }
        self.receive_data = try std.ArrayList([]u8).initCapacity(std.testing.allocator, 16);
        self.transmit_buffer = try std.ArrayList([]u8).initCapacity(std.testing.allocator, 16);
        if (self.should_fail_init) {
            return error.InitializationFailed;
        }
        self.initialized = true;
        self.busy_count = 0;
    }

    pub fn reset(self: *MmcStub) void {
        self.initialized = false;
        self.chip_selected = false;
        self.transmit_count = 0;
        self.receive_count = 0;
        self.command_count = 0;
        self.last_command = 0;
        self.last_argument = 0;
        self.busy_count = 0;
        if (self.receive_data) |*r| {
            for (r.items) |item| {
                std.debug.print("Unconsumed receive data: {x}\n", .{item});
                std.testing.allocator.free(item);
            }
            r.deinit(std.testing.allocator);
            self.receive_data = null;
        }
        if (self.transmit_buffer) |*t| {
            for (t.items) |item| {
                std.debug.print("Unconsumed transmit data: {x}\n", .{item});
                std.testing.allocator.free(item);
            }
            t.deinit(std.testing.allocator);
            self.transmit_buffer = null;
        }
    }

    pub fn build_command(self: *MmcStub, command: u6, argument: u32) [6]u8 {
        var buf: [6]u8 = [_]u8{0x00} ** 6;
        buf[0] = 0x40;
        buf[0] |= command; // Standard MMC command format
        buf[1] = @intCast((argument >> 24) & 0xFF);
        buf[2] = @intCast((argument >> 16) & 0xFF);
        buf[3] = @intCast((argument >> 8) & 0xFF);
        buf[4] = @intCast(argument & 0xFF);
        buf[5] = 0x95; // CRC (dummy for most commands except CMD0)

        self.last_command = command;
        self.last_argument = argument;
        self.command_count += 1;

        return buf;
    }

    pub fn transmit_blocking(self: *MmcStub, src: []const u8, dest: ?[]u8) void {
        const buf = std.testing.allocator.dupe(u8, src) catch unreachable;
        std.debug.print("MmcStub Transmit({d}): {x}\n", .{ self.transmit_count, buf });
        self.transmit_buffer.?.append(std.testing.allocator, buf) catch {};
        self.transmit_count += 1;

        if (dest) |d| {
            if (self.receive_data.?.items.len > 0) {
                const data = self.receive_data.?.orderedRemove(0);
                const recv_len = @min(d.len, data.len);
                std.debug.print("MmcStub Receive({d}): {x}\n", .{ self.receive_count, data[0..recv_len] });
                @memcpy(d[0..recv_len], data[0..recv_len]);
                self.receive_count += 1;

                std.testing.allocator.free(data);
            }
        }
    }

    pub fn receive_blocking(self: *MmcStub, dest: []u8) void {
        if (self.receive_data.?.items.len == 0) {
            return;
        }

        const data = self.receive_data.?.orderedRemove(0);
        const len = @min(dest.len, data.len);
        std.debug.print("MmcStub Receive({d}): {x}\n", .{ self.receive_count, data[0..len] });
        @memcpy(dest[0..len], data[0..len]);
        self.receive_count += 1;
        std.testing.allocator.free(data);
    }

    pub fn chip_select(self: *MmcStub, select: bool) void {
        self.chip_selected = select;
    }

    pub fn set_busy_times(self: *MmcStub, times: usize) void {
        self.busy_count = times;
    }

    pub fn is_busy(self: *const MmcStub) bool {
        return self.busy_count > 0;
    }

    pub fn get_config(self: *const MmcStub) hal.mmc.MmcConfig {
        return self._config;
    }

    pub fn change_speed_to(self: *MmcStub, speed: u32) void {
        self.current_speed = speed;
    }

    // Test helper functions
    pub fn set_busy(self: *MmcStub, busy: bool) void {
        self.busy_state = busy;
    }

    pub fn set_receive_data(self: *MmcStub, data: []const u8) !void {
        try self.receive_data.?.append(std.testing.allocator, try std.testing.allocator.dupe(u8, data));
    }

    pub fn get_transmit_data(self: *MmcStub) []const u8 {
        if (self.transmit_buffer.?.items.len == 0) {
            return std.testing.allocator.alloc(u8, 0) catch unreachable;
        }
        const d = self.transmit_buffer.?.orderedRemove(0);
        return d;
    }

    pub fn set_init_fail(self: *MmcStub, should_fail: bool) void {
        self.should_fail_init = should_fail;
    }

    pub fn verify(self: *MmcStub) !void {
        if (self.transmit_buffer) |b| {
            if (b.items.len != 0) {
                for (b.items) |item| {
                    std.debug.print("Unconsumed transmit data: {x}\n", .{item});
                }
                try std.testing.expectEqual(b.items.len, 0);
            }
        }
        if (self.receive_data) |b| {
            if (b.items.len != 0) {
                for (b.items) |item| {
                    std.debug.print("Unconsumed receive data: {x}\n", .{item});
                }
            }
            try std.testing.expectEqual(b.items.len, 0);
        }
    }
};
