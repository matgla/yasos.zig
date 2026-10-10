const template = @import("template");

export fn replay(view: *const template.View, layout: *const template.Layout, bases: *const template.Bases, code: *const [template.thunk_size]u8) void {
    view.apply(layout.*, bases, code);
}

export fn slot_size() usize {
    return template.thunk_size;
}
