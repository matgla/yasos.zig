//
// vfmt.zig
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

pub const Formatted = struct {
    ctx: *const anyopaque,
    render: *const fn (ctx: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void,
};

pub const Value = union(enum) {
    unsigned: u64,
    signed: i64,
    string: []const u8,
    bytes: []const u8,
    boolean: bool,
    char: u8,
    pointer: usize,
    formatted: Formatted,
};

pub inline fn value(v: anytype) Value {
    const T = @TypeOf(v);
    if (T == Value) return v;
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed)
            .{ .signed = @intCast(v) }
        else
            .{ .unsigned = @intCast(v) },
        .comptime_int => if (v < 0) .{ .signed = v } else .{ .unsigned = v },
        .bool => .{ .boolean = v },
        .@"enum" => .{ .string = @tagName(v) },
        .error_set => .{ .string = @errorName(v) },
        .null => .{ .string = "null" },
        .optional => if (v) |inner| value(inner) else .{ .string = "null" },
        .array => |a| if (a.child == u8) .{ .bytes = &v } else @compileError(
            "vfmt: unsupported array element " ++ @typeName(a.child),
        ),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) .{ .string = v } else .{ .pointer = @intFromPtr(v.ptr) },
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) .{ .string = v } else .{ .pointer = @intFromPtr(v) },
                .@"struct", .@"union", .@"enum" => if (@hasDecl(p.child, "format"))
                    .{ .formatted = .{ .ctx = @ptrCast(v), .render = renderer(p.child) } }
                else
                    .{ .pointer = @intFromPtr(v) },
                else => .{ .pointer = @intFromPtr(v) },
            },
            else => .{ .pointer = @intFromPtr(v) },
        },
        .@"struct", .@"union" => if (@hasDecl(T, "format"))
            .{ .formatted = .{ .ctx = @ptrCast(&v), .render = renderer(T) } }
        else
            @compileError("vfmt: " ++ @typeName(T) ++ " has no format method"),
        else => @compileError("vfmt: unsupported argument type " ++ @typeName(T)),
    };
}

fn renderer(comptime T: type) *const fn (*const anyopaque, *std.Io.Writer) std.Io.Writer.Error!void {
    return &struct {
        fn render(ctx: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *const T = @ptrCast(@alignCast(ctx));
            return T.format(self.*, w);
        }
    }.render;
}

pub fn ArgsArray(comptime T: type) type {
    return [@typeInfo(T).@"struct".field_names.len]Value;
}

pub inline fn erase(args: anytype) ArgsArray(@TypeOf(args)) {
    const names = @typeInfo(@TypeOf(args)).@"struct".field_names;
    var out: ArgsArray(@TypeOf(args)) = undefined;
    inline for (names, 0..) |name, i| out[i] = value(@field(args, name));
    return out;
}

const Spec = struct {
    verb: u8 = 0, // 0 == default
    fill: u8 = ' ',
    alignment: u8 = '>',
    width: usize = 0,
};

fn parseSpec(text: []const u8) Spec {
    var spec: Spec = .{};
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const verb_part = if (colon) |c| text[0..c] else text;
    if (verb_part.len > 0) spec.verb = verb_part[0];
    if (verb_part.len > 1 and verb_part[0] == 'a') spec.verb = 'a';

    if (colon == null) return spec;
    var rest = text[colon.? + 1 ..];
    if (rest.len >= 2 and (rest[1] == '<' or rest[1] == '>' or rest[1] == '^')) {
        spec.fill = rest[0];
        spec.alignment = rest[1];
        rest = rest[2..];
    } else if (rest.len >= 1 and (rest[0] == '<' or rest[0] == '>' or rest[0] == '^')) {
        spec.alignment = rest[0];
        rest = rest[1..];
    }
    var width: usize = 0;
    for (rest) |ch| {
        if (ch < '0' or ch > '9') break;
        width = width * 10 + (ch - '0');
    }
    spec.width = width;
    return spec;
}

const Out = struct {
    buf: []u8,
    len: usize = 0,
    needed: usize = 0,

    fn byte(self: *Out, c: u8) void {
        self.needed += 1;
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn bytes(self: *Out, s: []const u8) void {
        self.needed += s.len;
        const room = self.buf.len - self.len;
        const n = @min(room, s.len);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn padded(self: *Out, s: []const u8, spec: Spec) void {
        if (s.len >= spec.width) return self.bytes(s);
        const pad = spec.width - s.len;
        switch (spec.alignment) {
            '<' => {
                self.bytes(s);
                for (0..pad) |_| self.byte(spec.fill);
            },
            '^' => {
                const left = pad / 2;
                for (0..left) |_| self.byte(spec.fill);
                self.bytes(s);
                for (0..pad - left) |_| self.byte(spec.fill);
            },
            else => {
                for (0..pad) |_| self.byte(spec.fill);
                self.bytes(s);
            },
        }
    }
};

const digits_lower = "0123456789abcdef";
const digits_upper = "0123456789ABCDEF";

fn renderInt(scratch: []u8, v: u64, negative: bool, base: u8, digits: []const u8) []u8 {
    var i = scratch.len;
    var n = v;
    while (true) {
        i -= 1;
        scratch[i] = digits[@intCast(n % base)];
        n /= base;
        if (n == 0) break;
    }
    if (negative) {
        i -= 1;
        scratch[i] = '-';
    }
    return scratch[i..];
}

fn emitValue(out: *Out, v: Value, spec: Spec) void {
    var scratch: [24]u8 = undefined;
    switch (v) {
        .unsigned => |u| switch (spec.verb) {
            'x' => out.padded(renderInt(&scratch, u, false, 16, digits_lower), spec),
            'X' => out.padded(renderInt(&scratch, u, false, 16, digits_upper), spec),
            'c' => out.padded(&[_]u8{@truncate(u)}, spec),
            else => out.padded(renderInt(&scratch, u, false, 10, digits_lower), spec),
        },
        .signed => |i| {
            const negative = i < 0;
            const magnitude: u64 = if (negative) @intCast(-@as(i128, i)) else @intCast(i);
            switch (spec.verb) {
                'x' => out.padded(renderInt(&scratch, magnitude, negative, 16, digits_lower), spec),
                'X' => out.padded(renderInt(&scratch, magnitude, negative, 16, digits_upper), spec),
                else => out.padded(renderInt(&scratch, magnitude, negative, 10, digits_lower), spec),
            }
        },
        .string => |s| out.padded(s, spec),
        .bytes => |b| {
            if (spec.verb == 's') return out.padded(b, spec);
            const upper = spec.verb == 'X';
            const digits = if (upper) digits_upper else digits_lower;
            out.byte('{');
            for (b, 0..) |byte_value, i| {
                if (i != 0) out.byte(' ');
                out.byte(digits[byte_value >> 4]);
                out.byte(digits[byte_value & 0xf]);
            }
            out.byte('}');
        },
        .boolean => |b| out.padded(if (b) "true" else "false", spec),
        .char => |c| out.padded(&[_]u8{c}, spec),
        .pointer => |p| {
            out.bytes("0x");
            out.padded(renderInt(&scratch, p, false, 16, digits_lower), spec);
        },
        .formatted => |f| {
            var w: std.Io.Writer = .fixed(out.buf[out.len..]);
            f.render(f.ctx, &w) catch {};
            out.len += w.buffered().len;
        },
    }
}

pub fn vprint(buf: []u8, fmt: []const u8, args: []const Value) []u8 {
    var out: Out = .{ .buf = buf };
    render(&out, fmt, args);
    return buf[0..out.len];
}

fn render(out: *Out, fmt: []const u8, args: []const Value) void {
    var i: usize = 0;
    var next_arg: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                out.byte('{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, fmt, i + 1, '}') orelse {
                out.byte(c);
                i += 1;
                continue;
            };
            const spec = parseSpec(fmt[i + 1 .. close]);
            i = close + 1;
            if (next_arg < args.len) {
                emitValue(out, args[next_arg], spec);
                next_arg += 1;
            } else {
                out.bytes("<missing>");
            }
            continue;
        }
        if (c == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
            out.byte('}');
            i += 2;
            continue;
        }
        out.byte(c);
        i += 1;
    }
}

pub inline fn print(buf: []u8, comptime fmt: []const u8, args: anytype) []u8 {
    const argv = erase(args);
    return vprint(buf, fmt, &argv);
}

pub fn vprintLen(fmt: []const u8, args: []const Value) usize {
    var out: Out = .{ .buf = &.{} };
    render(&out, fmt, args);
    return out.needed;
}

pub fn vallocPrint(allocator: std.mem.Allocator, fmt: []const u8, args: []const Value) std.mem.Allocator.Error![]u8 {
    const buf = try allocator.alloc(u8, vprintLen(fmt, args));
    return vprint(buf, fmt, args);
}

pub inline fn allocPrint(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error![]u8 {
    const argv = erase(args);
    return vallocPrint(allocator, fmt, &argv);
}

pub fn vallocPrintZ(allocator: std.mem.Allocator, fmt: []const u8, args: []const Value) std.mem.Allocator.Error![:0]u8 {
    const n = vprintLen(fmt, args);
    const buf = try allocator.allocSentinel(u8, n, 0);
    _ = vprint(buf, fmt, args);
    return buf;
}

pub inline fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error![:0]u8 {
    const argv = erase(args);
    return vallocPrintZ(allocator, fmt, &argv);
}
