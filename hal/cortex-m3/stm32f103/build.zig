const std = @import("std");

pub const target = std.Target.Query{
    .cpu_arch = .thumb,
    .cpu_model = .{
        .explicit = &std.Target.arm.cpu.cortex_m3,
    },
    .os_tag = .freestanding,
    .abi = .eabi,
};
