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

const memory = @import("hal").memory;
const c = @import("libc_imports").c;

const kernel = @import("../../kernel.zig");

const log = std.log.scoped(.@"kernel/memory_pool");
// Only one process is owner of memory chunk
// shared memory will be implemented as seperate structure
pub const ProcessMemoryPool = struct {
    pub const page_size = 4096;

    const AccessType = packed struct {
        read: u1,
        write: u1,
        execute: u1,
    };

    const ProcessMemoryEntity = struct {
        address: []u8,
        pid: c.pid_t,
        access: AccessType,
        node: std.DoublyLinkedList.Node,
    };
    const ProcessMemoryList = std.DoublyLinkedList;
    const ProcessMemoryMap = std.AutoHashMap(c.pid_t, ProcessMemoryList);

    memory_size: usize,
    page_count: usize,
    page_bitmap: std.DynamicBitSet,
    memory_map: ProcessMemoryMap,
    // this allocator is used to keep track of the memory allocated for the process inside the kernel
    allocator: std.mem.Allocator,
    start_address: usize,

    pub fn init(allocator: std.mem.Allocator) !ProcessMemoryPool {
        log.debug("Process memory pool initialized", .{});
        const memory_layout = memory.get_memory_layout();
        return ProcessMemoryPool{
            .memory_size = memory_layout[2].size,
            .page_count = memory_layout[2].size / page_size,
            .page_bitmap = try std.DynamicBitSet.initEmpty(allocator, memory_layout[2].size / page_size),
            .memory_map = ProcessMemoryMap.init(allocator),
            .allocator = allocator,
            .start_address = memory_layout[2].start_address,
        };
    }

    pub fn deinit(self: *ProcessMemoryPool) void {
        log.debug("Process memory pool deinitialization started...", .{});
        self.page_bitmap.deinit();
        var it = self.memory_map.iterator();
        while (it.next()) |process| {
            var next = process.value_ptr.pop();
            while (next) |node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", node);
                next = process.value_ptr.pop();
                self.allocator.destroy(entity);
            }
        }
        self.memory_map.deinit();
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
            return kernel.errno.ErrnoSet.OutOfMemory;
        }

        var end_index = start;
        while (end_index < self.page_count and pages != 0) {
            if (self.page_bitmap.isSet(end_index)) {
                return .{ start, end_index - 1 };
            }
            end_index += 1;
            pages -= 1;
        }

        if (end_index - start_index < @as(usize, @intCast(pages_number - 1))) {
            return kernel.errno.ErrnoSet.OutOfMemory;
        }

        if (end_index >= self.page_count or self.page_bitmap.isSet(end_index)) {
            return .{ start, end_index - 1 };
        }
        return .{ start, end_index };
    }

    fn slicify(ptr: [*]u8, len: usize) []u8 {
        return ptr[0..len];
    }

    pub fn allocate_pages(self: *ProcessMemoryPool, number_of_pages: i32, pid: c.pid_t) ?[]u8 {
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
                const end_index: usize = slot_start + @as(usize, @intCast(number_of_pages));
                for (slot_start..end_index) |i| {
                    self.page_bitmap.set(i);
                }
                var list = self.memory_map.getOrPut(pid) catch {
                    return null;
                };
                if (!list.found_existing) {
                    list.value_ptr.* = .{};
                }
                const entity = self.allocator.create(ProcessMemoryEntity) catch return null;
                entity.* = .{
                    .address = slicify(
                        @as([*]u8, @ptrFromInt(self.start_address + start_index * page_size)),
                        @as(usize, @intCast(number_of_pages)) * page_size,
                    ),
                    .pid = pid,
                    .access = .{ .read = 1, .write = 1, .execute = 1 },
                    .node = .{},
                };
                list.value_ptr.append(&entity.node);
                log.debug("Allocating {d} pages for {d} at 0x{x}", .{ number_of_pages, pid, @intFromPtr(entity.address.ptr) });
                return entity.address;
            } else {
                start_index = slot_end + 1;
            }
        }
        return null;
    }

    pub fn release_pages_for(self: *ProcessMemoryPool, pid: c.pid_t) void {
        log.debug("Releasing pages for: {d}", .{pid});
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var next = mapping.value_ptr.first;
            while (next) |entity_node| {
                const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                const start_index = (@intFromPtr(entity.address.ptr) - self.start_address) / page_size;
                const end_index = start_index + @as(usize, @intCast(entity.address.len)) / page_size;
                for (start_index..end_index) |index| {
                    self.page_bitmap.unset(index);
                }
                next = entity_node.next;
            }
            if (self.memory_map.getPtr(pid)) |*list| {
                var next_element = list.*.pop();
                while (next_element) |node| {
                    const entity: *const ProcessMemoryEntity = @fieldParentPtr("node", node);
                    self.allocator.destroy(entity);
                    next_element = list.*.pop();
                }
            }
            _ = self.memory_map.remove(pid);
        }
    }

    pub fn free_pages(self: *ProcessMemoryPool, address: *anyopaque, number_of_pages: i32, pid: c.pid_t) void {
        log.debug("Releasing pages {d} at 0x{x} for pid: {d}", .{ number_of_pages, @intFromPtr(address), pid });
        if (@intFromPtr(address) < self.start_address or
            @intFromPtr(address) >= self.start_address + self.memory_size)
        {
            return;
        }
        const maybe_mapping = self.memory_map.getEntry(pid);
        if (maybe_mapping) |*mapping| {
            var next = mapping.value_ptr.first;
            while (next) |entity_node| {
                const entity: *ProcessMemoryEntity = @fieldParentPtr("node", entity_node);
                if (@as(*anyopaque, entity.address.ptr) == address) {
                    _ = mapping.value_ptr.remove(entity_node);
                    self.allocator.destroy(entity);
                    break;
                }
                next = entity_node.next;
            }
            const start_index = (@intFromPtr(address) - self.start_address) / page_size;
            const end_index = start_index + @as(usize, @intCast(number_of_pages));
            for (start_index..end_index) |index| {
                self.page_bitmap.unset(index);
            }
        }
    }

    pub fn get_used_size(self: ProcessMemoryPool) usize {
        return self.page_bitmap.count() * page_size;
    }
};

test "ProcessMemoryPool.ShouldInitializeAndDeinitialize" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expect(pool.page_count > 0);
    try std.testing.expect(pool.memory_size > 0);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldAllocateSinglePage" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(1, pid);

    try std.testing.expect(pages != null);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size), pages.?.len);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldAllocateMultiplePages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const num_pages = 4;
    const pages = pool.allocate_pages(num_pages, pid);

    try std.testing.expect(pages != null);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * num_pages), pages.?.len);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * num_pages), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReturnNullForZeroPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(0, pid);

    try std.testing.expectEqual(null, pages);
}

test "ProcessMemoryPool.ShouldReturnNullForNegativePages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(-5, pid);

    try std.testing.expectEqual(null, pages);
}

test "ProcessMemoryPool.ShouldAllocateForDifferentProcesses" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid1: c.pid_t = 1;
    const pid2: c.pid_t = 2;

    const pages1 = pool.allocate_pages(2, pid1);
    const pages2 = pool.allocate_pages(3, pid2);

    try std.testing.expect(pages1 != null);
    try std.testing.expect(pages2 != null);
    try std.testing.expect(@intFromPtr(pages1.?.ptr) != @intFromPtr(pages2.?.ptr));
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 5), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldFreePages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const num_pages = 3;
    const pages = pool.allocate_pages(num_pages, pid);

    try std.testing.expect(pages != null);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * num_pages), pool.get_used_size());

    pool.free_pages(pages.?.ptr, num_pages, pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReleasePagesForProcess" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;

    _ = pool.allocate_pages(2, pid);
    _ = pool.allocate_pages(3, pid);
    _ = pool.allocate_pages(1, pid);

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 6), pool.get_used_size());

    pool.release_pages_for(pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReleaseOnlySpecificProcessPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid1: c.pid_t = 1;
    const pid2: c.pid_t = 2;

    _ = pool.allocate_pages(2, pid1);
    _ = pool.allocate_pages(3, pid2);

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 5), pool.get_used_size());

    pool.release_pages_for(pid1);
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 3), pool.get_used_size());

    pool.release_pages_for(pid2);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldReuseFreedPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;

    const pages1 = pool.allocate_pages(2, pid);
    try std.testing.expect(pages1 != null);
    const addr1 = @intFromPtr(pages1.?.ptr);

    pool.free_pages(pages1.?.ptr, 2, pid);

    const pages2 = pool.allocate_pages(2, pid);
    try std.testing.expect(pages2 != null);
    const addr2 = @intFromPtr(pages2.?.ptr);

    try std.testing.expectEqual(addr1, addr2);
}

test "ProcessMemoryPool.ShouldAllocateContiguousPages" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const num_pages = 5;
    const pages = pool.allocate_pages(num_pages, pid);

    try std.testing.expect(pages != null);

    const start_addr = @intFromPtr(pages.?.ptr);
    const expected_size = ProcessMemoryPool.page_size * num_pages;

    try std.testing.expectEqual(expected_size, pages.?.len);

    // Verify addresses are contiguous
    for (0..num_pages) |i| {
        const page_addr = start_addr + i * ProcessMemoryPool.page_size;
        try std.testing.expect(page_addr >= pool.start_address);
        try std.testing.expect(page_addr < pool.start_address + pool.memory_size);
    }
}

test "ProcessMemoryPool.ShouldHandleFragmentation" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;

    const pages1 = pool.allocate_pages(2, pid);
    const pages2 = pool.allocate_pages(2, pid);
    const pages3 = pool.allocate_pages(2, pid);

    try std.testing.expect(pages1 != null);
    try std.testing.expect(pages2 != null);
    try std.testing.expect(pages3 != null);

    // Free middle allocation
    pool.free_pages(pages2.?.ptr, 2, pid);

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 4), pool.get_used_size());

    // Should be able to allocate in the freed spot
    const pages4 = pool.allocate_pages(2, pid);
    try std.testing.expect(pages4 != null);
    try std.testing.expectEqual(@intFromPtr(pages2.?.ptr), @intFromPtr(pages4.?.ptr));
}

test "ProcessMemoryPool.ShouldHandleMultipleAllocationsForSameProcess" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 100;
    var allocations = try std.ArrayList([]u8).initCapacity(std.testing.allocator, 16);
    defer allocations.deinit(std.testing.allocator);

    for (0..5) |_| {
        const pages = pool.allocate_pages(1, pid);
        try std.testing.expect(pages != null);
        try allocations.append(std.testing.allocator, pages.?);
    }

    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 5), pool.get_used_size());

    pool.release_pages_for(pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldHandleNoAvailableMemory" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const total_pages = pool.page_count;

    // Try to allocate more than available
    const pages = pool.allocate_pages(@intCast(total_pages + 1), pid);
    try std.testing.expectEqual(@as(?[]u8, null), pages);
}

test "ProcessMemoryPool.ShouldReleaseNonExistentProcessSafely" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 999;

    // Should not crash
    pool.release_pages_for(pid);
    try std.testing.expectEqual(@as(usize, 0), pool.get_used_size());
}

test "ProcessMemoryPool.ShouldFreeNonExistentPagesSafely" {
    var pool = try ProcessMemoryPool.init(std.testing.allocator);
    defer pool.deinit();

    const pid: c.pid_t = 1;
    const pages = pool.allocate_pages(2, pid);
    try std.testing.expect(pages != null);

    // Try to free with wrong address
    const fake_addr: *anyopaque = @ptrFromInt(0xDEADBEEF);
    pool.free_pages(fake_addr, 2, pid);

    // Original allocation should still be tracked
    try std.testing.expectEqual(@as(usize, ProcessMemoryPool.page_size * 2), pool.get_used_size());
}
