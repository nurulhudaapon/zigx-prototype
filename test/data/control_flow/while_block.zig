pub fn Page(allocator: zx.Allocator) zx.Component {
    var i: usize = 0;

    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = blk: {
                var __zx_count: usize = 0;
                const __zx_children = _zx.getAllocator().alloc(zx.Component, 1024) catch unreachable;
                while (i < 3) : (i += 1) {
                    __zx_children[__zx_count] = _zx.zx(
                        .div,
                        .{
                            .children = &.{
                                _zx.zx(
                                    .p,
                                    .{
                                        .children = &.{
                                            _zx.fmt("{d}", .{i}),
                                        },
                                    },
                                ),
                            },
                        },
                    );
                    __zx_count += 1;
                }
                break :blk __zx_children[0..__zx_count];
            },
        },
    );
}

const zx = @import("zx");
