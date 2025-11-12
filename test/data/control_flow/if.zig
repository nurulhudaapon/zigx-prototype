pub fn Page(allocator: zx.Allocator) zx.Component {
    const is_logged_in = false;
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.zx(
                    .section,
                    .{
                        .children = &.{
                            if ((is_logged_in)) _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("Welcome, User!"),
                                    },
                                },
                            ) else _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("Please log in to continue."),
                                    },
                                },
                            ),
                        },
                    },
                ),
            },
        },
    );
}

const zx = @import("zx");
