//
// display_driver.zig
//
// Registers a hal display as `/dev/fb0`. load() brings the panel up and selects
// a default mode so the node is usable the moment it appears — a board that
// only wants the device present without lighting it up can set the mode from
// userspace instead.
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

const IDriver = @import("../idriver.zig").IDriver;
const DisplayFile = @import("display_file.zig").DisplayFile;

const kernel = @import("../../kernel.zig");

const interface = @import("interface");

pub fn DisplayDriver(comptime DisplayType: type) type {
    const Internal = struct {
        const DisplayDriverImpl = interface.DeriveFromBase(IDriver, struct {
            pub const Self = @This();

            _allocator: std.mem.Allocator,
            _node: kernel.fs.Node,
            _display: *DisplayType,

            pub fn create(allocator: std.mem.Allocator, display: *DisplayType, driver_name: []const u8) !DisplayDriverImpl {
                return DisplayDriverImpl.init(.{
                    ._allocator = allocator,
                    ._node = try DisplayFile(DisplayType).InstanceType.create_node(allocator, display, driver_name),
                    ._display = display,
                });
            }

            pub fn delete(self: *Self) void {
                self._node.delete();
            }

            pub fn load(self: *Self) anyerror!void {
                try self._display.init();
                // First advertised mode is the board's preferred one.
                const caps = self._display.caps();
                if (caps.modes.len > 0) {
                    self._display.set_mode(caps.modes[0]) catch |err| {
                        kernel.log.err("display: can't set default mode: {s}", .{@errorName(err)});
                        return err;
                    };
                }
            }

            pub fn unload(self: *Self) bool {
                _ = self;
                return true;
            }

            pub fn node(self: *Self) anyerror!kernel.fs.Node {
                return try self._node.clone();
            }

            pub fn name(self: *const Self) []const u8 {
                return self._node.name();
            }
        });
    };
    return Internal.DisplayDriverImpl;
}
