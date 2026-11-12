//! Trims the card's copy of std down to the systems the device compiler builds for.
//!
//! The device zig compiles for YasOS (thumb-linux) and freestanding Arm, nothing else,
//! yet std is written for every OS and CPU: most of std/c.zig and std/os/linux.zig is
//! `switch (native_os)` / `switch (native_arch)` prongs for other systems.  A file's ZIR
//! is loaded whole and stays pinned while analysis is inside it, and in `zig build`'s
//! configurer Io/Threaded.zig, c.zig and os/linux.zig are pinned together: 2.4 MB of ZIR
//! on a machine with 8.
//!
//! For every switch on the native OS or CPU, this drops the prongs that name only other
//! systems (`else` and prongs with anything but enum literals stay), so the source and
//! the ZIR lowered from it shrink alike.  A file whose trimmed form does not pass AstGen
//! (a local now used only by a dropped prong is "unused") gets its switches back one at
//! a time until it does.  The PC's std is not touched.
//!
//! usage: trim_std <std dir>   (rewrites files in place, prints what it saved)

const std = @import("std");
const Ast = std.zig.Ast;

const keep_os = [_][]const u8{ "linux", "freestanding", "other" };
const keep_arch = [_][]const u8{ "arm", "armeb", "thumb", "thumbeb" };

const Kind = enum { os, arch };

const Span = struct { start: u32, end: u32 };

/// A switch on the native OS or CPU and the byte spans of the prongs it would lose.
const Cut = struct { spans: []Span };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: trim_std <std dir>\n", .{});
        std.process.exit(2);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var before: usize = 0;
    var after: usize = 0;
    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const res = try trimFile(gpa, io, dir, entry.path);
        before += res[0];
        after += res[1];
        if (res[0] != res[1]) files += 1;
    }
    std.debug.print("trim_std: {d} files, {d} -> {d} bytes\n", .{ files, before, after });
}

fn trimFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !struct { usize, usize } {
    const source = try dir.readFileAllocOptions(io, path, gpa, .limited(16 << 20), .of(u8), 0);
    defer gpa.free(source);
    const os_name = nativeName(source, .os);
    const arch_name = nativeName(source, .arch);

    var tree = try Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return .{ source.len, source.len };

    var cuts: std.ArrayList(Cut) = .empty;
    defer {
        for (cuts.items) |c| gpa.free(c.spans);
        cuts.deinit(gpa);
    }
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        switch (tree.nodeTag(node)) {
            .@"switch", .switch_comma => {},
            else => continue,
        }
        const sw = tree.fullSwitch(node).?;
        const kind = condKind(&tree, sw.ast.condition, os_name, arch_name) orelse continue;
        const keep: []const []const u8 = switch (kind) {
            .os => &keep_os,
            .arch => &keep_arch,
        };
        var spans: std.ArrayList(Span) = .empty;
        errdefer spans.deinit(gpa);
        for (sw.ast.cases) |case_node| {
            const case = tree.fullSwitchCase(case_node).?;
            if (case.ast.values.len == 0) continue; // else
            if (!droppable(&tree, case.ast.values, keep)) continue;
            const first = tree.firstToken(case_node);
            var last = tree.lastToken(case_node);
            if (tree.tokenTag(last + 1) == .comma) last += 1;
            const start = lineStartIfBlank(source, tree.tokenStart(first));
            const end_tok = tree.tokenStart(last) + @as(u32, @intCast(tree.tokenSlice(last).len));
            try spans.append(gpa, .{ .start = start, .end = end_tok });
        }
        if (spans.items.len == 0) {
            spans.deinit(gpa);
            continue;
        }
        try cuts.append(gpa, .{ .spans = try spans.toOwnedSlice(gpa) });
    }
    if (cuts.items.len == 0) return .{ source.len, source.len };

    // All at once, then -- if AstGen objects -- one switch at a time, keeping each cut
    // that leaves the file clean.
    const enabled = try gpa.alloc(bool, cuts.items.len);
    defer gpa.free(enabled);
    @memset(enabled, true);
    var out = try render(gpa, source, cuts.items, enabled);
    if (!try clean(gpa, out)) {
        gpa.free(out);
        @memset(enabled, false);
        out = try gpa.dupeSentinel(u8, source, 0);
        for (0..cuts.items.len) |i| {
            enabled[i] = true;
            const attempt = try render(gpa, source, cuts.items, enabled);
            if (try clean(gpa, attempt)) {
                gpa.free(out);
                out = attempt;
            } else {
                gpa.free(attempt);
                enabled[i] = false;
            }
        }
    }
    defer gpa.free(out);
    if (out.len != source.len) try dir.writeFile(io, .{ .sub_path = path, .data = out });
    return .{ source.len, out.len };
}

/// The name a file gives the native OS tag or CPU arch, if it has one of the usual ones.
fn nativeName(source: []const u8, kind: Kind) ?[]const u8 {
    const forms: []const [2][]const u8 = switch (kind) {
        .os => &.{
            .{ "native_os", "const native_os = builtin.os.tag;" },
            .{ "native_os", "const native_os = @import(\"builtin\").os.tag;" },
            .{ "native_os", "const native_os = builtin.target.os.tag;" },
        },
        .arch => &.{
            .{ "native_arch", "const native_arch = builtin.cpu.arch;" },
            .{ "native_arch", "const native_arch = @import(\"builtin\").cpu.arch;" },
            .{ "native_arch", "const native_arch = builtin.target.cpu.arch;" },
        },
    };
    for (forms) |f| if (std.mem.indexOf(u8, source, f[1]) != null) return f[0];
    return null;
}

fn condKind(tree: *const Ast, cond: Ast.Node.Index, os_name: ?[]const u8, arch_name: ?[]const u8) ?Kind {
    const first = tree.tokenStart(tree.firstToken(cond));
    const last = tree.lastToken(cond);
    const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
    const text = tree.source[first..end];
    const os_forms = [_][]const u8{ "builtin.os.tag", "builtin.target.os.tag", "@import(\"builtin\").os.tag" };
    const arch_forms = [_][]const u8{ "builtin.cpu.arch", "builtin.target.cpu.arch", "@import(\"builtin\").cpu.arch" };
    if (os_name) |n| if (std.mem.eql(u8, text, n)) return .os;
    if (arch_name) |n| if (std.mem.eql(u8, text, n)) return .arch;
    for (os_forms) |f| if (std.mem.eql(u8, text, f)) return .os;
    for (arch_forms) |f| if (std.mem.eql(u8, text, f)) return .arch;
    return null;
}

/// A prong goes when every value is an enum literal naming a system not kept.
fn droppable(tree: *const Ast, values: []const Ast.Node.Index, keep: []const []const u8) bool {
    for (values) |v| {
        if (tree.nodeTag(v) != .enum_literal) return false;
        const name = tree.tokenSlice(tree.nodeMainToken(v));
        for (keep) |k| if (std.mem.eql(u8, name, k)) return false;
    }
    return true;
}

/// Start the cut at the line's start when only indentation precedes the prong, so no
/// blank line is left behind.
fn lineStartIfBlank(source: []const u8, at: u32) u32 {
    var i = at;
    while (i > 0 and (source[i - 1] == ' ' or source[i - 1] == '\t')) i -= 1;
    return if (i == 0 or source[i - 1] == '\n') i else at;
}

fn render(gpa: std.mem.Allocator, source: [:0]const u8, cuts: []const Cut, enabled: []const bool) ![:0]u8 {
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(gpa);
    for (cuts, enabled) |c, on| if (on) try spans.appendSlice(gpa, c.spans);
    std.mem.sort(Span, spans.items, {}, struct {
        fn lessThan(_: void, a: Span, b: Span) bool {
            return a.start < b.start;
        }
    }.lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: u32 = 0;
    for (spans.items) |s| {
        if (s.start < at) continue; // inside a prong already dropped
        try out.appendSlice(gpa, source[at..s.start]);
        at = s.end;
        // the line the prong ended on, if nothing else is left on it
        var j = at;
        while (j < source.len and (source[j] == ' ' or source[j] == '\t')) j += 1;
        if (j < source.len and source[j] == '\n' and (s.start == 0 or source[s.start - 1] == '\n')) at = j + 1;
    }
    try out.appendSlice(gpa, source[at..]);
    return out.toOwnedSliceSentinel(gpa, 0);
}

fn clean(gpa: std.mem.Allocator, source: [:0]const u8) !bool {
    var tree = try Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return false;
    var zir = try std.zig.AstGen.generate(gpa, tree);
    defer zir.deinit(gpa);
    return !zir.hasCompileErrors();
}
