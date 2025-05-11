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

const malloc_allocator = @import("malloc.zig").malloc_allocator;
const log = &@import("../log/kernel_log.zig").kernel_log;

const memory = @import("hal").memory;

const dynamic_loader = @import("modules.zig");

// Only one process is owner of memory chunk
// shared memory will be implemented as seperate structure
pub const ProcessMemoryPool = struct {
    pub const page_size = 4096;

    const BitSetType = std.StaticBitSet(2000);
    const AccessType = packed struct {
        read: u1,
        write: u1,
        execute: u1,
    };

    const ProcessMemoryEntity = struct {
        address: []u8,
        pid: u32,
        access: AccessType,
    };
    const ProcessMemoryList = std.ArrayList(ProcessMemoryEntity);
    const ProcessMemoryMap = std.AutoHashMap(u32, ProcessMemoryList);

    memory_size: usize,
    page_count: usize,
    page_bitmap: BitSetType,
    memory_map: ProcessMemoryMap,
    // this allocator is used to keep track of the memory allocated for the process inside the kernel
    allocator: std.mem.Allocator,
    start_address: usize,

    pub fn create(allocator: std.mem.Allocator) ProcessMemoryPool {
        const memory_layout = memory.get_memory_layout();
        return ProcessMemoryPool{
            .memory_size = memory_layout[2].size,
            .page_count = memory_layout[2].size / page_size,
            .page_bitmap = BitSetType.initEmpty(),
            .memory_map = ProcessMemoryMap.init(allocator),
            .allocator = allocator,
            .start_address = memory_layout[2].start_address,
        };
    }

    fn get_next_free_slot(self: *ProcessMemoryPool, start_index: usize, pages_number: i32) !struct { usize, usize } {
        var start = start_index;
        var pages = pages_number - 1;
        while (start < self.page_count) {
            if (!self.page_bitmap.isSet(start)) {
                break;
            }

            start += 1;
        }

        if (start >= self.page_count) {
            return std.posix.MMapError.OutOfMemory;
        }

        var end_index = start;
        while (end_index < self.page_count and pages != 0) {
            if (self.page_bitmap.isSet(end_index)) {
                return .{ start, end_index };
            }
            end_index += 1;
            pages -= 1;
        }
        return .{ start, end_index };
    }

    fn slicify(ptr: [*]u8, len: usize) []u8 {
        return ptr[0..len];
    }

    pub fn allocate_pages(self: *ProcessMemoryPool, number_of_pages: i32, pid: u32) ?[]u8 {
        // log.print("Allocating {d} pages for process {d}\n", .{ number_of_pages, pid });
        if (number_of_pages <= 0) {
            return null;
        }
        var start_index: usize = 0;
        while (start_index < self.page_count) {
            const slot_start, const slot_end = self.get_next_free_slot(start_index, number_of_pages) catch {
                return null;
            };
            if (slot_end - slot_start >= number_of_pages - 1) {
                start_index = slot_start;
                const end_index: usize = slot_start + @as(usize, @intCast(number_of_pages)) - 1;
                for (slot_start..end_index + 1) |i| {
                    self.page_bitmap.set(i);
                }
                var list = self.memory_map.getOrPut(pid) catch {
                    return null;
                };
                if (!list.found_existing) {
                    list.value_ptr.* = ProcessMemoryList.init(self.allocator);
                }
                list.value_ptr.append(ProcessMemoryEntity{
                    .address = slicify(
                        @as([*]u8, @ptrFromInt(self.start_address + start_index * page_size)),
                        @as(usize, @intCast(number_of_pages)) * page_size,
                    ),
                    .pid = pid,
                    .access = .{ .read = 1, .write = 1, .execute = 1 },
                }) catch {
                    return null;
                };
                @memset(list.value_ptr.getLast().address, 0);
                return list.value_ptr.getLast().address;
            } else {
                start_index = slot_end + 1;
            }
        }
        return null;
    }

    pub fn release_pages_for(self: *ProcessMemoryPool, pid: u32) void {
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            for (mapping.value_ptr.items) |entity| {
                const start_index = (@intFromPtr(entity.address.ptr) - self.start_address) / page_size;
                const end_index = start_index + @as(usize, @intCast(entity.address.len)) / page_size;
                for (start_index..end_index) |index| {
                    self.page_bitmap.unset(index);
                }
            }
            if (self.memory_map.getPtr(pid)) |*arr| {
                arr.*.deinit();
            }
            _ = self.memory_map.remove(pid);
        }
    }

    pub fn free_pages(self: *ProcessMemoryPool, address: *anyopaque, number_of_pages: i32, pid: u32) void {
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var i: usize = 0;
            for (mapping.value_ptr.items) |entity| {
                if (@as(*anyopaque, entity.address.ptr) == address) {
                    _ = mapping.value_ptr.swapRemove(i);
                    break;
                }
                i += 1;
            }
            const start_index = (@intFromPtr(address) - self.start_address) / page_size;
            const end_index = start_index + @as(usize, @intCast(number_of_pages));
            for (start_index..end_index) |index| {
                self.page_bitmap.unset(index);
            }
        }
    }
};

pub var instance: ProcessMemoryPool = undefined;

pub fn init() void {
    instance = ProcessMemoryPool.create(malloc_allocator);
}
