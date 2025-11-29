pub fn Page(allocator: zx.Allocator) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.client(.{ .name = "CounterComponent", .path = "././CounterComponent.tsx", .id = "zx-3badae80b344e955a3048888ed2aae42" }, .{}),
            },
        },
    );
}

pub fn CounterComponent(allocator: zx.Allocator, count: i32) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .div,
        .{
            .allocator = allocator,
            .attributes = &.{},
            .children = &.{
                _zx.zx(.h1, .{
                    .children = &.{
                        _zx.txt(std.fmt.allocPrint(allocator, "Counter: {d}", .{count}) catch @panic("OOM")),
                    },
                }),
                _zx.zx(.br, .{}),
                _zx.zx(.button, .{
                    .children = &.{
                        _zx.txt("Increment"),
                    },
                    .attributes = &.{
                        .{ .name = "onclick", .value = "_zx.onclick(1)" },
                    },
                }),

                _zx.zx(.input, .{
                    .children = &.{},
                    .attributes = &.{
                        .{ .name = "type", .value = "text" },
                        .{ .name = "id", .value = "hello-input" },
                    },
                }),
            },
        },
    );
}

const zx = @import("zx");
const std = @import("std");

export const nurul_turul: i32 = 3;
