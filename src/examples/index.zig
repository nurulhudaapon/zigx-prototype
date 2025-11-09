pub fn Page(allocator: zx.Allocator) zx.Component {
    const dynamic_title = "Dynamic Title!";

    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .div,
        .{
            .children = &.{
                .{
                    .element = .{
                        .tag = .h1,
                        .children = blk: {
                            const childs = allocator.alloc(zx.Component, 3) catch unreachable;
                            for (childs, 0..) |*child, i| {
                                const text = std.fmt.allocPrint(allocator, "Hello {d}", .{i}) catch unreachable;
                                child.* = zx.Component{ .text = text };
                            }
                            break :blk childs;
                        },
                    },
                },
                Button(allocator, .{ .title = "Send Message" }),
                Button(allocator, .{ .title = dynamic_title }),
                Button(allocator, .{}),
                .{
                    .element = .{
                        .tag = .p,
                        .children = &.{
                            .{ .text = "Three buttons with different titles!" },
                        },
                    },
                },
            },
        },
    );
}

const std = @import("std");
const zx = @import("zx");

const ButtonProps = struct {
    title: []const u8 = "Click Me", // Default value
};

// Custom Button component with props
fn Button(allocator: zx.Allocator, props: ButtonProps) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .button,
        .{
            .attributes = &.{
                .{ .name = "class", .value = "btn" },
            },
            .children = &.{
                .{ .text = props.title },
            },
        },
    );
}
