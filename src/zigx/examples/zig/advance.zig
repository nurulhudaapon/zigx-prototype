const User = struct {
    name: []const u8,
    age: u32,
};

const PageProps = struct {
    users: []const User,
    allocator: std.mem.Allocator,
};
const Point = struct {
    x: i32,
    y: i32,
};
pub fn Page() zx.Component {
    // var users_children = props.allocator.alloc(zx.Component, props.users.len) catch unreachable;
    // for (props.users, 0..) |user, i| {
    //     users_children[i] = .{
    //         .element = .{
    //             .tag = .div,
    //             .children = &.{.{ .text = user.name }},
    //         },
    //     };
    // }

    const chars = [_][]const u8{ "a", "b", "c" };

    // var char_childs = blk: {
    //     var childs: [3]zx.Component = undefined;
    //     for (&childs, 0..) |*child, i| {
    //         child.* = zx.Component{ .text = chars[i] };
    //     }
    //     break :blk childs;
    // };

    // for (char_childs) |child| {
    //     std.debug.print("Child: {s}\n", .{child.text});
    // }

    // use compile-time code to initialize an array
    const fancy_array = init: {
        var initial_value: [chars.len]zx.Component = undefined;
        for (&initial_value, 0..) |*pt, i| {
            pt.* = zx.Component{ .text = chars[i] };
        }
        break :init initial_value;
    };

    for (fancy_array) |point| {
        std.debug.print("Point: {s}\n", .{point.text});
    }

    for (fancy_array) |point| {
        std.debug.print("Point: {s}\n", .{point.text});
    }

    std.debug.print("\n", .{});
    return zx.zx(
        .html,
        .{
            .children = &.{
                .{ .text = "Hello" },
                .{ .text = "World" },
                .{ .text = "!" },
                // .{
                //     .element = .{
                //         .tag = .body,
                //         .children = users_children,
                //     },
                // },
                .{
                    .element = .{
                        .tag = .div,
                        .children = blk: {
                            const childs = &[_]zx.Component{ .{ .text = "Hello" }, .{ .text = "World" }, .{ .text = "!" } };
                            // for (&childs, 0..) |*child, i| {
                            //     child.* = zx.Component{ .text = chars[i] };
                            // }
                            break :blk childs;
                        },
                    },
                },
            },
        },
    );
}

const zx = @import("zx");
// const zx = @import("../../../root.zig");

const std = @import("std");
