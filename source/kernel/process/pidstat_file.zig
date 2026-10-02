// Copyright (c) 2025 Mateusz Stadnik
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of
// this software and associated documentation files (the "Software"), to deal in
// the Software without restriction, including without limitation the rights to
// use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");
const vfmt = @import("../vfmt.zig");

const c = @import("libc_imports").c;
const interface = @import("interface");

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.@"vfs/meminfo");

const MemoryInfo = struct {
    free: usize,
    total: usize,
};

const BufferSize = 1024;
const PidStatBufferedFile = kernel.fs.BufferedFile(BufferSize);
pub const PidStatFile = interface.DeriveFromBase(PidStatBufferedFile, struct {
    const Self = @This();
    base: PidStatBufferedFile,
    _pid: i16,
    _human_readable: bool,

    pub fn create(allocator: std.mem.Allocator, pid: i16, human_readable: bool) PidStatFile {
        return PidStatFile.init(.{
            .base = PidStatBufferedFile.InstanceType.create(allocator, if (human_readable) "status" else "stat"),
            ._pid = pid,
            ._human_readable = human_readable,
        });
    }

    /// Rendered here rather than in `create`: the content belongs to the
    /// instance the caller gets (see BufferedFile).
    pub fn create_node(allocator: std.mem.Allocator, pid: i16, human_readable: bool) anyerror!kernel.fs.Node {
        var file = try create(allocator, pid, human_readable).interface.new(allocator);
        _ = file.interface.sync();
        return kernel.fs.Node.create_file(file);
    }

    const human_readable_file_content_format =
        \\Name:   {s}
        \\Umask:  0000
        \\Tgid:   {d}
        \\Ngid:   {d}
        \\Pid:    {d}
        \\PPid:   {d}
        \\
    ;

    fn write_status_content(process: anytype, name: []const u8, pid: i16, buffer: []u8) usize {
        const ppid: i32 = if (process.get_parent()) |p| p.pid else 0;
        var written = vfmt.print(buffer, human_readable_file_content_format, .{ name, pid, pid, pid, ppid }).len;
        written += vfmt.print(buffer[written..], "Sched:  {s}\nWaitOn: 0x{x}\n", .{ @tagName(process.state), if (process.waiting_for) |w| @intFromPtr(w) else 0 }).len;
        // Open descriptors; for a pipe end, the pipe and its end counts, which
        // is what finding a reader that never gets EOF comes down to.
        if (!process._fds_cleared) {
            var it = process._fds.iterator();
            while (it.next()) |entry| {
                const handle = entry.value_ptr;
                written += vfmt.print(buffer[written..], "fd {d}{s}: {s}", .{ entry.key_ptr.*, if (handle.cloexec) " cloexec" else "", handle.path }).len;
                if (handle.node.is_file() and handle.node.filetype() == .Fifo) {
                    const e = kernel.fs.describe_pipe_end(handle.node.instance.file.__ptr);
                    written += vfmt.print(buffer[written..], " pipe=0x{x} {s} r={d} w={d}", .{ e.pipe, if (e.writable) "W" else "R", e.readers, e.writers }).len;
                }
                written += vfmt.print(buffer[written..], "\n", .{}).len;
            }
        }
        return written;
    }

    const PidStat = struct {
        pid: i32,
        comm: []const u8,
        state: []const u8,
        pgid: i32,
        pgrp: i32,
        session: i32,
        tty_nr: i32,
        tpgid: i32,
        flags: u32,
        minflt: u64,
        cminflt: u64,
        majflt: u64,
        cmajflt: u64,
        utime: u64,
        stime: u64,
        cutime: i64,
        cstime: i64,
        priority: i64,
        nice: i64,
        num_threads: i64,
        itrealvalue: i64,
        starttime: u64,
        vsize: u64,
        rss: i64,
        rsslim: u64,
        startcode: u64,
        endcode: u64,
        startstack: u64,
        kstkesp: u64,
        kstkeip: u64,
        signal: u64,
        blocked: u64,
        sigignore: u64,
        sigcatch: u64,
        wchan: u64,
        nswap: u64,
        cnswap: u64,
        exit_signal: i32,
        processor: i32,
        rt_priority: u32,
        policy: u32,
        delayacct_blkio_ticks: u64,
        guest_time: u64,
        cguest_time: i64,
        start_data: u64,
        end_data: u64,
        start_brk: u64,
        arg_start: u64,
        arg_end: u64,
        env_start: u64,
        env_end: u64,
        exit_code: i32,
    };

    const stat_fields = @typeInfo(PidStat).@"struct".field_names;

    // One format string for the whole line, built at comptime. A print per
    // field, unrolled over 52 fields, was 152 KB of C in one function
    // (erasure + bounds-checked slicing each time) and 15 MB of tcc heap to
    // compile it on the device.
    const stat_format = blk: {
        var fmt: []const u8 = "";
        for (stat_fields) |field_name| {
            fmt = fmt ++ if (std.mem.eql(u8, field_name, "comm"))
                "({s}) "
            else if (std.mem.eql(u8, field_name, "state"))
                "{s} "
            else
                "{d} ";
        }
        break :blk fmt ++ "\n";
    };

    fn write_stat_content(stat: *const PidStat, buffer: []u8) usize {
        var args: [stat_fields.len]vfmt.Value = undefined;
        inline for (stat_fields, 0..) |field_name, i| {
            args[i] = vfmt.value(@field(stat, field_name));
        }
        return vfmt.vprint(buffer, stat_format, &args).len;
    }

    pub fn sync(self: *Self) i32 {
        const maybe_process = kernel.process.process_manager.instance.get_process_for_pid(self._pid);
        if (maybe_process) |process| {
            // const proc_name = process.get_name();
            const buffer = interface.base(self).buffer() orelse return -1;
            var name: []const u8 = "??";
            if (kernel.dynamic_loader.get_executable_for_pid(self._pid)) |ex| {
                if (ex.module.name) |n| {
                    name = n;
                }
            }
            if (self._human_readable) {
                interface.base(self)._end = write_status_content(process, name, self._pid, buffer);
            } else {
                const stat: PidStat = .{
                    .pid = self._pid,
                    .comm = name,
                    .state = "R",
                    .pgid = 0,
                    .pgrp = 0,
                    .session = 0,
                    .tty_nr = 1,
                    .tpgid = 0,
                    .flags = 0,
                    .minflt = 0,
                    .cminflt = 0,
                    .majflt = 0,
                    .cmajflt = 0,
                    .utime = process.get_uptime() / 1000,
                    .stime = 0,
                    .cutime = 0,
                    .cstime = 0,
                    .priority = 0,
                    .nice = 0,
                    .num_threads = 1,
                    .itrealvalue = 0,
                    .starttime = 0,
                    .vsize = 0,
                    .rss = 0,
                    .rsslim = 0,
                    .startcode = 0,
                    .endcode = 0,
                    .startstack = 0,
                    .kstkesp = 0,
                    .kstkeip = 0,
                    .signal = 0,
                    .blocked = 0,
                    .sigignore = 0,
                    .sigcatch = 0,
                    .wchan = 0,
                    .nswap = 0,
                    .cnswap = 0,
                    .exit_signal = 0,
                    .processor = 0,
                    .rt_priority = 0,
                    .policy = 0,
                    .delayacct_blkio_ticks = 0,
                    .guest_time = 0,
                    .cguest_time = 0,
                    .start_data = 0,
                    .end_data = 0,
                    .start_brk = 0,
                    .arg_start = 0,
                    .arg_end = 0,
                    .env_start = 0,
                    .env_end = 0,
                    .exit_code = 0,
                };
                interface.base(self)._end = write_stat_content(&stat, buffer);
            }
        }
        return 0;
    }

    pub fn delete(self: *Self) void {
        interface.base(self).delete();
    }
});

fn test_entry() void {}
const DirectoryMock = @import("../fs/tests/directory_mock.zig").DirectoryMock;
const FileMock = @import("../fs/tests/file_mock.zig").FileMock;
const FileSystemMock = @import("../fs/tests/filesystem_mock.zig").FileSystemMock;

test "PidStatFile.ShouldCreateStatFile" {
    kernel.process.process_manager.initialize_process_manager(std.testing.allocator);
    defer kernel.process.process_manager.deinitialize_process_manager();
    kernel.dynamic_loader.init(std.testing.allocator);
    defer kernel.dynamic_loader.deinit();
    kernel.fs.vfs_init(std.testing.allocator);
    defer kernel.fs.vfs_deinit();

    const fsmock = try FileSystemMock.create(std.testing.allocator);
    try kernel.fs.get_vfs().mount_filesystem("/", fsmock.interface);

    const filemock = try FileMock.create(std.testing.allocator);

    const IoctlCallback = struct {
        pub fn call(ctx: ?*const anyopaque, args: @Tuple(&[_]type{ i32, ?*anyopaque })) !i32 {
            const cmd = args[0];
            try std.testing.expectEqual(cmd, @as(i32, @intFromEnum(kernel.fs.IoctlCommonCommands.GetMemoryMappingStatus)));

            const a = args[1];
            var attr: *kernel.fs.FileMemoryMapAttributes = @ptrCast(@alignCast(a.?));
            attr.is_memory_mapped = true;
            attr.mapped_address_w = null;
            attr.mapped_address_r = ctx.?;
            return 0;
        }
    };
    const test_mapped_address: usize = 0x1000;
    _ = filemock
        .expectCall("ioctl")
        .invoke(&IoctlCallback.call, &test_mapped_address)
        .willReturn(0);

    _ = fsmock
        .expectCall("get")
        .withArgs(.{"stat"})
        .willReturn(kernel.fs.Node.create_file(filemock.interface));

    var arg: usize = 0;
    try kernel.process.process_manager.instance.create_process(4096, &test_entry, &arg, "test");
    _ = try kernel.dynamic_loader.load_executable("test", std.testing.allocator, 1);

    var sut = try PidStatFile.InstanceType.create_node(std.testing.allocator, 1, false);
    defer sut.delete();

    try std.testing.expect(sut.is_file());
    try std.testing.expectEqualStrings("stat", sut.name());

    var buf: [512]u8 = undefined;
    var file = sut.as_file().?;
    const readed = file.interface.read(buf[0..]);
    const expected = "1 (dummy_module) R 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 \n";
    try std.testing.expectEqualStrings(expected, buf[0..@intCast(readed)]);

    var sut_status = try PidStatFile.InstanceType.create_node(std.testing.allocator, 1, true);
    defer sut_status.delete();

    try std.testing.expect(sut_status.is_file());
    try std.testing.expectEqualStrings("status", sut_status.name());

    file = sut_status.as_file().?;
    const readed_status = file.interface.read(buf[0..]);
    const expected_status =
        \\Name:   dummy_module
        \\Umask:  0000
        \\Tgid:   1
        \\Ngid:   1
        \\Pid:    1
        \\PPid:   0
        \\Sched:  Ready
        \\WaitOn: 0x0
        \\
    ;
    try std.testing.expectEqualStrings(expected_status, buf[0..@intCast(readed_status)]);
}
