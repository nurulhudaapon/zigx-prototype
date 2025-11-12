pub fn Page(ctx: zx.PageContext) zx.Component {
    var _zx = zx.initWithAllocator(ctx.arena);
    return _zx.zx(
        .main,
        .{
            .allocator = ctx.arena,
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
