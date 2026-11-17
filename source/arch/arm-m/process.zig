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

const kernel = @import("kernel");

const hal = @import("hal");

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

/// The DCP (RP2350's double coprocessor on CP4) keeps state the hardware does
/// not stack on exception entry, and the instruction sequences that use it are
/// not atomic: preempting one and letting another process start its own
/// corrupts the first. So when user code may execute those sequences, the
/// context switch saves and restores that state -- see the DCP block in
/// context_switch.S. Present in the software frame only then; the assembly is
/// gated on the same condition through YASOS_SAVE_DCP_STATE.
///
/// @hasDecl-guarded so a config.zig generated before these symbols existed
/// still builds (as `false`) instead of failing to compile.
pub const saves_dcp_state = @hasDecl(config.cpu, "has_dcp") and config.cpu.has_dcp and
    @hasDecl(config.build, "userspace_hardware_fp") and config.build.userspace_hardware_fp;

fn void_or_dcp_register() type {
    return if (saves_dcp_state) u32 else void;
}

fn void_or_dcp_value(comptime value: anytype) void_or_dcp_register() {
    return if (saves_dcp_state) value else {};
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
    // The word the hardware reserves at the top of an *FP* exception frame, so
    // that a frame carrying FP state is 104 bytes. The integer-only frame is
    // eight words and has no such slot: carrying one unconditionally made the
    // synthetic frame 36 bytes, the hardware popped 32 on exception return, and
    // every thread on a no-FPU build started life with SP 4 bytes low. AAPCS
    // requires SP to be 8-byte aligned at a public interface, and tcc's va_arg
    // relies on it -- so `printf("%lld")` read the wrong stack word in every
    // process. `frame_is_a_whole_number_of_eight_byte_units` below is the guard.
    reserved: void_or_register(),
};

comptime {
    // An exception frame that is not a multiple of 8 bytes shifts the thread's
    // stack pointer off AAPCS alignment for the rest of its life.
    if (@sizeOf(HardwareStoredRegisters) % 8 != 0)
        @compileError("hardware exception frame must be a multiple of 8 bytes");
}

/// r0-r3, r12, LR, PC, xPSR: the frame the hardware stacks when no FP state is
/// involved, whether or not this build has an FPU.
const basic_frame_size = 8 * @sizeOf(u32);

pub const SoftwareStoredRegisters = extern struct {
    is_fpu_frame: u32,
    lr: u32,
    r4: u32,
    r5: u32,
    r6: u32,
    r7: u32,
    r8: u32,
    r9: u32,
    r10: u32,
    r11: u32,
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
    /// DCP state, at the top of the software frame (pushed first, popped last)
    /// so the layout below the FP registers is untouched. `dcp_engaged` is
    /// non-zero only when the process was preempted in the middle of a DCP
    /// sequence, which is the only case where the X/Y/EFD words hold anything
    /// worth restoring. See `saves_dcp_state`.
    dcp_xl: void_or_dcp_register(),
    dcp_xh: void_or_dcp_register(),
    dcp_yl: void_or_dcp_register(),
    dcp_yh: void_or_dcp_register(),
    dcp_el: void_or_dcp_register(),
    dcp_eh: void_or_dcp_register(),
    dcp_engaged: void_or_dcp_register(),
};

const has_fp_registers = config.cpu.has_fpu and config.cpu.use_fpu;
/// is_fpu_frame, EXC_RETURN, r4-r11: the software frame without FP or DCP words.
const software_frame_words = 10;
const max_saved_frame_words = software_frame_words + 16 + 7 + @sizeOf(HardwareStoredRegisters) / 4;
const xpsr_thumb: u32 = 1 << 24;
/// The hardware skipped a word to 8-align the frame; it pops it on return.
const xpsr_stack_aligned: u32 = 1 << 9;
/// N Z C V Q and GE[3:0]: what a debugger may change.
const xpsr_flags: u32 = 0xF80F0000;
/// IT/ICI: the state of an IT block, meaningless at another pc.
const xpsr_it_bits: u32 = 0x0600FC00;

const SavedFrame = struct {
    sw: usize,
    sw_fp: bool,
    hw: usize,
    hw_fp: bool,
    hw_size: usize,
    /// The thread's sp once the hardware frame is popped.
    end: usize,
};

/// What ptrace shows of a process: Linux/ARM's `struct user_regs` -- r0-r12,
/// sp, lr, pc, xPSR, orig_r0 (always 0 here).  libc sys/ptrace.h.
pub const UserRegisters = extern struct {
    r: [13]u32,
    sp: u32,
    lr: u32,
    pc: u32,
    xpsr: u32,
    orig_r0: u32,
};

/// Linux/ARM's `struct user_vfp`: d0-d31 and FPSCR.  The FPv5-SP unit has
/// s0-s31, which are d0-d15; d16-d31 stay 0.
pub const FpRegisters = extern struct {
    fpregs: [32]u64,
    fpscr: u32,
};

comptime {
    if (@sizeOf(UserRegisters) != 18 * 4) @compileError("struct user_regs is 18 words");
    if (@sizeOf(FpRegisters) != 264) @compileError("struct user_vfp is 264 bytes");
}

fn create_default_hardware_registers(comptime exit_handler: *const fn () void, process_entry: anytype) HardwareStoredRegisters {
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
        .reserved = void_or_value(0),
    };
}

fn create_default_software_registers(lr: usize) SoftwareStoredRegisters {
    return .{
        // for now handler msp mode is reserved for kernel
        // interrupts handlers, but in the future kernel process
        // may also use thread/handler msp mode
        .is_fpu_frame = if (config.cpu.has_fpu and config.cpu.use_fpu) 1 else 0,
        .lr = lr,
        .r4 = 0,
        .r5 = 0,
        .r6 = 0,
        .r7 = 0,
        .r8 = 0,
        .r9 = 0,
        .r10 = 0,
        .r11 = 0,
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
        // A process starts outside any DCP sequence, so there is nothing to
        // restore on its first switch-in.
        .dcp_xl = void_or_dcp_value(0),
        .dcp_xh = void_or_dcp_value(0),
        .dcp_yl = void_or_dcp_value(0),
        .dcp_yh = void_or_dcp_value(0),
        .dcp_el = void_or_dcp_value(0),
        .dcp_eh = void_or_dcp_value(0),
        .dcp_engaged = void_or_dcp_value(0),
    };
}

fn prepare_process_stack(stack: []align(8) u8, comptime exit_handler: *const fn () void, process_entry: anytype, maybe_args: ?[]const usize, is_root: bool) *u8 {
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
    var lr = if (config.cpu.has_fpu) exc_return.return_to_thread_mode_with_fp_psp else exc_return.return_to_thread_psp;
    if (is_root) {
        lr = @intFromPtr(process_entry);
    }
    const software_pushed_registers = create_default_software_registers(lr);
    @memcpy(stack[sw_registers_place .. sw_registers_place + @sizeOf(SoftwareStoredRegisters)], std.mem.asBytes(&software_pushed_registers));

    return &stack[sw_registers_place];
}

pub fn init() void {
    std.log.info("Initializing ARM Cortex-M process module...", .{});
    hal.time.systick.init(@intCast(hal.cpu.frequency() / 1000)) catch @panic("Unable to initialize systick");
    initialize_context_switching();
    hal.time.systick.disable();
}

/// Per-core timer setup for a secondary core, run by that core itself. SysTick
/// lives in the System Control Space, which is per-core hardware, so this is the
/// same registers on different silicon rather than a repeat of `init()`.
///
/// It does not call `initialize_context_switching`, which installs the
/// scheduler's hand-off; until this core takes its first switch the tick drives
/// nothing but its liveness counter. Unlike `init()` the timer is left enabled,
/// because the caller is already parked in its idle loop.
///
/// It does call `disable_lazy_fp_stacking`: FPCCR is banked per core too, so
/// core 1 comes up with LSPEN at its reset value whatever core 0 did.
pub fn init_secondary() void {
    disable_lazy_fp_stacking();
    // Exception priorities live in the SCB's SHPR registers, which are banked
    // per core, so core 0 setting them does nothing for core 1. The ordering
    // argument below -- PendSV strictly lowest, so it can never preempt SysTick
    // or SVCall and strand their ACTIVE bits -- is a property of these
    // registers, and equal priorities happen not to preempt, so leaving them at
    // reset reads as working right up until something moves.
    set_exception_priorities();
    hal.time.systick.init(@intCast(hal.cpu.frequency() / 1000)) catch @panic("Unable to initialize systick on a secondary core");
}

/// The priority ordering the context switch depends on. See
/// `initialize_context_switching` for why PendSV must be last.
fn set_exception_priorities() void {
    hal.irq.set_priority(.supervisor_call, 0xf0); // system calls are not interuptible
    hal.irq.set_priority(.systick, 0xfe);
    hal.irq.set_priority(.pendsv, 0xff);
}

// FPCCR.LSPEN (bit 30), the FPU's lazy state-preservation enable. Reset value
// is 1.
const fpccr: *volatile u32 = @ptrFromInt(0xE000EF34);
const fpccr_lspen: u32 = 1 << 30;

// Turn OFF lazy FP state preservation, so exception entry writes s0-s15 and
// FPSCR into the frame immediately instead of only reserving 68 bytes for them
// and arming a deferred write at FPCAR.
//
// Lazy stacking assumes every exception entry that sets LSPACT is matched by an
// exception return that clears it (EXC_RETURN.FType == 0). This kernel breaks
// that pairing on purpose: process_syscall_entry (context_switch.S) is entered
// from a user `svc` with FType == 0 but returns with a hardcoded 0xfffffffd
// (FType == 1) to run the syscall body in thread mode. LSPACT stays set and
// FPCAR keeps pointing into the *old* frame; the process then goes on using
// that memory as ordinary stack, and whenever the deferred save finally fires
// it writes 17 words straight through live data.
//
// That is not theoretical -- it is what the intermittent smoke crashes were.
// In mibench_dijkstra the four words of memmove's saved r5/r6/r8/lr all landed
// inside [FPCAR, FPCAR+0x44) of a dead frame, so its `ldmia sp!, {r4,r5,r6,r8,pc}`
// branched to 0x000000C2. Same signature in 370_ptr_struct_copy_inline,
// bug_struct_slot_reuse, bug_switch_default_chain, bug_mla64_non_inplace and
// ieee/pr50310: a zeroed saved-LR, or a saved r9 (the GOT base) reloaded as
// garbage so the next PLT stub faulted. It only became reachable when userspace
// got hardware FP -- before that nothing set CONTROL.FPCA, so the deferred save
// was never armed with anything to write.
//
// Eager stacking costs ~17 stores per exception entry taken from FP context and
// makes the frame layout unconditionally match HardwareStoredRegisters above.
// ASPEN (bit 31) stays on: CONTROL.FPCA must still track FP use automatically.
fn disable_lazy_fp_stacking() void {
    if (!(config.cpu.has_fpu and config.cpu.use_fpu)) return;
    fpccr.* = fpccr.* & ~fpccr_lspen;
    asm volatile ("dsb" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

pub fn initialize_context_switching() void {
    std.log.err("Initializing ARM Cortex-M context switching...", .{});
    disable_lazy_fp_stacking();
    set_exception_priorities();
    // PendSV MUST be the lowest-priority exception. The context switch performed
    // inside the PendSV handler exits via an exception-return into the switched-to
    // task instead of returning to whatever it interrupted. If PendSV could
    // preempt SysTick (or SVCall), that preempted handler's exception frame is
    // abandoned and its ACTIVE bit (SHCSR.SYSTICKACT/PENDSVACT) is stranded set,
    // which corrupts exception nesting so PendSV can never become pending->active
    // again -> all further context switches stall. Keeping PendSV strictly below
    // SysTick makes SysTick return first (clearing SYSTICKACT) and PendSV
    // tail-chain afterwards.
}

pub const ArmProcess = struct {
    const Self = @This();

    const stack_marker: u32 = 0xdeadbeef;
    stack: []align(8) u8,
    stack_position: *u8,
    process_allocator: std.mem.Allocator,
    stack_is_shared: bool = false,

    pub fn init(process_allocator: std.mem.Allocator, stack_size: u32, process_entry: anytype, exit_handler_impl: anytype, arg: anytype, is_root: bool) !Self {
        const stack = try process_allocator.alignedAlloc(u8, .@"8", stack_size);
        const stack_position = prepare_process_stack(stack, exit_handler_impl, process_entry, arg, is_root);
        return ArmProcess{
            .stack = stack,
            .stack_position = stack_position,
            .process_allocator = process_allocator,
            .stack_is_shared = false,
        };
    }

    pub fn deinit(self: *Self, process_allocator: std.mem.Allocator) void {
        if (self.stack_is_shared) {
            return;
        }
        process_allocator.free(self.stack);
    }

    pub fn stack_pointer(self: *const Self) *const u8 {
        return self.stack_position;
    }

    pub fn get_stack_bottom(self: *const Self) *const u8 {
        return @ptrCast(self.stack.ptr);
    }

    /// Where a switched-out process resumes: the PC and LR of the hardware frame
    /// above its saved software frame (`arch_store_registers_on_stack`: is_fpu,
    /// lr + r4-r11, s16-s31 when is_fpu, then the DCP slot). Null when the saved
    /// stack pointer is not inside the stack. Meaningless for a process that is
    /// running -- its saved frame is the one from its last switch.
    pub fn saved_pc_lr(self: *const Self) ?[2]u32 {
        const sp = @intFromPtr(self.stack_position);
        const dcp_bytes: usize = if (saves_dcp_state) 7 * @sizeOf(u32) else 0;
        const lo = @intFromPtr(self.stack.ptr);
        const hi = lo + self.stack.len;
        if (sp < lo or sp % 4 != 0 or sp + 10 * @sizeOf(u32) > hi) return null;
        const is_fpu = @as(*const u32, @ptrFromInt(sp)).* != 0;
        const fpu_bytes: usize = if (is_fpu) 16 * @sizeOf(u32) else 0;
        const hw = sp + 10 * @sizeOf(u32) + fpu_bytes + dcp_bytes;
        if (hw + basic_frame_size > hi) return null;
        const frame: *const [8]u32 = @ptrFromInt(hw);
        return .{ frame[6], frame[5] };
    }

    /// Where a switched-out process's context lies on its stack: the software
    /// frame at `stack_position` ([is_fpu_frame, EXC_RETURN, r4-r11],
    /// s16-s31 when is_fpu_frame, the DCP words on a DCP build), then the
    /// hardware frame (r0-r3, r12, lr, pc, xPSR, and s0-s15, FPSCR and the
    /// reserved word when EXC_RETURN says it is an FP frame), then the word the
    /// hardware skipped to 8-align it when xPSR bit 9 says so.  Null when that
    /// does not fit the stack, or the frame is not an exception frame (the root
    /// process's first one).
    fn saved_frame(self: *const Self) ?SavedFrame {
        const sp = @intFromPtr(self.stack_position);
        const lo = @intFromPtr(self.stack.ptr);
        const hi = lo + self.stack.len;
        if (sp < lo or sp % 4 != 0 or sp + software_frame_words * 4 > hi) return null;
        const words: [*]const u32 = @ptrFromInt(sp);
        const exc = words[1];
        if (exc & 0xFF000000 != 0xFF000000) return null;
        const sw_fp = has_fp_registers and words[0] != 0;
        const dcp_bytes: usize = if (saves_dcp_state) 7 * @sizeOf(u32) else 0;
        const hw = sp + software_frame_words * 4 + (if (sw_fp) @as(usize, 16 * @sizeOf(u32)) else 0) + dcp_bytes;
        const hw_fp = has_fp_registers and (exc & 0x10) == 0;
        const hw_size: usize = if (hw_fp) @sizeOf(HardwareStoredRegisters) else basic_frame_size;
        if (hw + hw_size > hi) return null;
        const psr = @as(*const u32, @ptrFromInt(hw + 7 * 4)).*;
        const end = hw + hw_size + (if (psr & xpsr_stack_aligned != 0) @as(usize, 4) else 0);
        if (end > hi) return null;
        return .{ .sw = sp, .sw_fp = sw_fp, .hw = hw, .hw_fp = hw_fp, .hw_size = hw_size, .end = end };
    }

    /// The registers of a switched-out process, as ptrace shows them.
    pub fn read_user_registers(self: *const Self) ?UserRegisters {
        const f = self.saved_frame() orelse return null;
        const sw: [*]const u32 = @ptrFromInt(f.sw);
        const hw: [*]const u32 = @ptrFromInt(f.hw);
        var regs = std.mem.zeroes(UserRegisters);
        @memcpy(regs.r[0..4], hw[0..4]);
        @memcpy(regs.r[4..12], sw[2..10]);
        regs.r[12] = hw[4];
        regs.sp = @intCast(f.end);
        regs.lr = hw[5];
        regs.pc = hw[6];
        regs.xpsr = hw[7];
        return regs;
    }

    /// Write the registers of a switched-out process back into its stored
    /// context.  pc keeps the Thumb state and loses bit 0, which a stacked
    /// return address may not have; of xPSR only the flags (N Z C V Q, GE) are
    /// the debugger's, and a moved pc leaves any IT block.  A different sp
    /// moves the whole stored context there.  False when the context cannot be
    /// read or the new sp is outside the stack.
    pub fn write_user_registers(self: *Self, regs: *const UserRegisters) bool {
        var f = self.saved_frame() orelse return false;
        if (regs.sp != f.end) {
            if (!self.move_saved_frame(f, regs.sp)) return false;
            f = self.saved_frame() orelse return false;
        }
        const sw: [*]u32 = @ptrFromInt(f.sw);
        const hw: [*]u32 = @ptrFromInt(f.hw);
        @memcpy(hw[0..4], regs.r[0..4]);
        @memcpy(sw[2..10], regs.r[4..12]);
        hw[4] = regs.r[12];
        hw[5] = regs.lr;
        const old_pc = hw[6];
        hw[6] = regs.pc & ~@as(u32, 1);
        var psr = (hw[7] & ~xpsr_flags) | (regs.xpsr & xpsr_flags) | xpsr_thumb;
        if (hw[6] != old_pc) psr &= ~xpsr_it_bits;
        hw[7] = psr;
        return true;
    }

    /// Move the stored context so the thread resumes with sp = `new_sp`.
    fn move_saved_frame(self: *Self, f: SavedFrame, new_sp: usize) bool {
        const lo = @intFromPtr(self.stack.ptr);
        const hi = lo + self.stack.len;
        if (new_sp % 4 != 0 or new_sp > hi) return false;
        const sw_size = f.hw - f.sw;
        var hw_new = std.math.sub(usize, new_sp, f.hw_size) catch return false;
        const pad = hw_new % 8 != 0;
        if (pad) hw_new -= 4;
        const sw_new = std.math.sub(usize, hw_new, sw_size) catch return false;
        if (sw_new < lo) return false;
        var buffer: [max_saved_frame_words]u32 = undefined;
        const total = sw_size + f.hw_size;
        const bytes = std.mem.sliceAsBytes(buffer[0..])[0..total];
        @memcpy(bytes, @as([*]const u8, @ptrFromInt(f.sw))[0..total]);
        @memcpy(@as([*]u8, @ptrFromInt(sw_new))[0..total], bytes);
        const psr: *u32 = @ptrFromInt(hw_new + 7 * 4);
        psr.* = if (pad) psr.* | xpsr_stack_aligned else psr.* & ~xpsr_stack_aligned;
        self.stack_position = @ptrFromInt(sw_new);
        return true;
    }

    /// s0-s31 (as d0-d15) and FPSCR of a switched-out process; all zero when it
    /// has no FP context stored.
    pub fn read_fp_registers(self: *const Self) ?FpRegisters {
        const f = self.saved_frame() orelse return null;
        var regs = std.mem.zeroes(FpRegisters);
        if (!f.sw_fp or !f.hw_fp) return regs;
        const sw: [*]const u32 = @ptrFromInt(f.sw);
        const hw: [*]const u32 = @ptrFromInt(f.hw);
        var single: [32]u32 = undefined;
        @memcpy(single[0..16], hw[8..24]);
        @memcpy(single[16..32], sw[software_frame_words..][0..16]);
        for (0..16) |i| regs.fpregs[i] = @as(u64, single[2 * i]) | (@as(u64, single[2 * i + 1]) << 32);
        regs.fpscr = hw[24];
        return regs;
    }

    /// Write s0-s31 and FPSCR back; false when the process has no FP context
    /// stored to write them into.
    pub fn write_fp_registers(self: *Self, regs: *const FpRegisters) bool {
        const f = self.saved_frame() orelse return false;
        if (!f.sw_fp or !f.hw_fp) return false;
        const sw: [*]u32 = @ptrFromInt(f.sw);
        const hw: [*]u32 = @ptrFromInt(f.hw);
        for (0..16) |i| {
            const lo: u32 = @truncate(regs.fpregs[i]);
            const hi: u32 = @truncate(regs.fpregs[i] >> 32);
            if (i < 8) {
                hw[8 + 2 * i] = lo;
                hw[8 + 2 * i + 1] = hi;
            } else {
                sw[software_frame_words + 2 * (i - 8)] = lo;
                sw[software_frame_words + 2 * (i - 8) + 1] = hi;
            }
        }
        hw[24] = regs.fpscr;
        return true;
    }

    /// Have a switched-out process resume by calling `pc` with r0 = `r0`, as if
    /// interrupted at its first instruction -- how a killed tracee is sent to
    /// `_exit`.
    pub fn redirect_saved_frame(self: *Self, pc: usize, r0: u32) void {
        const f = self.saved_frame() orelse return;
        const hw: [*]u32 = @ptrFromInt(f.hw);
        hw[0] = r0;
        hw[5] = 0;
        hw[6] = @as(u32, @intCast(pc)) & ~@as(u32, 1);
        hw[7] = (hw[7] & xpsr_stack_aligned) | xpsr_thumb;
    }

    pub fn get_stack_top(self: *const Self) *const u8 {
        return @ptrFromInt(@intFromPtr(self.stack.ptr) + self.stack.len);
    }

    pub fn set_stack_pointer(self: *Self, ptr: *u8, blocked_by_process: ?*Self) void {
        _ = blocked_by_process;
        self.stack_position = ptr;
    }

    pub fn vfork(self: *Self, process_allocator: std.mem.Allocator) !Self {
        // update stack position
        var psp_value: usize = 0;
        asm volatile (
            \\ mrs %[out], psp
            : [out] "=r" (psp_value),
        );

        return .{
            .stack = self.stack,
            .stack_position = @ptrFromInt(psp_value),
            .process_allocator = process_allocator,
            .stack_is_shared = true,
        };
    }

    pub fn reallocate_stack(self: *Self, stack_size: u32) !void {
        self.stack = try self.process_allocator.alignedAlloc(u8, .@"8", stack_size);
        self.stack_is_shared = false;
    }

    /// reallocate_stack with a stack the caller allocated from process_allocator.
    pub fn adopt_stack(self: *Self, stack: []align(8) u8) void {
        self.stack = stack;
        self.stack_is_shared = false;
    }

    pub fn reinitialize_stack(self: *Self, process_entry: anytype, argc: usize, argv: usize, symbol: usize, got: usize, exit_handler_impl: anytype) !void {
        const args = [_]usize{
            argc,
            argv,
            symbol,
            got,
        };

        self.stack_position = prepare_process_stack(self.stack, exit_handler_impl, process_entry, args[0..4], false);
    }

    pub fn validate_stack(self: *const Self) bool {
        return std.mem.eql(u8, self.stack[0..@sizeOf(u32)], std.mem.asBytes(&stack_marker));
    }
};

pub fn get_offset_of_hardware_stored_registers(use_fpu: bool) isize {
    // Derived from `basic_frame_size` rather than by subtracting the FP fields
    // from the struct: on a build without an FPU those fields are `void`, so the
    // subtraction went negative and this returned a *positive* offset.
    return if (use_fpu) -@sizeOf(HardwareStoredRegisters) else -basic_frame_size;
}

fn test_entry() void {}
fn test_exit_handler() void {}

test "prepare process initial stack" {
    var stack: [1024]u8 align(8) = @splat(0);
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
