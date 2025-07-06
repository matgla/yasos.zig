//
// process.zig
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
const config = @import("config");
const exc_return = @import("exc_return.zig");

const hal = @import("hal");

// This must be reimplemented for armv6-m
// TODO!

fn void_or_register() type {
    if (config.cpu.has_fpu and config.cpu.use_fpu) {
        return u32;
    }
    return void;
}

fn void_or_value(comptime value: anytype) void_or_register() {
    if (config.cpu.has_fpu and config.cpu.use_fpu) {
        return value;
    }
    return {};
}

pub const HardwareStoredRegisters = extern struct {
    r0: u32,
    r1: u32,
    r2: u32,
    r3: u32,
    r12: u32,
    lr: u32,
    pc: u32,
    psr: u32,
    s0: void_or_register(),
    s1: void_or_register(),
    s2: void_or_register(),
    s3: void_or_register(),
    s4: void_or_register(),
    s5: void_or_register(),
    s6: void_or_register(),
    s7: void_or_register(),
    s8: void_or_register(),
    s9: void_or_register(),
    s10: void_or_register(),
    s11: void_or_register(),
    s12: void_or_register(),
    s13: void_or_register(),
    s14: void_or_register(),
    s15: void_or_register(),
    fpscr: void_or_register(),
    aligner: u32,
};

pub const SoftwareStoredRegisters = extern struct {
    lr: u32,
    r4: u32,
    r5: u32,
    r6: u32,
    r7: u32,
    r8: u32,
    r9: u32,
    r10: u32,
    r11: u32,
    r12: u32,
    s16: void_or_register(),
    s17: void_or_register(),
    s18: void_or_register(),
    s19: void_or_register(),
    s20: void_or_register(),
    s21: void_or_register(),
    s22: void_or_register(),
    s23: void_or_register(),
    s24: void_or_register(),
    s25: void_or_register(),
    s26: void_or_register(),
    s27: void_or_register(),
    s28: void_or_register(),
    s29: void_or_register(),
    s30: void_or_register(),
    s31: void_or_register(),
};

pub fn create_default_hardware_registers(comptime exit_handler: *const fn () void, process_entry: anytype) HardwareStoredRegisters {
    return .{
        .r0 = 0,
        .r1 = 0,
        .r2 = 0,
        .r3 = 0,
        .r12 = 0,
        .lr = @as(u32, @intCast(@intFromPtr(exit_handler))),
        .pc = @as(u32, @intCast(@intFromPtr(process_entry))),
        .psr = 0x21000000,
        .s0 = void_or_value(0),
        .s1 = void_or_value(0),
        .s2 = void_or_value(0),
        .s3 = void_or_value(0),
        .s4 = void_or_value(0),
        .s5 = void_or_value(0),
        .s6 = void_or_value(0),
        .s7 = void_or_value(0),
        .s8 = void_or_value(0),
        .s9 = void_or_value(0),
        .s10 = void_or_value(0),
        .s11 = void_or_value(0),
        .s12 = void_or_value(0),
        .s13 = void_or_value(0),
        .s14 = void_or_value(0),
        .s15 = void_or_value(0),
        .fpscr = void_or_value(0),
        .aligner = 0,
    };
}

pub fn create_default_software_registers() SoftwareStoredRegisters {
    return .{
        // for now handler msp mode is reserved for kernel
        // interrupts handlers, but in the future kernel process
        // may also use thread/handler msp mode
        .lr = exc_return.return_to_thread_psp,
        .r4 = 0,
        .r5 = 0,
        .r6 = 0,
        .r7 = 0,
        .r8 = 0,
        .r9 = 0,
        .r10 = 0,
        .r11 = 0,
        .r12 = 0,
        .s16 = void_or_value(0),
        .s17 = void_or_value(0),
        .s18 = void_or_value(0),
        .s19 = void_or_value(0),
        .s20 = void_or_value(0),
        .s21 = void_or_value(0),
        .s22 = void_or_value(0),
        .s23 = void_or_value(0),
        .s24 = void_or_value(0),
        .s25 = void_or_value(0),
        .s26 = void_or_value(0),
        .s27 = void_or_value(0),
        .s28 = void_or_value(0),
        .s29 = void_or_value(0),
        .s30 = void_or_value(0),
        .s31 = void_or_value(0),
    };
}

pub fn prepare_process_stack(stack: []align(8) u8, comptime exit_handler: *const fn () void, process_entry: anytype, maybe_args: ?[]const usize) *u8 {
    var hardware_pushed_registers = create_default_hardware_registers(exit_handler, process_entry);
    if (maybe_args) |args| {
        if (args.len >= 1) {
            hardware_pushed_registers.r0 = @intCast(args[0]);
        }
        if (args.len >= 2) {
            hardware_pushed_registers.r1 = @intCast(args[1]);
        }
        if (args.len >= 3) {
            hardware_pushed_registers.r2 = @intCast(args[2]);
        }
        if (args.len >= 4) {
            hardware_pushed_registers.r3 = @intCast(args[3]);
        }
    }
    // const software_pushed_registers = create_default_software_registers();
    const stack_start: usize = if (stack.len % 8 == 0) stack.len else stack.len - stack.len % 8;
    const hw_registers_size = @sizeOf(HardwareStoredRegisters);
    const hw_registers_place = stack_start - hw_registers_size;
    @memcpy(stack[hw_registers_place .. hw_registers_place + @sizeOf(HardwareStoredRegisters)], std.mem.asBytes(&hardware_pushed_registers));

    const sw_registers_size = @sizeOf(SoftwareStoredRegisters);
    const sw_registers_place = stack_start - sw_registers_size - hw_registers_size;

    const software_pushed_registers = create_default_software_registers();
    @memcpy(stack[sw_registers_place .. sw_registers_place + @sizeOf(SoftwareStoredRegisters)], std.mem.asBytes(&software_pushed_registers));

    return &stack[sw_registers_place];
}

pub fn init() void {
    hal.time.systick.init(@intCast(hal.cpu.frequency() / 1000)) catch @panic("Unable to initialize systick");
    hal.time.systick.disable();
}

pub fn initialize_context_switching() void {
    hal.irq.set_priority(.supervisor_call, 0x00);
    hal.irq.set_priority(.pendsv, 0xfe);
    hal.irq.set_priority(.systick, 0xff);
}

extern fn context_switch_push_registers_to_stack(result_ptr: usize, pid: usize, lr: usize, restore: usize) *u8;

pub fn dump_registers_on_stack(result_ptr: usize, ret: usize, lr: usize, restore: usize) *u8 {
    return context_switch_push_registers_to_stack(result_ptr, ret, lr, restore);
}

pub const ArmProcess = struct {
    const stack_marker: u32 = 0xdeadbeef;
    stack: []align(8) u8,
    stack_position: *u8,
    has_own_stack: bool = true,
    memory_pool_allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, exit_handler_impl: anytype) !ArmProcess {
        const stack = try allocator.alignedAlloc(u8, .@"8", stack_size);
        if (comptime config.process.use_stack_overflow_detection) {
            @memcpy(stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
        }
        const stack_position = prepare_process_stack(stack, exit_handler_impl, process_entry, null);
        return ArmProcess{
            .stack = stack,
            .stack_position = stack_position,
            .has_own_stack = true,
            .memory_pool_allocator = allocator,
        };
    }

    pub fn deinit(self: *ArmProcess) void {
        self.memory_pool_allocator.free(self.stack);
    }

    pub fn stack_pointer(self: *const ArmProcess) *const u8 {
        if (config.process.use_stack_overflow_detection) {
            if (!self.validate_stack()) {
                if (!config.process.use_mpu_stack_protection) {
                    @panic("Stack overlflow occured, please reset");
                } else {
                    @panic("TODO: implement process kill here");
                }
            }
        }
        return self.stack_position;
    }

    pub fn set_stack_pointer(self: *ArmProcess, ptr: *u8, blocked_by_process: ?*ArmProcess) void {
        // if the process is using its parent stack, then we have to copy stack to parent
        // and set stack position to the freshly pushed registers
        if (!self.has_own_stack) {
            // temporary hack
            if (blocked_by_process) |p| {
                if (@intFromPtr(ptr) < @intFromPtr(p.stack_position)) {
                    const diff = @intFromPtr(p.stack_position) - @intFromPtr(ptr);
                    self.stack_position = @ptrFromInt(@intFromPtr(self.stack_position) - diff);
                } else {
                    const diff = @intFromPtr(ptr) - @intFromPtr(p.stack_position);
                    self.stack_position = @ptrFromInt(@intFromPtr(self.stack_position) + diff);
                }
                @memcpy(self.stack, p.stack);
                p.stack_position = ptr;
            }
        } else {
            self.stack_position = ptr;
        }
    }

    pub fn vfork(self: *ArmProcess, allocator: std.mem.Allocator) !ArmProcess {
        const stack: []align(8) u8 = try allocator.alignedAlloc(u8, .@"8", self.stack.len);
        const stack_position = self.stack_position;
        @memcpy(stack, self.stack);
        const parent_stack = self.stack;
        self.stack = stack;
        self.has_own_stack = false;
        return ArmProcess{
            .stack = parent_stack,
            .stack_position = stack_position,
            .has_own_stack = false,
            .memory_pool_allocator = allocator,
        };
    }

    pub fn reinitialize_stack(self: *ArmProcess, process_entry: anytype, argc: usize, argv: usize, symbol: usize, got: usize, exit_handler_impl: anytype) void {
        if (comptime config.process.use_stack_overflow_detection) {
            @memcpy(self.stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
        }
        const args = [_]usize{
            argc,
            argv,
            symbol,
            got,
        };
        self.stack_position = prepare_process_stack(self.stack, exit_handler_impl, process_entry, args[0..4]);
    }

    pub fn validate_stack(self: *const ArmProcess) bool {
        if (!config.process.use_stack_overflow_detection) @compileError("Stack overflow detection is disabled in config!");
        return std.mem.eql(u8, self.stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
    }

    pub fn restore_stack(self: *ArmProcess, blocks_process: ?*ArmProcess) void {
        if (blocks_process) |p| {
            if (!p.has_own_stack) {
                @memcpy(self.stack, p.stack);
                const stack = p.stack;
                p.stack = self.stack;
                self.stack = stack;
                p.has_own_stack = true;
                self.has_own_stack = true;
            }
        }
    }
};

fn test_entry() void {}

fn test_exit_handler() void {}

test "prepare process initial stack" {
    var stack align(8) = [_]u8{0} ** 1024;
    const offset = prepare_process_stack(&stack, &test_exit_handler, &test_entry);
    _ = try std.testing.expect(offset % 8 == 0);
    if (config.cpu.has_fpu and config.cpu.use_fpu) {} else {
        const test_entry_address: u32 = @intCast(@intFromPtr(&test_entry));
        const test_exit_handler_address: u32 = @intCast(@intFromPtr(&test_exit_handler));

        // hardware registers
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 4 .. stack.len]).*, 0x21000000);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 8 .. stack.len - 4]).*, test_entry_address);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 12 .. stack.len - 8]).*, test_exit_handler_address);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 16 .. stack.len - 12]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 20 .. stack.len - 16]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 24 .. stack.len - 20]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 28 .. stack.len - 24]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 32 .. stack.len - 28]).*, 0);
        // software registers
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 36 .. stack.len - 32]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 40 .. stack.len - 36]).*, exc_return.return_to_thread_psp);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 44 .. stack.len - 40]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 48 .. stack.len - 44]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 52 .. stack.len - 48]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 56 .. stack.len - 52]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 60 .. stack.len - 56]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 64 .. stack.len - 60]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 68 .. stack.len - 64]).*, 0);
        try std.testing.expectEqual(std.mem.bytesAsValue(u32, stack[stack.len - 72 .. stack.len - 68]).*, 0);
    }
}
