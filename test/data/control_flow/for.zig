pub fn Page(ctx: zx.PageContext) zx.Component {
    const user_names = [_][]const u8{ "John", "Jane", "Jim", "Jill" };
    var _zx = zx.initWithAllocator(ctx.arena);
    return _zx.zx(
        .main,
        .{
            .allocator = ctx.arena,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, user_names.len) catch unreachable;
                for (user_names, 0..) |name, i| {
                    __zx_children[i] = _zx.zx(
                        .p,
                        .{
                            .children = &.{
                                _zx.txt(name),
                            },
                        },
                    );
                }
                break :blk __zx_children;
            },
        },
    );
}

const zx = @import("zx");
