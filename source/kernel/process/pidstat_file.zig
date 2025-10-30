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

const c = @import("libc_imports").c;
const interface = @import("interface");

const kernel = @import("../kernel.zig");

const log = std.log.scoped(.@"vfs/meminfo");

const MemoryInfo = struct {
    free: usize,
    total: usize,
};

const BufferSize = 512;
const PidStatBufferedFile = kernel.fs.BufferedFile(BufferSize);
pub const PidStatFile = interface.DeriveFromBase(PidStatBufferedFile, struct {
    const Self = @This();
    base: PidStatBufferedFile,
    _pid: i16,
    _human_readable: bool,

    pub fn create(pid: i16, human_readable: bool) PidStatFile {
        var file = PidStatFile.init(.{
            .base = PidStatBufferedFile.InstanceType.create(if (human_readable) "status" else "stat"),
            ._pid = pid,
            ._human_readable = human_readable,
        });

        _ = file.data().sync();
        return file;
    }
    pub fn create_node(allocator: std.mem.Allocator, pid: i16, human_readable: bool) anyerror!kernel.fs.Node {
        const file = try create(pid, human_readable).interface.new(allocator);
        return kernel.fs.Node.create_file(file);
    }

    const human_readable_file_content_format =
        \\Name:   {s}
        \\Umask:  0000
        \\State:  R(running)
        \\Tgid:   {d}
        \\Ngid:   {d}
        \\Pid:    {d}
        \\PPid:   {d}
        \\
    ;

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

    fn write_stat_content(stat: *const PidStat, buffer: []u8) usize {
        var written: usize = 0;
        inline for (@typeInfo(PidStat).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, "comm")) {
                const buf = std.fmt.bufPrint(buffer[written..], "({s}) ", .{stat.comm}) catch buffer[written..];
                written += buf.len;
            } else if (std.mem.eql(u8, field.name, "state")) {
                const buf = std.fmt.bufPrint(buffer[written..], "{s} ", .{stat.state}) catch buffer[written..];
                written += buf.len;
            } else {
                const buf = std.fmt.bufPrint(buffer[written..], "{any} ", .{@field(stat, field.name)}) catch buffer[written..];
                written += buf.len;
            }
        }
        const buf = std.fmt.bufPrint(buffer[written..], "\n", .{}) catch buffer[written..];
        written += buf.len;

        return written;
    }

    pub fn sync(self: *Self) i32 {
        const maybe_process = kernel.process.process_manager.instance.get_process_for_pid(self._pid);
        if (maybe_process) |process| {
            // const proc_name = process.get_name();
            const buffer = &interface.base(self)._buffer;
            if (self._human_readable) {
                const buf = std.fmt.bufPrint(buffer, human_readable_file_content_format, .{ "stub", 0, 0, 1, 0 }) catch buffer;
                interface.base(self)._end = buf.len;
            } else {
                var name: []const u8 = "??";
                if (kernel.dynamic_loader.get_executable_for_pid(self._pid)) |ex| {
                    if (ex.module.name) |n| {
                        name = n;
                    }
                }
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
        _ = self;
    }
});
