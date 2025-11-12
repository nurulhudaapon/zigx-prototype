pub fn Page(ctx: zx.PageContext) zx.Component {
    var _zx = zx.initWithAllocator(ctx.arena);
    return _zx.zx(
        .main,
        .{
            .allocator = ctx.arena,
            .children = &.{
                _zx.lazy(Button, ButtonProps{ .title = "Submit" }),
                _zx.lazy(Button, ButtonProps{ .title = "Cancel" }),
                _zx.lazy(AsyncScore, AsyncScoreProps{ .index = 1, .label = "Score" }),
                _zx.lazy(AsyncScore, AsyncScoreProps{ .index = 2, .label = "Points" }),
                _zx.lazy(AsyncScore, AsyncScoreProps{ .index = 3, .label = "Rating" }),
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

const AsyncScoreProps = struct { index: u64, label: []const u8 };
fn AsyncScore(allocator: zx.Allocator, props: AsyncScoreProps) zx.Component {
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .span,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.txt(props.label),
                _zx.txt(" #"),
                _zx.fmt("{d}", .{props.index}),
            },
        },
    );
}

const zx = @import("zx");
