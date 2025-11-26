pub fn Page(allocator: zx.Allocator) zx.Component {
    const chars = "ABC";
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, chars.len) catch unreachable;
                for (chars, 0..) |char, _zx_i| {
                    __zx_children[_zx_i] = _zx.zx(
                        .div,
                        .{
                            .children = &.{
                                _zx.zx(
                                    .i,
                                    .{
                                        .children = &.{
                                            _zx.fmt("{c}", .{char}),
                                        },
                                    },
                                ),
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
