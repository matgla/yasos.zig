//
// fstab.zig
//
// Copyright (C) 2026 Mateusz Stadnik <matgla@live.com>
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

// fstab(5), the subset yasos reads at boot.
//
//   <source> <target> <type> <options> [<dump> [<pass>]]
//
// Blank lines and `#` comments are skipped, fields are separated by blanks,
// and `\040`-style octal escapes are not supported (no yasos path needs a
// space). The parser only splits text; what the options mean is up to the
// mounter (`source/fs/mounter.zig`).

const std = @import("std");

pub const Entry = struct {
    source: []const u8,
    target: []const u8,
    fstype: []const u8,
    options: []const u8,
    dump: u8 = 0,
    pass: u8 = 0,

    /// `name` among the comma-separated options, as a whole word.
    pub fn has_option(self: *const Entry, name: []const u8) bool {
        return has_option_in(self.options, name);
    }

    /// The value of `name=value` among the options, or null.
    pub fn option_value(self: *const Entry, name: []const u8) ?[]const u8 {
        return option_value_in(self.options, name);
    }
};

pub fn has_option_in(options: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, options, ',');
    while (it.next()) |option| {
        if (std.mem.eql(u8, option, name)) return true;
    }
    return false;
}

pub fn option_value_in(options: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, options, ',');
    while (it.next()) |option| {
        if (option.len > name.len and std.mem.startsWith(u8, option, name) and option[name.len] == '=') {
            return option[name.len + 1 ..];
        }
    }
    return null;
}

/// Walks the entries of an fstab held in memory. Entries point into `text`.
pub const Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line_number: usize = 0,

    pub fn init(text: []const u8) Iterator {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    pub const Error = error{MalformedLine};

    /// The next entry, null at the end. A line with fewer than four fields is
    /// `MalformedLine`; `line_number` says which, and the iterator can carry
    /// on past it.
    pub fn next(self: *Iterator) Error!?Entry {
        while (self.lines.next()) |raw_line| {
            self.line_number += 1;
            const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |hash| raw_line[0..hash] else raw_line;
            const line = std.mem.trim(u8, without_comment, " \t\r");
            if (line.len == 0) continue;

            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const source = fields.next() orelse continue;
            const target = fields.next() orelse return Error.MalformedLine;
            const fstype = fields.next() orelse return Error.MalformedLine;
            const options = fields.next() orelse "defaults";
            const dump = std.fmt.parseInt(u8, fields.next() orelse "0", 10) catch 0;
            const pass = std.fmt.parseInt(u8, fields.next() orelse "0", 10) catch 0;
            return .{
                .source = source,
                .target = target,
                .fstype = fstype,
                .options = options,
                .dump = dump,
                .pass = pass,
            };
        }
        return null;
    }
};

test "Fstab.ParsesEntriesSkippingCommentsAndBlanks" {
    const text =
        \\# <source>  <target> <type> <options>
        \\
        \\LABEL=YASVAR   /var   vfat   nofail,x-fallback=ramfs 0 2
        \\  /home/root /root bind nofail   # trailing comment
        \\tmpfs /tmp tmpfs spill=/var/tmp
        \\
    ;
    var it = Iterator.init(text);
    const first = (try it.next()).?;
    try std.testing.expectEqualStrings("LABEL=YASVAR", first.source);
    try std.testing.expectEqualStrings("/var", first.target);
    try std.testing.expectEqualStrings("vfat", first.fstype);
    try std.testing.expect(first.has_option("nofail"));
    try std.testing.expect(!first.has_option("fail"));
    try std.testing.expectEqualStrings("ramfs", first.option_value("x-fallback").?);
    try std.testing.expectEqual(@as(u8, 2), first.pass);

    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("/home/root", second.source);
    try std.testing.expectEqualStrings("bind", second.fstype);
    try std.testing.expectEqualStrings("nofail", second.options);

    const third = (try it.next()).?;
    try std.testing.expectEqualStrings("/var/tmp", third.option_value("spill").?);
    try std.testing.expect(third.option_value("spil") == null);

    try std.testing.expect((try it.next()) == null);
}

test "Fstab.ReportsAShortLineAndCarriesOn" {
    var it = Iterator.init("/dev/mmc0p1 /boot\nproc /proc proc\n");
    try std.testing.expectError(Iterator.Error.MalformedLine, it.next());
    try std.testing.expectEqual(@as(usize, 1), it.line_number);
    const entry = (try it.next()).?;
    try std.testing.expectEqualStrings("defaults", entry.options);
}
