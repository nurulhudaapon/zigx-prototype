pub fn Page(allocator: zx.Allocator) zx.Component {
    const is_logged_in = true;
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                if ((is_logged_in)) _zx.zx(
                    .div,
                    .{
                        .children = &.{
                            _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("Welcome, User"),
                                    },
                                },
                            ),
                        },
                    },
                ) else _zx.zx(
                    .fragment,
                    .{},
                ),
            },
        },
    );
}

const zx = @import("zx");
