pub fn Page(allocator: zx.Allocator) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.lazy(Button, .{ .title = "Custom Button" }),
            },
        },
    );
}

const ButtonProps = struct { title: []const u8 };
fn Button(allocator: zx.Allocator, props: ButtonProps) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .button,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.txt(props.title),
            },
        },
    );
}

const zx = @import("zx");
