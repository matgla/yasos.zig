// based on https://github.com/ZigEmbeddedGroup/microzig/blob/ff006c54bdd752c973d559c94a186681054d62b3/core/src/mmio.zig#L4
// but optimized for hardware instead of generic implementation
// this should be safer when two cores are working in parallel

//
// mmio.zig
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

pub fn Mmio(comptime RegisterFieldDescription: type) type {
    const size = @bitSizeOf(RegisterFieldDescription);
    if (size != 32) {
        @compileError("Register must be 32-bit on RPXXXX!");
    }

    return extern struct {
        const Self = @This();

        raw: u32,

        pub const underlaying_type = RegisterFieldDescription;

        pub inline fn read(self: *volatile Self) RegisterFieldDescription {
            return @bitCast(self.raw);
        }

        pub inline fn write(self: *volatile Self, value: RegisterFieldDescription) void {
            self.write_raw(@bitCast(value));
        }

        pub inline fn write_raw(self: *volatile Self, value: u32) void {
            self.raw = value;
        }

        pub inline fn xor_raw(self: *volatile Self, value: u32) void {
            var xor_alias: *Self = @ptrFromInt((@intFromPtr(self) + 0x1000));
            xor_alias.raw = value;
        }

        pub inline fn set_raw(self: *volatile Self, value: u32) void {
            var set_alias: *Self = @ptrFromInt((@intFromPtr(self) + 0x2000));
            set_alias.raw = value;
        }

        pub inline fn clear_raw(self: *volatile Self, value: u32) void {
            var clear_alias: *Self = @ptrFromInt((@intFromPtr(self) + 0x3000));
            clear_alias.raw = value;
        }

        pub inline fn update(self: *volatile Self, fields: anytype) void {
            // clear modified fields and then set them
            var set: RegisterFieldDescription = {};
            var clear: RegisterFieldDescription = {};
            inline for (@typeInfo(@TypeOf(fields)).Struct.fields) |field| {
                @field(set, field.name) = @field(fields, field.name);
                @field(clear, field.name) = ~@field(fields, field.name);
            }
            self.clear_raw(@bitCast(clear));
            self.set_raw(@bitCast(set));
        }
    };
}
