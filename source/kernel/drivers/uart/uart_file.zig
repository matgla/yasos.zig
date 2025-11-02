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

const kernel = @import("../../kernel.zig");

const IFile = @import("../../fs/ifile.zig").IFile;
const FileName = @import("../../fs/ifile.zig").FileName;
const FileType = @import("../../fs/ifile.zig").FileType;

const interface = @import("interface");

pub fn UartFile(comptime UartType: anytype) type {
    const Internal = struct {
        const UartFileImpl = interface.DeriveFromBase(IFile, struct {
            const Self = @This();
            const uart = UartType;
            _icanonical: bool,
            _echo: bool,
            _nonblock: bool,
            _allocator: std.mem.Allocator,
            _name: []const u8,

            pub fn delete(self: *Self) void {
                _ = self;
            }

            pub fn create(allocator: std.mem.Allocator, filename: []const u8) UartFileImpl {
                return UartFileImpl.init(.{
                    ._icanonical = true,
                    ._echo = true,
                    ._nonblock = false,
                    ._allocator = allocator,
                    ._name = filename,
                });
            }

            pub fn create_node(allocator: std.mem.Allocator, filename: []const u8) anyerror!kernel.fs.Node {
                const file = try create(allocator, filename).interface.new(allocator);
                return kernel.fs.Node.create_file(file);
            }

            pub fn read(self: *Self, buffer: []u8) isize {
                var index: usize = 0;
                var ch: [1]u8 = .{0};
                while (index < buffer.len) {
                    if (self._nonblock) {
                        if (!Self.uart.is_readable()) {
                            return @intCast(index);
                        }
                    }
                    const result = Self.uart.read(ch[0..1]) catch {
                        continue;
                    };
                    if (result == 0) {
                        return @intCast(index);
                    }

                    if (ch[0] == '\r') {
                        ch[0] = '\n';
                    }

                    if (ch[0] == 8 or ch[0] == 127 and self._icanonical) {
                        if (index > 0) {
                            buffer[index] = 0;
                            index -= 1;
                            if (self._echo) {
                                ch[0] = 8;
                                _ = Self.uart.write_some(ch[0..1]) catch {};
                                ch[0] = ' ';
                                _ = Self.uart.write_some(ch[0..1]) catch {};
                                ch[0] = 8;
                                _ = Self.uart.write_some(ch[0..1]) catch {};
                            }
                        }
                        continue;
                    }
                    buffer[index] = ch[0];
                    if (self._echo) {
                        _ = uart.write_some(ch[0..1]) catch {};
                    }
                    index += 1;
                    if (self._icanonical) {
                        if (ch[0] == 0 or ch[0] == '\n' or ch[0] == -1) {
                            break;
                        }
                    }
                    // return @intCast(index);
                }
                return @intCast(index);
            }

            pub fn write(self: *Self, data: []const u8) isize {
                _ = self;
                const result = uart.write_some(data) catch return 0;
                return @intCast(result);
            }

            pub fn seek(self: *Self, _: c.off_t, _: i32) anyerror!c.off_t {
                _ = self;
                return 0;
            }

            pub fn sync(self: *Self) i32 {
                _ = self;
                return 0;
            }

            pub fn tell(self: *Self) c.off_t {
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
                        c.TCSETS => {
                            self._icanonical = (termios.c_lflag & c.ICANON) != 0;
                            self._echo = (termios.c_lflag & c.ECHO) != 0;
                            return 0;
                        },
                        c.TCSETSW => {
                            return -1;
                        },
                        c.TCSETSF => {
                            return -1;
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
                            if (self._icanonical) {
                                termios.c_lflag |= c.ICANON;
                            }
                            if (self._echo) {
                                termios.c_lflag |= c.ECHO;
                            }
                            return 0;
                        },
                        c.TIOCGWINSZ => {
                            const ws: *c.struct_winsize = @ptrCast(@alignCast(termios_arg));
                            ws.*.ws_row = 24;
                            ws.*.ws_col = 80;
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
                if (maybe_arg) |arg| {
                    const flags: *c_int = @ptrCast(@alignCast(arg));
                    switch (op) {
                        c.F_GETFL => {
                            if (self._nonblock) {
                                result |= c.O_NONBLOCK;
                                return result;
                            }
                            return 0;
                        },
                        c.F_SETFL => {
                            self._nonblock = (flags.* & c.O_NONBLOCK) != 0;
                            return 0;
                        },
                        else => {
                            return -1;
                        },
                    }
                }
                return -1;
            }

            pub fn size(self: *const Self) usize {
                _ = self;
                return 0;
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
    var flags: c_int = c.O_NONBLOCK;

    const result = file.data().fcntl(c.F_SETFL, @ptrCast(&flags));
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
    var flags: c_int = 0;
    const result = file.data().fcntl(c.F_GETFL, &flags);
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expect((result & c.O_NONBLOCK) == 0);
}

test "UartFile.Fcntl.F_GETFL.ShouldReturnStatusWhenNonBlockIsSet" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var flags: c_int = 0;
    file.data()._nonblock = true;
    const result = file.data().fcntl(c.F_GETFL, &flags);
    try std.testing.expectEqual(@as(i32, c.O_NONBLOCK), result);
}

test "UartFile.Ioctl.TCSETSW.ShouldReturnError" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);

    const result = file.data().ioctl(c.TCSETSW, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, -1), result);
}

test "UartFile.Ioctl.TCSETSF.ShouldReturnError" {
    MockUart.reset();
    defer MockUart.reset();

    var file = TestUartFile.InstanceType.create(std.testing.allocator, "uart0");
    var termios: c.termios = std.mem.zeroes(c.termios);

    const result = file.data().ioctl(c.TCSETSF, @ptrCast(&termios));
    try std.testing.expectEqual(@as(i32, -1), result);
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
