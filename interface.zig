const std = @import("std");

fn addDecl(comptime interface: anytype, d: anytype) std.builtin.Type.StructField {
    const FieldType = @TypeOf(@field(interface, d.name));
    return .{
        .name = d.name,
        .type = FieldType,
        .default_value_ptr = @field(interface, d.name),
        .is_comptime = true,
        .alignment = @alignOf(FieldType),
    };
}

fn genDecl(comptime obj: anytype, name: [:0]const u8) std.builtin.Type.StructField {
    const FieldType = @TypeOf(obj);
    return .{
        .name = name,
        .type = FieldType,
        .default_value_ptr = obj,
        .is_comptime = true,
        .alignment = @alignOf(FieldType),
    };
}

const InterfaceType = struct {
    // deriving replaces vtable
    pub fn derive(comptime ChildType: anytype) type {
        _ = ChildType;
        return u32;
    }
};

const ShapeVTable = struct {
    draw: *const fn (*const anyopaque) void,
    set_size: *const fn (*anyopaque, u32) void,
    get_size: *const fn (*const anyopaque) u32,
};

fn Interface(comptime declarations: type) type {
    comptime var fields: []const std.builtin.Type.StructField = std.meta.fields(declarations);
    for (std.meta.declarations(declarations)) |d| {
        fields = fields ++ &[_]std.builtin.Type.StructField{addDecl(declarations, d)};
    }
    fields = fields ++ &[_]std.builtin.Type.StructField{genDecl(InterfaceType.derive, "derive")};
    fields = fields ++ &[_]std.builtin.Type.StructField{.{
        .name = "_vtable",
        .type = @TypeOf(ShapeVTable),
        .default_value_ptr = ShapeVTable,
        .is_comptime = true,
        .alignment = @alignOf(@TypeOf(ShapeVTable)),
    }};

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .is_tuple = false,
        .fields = fields,
        .decls = &.{},
    } });
}

fn deduce_type(info: anytype, object_type: anytype) type {
    if (info.pointer.is_const) {
        return *const object_type;
    }
    return *object_type;
}

fn wrap0(fun: anytype, objtype: anytype, name: []const u8) type {
    const return_type = @typeInfo(fun).@"fn".return_type.?;
    const params = @typeInfo(fun).@"fn".params;
    const object_info = @typeInfo(params[0].type.?);
    std.debug.assert(object_info == .pointer);
    const object_type = deduce_type(object_info, objtype);
    return struct {
        pub fn call(ptr: params[0].type.?) return_type {
            const self: object_type = @ptrCast(@alignCast(ptr));
            return @field(@TypeOf(self.*), name)(self);
        }
    };
}

fn wrap1(fun: anytype, objtype: anytype, name: []const u8) type {
    const return_type = @typeInfo(fun).@"fn".return_type.?;
    const params = @typeInfo(fun).@"fn".params;
    const object_info = @typeInfo(params[0].type.?);
    std.debug.assert(object_info == .pointer);
    const object_type = deduce_type(object_info, objtype);
    return struct {
        pub fn call(ptr: params[0].type.?, arg: params[1].type.?) return_type {
            const self: object_type = @ptrCast(@alignCast(ptr));
            return @field(@TypeOf(self.*), name)(self, arg);
        }
        // comptime {
        //     if (params.len > 1) {
        //         const call1 = struct {
        //             pub fn call(ptr: params[0].type.?, arg: params[1].type.?) return_type {
        //                 const self: object_type = @ptrCast(@alignCast(ptr));
        //                 return @field(@TypeOf(self.*), name)(self, arg);
        //             }
        //         };
        //     }
        // }
    };
}

pub fn deduce_vtable(t: anytype, name: anytype, o: anytype) type {
    const fun_type = @typeInfo(@FieldType(t, name)).pointer.child;

    return struct {
        const call = @field(FileThis, "wrap" ++ int_to_str(@typeInfo(fun_type).@"fn".params.len - 1))(fun_type, o, name).call;
    };
}

const Shape = struct {
    const VTable = struct {
        draw: *const fn (*const anyopaque) void,
        set_size: *const fn (*anyopaque, u32) void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    fn build_vtable() type {
        return struct {
            pub fn get_vtable(caller: anytype) VTable {
                var value: VTable = undefined;
                inline for (
                    std.meta.fields(VTable),
                ) |field| {
                    @field(value, field.name) = deduce_vtable(VTable, field.name, caller).call; //@field(caller, "gen_" ++ field.name);
                }
                return value;
            }
        };
    }

    pub fn init(ptr: anytype) Shape {
        // const f = deduce_vtable(VTable, "draw", @TypeOf(ptr)).call;
        // f(ptr);
        const gen_vtable = struct {
            const vtable = build_vtable().get_vtable(@TypeOf(ptr.*));
            // const gen_draw = deduce_vtable(VTable, "draw", @TypeOf(ptr.*)).call;

            //_gen_draw; //deduce(@FieldType(VTable, "draw")).call; //_gen_draw; //call_vtable_entry(@FieldType(VTable, "draw"), @TypeOf(ptr), .{});

            pub fn gen_set_size(ctx: *anyopaque, size: u32) void {
                const self: @TypeOf(ptr) = @ptrCast(@alignCast(ctx));
                self.set_size(size);
            }
        };

        return Shape{
            .ptr = @ptrCast(ptr),
            .vtable = &gen_vtable.vtable,
        };
    }

    pub fn draw(self: *const Shape) void {
        self.vtable.draw(self.ptr);
    }

    pub fn set_size(self: *Shape, size: u32) void {
        self.vtable.set_size(self.ptr, size);
    }
};

const Triangle = struct {
    size: u32,

    pub fn draw(self: *const Triangle) void {
        std.debug.print("Drawing a triangle, size: {d}\n", .{self.size});
    }

    pub fn set_size(self: *Triangle, size: u32) void {
        self.size = size;
    }

    pub fn ishape(self: *Triangle) Shape {
        return Shape.init(self);
    }
};

const Rectangle = struct {
    size: u32,

    pub fn set_size(self: *Rectangle, size: u32) void {
        self.size = size;
    }

    pub fn draw(self: *const Rectangle) void {
        std.debug.print("Drawing a rectangle, size: {d}\n", .{self.size});
    }
};

pub fn some_fun1(a1: u32) i32 {
    std.debug.print("some_fun1 called with a1: {d}\n", .{a1});
    return 123;
}

pub fn some_float1(a1: f32) f32 {
    std.debug.print("some_float1 called with a1: {d}\n", .{a1});
    return a1 * 2.0;
}

pub fn some_fun2(a: u32, b: u32) void {
    std.debug.print("some_fun called with a: {d}, b: {d}\n", .{ a, b });
}

fn get_var1(fun: anytype) type {
    const return_type = @typeInfo(@TypeOf(fun)).@"fn".return_type.?;
    return struct {
        pub fn call(a1: anytype) return_type {
            std.debug.print("get_var1 called with name: {s}, a1: {d}\n", .{ @typeName(@TypeOf(fun)), a1 });
            return @call(.auto, fun, .{a1});
        }
    };
}
pub fn var1(fun: anytype, a1: anytype) @typeInfo(@TypeOf(fun)).@"fn".return_type.? {
    std.debug.print("var1 called with name: {s}, a1: {d}\n", .{ @typeName(@TypeOf(fun)), a1 });
    return @call(.auto, fun, .{a1});
}

// const vard1 = var1(some_fun1, 1, @typeInfo(@TypeOf(some_fun1)).@"fn".return_type.?);
// const varf1 = var1(some_float1, 1.0, @typeInfo(@TypeOf(some_float1)).@"fn".return_type.?);

pub fn var2(name: anytype, a1: anytype, a2: anytype) void {
    std.debug.print("var1 called with name: {s}, a1: {d}, a2: {d}\n", .{ name, a1, a2 });
    return @call(.auto, some_fun2, .{ a1, a2 });
}
const FileThis = @This();

fn int_to_str(comptime i: usize) []const u8 {
    var buffer: [20]u8 = undefined;
    return std.fmt.bufPrint(&buffer, "{d}", .{i}) catch unreachable;
}

pub fn deduce(a: anytype) type {
    return struct {
        const call = @field(FileThis, "get_var" ++ int_to_str(@typeInfo(@TypeOf(a)).@"fn".params.len))(a).call;
    };
    // if (@typeInfo(@TypeOf(a)).@"fn".params.len == 1) {
    //     @compileLog("Function has 1 parameter: {s}\n", .{@typeName(@TypeOf(a))});
    //     return var1;
    // } else if (@typeInfo(@TypeOf(a)).@"fn".params.len == 2) {
    //     @compileLog("Function has 2 parameters: {s}\n", .{@typeName(@TypeOf(a))});
    //     return var2;
    // }
}

// const InterfaceType = struct {
//    pub fn derive(comptime Child) type {

//     }
// };
pub fn main() void {
    // const result = var1(some_fun1, 1);
    // const result2 = var1(some_float1, 3.12);

    // const rect = Rectangle{ .size = 5 };
    // inline for (
    //     std.meta.fields(Rectangle),
    // ) |field| {
    //     std.debug.print("Field: {s}, Type: {s}\n", .{ field.name, @typeName(@FieldType(Rectangle, field.name)) });
    // }
    // const rect = Rectangle{ .size = 5 };
    // @field(Rectangle, "draw")(rect);

    // std.debug.print("var1: {d}, {d}\n", .{ result, result2 });
    // // var2("test", 2, 3);
    // const ret1 = deduce(some_fun1).call(4);
    // std.debug.print("deduce(some_fun1).call(4): {d}\n", .{ret1});
    // const ret2 = deduce(some_float1).call(5.5);
    // std.debug.print("deduce(some_float1).call(5.5): {d}\n", .{ret2});

    // //ret2 = deduce(@FieldType(@FieldType(Shape, "VTable"), "draw"));
    // // deduce(var2).call("test", 5, 6);
    var triangles = [_]Triangle{
        .{ .size = 10 },
        .{ .size = 20 },
        .{ .size = 30 },
    };

    var rectangles = [_]Rectangle{
        .{ .size = 15 },
        .{ .size = 25 },
        .{ .size = 35 },
    };

    const shapes = [_]Shape{
        Shape.init(&triangles[0]),
        Shape.init(&triangles[1]),
        Shape.init(&triangles[2]),
        Shape.init(&rectangles[0]),
        Shape.init(&rectangles[1]),
        Shape.init(&rectangles[2]),
        triangles[0].ishape(),
    };

    for (shapes) |shape| {
        shape.draw();
    }

    const shake = Interface(struct {
        pub fn draw(_: *const anyopaque) void {
            unreachable;
        }

        pub fn set_size(_: *anyopaque, _: u32) void {
            unreachable;
        }

        pub fn get_size(_: *const anyopaque) u32 {
            unreachable;
        }

        // pub usingnamespace InterfaceType;
    });
    // const shake = Interface(ShakeInterface);
    const s1: shake = .{};
    s1._vtable.draw(&triangles[0]);
    // const TriangleT = s1.derive(struct {
    //     size: u32,
    //     const Self = @This();

    //     pub fn draw(self: *const Self) void {
    //         std.debug.print("Drawing a triangle, size: {d}\n", .{self.size});
    //     }

    //     pub fn set_size(self: *Self, size: u32) void {
    //         self.size = size;
    //     }

    //     pub fn get_size(self: *const Self) u32 {
    //         return self.size;
    //     }
    // });
    // var t1: TriangleT = .{
    //     .size = 40,
    // };
    // t1.draw();
    // t1.set_size(50);
    // t1.draw();
    // std.debug.print("Triangle size: {d}\n", .{t1.get_size()});
    // s1.draw(&triangles[0]);
}
