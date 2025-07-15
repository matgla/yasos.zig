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

pub fn ExternalMemory(comptime ExternalMemoryImpl: anytype) type {
    return struct {
        const ExternalMemoryInterface = ExternalMemoryImpl.Impl;
        const Self = @This();
        impl: ExternalMemoryImpl,

        pub fn create() Self {
            return Self{
                .impl = .{},
            };
        }

        pub fn enable(self: *Self) bool {
            return self.impl.enable();
        }

        pub fn disable(self: Self) void {
            self.impl.disable();
        }

        pub fn dump_configuration(self: Self) void {
            self.impl.dump_configuration();
        }

        pub fn get_memory_size(self: Self) usize {
            return self.impl.get_memory_size();
        }

        pub fn perform_post(self: *Self) bool {
            return self.impl.perform_post();
        }
    };
}
