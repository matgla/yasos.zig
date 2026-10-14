//! Build the kernel with tinycc instead of LLVM (`-Dkernel_cc=tcc`).
//!
//! The kernel's Zig modules go through Zig's C backend into one C file; that,
//! every C and assembly unit the kernel's modules and static libraries carry,
//! tcc's runtime, its soft-double FP helpers and Zig's compiler-rt (also
//! through the C backend) are all compiled by the cross tcc and linked by it,
//! with the kernel's own linker script.  Nothing here uses clang, gcc or a
//! binutils tool: the same steps are what the device runs to rebuild itself.
//!
//! The units are not listed by hand: they are read from the module graph the
//! LLVM kernel is configured with (`kernel`), so a source added to the kernel
//! the usual way is picked up here too.
//!
//! Every tcc command is also recorded, argument by argument, into a plan
//! (`zig build kernel-tcc-plan` -> zig-out/kernel_tcc_plan.json) that
//! scripts/kernel_tcc/device.py replays with the device's own tcc.

const std = @import("std");

const Build = std.Build;
const LazyPath = Build.LazyPath;
const Module = Build.Module;
const Compile = Build.Step.Compile;

pub const Options = struct {
    /// The host cross compiler (libs/tinycc/bin/armv8m-tcc, built by build_rootfs.sh).
    tcc: []const u8,
};

pub const Result = struct {
    elf: LazyPath,
    /// The tcc commands as data, for a rebuild on the device.
    plan: LazyPath,
};

/// One tcc command.  Each argument goes to the step that runs it and, marked
/// with its kind, to the plan step (scripts/kernel_tcc/tool.py plan): "@cmd"
/// starts a command, "@in"/"@dir"/"@out"/"@dep" PREFIX PATH are files,
/// anything else is a literal argument.
const Cmd = struct {
    run: *Build.Step.Run,
    plan: *Build.Step.Run,

    fn arg(c: Cmd, s: []const u8) void {
        std.debug.assert(s.len == 0 or s[0] != '@');
        c.run.addArg(s);
        c.plan.addArg(s);
    }

    fn args(c: Cmd, ss: []const []const u8) void {
        for (ss) |s| c.arg(s);
    }

    fn file(c: Cmd, prefix: []const u8, lp: LazyPath) void {
        c.run.addPrefixedFileArg(prefix, lp);
        c.plan.addArgs(&.{ "@in", prefix });
        c.plan.addFileArg(lp);
    }

    fn dir(c: Cmd, prefix: []const u8, lp: LazyPath) void {
        c.run.addPrefixedDirectoryArg(prefix, lp);
        c.plan.addArgs(&.{ "@dir", prefix });
        c.plan.addDirectoryArg(lp);
    }

    fn out(c: Cmd, prefix: []const u8, name: []const u8) LazyPath {
        const lp = c.run.addPrefixedOutputFileArg(prefix, name);
        c.plan.addArgs(&.{ "@out", prefix });
        c.plan.addFileArg(lp);
        return lp;
    }

    /// The compile's headers, read back from tcc's make-style depfile -- by
    /// the build cache here, and by the plan to know what the device needs.
    fn depfile(c: Cmd, name: []const u8) void {
        c.run.addArg("-MD");
        const lp = c.run.addPrefixedDepFileOutputArg("-MF", name);
        c.plan.addArgs(&.{ "@dep", "" });
        c.plan.addFileArg(lp);
    }
};

const Unit = struct {
    file: LazyPath,
    flags: []const []const u8,
    module: *Module,
    name: []const u8,
};

const Ctx = struct {
    b: *Build,
    tcc: []const u8,
    /// The compiler binary as a cache input: a rebuilt tcc must invalidate
    /// every step it ran in (a string argv[0] is not hashed by content).
    tcc_input: LazyPath,
    fp_flags: []const []const u8,
    root_optimize: std.builtin.OptimizeMode,
    zig_lib: LazyPath,
    plan: *Build.Step.Run,
    count: usize = 0,

    fn optFlag(ctx: *Ctx, m: *Module) []const u8 {
        return switch (m.optimize orelse ctx.root_optimize) {
            .Debug => "-O0",
            .ReleaseSmall => "-Os",
            .ReleaseFast, .ReleaseSafe => "-O2",
        };
    }

    /// A tcc command run from the repository root.
    fn cmd(ctx: *Ctx, first: []const []const u8) Cmd {
        const run = ctx.b.addSystemCommand(&.{ctx.tcc});
        run.setCwd(ctx.b.path("."));
        run.addFileInput(ctx.tcc_input);
        ctx.plan.addArg("@cmd");
        const c: Cmd = .{ .run = run, .plan = ctx.plan };
        c.args(first);
        return c;
    }

    /// A compile.  -DYASLIBC_REAL_BOOL: yaslibc's <stdbool.h> gives tcc-built
    /// userspace `unsigned char` for bool; the kernel's C needs _Bool, as
    /// clang compiles it (libs/libc/stdbool.h says why).
    fn base(ctx: *Ctx, opt: []const u8) Cmd {
        return ctx.cmd(&.{ opt, "-fno-pic", "-ffunction-sections", "-fdata-sections", "-DYASLIBC_REAL_BOOL" });
    }

    fn depfile(ctx: *Ctx, c: Cmd) void {
        ctx.count += 1;
        c.depfile(ctx.b.fmt("{d}.d", .{ctx.count}));
    }

    /// One tcc compile of `u` with its module's include path and macros.
    fn compile(ctx: *Ctx, u: Unit) LazyPath {
        const b = ctx.b;
        const c = ctx.base(ctx.optFlag(u.module));
        c.args(ctx.fp_flags);
        for (u.flags) |f| {
            if (keepFlag(f)) c.arg(f);
        }
        for (u.module.c_macros.items) |d| c.arg(d);
        for (u.module.include_dirs.items) |inc| switch (inc) {
            .path, .path_system, .path_after => |p| c.dir("-I", p),
            .other_step => |o| c.dir("-I", o.getEmittedIncludeTree()),
            .config_header_step => |h| c.dir("-I", h.getOutputDir()),
            else => {},
        };
        ctx.depfile(c);
        c.arg("-c");
        c.file("", u.file);
        c.arg("-o");
        ctx.count += 1;
        return c.out("", b.fmt("{d}_{s}.o", .{ ctx.count, u.name }));
    }

    fn archive(ctx: *Ctx, name: []const u8, objs: []const LazyPath) LazyPath {
        const c = ctx.cmd(&.{ "-ar", "rcs" });
        const out = c.out("", ctx.b.fmt("lib{s}.a", .{name}));
        for (objs) |o| c.file("", o);
        return out;
    }
};

/// Flags a module gives its C sources that mean something to tcc; warnings
/// and clang-only options are dropped.
fn keepFlag(f: []const u8) bool {
    return std.mem.startsWith(u8, f, "-D") or std.mem.startsWith(u8, f, "-I") or
        std.mem.startsWith(u8, f, "-std=") or std.mem.eql(u8, f, "-fno-builtin") or
        std.mem.eql(u8, f, "-ffunction-sections") or std.mem.eql(u8, f, "-fdata-sections");
}

fn baseName(b: *Build, lp: LazyPath) []const u8 {
    const p = switch (lp) {
        .src_path => |sp| sp.sub_path,
        .cwd_relative => |p| p,
        .dependency => |d| d.sub_path,
        else => "unit",
    };
    const stem = std.fs.path.stem(p);
    return b.dupe(if (stem.len == 0) "unit" else stem);
}

/// C and assembly units of one module; static libraries it links are queued.
fn collectModule(b: *Build, m: *Module, units: *std.ArrayList(Unit), libs: *std.ArrayList(*Compile)) void {
    for (m.link_objects.items) |lo| switch (lo) {
        .c_source_file => |f| units.append(b.allocator, .{ .file = f.file, .flags = f.flags, .module = m, .name = baseName(b, f.file) }) catch @panic("OOM"),
        .c_source_files => |fs| for (fs.files) |file| {
            const lp = fs.root.path(b, file);
            units.append(b.allocator, .{ .file = lp, .flags = fs.flags, .module = m, .name = b.dupe(std.fs.path.stem(file)) }) catch @panic("OOM");
        },
        .assembly_file => |lp| units.append(b.allocator, .{ .file = lp, .flags = &.{}, .module = m, .name = baseName(b, lp) }) catch @panic("OOM"),
        .other_step => |c| if (c.kind == .lib) {
            for (libs.items) |seen| {
                if (seen == c) break;
            } else libs.append(b.allocator, c) catch @panic("OOM");
        },
        // libgcc and other prebuilt archives: tcc's runtime, its FP helpers
        // and Zig's compiler-rt take their place.
        else => {},
    };
}

fn collectGraph(b: *Build, root: *Module, units: *std.ArrayList(Unit), libs: *std.ArrayList(*Compile)) void {
    for (root.getGraph().modules) |m| collectModule(b, m, units, libs);
}

/// A C-backend object of `root`'s module graph: the same root source and
/// imports, the target re-pointed at the C object format.
fn cbeObject(b: *Build, name: []const u8, root_source: LazyPath, root: ?*Module, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) LazyPath {
    var query = target.query;
    query.ofmt = .c;
    const mod = b.createModule(.{
        .root_source_file = root_source,
        .target = b.resolveTargetQuery(query),
        .optimize = optimize,
    });
    if (root) |r| {
        for (r.import_table.keys(), r.import_table.values()) |n, m| mod.addImport(n, m);
    }
    const obj = b.addObject(.{ .name = name, .root_module = mod, .use_llvm = false });
    obj.bundle_compiler_rt = false;
    return obj.getEmittedBin();
}

pub fn build(b: *Build, kernel: *Compile, opts: Options) Result {
    const target = kernel.root_module.resolved_target.?;
    const t = target.result;
    const hard = t.abi == .eabihf;
    const has_dp = std.Target.arm.featureSetHas(t.cpu.features, .fp_armv8d16);
    var ctx: Ctx = .{
        .b = b,
        .tcc = opts.tcc,
        .tcc_input = if (std.fs.path.isAbsolute(opts.tcc)) .{ .cwd_relative = opts.tcc } else b.path(opts.tcc),
        .fp_flags = if (!hard) &.{"-mfloat-abi=soft"} else if (has_dp)
            &.{ "-mfloat-abi=hard", "-mfpu=fpv5-d16" }
        else
            &.{ "-mfloat-abi=hard", "-mfpu=fpv5-sp-d16" },
        .root_optimize = kernel.root_module.optimize orelse .ReleaseSafe,
        .zig_lib = b.graph.path(.zig_lib, ""),
        .plan = b.addSystemCommand(&.{ "python3", "scripts/kernel_tcc/tool.py", "plan" }),
    };
    ctx.plan.setCwd(b.path("."));
    ctx.plan.addFileInput(b.path("scripts/kernel_tcc/tool.py"));
    const plan = ctx.plan.addOutputFileArg("kernel_tcc_plan.json");

    // 1. Zig -> C -> tcc.
    const kernel_c = cbeObject(b, "yasos_kernel", kernel.root_module.root_source_file.?, kernel.root_module, target, ctx.root_optimize);
    const fixed = b.addSystemCommand(&.{ "python3", "scripts/kernel_tcc/tool.py", "fix-cbe" });
    fixed.setCwd(b.path("."));
    fixed.addFileInput(b.path("scripts/kernel_tcc/tool.py"));
    fixed.addFileArg(kernel_c);
    const kernel_fixed = fixed.addOutputFileArg("kernel.c");
    const kernel_obj = blk: {
        const c = ctx.base("-O2");
        c.args(ctx.fp_flags);
        // Atomic read-modify-writes as LDREX/STREX loops in place, not calls
        // into armv8m_atomic.S: the kernel's atomics all live in SRAM, where
        // exclusives work (never in PSRAM -- sync/placement.zig).  A tinycc
        // without the option ignores it.
        c.args(&.{ "-fvisibility=hidden", "-minline-atomics", "-include", "apps/zig/zig_c_prelude.h" });
        c.dir("-I", ctx.zig_lib);
        ctx.depfile(c);
        c.arg("-c");
        c.file("", kernel_fixed);
        c.arg("-o");
        break :blk c.out("", "kernel.o");
    };

    // 2. Every C/asm unit of the kernel's modules, and its static libraries.
    var units: std.ArrayList(Unit) = .empty;
    var libs: std.ArrayList(*Compile) = .empty;
    collectGraph(b, kernel.root_module, &units, &libs);
    var objs: std.ArrayList(LazyPath) = .empty;
    objs.append(b.allocator, kernel_obj) catch @panic("OOM");
    for (units.items) |u| objs.append(b.allocator, ctx.compile(u)) catch @panic("OOM");

    var archives: std.ArrayList(LazyPath) = .empty;
    var i: usize = 0;
    while (i < libs.items.len) : (i += 1) {
        const lib = libs.items[i];
        var lib_units: std.ArrayList(Unit) = .empty;
        collectGraph(b, lib.root_module, &lib_units, &libs);
        var lib_objs: std.ArrayList(LazyPath) = .empty;
        for (lib_units.items) |u| lib_objs.append(b.allocator, ctx.compile(u)) catch @panic("OOM");
        archives.append(b.allocator, ctx.archive(lib.name, lib_objs.items)) catch @panic("OOM");
    }

    // 3. tcc's runtime: __aeabi_* helpers use the base AAPCS whatever the
    //    caller's float ABI, so they are built soft.
    const soft: []const []const u8 = &.{"-mfloat-abi=soft"};
    const rt_objs = runtime(&ctx, soft, &.{ "builtin.c", "armeabi.c", "armeabi_divmod.S", "arm_string.S", "arm_copystub.S", "armv8m_atomic.S" }, "libs/tinycc/lib", "-O1");
    const krt = ctx.archive("ktcc1", rt_objs);
    const fp_srcs: []const []const u8 = if (hard)
        &.{ "arm/vfpv4-sp/fops.c", "arm/vfpv4-sp/conv.c", "soft/dadd.c", "soft/dmul.c", "soft/ddiv.c", "soft/dcmp.c", "soft/dconv.c", "soft/fcmp.c", "soft/conv64.c", "soft/dcmp_asm.S", "soft/fcmp_asm.S", "soft/f2d_stub.S" }
    else
        &.{ "soft/fadd.c", "soft/fmul.c", "soft/fdiv.c", "soft/fcmp.c", "soft/dadd.c", "soft/dmul.c", "soft/ddiv.c", "soft/dconv.c", "soft/dcmp.c", "soft/conv.c", "soft/conv64.c", "soft/f2d_stub.S", "soft/fcmp_asm.S", "soft/dcmp_asm.S" };
    // The single-precision helpers use the FPU inside while keeping the
    // base-AAPCS interface: soft ABI, hardware FP instructions.
    const fp_flags: []const []const u8 = if (hard)
        &.{ "-mfloat-abi=soft", "-mfpu=fpv5-sp-d16", "-Ilibs/tinycc/lib/fp", "-Ilibs/tinycc", "-Ilibs/tinycc/include" }
    else
        &.{ "-mfloat-abi=soft", "-Ilibs/tinycc/lib/fp", "-Ilibs/tinycc", "-Ilibs/tinycc/include" };
    const fp_objs = runtime(&ctx, fp_flags, fp_srcs, "libs/tinycc/lib/fp", "-O2");
    const kfp = ctx.archive("kfp", fp_objs);

    // 4. Zig's compiler-rt through the C backend, minus what the archives
    //    above already define (apps/zig/strip_naked_asm.py).
    const crt_c = cbeObject(b, "compiler_rt", b.graph.path(.zig_lib, "compiler_rt.zig"), null, target, .ReleaseFast);
    const prov = b.addSystemCommand(&.{ "python3", "scripts/kernel_tcc/tool.py", "provided" });
    prov.setCwd(b.path("."));
    prov.addFileInput(b.path("scripts/kernel_tcc/tool.py"));
    const provided = prov.addOutputFileArg("provided.txt");
    prov.addFileArg(krt);
    prov.addFileArg(kfp);
    for (archives.items) |a| prov.addFileArg(a);
    const strip = b.addSystemCommand(&.{ "python3", "apps/zig/strip_naked_asm.py" });
    strip.setCwd(b.path("."));
    strip.addFileInput(b.path("apps/zig/strip_naked_asm.py"));
    strip.addFileArg(crt_c);
    const crt_tcc = strip.addOutputFileArg("compiler_rt_tcc.c");
    strip.addFileArg(provided);
    const crt_obj = blk: {
        const c = ctx.base("-O2");
        c.args(ctx.fp_flags);
        c.args(&.{ "-fvisibility=hidden", "-include", "apps/zig/zig_c_prelude.h" });
        c.dir("-I", ctx.zig_lib);
        ctx.depfile(c);
        c.arg("-c");
        c.file("", crt_tcc);
        c.arg("-o");
        break :blk c.out("", "compiler_rt.o");
    };
    const kcrt = ctx.archive("kcrt", &.{crt_obj});

    // 5. Link with tcc and the kernel's linker script.
    const link = ctx.cmd(&.{ "-g", "-nostdlib", "-nodefaultlibs", "-static", "-Wl,--gc-sections", "-Wl,-oformat=elf32-littlearm" });
    if (kernel.linker_script) |script| link.file("-T", script);
    link.arg("-o");
    const elf = link.out("", "yasos_kernel");
    for (objs.items) |o| link.file("", o);
    // The libraries call each other (lwext4 -> libc's qsort, libc -> the FP
    // helpers): one group, searched until nothing new resolves.
    link.arg("-Wl,--start-group");
    for (archives.items) |a| link.file("", a);
    link.file("", kcrt);
    link.file("", kfp);
    link.file("", krt);
    link.arg("-Wl,--end-group");
    return .{ .elf = elf, .plan = plan };
}

fn runtime(ctx: *Ctx, flags: []const []const u8, srcs: []const []const u8, dir: []const u8, opt: []const u8) []const LazyPath {
    const b = ctx.b;
    var out: std.ArrayList(LazyPath) = .empty;
    for (srcs) |s| {
        const c = ctx.base(opt);
        c.args(flags);
        ctx.depfile(c);
        c.arg("-c");
        c.file("", b.path(b.fmt("{s}/{s}", .{ dir, s })));
        c.arg("-o");
        ctx.count += 1;
        out.append(b.allocator, c.out("", b.fmt("{d}_{s}.o", .{ ctx.count, std.fs.path.stem(s) }))) catch @panic("OOM");
    }
    return out.items;
}
