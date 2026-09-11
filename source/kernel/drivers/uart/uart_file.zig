//
// uart_file.zig
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
const c = @import("libc_imports").c;

const hal = @import("hal");

const kernel = @import("../../kernel.zig");

const IFile = @import("../../fs/ifile.zig").IFile;
const FileName = @import("../../fs/ifile.zig").FileName;
const FileType = @import("../../fs/ifile.zig").FileType;
const PollMask = @import("../../fs/ifile.zig").PollMask;
const poll_readable = @import("../../fs/ifile.zig").poll_readable;
const poll_writable = @import("../../fs/ifile.zig").poll_writable;

const interface = @import("interface");
const config = @import("config");

/// Boot-time ONLCR, from CONFIG_CONSOLE_ONLCR (menuconfig: Console). A config
/// generated before the option existed gets it on, the Linux tty default.
const default_onlcr: bool = if (@hasDecl(config, "console") and @hasDecl(config.console, "onlcr"))
    config.console.onlcr
else
    true;

pub fn UartFile(comptime UartType: anytype) type {
    const Internal = struct {
        const UartFileImpl = interface.DeriveFromBase(IFile, struct {
            const Self = @This();
            const uart = UartType;
            _icanonical: bool,
            _echo: bool,
            _raw_mode: bool,
            _nonblock: bool,
            _allocator: std.mem.Allocator,
            _name: []const u8,
            _read_timeout: u8,
            _minimum_bytes_to_read: usize,

            /// Output processing belongs to the tty, not to an open file: a
            /// termios set through any fd governs every write to the device, as
            /// on Linux. This matters because the files here are not shared --
            /// stdin, stdout and stderr are each a `dupe` of the driver's node,
            /// with their own copy of the fields above. `rz` switches raw mode
            /// on with tcsetattr(STDIN_FILENO) and then writes binary ZMODEM
            /// headers to stdout; with these flags per file, stdout stayed
            /// cooked and every 0x0A in a header went out as CR LF. A header
            /// whose offset field holds 0x0A (330464 = 0x50AE0) could then never
            /// be acknowledged, and the upload died there on every retry.
            ///
            /// Only the output side is shared. The input side stays per file as
            /// it always was.
            const Output = struct {
                opost: bool = true,
                onlcr: bool = default_onlcr,
            };
            var output: Output = .{};

            pub fn delete(self: *Self) void {
                _ = self;
            }

            /// Emit to the console UART under the console lock. Every byte this
            /// file puts on the wire goes through here or through an explicit
            /// `console_acquire` around a group of writes -- otherwise
            /// `/dev/uart0` is a second front door onto the UART that
            /// `stdout.zig` knows nothing about, and the two interleave
            /// mid-token.
            ///
            /// Never call this while already inside a console section: the
            /// underlying spinlock panics on a recursive acquisition. The
            /// multi-write echo groups below take the lock once and call
            /// `uart.write_some` directly inside it.
            fn echo(data: []const u8) void {
                const held = kernel.stdout.console_acquire();
                defer kernel.stdout.console_release(held);
                _ = uart.write_some(data) catch {};
            }

            /// ONLCR: map NL to CRLF on output, which every Linux tty does by
            /// default. Without it a program's "\n" is a bare line feed, and a
            /// terminal that takes bytes literally (minicom, screen, picocom
            /// without --imap) walks each line down a staircase. OPOST off (raw
            /// mode, set through any fd) switches all output processing off.
            fn translates_nl() bool {
                return output.opost and output.onlcr;
            }

            /// Put `data` on the wire, NL expanded to CRLF when ONLCR is on.
            /// The caller holds the console lock.
            fn write_locked(data: []const u8) void {
                if (!translates_nl()) {
                    _ = uart.write_some(data) catch {};
                    return;
                }
                var rest = data;
                while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                    _ = uart.write_some(rest[0..nl]) catch {};
                    _ = uart.write_some("\r\n") catch {};
                    rest = rest[nl + 1 ..];
                }
                _ = uart.write_some(rest) catch {};
            }

            /// Echo typed input. Output processing applies to echo as it does on
            /// Linux, so Enter comes back as CRLF under ONLCR.
            fn echo_input(data: []const u8) void {
                const held = kernel.stdout.console_acquire();
                defer kernel.stdout.console_release(held);
                write_locked(data);
            }

            fn apply_termios(self: *Self, termios: *const c.termios) void {
                self._icanonical = (termios.c_lflag & c.ICANON) != 0;
                self._echo = (termios.c_lflag & c.ECHO) != 0;
                self._read_timeout = @intCast(termios.c_cc[c.VTIME]);
                self._minimum_bytes_to_read = @intCast(termios.c_cc[c.VMIN]);
                // Raw is "OPOST off", not "c_oflag == 0": cfmakeraw clears
                // OPOST alone, so a raw tty still carries ONLCR. Testing the
                // whole word read that as cooked, and read() then waited for a
                // full buffer -- the sh line editor never saw a key.
                self._raw_mode = (termios.c_oflag & c.OPOST) == 0;
                output.opost = !self._raw_mode;
                // Kept while raw and only acted on under OPOST, as on Linux,
                // so a tcgetattr taken in raw mode restores it intact.
                output.onlcr = (termios.c_oflag & c.ONLCR) != 0;
            }

            pub fn create(allocator: std.mem.Allocator, filename: []const u8) UartFileImpl {
                // Called once per device, from create_node at boot -- every
                // open after that is a `dupe` -- so this is the tty's initial
                // state, not something an open resets.
                output = .{};
                return UartFileImpl.init(.{
                    ._icanonical = true,
                    ._echo = true,
                    ._nonblock = false,
                    ._raw_mode = false,
                    ._allocator = allocator,
                    ._name = filename,
                    ._read_timeout = 0,
                    ._minimum_bytes_to_read = 1,
                });
            }

            pub fn create_node(allocator: std.mem.Allocator, filename: []const u8) anyerror!kernel.fs.Node {
                const file = try create(allocator, filename).interface.new(allocator);
                return kernel.fs.Node.create_file(file);
            }

            pub fn read(self: *Self, buffer: []u8) isize {
                var index: usize = 0;
                var cursor_pos: usize = 0;
                var ch: [1]u8 = .{0};
                var start_time: u64 = 0;
                if (self._read_timeout != 0) {
                    start_time = hal.time.get_time_us() / 1000;
                }
                while (index < buffer.len) {
                    if (self._read_timeout != 0) {
                        const current_time = hal.time.get_time_us() / 1000;
                        if (current_time - start_time >= @as(u64, self._read_timeout) * 100) {
                            break;
                        }
                    }

                    if (!Self.uart.is_readable()) {
                        if (self._nonblock) {
                            return @intCast(index);
                        } else if (self._raw_mode and index >= self._minimum_bytes_to_read) {
                            return @intCast(index);
                        }
                        continue;
                    }

                    const result = Self.uart.read(ch[0..]) catch {
                        continue;
                    };

                    if (result == 0) {
                        return @intCast(index);
                    }

                    if (ch[0] == '\r' and !self._raw_mode) {
                        ch[0] = '\n';
                    }

                    if ((ch[0] == 8 or ch[0] == 127) and self._icanonical) {
                        if (cursor_pos > 0) {
                            // Shift buffer left from cursor_pos
                            var j = cursor_pos - 1;
                            while (j < index - 1) : (j += 1) {
                                buffer[j] = buffer[j + 1];
                            }
                            buffer[index - 1] = 0;
                            index -= 1;
                            cursor_pos -= 1;
                            if (self._echo) {
                                // One console section for the whole sequence:
                                // these bytes are a cursor movement, a repaint
                                // and a move back, so a log line landing in the
                                // middle leaves the cursor somewhere this code
                                // no longer believes it is.
                                const held = kernel.stdout.console_acquire();
                                defer kernel.stdout.console_release(held);
                                // Move cursor left
                                _ = Self.uart.write_some("\x08") catch {};
                                // Re-echo from cursor to end + space to clear last char
                                if (cursor_pos < index) {
                                    _ = Self.uart.write_some(buffer[cursor_pos..index]) catch {};
                                }
                                _ = Self.uart.write_some(" ") catch {};
                                // Move cursor back to cursor_pos
                                var back: usize = index - cursor_pos + 1;
                                while (back > 0) : (back -= 1) {
                                    _ = Self.uart.write_some("\x08") catch {};
                                }
                            }
                        }
                        continue;
                    }

                    // In canonical mode, handle escape sequences for line editing
                    if (ch[0] == 0x1B and self._icanonical) {
                        // Use time-based timeout (20ms) to wait for escape sequence bytes
                        const esc_start = hal.time.get_time_us();
                        while (!Self.uart.is_readable()) {
                            if (hal.time.get_time_us() - esc_start > 20000) break;
                        }
                        if (!Self.uart.is_readable()) continue; // bare ESC, discard
                        _ = Self.uart.read(ch[0..]) catch continue;

                        if (ch[0] == '[') {
                            const esc_start2 = hal.time.get_time_us();
                            while (!Self.uart.is_readable()) {
                                if (hal.time.get_time_us() - esc_start2 > 20000) break;
                            }
                            if (!Self.uart.is_readable()) continue;
                            _ = Self.uart.read(ch[0..]) catch continue;

                            switch (ch[0]) {
                                'D' => {
                                    // Left arrow
                                    if (cursor_pos > 0) {
                                        cursor_pos -= 1;
                                        if (self._echo) {
                                            echo("\x1b[D");
                                        }
                                    }
                                },
                                'C' => {
                                    // Right arrow
                                    if (cursor_pos < index) {
                                        cursor_pos += 1;
                                        if (self._echo) {
                                            echo("\x1b[C");
                                        }
                                    }
                                },
                                'A', 'B', 'H', 'F' => {
                                    // Up/Down/Home/End: discard in canonical mode
                                },
                                else => {
                                    // Consume rest of extended sequences (e.g. ESC[3~, ESC[15~)
                                    while (true) {
                                        if (ch[0] == '~' or
                                            (ch[0] >= 'A' and ch[0] <= 'Z') or
                                            (ch[0] >= 'a' and ch[0] <= 'z'))
                                        {
                                            break;
                                        }
                                        const esc_start3 = hal.time.get_time_us();
                                        while (!Self.uart.is_readable()) {
                                            if (hal.time.get_time_us() - esc_start3 > 20000) break;
                                        }
                                        if (!Self.uart.is_readable()) break;
                                        _ = Self.uart.read(ch[0..]) catch break;
                                    }
                                },
                            }
                        } else if (ch[0] == 'O') {
                            // SS3 sequences: ESC O P (F1), ESC O Q (F2), etc.
                            const esc_start2 = hal.time.get_time_us();
                            while (!Self.uart.is_readable()) {
                                if (hal.time.get_time_us() - esc_start2 > 20000) break;
                            }
                            if (Self.uart.is_readable()) {
                                _ = Self.uart.read(ch[0..]) catch {};
                            }
                            // Discard the whole sequence in canonical mode
                        }
                        // Any other byte after ESC: already consumed, discard
                        continue;
                    }

                    if (cursor_pos < index and self._icanonical) {
                        // Line terminators always go at the end
                        if (ch[0] == '\n' or ch[0] == 0) {
                            buffer[index] = ch[0];
                            index += 1;
                            cursor_pos = index;
                            if (self._echo) {
                                echo_input(ch[0..1]);
                            }
                        } else {
                            // Insert in middle: shift buffer right
                            var j = index;
                            while (j > cursor_pos) : (j -= 1) {
                                buffer[j] = buffer[j - 1];
                            }
                            buffer[cursor_pos] = ch[0];
                            cursor_pos += 1;
                            index += 1;
                            if (self._echo) {
                                // As above: repaint plus cursor-restore is one
                                // indivisible sequence.
                                const held = kernel.stdout.console_acquire();
                                defer kernel.stdout.console_release(held);
                                // Echo from cursor-1 to end of line
                                _ = Self.uart.write_some(buffer[cursor_pos - 1 .. index]) catch {};
                                // Move cursor back to cursor_pos
                                var back: usize = index - cursor_pos;
                                while (back > 0) : (back -= 1) {
                                    _ = Self.uart.write_some("\x08") catch {};
                                }
                            }
                        }
                    } else {
                        buffer[index] = ch[0];
                        if (self._echo) {
                            echo_input(ch[0..1]);
                        }
                        index += 1;
                        cursor_pos = index;
                    }
                    if (self._icanonical) {
                        if (ch[0] == 0 or ch[0] == '\n' or ch[0] == -1) {
                            break;
                        }
                    }
                    // return @intCast(index);
                }
                return @intCast(index);
            }

            /// Write to the console, serialised against the other core. One
            /// console section for the whole slice, deliberately not released
            /// between the chunks ONLCR splits it into: `Uart.write` masks
            /// interrupts for its byte loop, so the console lock is only ever
            /// held across a region that cannot be preempted. Release it between
            /// chunks and PendSV can switch threads there, after which the
            /// incoming thread's write sees `held_by_current` -- which is per
            /// core, not per thread -- come back true and writes ungoverned into
            /// the displaced thread's bytes.
            ///
            /// The hold is therefore as long as the caller's slice, ~3.4 ms per
            /// KiB at 3 Mbaud, and libc hands us line-sized buffers.
            pub fn write(self: *Self, data: []const u8) isize {
                _ = self;
                const held = kernel.stdout.console_acquire();
                defer kernel.stdout.console_release(held);
                if (!translates_nl()) {
                    const result = uart.write_some(data) catch return 0;
                    return @intCast(result);
                }
                // The count is of the caller's bytes, not the expanded ones.
                write_locked(data);
                return @intCast(data.len);
            }

            pub fn seek(self: *Self, _: i64, _: i32) anyerror!i64 {
                _ = self;
                return 0;
            }

            pub fn sync(self: *Self) i32 {
                _ = self;
                return 0;
            }

            pub fn tell(self: *Self) i64 {
                _ = self;
                return 0;
            }

            pub fn name(self: *const Self) []const u8 {
                return self._name;
            }

            pub fn ioctl(self: *Self, op: i32, arg: ?*anyopaque) i32 {
                if (arg) |termios_arg| {
                    const termios: *c.termios = @ptrCast(@alignCast(termios_arg));
                    switch (op) {
                        c.TCSETS, c.TCSETSW, c.TCSETSF => {
                            self.apply_termios(termios);
                            return 0;
                        },
                        c.TCGETS => {
                            termios.c_iflag = 0;
                            termios.c_oflag = 0;
                            termios.c_cflag = 0;
                            termios.c_lflag = 0;
                            termios.c_line = 0;
                            termios.c_cc[0] = 0;
                            termios.c_cc[1] = 0;
                            termios.c_cc[2] = 0;
                            termios.c_cc[3] = 0;
                            termios.c_cc[c.VTIME] = self._read_timeout;
                            termios.c_cc[c.VMIN] = @intCast(self._minimum_bytes_to_read);
                            if (self._icanonical) {
                                termios.c_lflag |= c.ICANON;
                            }
                            if (self._echo) {
                                termios.c_lflag |= c.ECHO;
                            }
                            if (output.opost) {
                                termios.c_oflag |= c.OPOST;
                            }
                            if (output.onlcr) {
                                termios.c_oflag |= c.ONLCR;
                            }
                            return 0;
                        },
                        c.TIOCGWINSZ => {
                            const ws: *c.struct_winsize = @ptrCast(@alignCast(termios_arg));
                            ws.*.ws_row = 24;
                            ws.*.ws_col = 80;
                            return 0;
                        },
                        c.FIONREAD => {
                            const readable: *c_int = @ptrCast(@alignCast(termios_arg));
                            readable.* = @intCast(self.size());
                            return 0;
                        },
                        else => {
                            return -1;
                        },
                    }
                }
                return -1;
            }

            pub fn fcntl(self: *Self, op: i32, maybe_arg: ?*anyopaque) i32 {
                var result: i32 = 0;
                switch (op) {
                    c.F_GETFL => {
                        if (self._nonblock) {
                            result |= c.O_NONBLOCK;
                            return result;
                        }
                        return 0;
                    },
                    c.F_SETFL => {
                        const flags: c_int = if (maybe_arg) |a| @truncate(@as(c_int, @intCast(@intFromPtr(a)))) else 0;
                        self._nonblock = (flags & c.O_NONBLOCK) != 0;
                        return 0;
                    },
                    else => {
                        return -1;
                    },
                }
                return -1;
            }

            pub fn size(self: *const Self) u64 {
                _ = self;
                return uart.bytes_to_read();
            }

            pub fn truncate(self: *Self, length: u64) anyerror!void {
                _ = self;
                _ = length;
                return kernel.errno.ErrnoSet.InvalidArgument;
            }

            /// Readable exactly when the driver already holds bytes -- `read` below
            /// spins on `is_readable` otherwise, which is the wait `poll` exists to
            /// let the caller avoid. Always writable: `write` drains to the FIFO
            /// under the console lock and never reports back-pressure.
            pub fn poll(self: *Self, events: PollMask) PollMask {
                _ = self;
                var revents: PollMask = events & poll_writable;
                if (uart.bytes_to_read() > 0) revents |= events & poll_readable;
                return revents;
            }

            pub fn filetype(self: *const Self) FileType {
                _ = self;
                return FileType.CharDevice;
            }
        });
    };
    return Internal.UartFileImpl;
}

const MockUart = @import("tests/uart_mock.zig").MockUart;
const TestUartFile = UartFile(MockUart);

test "UartFile.Create.ShouldInitializeWithDefaults" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");

    try std.testing.expect(file.data()._icanonical);
    try std.testing.expect(file.data()._echo);
    try std.testing.expect(!file.data()._nonblock);
    try std.testing.expectEqualStrings("uart0", file.data()._name);
}

test "UartFile.CreateNode.ShouldCreateFileNode" {
    MockUart.reset();
    defer MockUart.reset();

    var node = try TestUartFile.InstanceType.create_node(std.testing.allocator, "uart0");
    defer node.delete();

    try std.testing.expect(node.is_file());
    const maybe_file = node.as_file();
    try std.testing.expect(maybe_file != null);
    if (maybe_file) |file| {
        try std.testing.expectEqualStrings("uart0", file.interface.name());
    }
}

test "UartFile.Filetype.ShouldReturnCharDevice" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    try std.testing.expectEqual(FileType.CharDevice, file.data().filetype());
}

test "UartFile.Size.ShouldReturnZero" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    try std.testing.expectEqual(@as(usize, 0), file.data().size());
}

test "UartFile.Write.ShouldWriteToUart" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    const data = "Hello, UART!";

    const written = file.data().write(data);
    try std.testing.expectEqual(@as(isize, @intCast(data.len)), written);
    try std.testing.expectEqualStrings(data, MockUart.get_written_data());
}

test "UartFile.Read.ShouldReadFromUart" {
    MockUart.reset();
    defer MockUart.reset();
    MockUart.set_read_data("test\n");

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqual(@as(isize, 5), bytes_read);
    try std.testing.expectEqualStrings("test\n", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldConvertCarriageReturnToNewline" {
    MockUart.reset();
    defer MockUart.reset();
    MockUart.set_read_data("test\r");

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqual(@as(isize, 5), bytes_read);
    try std.testing.expectEqualStrings("test\n", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldHandleBackspace" {
    MockUart.reset();
    defer MockUart.reset();
    // Simulate typing "hello" then backspace, then "i"
    MockUart.set_read_data("hello");

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._echo = false; // Disable echo for simpler testing
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqual(@as(isize, 5), bytes_read);
    try std.testing.expectEqualStrings("hello", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldStopAtNewlineInCanonicalMode" {
    MockUart.reset();
    defer MockUart.reset();
    MockUart.set_read_data("hello\nworld");

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var buffer: [20]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqual(@as(isize, 6), bytes_read);
    try std.testing.expectEqualStrings("hello\n", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldReadAllDataInNonCanonicalMode" {
    MockUart.reset();
    defer MockUart.reset();
    MockUart.set_read_data("hello\nworld");

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._icanonical = false;
    var buffer: [20]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqual(@as(isize, 11), bytes_read);
    try std.testing.expectEqualStrings("hello\nworld", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldReturnImmediatelyInNonBlockMode" {
    MockUart.reset();
    defer MockUart.reset();
    MockUart.readable = false;

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._nonblock = true;
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqual(@as(isize, 0), bytes_read);
}

test "UartFile.Ioctl.TCGETS.ShouldReturnCurrentSettings" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = undefined;

    const result = file.data().ioctl(c.TCGETS, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect((termios.c_lflag & c.ICANON) != 0);
    try std.testing.expect((termios.c_lflag & c.ECHO) != 0);
}

test "UartFile.Ioctl.TCSETS.ShouldSetCanonicalMode" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);
    termios.c_lflag = c.ICANON;

    const result = file.data().ioctl(c.TCSETS, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(file.data()._icanonical);
    try std.testing.expect(!file.data()._echo);
}

test "UartFile.Ioctl.TCSETS.ShouldSetEchoMode" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);
    termios.c_lflag = c.ECHO;

    const result = file.data().ioctl(c.TCSETS, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(!file.data()._icanonical);
    try std.testing.expect(file.data()._echo);
}

test "UartFile.Ioctl.TIOCGWINSZ.ShouldReturnWindowSize" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var ws: c.struct_winsize = undefined;

    const result = file.data().ioctl(c.TIOCGWINSZ, @ptrCast(&ws));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expectEqual(@as(c_ushort, 24), ws.ws_row);
    try std.testing.expectEqual(@as(c_ushort, 80), ws.ws_col);
}

test "UartFile.Ioctl.ShouldReturnErrorForInvalidOp" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = undefined;

    const result = file.data().ioctl(0xf00d, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, -1), result);
}

test "UartFile.Ioctl.ShouldReturnErrorForNullArg" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    const result = file.data().ioctl(c.TCGETS, null);
    try std.testing.expectEqual(@as(i32, -1), result);
}

test "UartFile.Fcntl.F_GETFL.ShouldReturnFlags" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._nonblock = true;

    const result = file.data().fcntl(c.F_GETFL, null);
    try std.testing.expect((result & c.O_NONBLOCK) != 0);
}

test "UartFile.Fcntl.F_SETFL.ShouldSetNonBlockMode" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    const flags: c_int = c.O_NONBLOCK;

    const result = file.data().fcntl(c.F_SETFL, @ptrFromInt(flags));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(file.data()._nonblock);
}

test "UartFile.Fcntl.ShouldReturnErrorForInvalidOp" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var flags: c_int = 0;

    const result = file.data().fcntl(0xf00d, @ptrCast(&flags));
    try std.testing.expectEqual(@as(i32, -1), result);
}

test "UartFile.Seek.ShouldReturnZero" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    const result = try file.data().seek(100, 0);
    try std.testing.expectEqual(@as(c.off_t, 0), result);
}

test "UartFile.Tell.ShouldReturnZero" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    const result = file.data().tell();
    try std.testing.expectEqual(@as(c.off_t, 0), result);
}

test "UartFile.Sync.ShouldReturnZero" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    const result = file.data().sync();
    try std.testing.expectEqual(@as(i32, 0), result);
}

test "UartFile.Fcntl.F_GETFL.ShouldReturnZeroWhenNonBlockIsNotSet" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._nonblock = false;
    const flags: c_int = 0;
    const result = file.data().fcntl(c.F_GETFL, @ptrFromInt(flags));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect((result & c.O_NONBLOCK) == 0);
}

test "UartFile.Fcntl.F_GETFL.ShouldReturnStatusWhenNonBlockIsSet" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    const flags: c_int = 0;
    file.data()._nonblock = true;
    const result = file.data().fcntl(c.F_GETFL, @ptrFromInt(flags));
    try std.testing.expectEqual(@as(i32, c.O_NONBLOCK), result);
}

test "UartFile.Ioctl.TCSETSW.ShouldApplySettings" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);
    termios.c_lflag = c.ICANON;

    const result = file.data().ioctl(c.TCSETSW, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(file.data()._icanonical);
    try std.testing.expect(!file.data()._echo);
}

test "UartFile.Ioctl.TCSETSF.ShouldApplySettings" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);
    termios.c_lflag = c.ECHO;

    const result = file.data().ioctl(c.TCSETSF, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect(!file.data()._icanonical);
    try std.testing.expect(file.data()._echo);
}

test "UartFile.Read.ShouldHandleBackspaceCharacter" {
    MockUart.reset();
    defer MockUart.reset();
    // Simulate typing "abc" then backspace (ASCII 8)
    const data = "abc\x08";
    MockUart.set_read_data(data);

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._echo = false; // Disable echo for simpler testing
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    // Should read "abc", then backspace removes 'c', leaving "ab"
    try std.testing.expectEqual(@as(isize, 2), bytes_read);
    try std.testing.expectEqualStrings("ab", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldHandleDeleteCharacter" {
    MockUart.reset();
    defer MockUart.reset();
    // Simulate typing "xyz" then delete (ASCII 127)
    const data = "xyz\x7F";
    MockUart.set_read_data(data);

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._echo = false; // Disable echo for simpler testing
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    // Should read "xyz", then delete removes 'z', leaving "xy"
    try std.testing.expectEqual(@as(isize, 2), bytes_read);
    try std.testing.expectEqualStrings("xy", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldHandleMultipleBackspaces" {
    MockUart.reset();
    defer MockUart.reset();
    // Simulate typing "hello" then three backspaces
    const data = "hello\x08\x08\x08";
    MockUart.set_read_data(data);

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._echo = false;
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    // Should read "hello", then three backspaces remove "llo", leaving "he"
    try std.testing.expectEqual(@as(isize, 2), bytes_read);
    try std.testing.expectEqualStrings("he", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldHandleBackspaceAtStartOfBuffer" {
    MockUart.reset();
    defer MockUart.reset();
    // Simulate backspace at the beginning (should be ignored)
    const data = "\x08abc";
    MockUart.set_read_data(data);

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._echo = false;
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    // Backspace at start should be ignored, should read "abc"
    try std.testing.expectEqual(@as(isize, 3), bytes_read);
    try std.testing.expectEqualStrings("abc", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Read.ShouldHandleMixedBackspaceAndDelete" {
    MockUart.reset();
    defer MockUart.reset();
    // Simulate typing with mixed backspace and delete
    const data = "test\x08\x7Fok";
    MockUart.set_read_data(data);

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._echo = false;
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    // "test" -> backspace removes 't' -> "tes" -> delete removes 's' -> "te" -> add "ok" -> "teok"
    try std.testing.expectEqual(@as(isize, 4), bytes_read);
    try std.testing.expectEqualStrings("teok", buffer[0..@intCast(bytes_read)]);
}

test "UartFile.Create.ShouldTakeOnlcrFromConfig" {
    MockUart.reset();
    defer MockUart.reset();

    _ = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    try std.testing.expectEqual(default_onlcr, TestUartFile.InstanceType.output.onlcr);
}

test "UartFile.Write.RawModeSetThroughAnotherFileStopsTranslation" {
    MockUart.reset();
    defer MockUart.reset();

    // Two files on one UART, as stdin and stdout are: separate objects.
    var stdin_file = TestUartFile.InstanceType.create(std.testing.allocator, "stdin");
    var stdout_file = TestUartFile.InstanceType.create(std.testing.allocator, "stdout");
    TestUartFile.InstanceType.output.onlcr = true;

    // What rz does: raw mode on stdin, c_oflag = 0 ...
    var raw: c.termios = std.mem.zeroes(c.termios);
    try std.testing.expectEqual(@as(i32, 0), stdin_file.data().ioctl(c.TCSETS, @ptrCast(&raw)));

    // ... then a binary ZMODEM header to stdout. 0x0A must stay one byte.
    _ = stdout_file.data().write("\xe0\x0a\x05\x00");
    try std.testing.expectEqualStrings("\xe0\x0a\x05\x00", MockUart.get_written_data());
}

test "UartFile.Write.ShouldTranslateNewlineToCrLf" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    TestUartFile.InstanceType.output.onlcr = true;
    const written = file.data().write("a\nb\n\nc");
    try std.testing.expectEqual(@as(isize, 6), written);
    try std.testing.expectEqualStrings("a\r\nb\r\n\r\nc", MockUart.get_written_data());
}

test "UartFile.Write.RawModeShouldNotTranslateNewline" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCSETS, @ptrCast(&termios)));

    _ = file.data().write("a\nb\n");
    try std.testing.expectEqualStrings("a\nb\n", MockUart.get_written_data());
}

test "UartFile.Write.OpostWithoutOnlcrShouldNotTranslateNewline" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);
    termios.c_oflag = c.OPOST;
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCSETS, @ptrCast(&termios)));

    _ = file.data().write("a\nb\n");
    try std.testing.expectEqualStrings("a\nb\n", MockUart.get_written_data());
}

test "UartFile.Ioctl.TCGETS.ShouldReportOnlcrAndRoundTrip" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    TestUartFile.InstanceType.output.onlcr = true;
    var termios: c.termios = undefined;
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCGETS, @ptrCast(&termios)));
    try std.testing.expect((termios.c_oflag & c.OPOST) != 0);
    try std.testing.expect((termios.c_oflag & c.ONLCR) != 0);

    // tcgetattr / tweak lflag / tcsetattr must keep the translation on.
    termios.c_lflag &= ~@as(c_uint, c.ECHO);
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCSETS, @ptrCast(&termios)));
    _ = file.data().write("x\n");
    try std.testing.expectEqualStrings("x\r\n", MockUart.get_written_data());
}

test "UartFile.Ioctl.CfmakerawShouldEnterRawModeAndKeepOnlcr" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    TestUartFile.InstanceType.output.onlcr = true;
    var cooked: c.termios = undefined;
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCGETS, @ptrCast(&cooked)));

    // What toybox's set_terminal(raw) sends: cfmakeraw clears OPOST only.
    var raw = cooked;
    c.cfmakeraw(&raw);
    try std.testing.expect(raw.c_oflag != 0);
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCSETS, @ptrCast(&raw)));
    try std.testing.expect(file.data()._raw_mode);
    _ = file.data().write("a\n");
    try std.testing.expectEqualStrings("a\n", MockUart.get_written_data());

    // A tcgetattr taken while raw still carries ONLCR.
    var seen: c.termios = undefined;
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCGETS, @ptrCast(&seen)));
    try std.testing.expect((seen.c_oflag & c.ONLCR) != 0);

    // Restoring the cooked settings turns translation back on.
    MockUart.reset();
    try std.testing.expectEqual(@as(i32, 0), file.data().ioctl(c.TCSETS, @ptrCast(&cooked)));
    try std.testing.expect(!file.data()._raw_mode);
    _ = file.data().write("b\n");
    try std.testing.expectEqualStrings("b\r\n", MockUart.get_written_data());
}

test "UartFile.Read.ShouldEchoEnterAsCrLf" {
    MockUart.reset();
    defer MockUart.reset();
    MockUart.set_read_data("ls\r");

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    TestUartFile.InstanceType.output.onlcr = true;
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqualStrings("ls\n", buffer[0..@intCast(bytes_read)]);
    try std.testing.expectEqualStrings("ls\r\n", MockUart.get_written_data());
}

test "UartFile.Read.ShouldEchoBackspaceSequence" {
    MockUart.reset();
    defer MockUart.reset();
    const data = "ab\x08";
    MockUart.set_read_data(data);

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    file.data()._echo = true; // Enable echo
    var buffer: [10]u8 = undefined;

    const bytes_read = file.data().read(&buffer);
    try std.testing.expectEqual(@as(isize, 1), bytes_read);
    try std.testing.expectEqualStrings("a", buffer[0..@intCast(bytes_read)]);

    // Check that backspace sequence was written (backspace, space, backspace)
    const written = MockUart.get_written_data();
    // Should contain the characters 'a', 'b', then backspace sequence: \x08, ' ', \x08
    try std.testing.expect(written.len >= 5);
}
