const std = @import("std");

pub fn build(b: *std.Build) !void {
    const maybe_cpu_arch = b.option([]const u8, "cpu_arch", "CPU architecture to build for") orelse null;
    const optimize = b.standardOptimizeOption(.{}) orelse .debug;
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "verify_templates", b.option(bool, "verify_templates", "Compare template replay against full relocation") orelse false);

    // `zig build prelink`: the rootfs precache builder (tools/yasld_prelink.zig).
    // It runs this loader on the build machine, so it is built for a 32-bit
    // host -- the loader's `usize` is the device's address width.
    const prelink_target = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .linux });
    const prelink_yaff = b.addTranslateC(.{
        .root_source_file = b.path("../libs/tinycc/source/obj/tccyaff.h"),
        .target = freestandingHeaderTarget(b, prelink_target),
        .optimize = .ReleaseSafe,
        .link_libc = false,
    });
    prelink_yaff.addIncludePath(b.path("../libs/tinycc/source/obj"));
    const prelink_yasld = b.createModule(.{
        .target = prelink_target,
        .optimize = .ReleaseSafe,
        .root_source_file = b.path("source/yasld.zig"),
    });
    prelink_yasld.addImport("tccyaff_headers", prelink_yaff.createModule());
    prelink_yasld.addOptions("yasld_options", options);
    const prelink = b.addExecutable(.{
        .name = "yasld-prelink",
        .root_module = b.createModule(.{
            .target = prelink_target,
            .optimize = .ReleaseSafe,
            .root_source_file = b.path("tools/yasld_prelink.zig"),
            .imports = &.{.{ .name = "yasld", .module = prelink_yasld }},
        }),
    });
    b.step("prelink", "Build yasld-prelink, the rootfs loader precache builder").dependOn(&b.addInstallArtifact(prelink, .{}).step);

    // Host tests of what does not need the device: the template cache, and the
    // image parser (which needs the YAFF header layout, so it gets the same
    // C import the prelink tool builds).
    const yaff_headers = prelink_yaff.createModule();
    const template_tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = b.graph.host,
        .root_source_file = b.path("source/template.zig"),
    }) });
    const parser_tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = b.graph.host,
        .root_source_file = b.path("source/parser.zig"),
        .imports = &.{.{ .name = "tccyaff_headers", .module = yaff_headers }},
    }) });
    const test_step = b.step("test", "Run the loader's host tests");
    const integer_hash_tests = b.addTest(.{ .root_module = b.createModule(.{
        .target = b.graph.host,
        .root_source_file = b.path("source/integer_hash_map.zig"),
    }) });
    const integer_hash_codegen = b.addSystemCommand(&.{ "python3", "-m", "pytest" });
    integer_hash_codegen.addDirectoryArg(b.path("tests"));
    b.step("test-hash-codegen", "Check integer hashing through Zig C and tcc (requires pytest)").dependOn(&integer_hash_codegen.step);
    const thunk_codegen = b.addSystemCommand(&.{ "python3", "-m", "pytest" });
    thunk_codegen.addFileArg(b.path("tests/test_thunk_replay_codegen.py"));
    b.step("test-thunk-codegen", "Check thunk replay through Zig C and tcc (requires pytest)").dependOn(&thunk_codegen.step);
    test_step.dependOn(&b.addRunArtifact(integer_hash_tests).step);
    test_step.dependOn(&b.addRunArtifact(template_tests).step);
    test_step.dependOn(&b.addRunArtifact(parser_tests).step);

    if (maybe_cpu_arch) |cpu_arch| {
        if (std.mem.eql(u8, cpu_arch, "host")) {
            _ = b.addModule("yasld", .{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("stub/yasld.zig"),
            });
        } else {
            const yasld = b.addModule("yasld", .{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("source/yasld.zig"),
            });
            yasld.addAssemblyFile(b.path(b.fmt("source/arch/{s}/call.S", .{cpu_arch})));
            yasld.addAssemblyFile(b.path(b.fmt("source/arch/{s}/indirect_call_thunk.S", .{cpu_arch})));
            const tccyaff_headers = b.addTranslateC(.{
                .root_source_file = b.path("../libs/tinycc/source/obj/tccyaff.h"),
                .target = freestandingHeaderTarget(b, target),
                .optimize = optimize,
                .link_libc = false,
            });
            tccyaff_headers.addIncludePath(b.path("../libs/tinycc/source/obj"));
            yasld.addImport("tccyaff_headers", tccyaff_headers.createModule());
            yasld.addOptions("yasld_options", options);
        }
    }
}

/// The target to translate tccyaff.h for: `target` with the OS set to
/// freestanding. The header only needs <stdint.h>, and since Zig 0.18
/// `translate-c` searches the host's /usr/include for any non-freestanding OS
/// even without -lc, so the builtin <stdint.h>'s `#include_next` reaches the
/// host libc: with no 32-bit glibc headers installed (the CI image) the
/// translation fails on gnu/stubs-32.h. The CPU and ABI, and so the C types,
/// are unchanged.
fn freestandingHeaderTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    var query = target.query;
    query.os_tag = .freestanding;
    query.os_version_min = null;
    query.os_version_max = null;
    query.glibc_version = null;
    query.android_api_level = null;
    return b.resolveTargetQuery(query);
}
