const std = @import("std");
const app = @import("app");

pub const Board = struct {
    pub fn initialize(_: Board) void {
        //      std.debug.print("Raspberry pico board initialization\n", .{});
    }
};

export fn _init() void {
    app.main();
}

pub export fn _start() callconv(.C) noreturn {
    while (true) {}
}
