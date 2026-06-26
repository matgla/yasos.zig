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

// Writable, RAM-backed "flash" for QEMU. Unlike Flash (source/flash.zig) the
// backing region is mutable and write() actually stores, so the kernel's
// FlashFile/DiskWrapper can use it as a read/write FAT block device. On the
// mps2-an505 host-test target a window of the host-mmap'd PSRAM is exposed this
// way (see hal/boards/qemu_mps2_an505 `fatdisk0` and linker_script.ld): the host
// pre-loads a FAT image into the backing file and reads device output back out,
// with no kernel rebuild. BlockSize is 1 byte and get_number_of_blocks() returns
// the full byte size, so FlashFile.size() == the true window size (FatFs derives
// its sector count from that).
pub fn RamFlash(comptime mapping_address: usize, comptime size: usize) type {
    return struct {
        pub const Self = @This();
        pub const BlockSize = 1;
        memory: []u8,

        pub fn init(self: Self) void {
            _ = self;
        }

        fn slicify(ptr: [*]u8, memory_size: usize) []u8 {
            return ptr[0..memory_size];
        }

        pub fn create(comptime id: u32) Self {
            _ = id;
            return .{
                .memory = slicify(@ptrFromInt(mapping_address), size),
            };
        }

        pub fn read(self: Self, address: u32, buffer: []u8) void {
            @memcpy(buffer, self.memory[address .. address + buffer.len]);
        }

        pub fn write(self: Self, address: u32, data: []const u8) void {
            @memcpy(self.memory[address .. address + data.len], data);
        }

        pub fn erase(self: Self, address: u32) void {
            _ = self;
            _ = address;
        }

        pub fn get_number_of_blocks(self: Self) u32 {
            _ = self;
            return size;
        }

        pub fn get_physical_address(self: Self) []const u8 {
            return self.memory;
        }
    };
}
