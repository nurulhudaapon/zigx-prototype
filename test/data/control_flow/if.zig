pub fn Page(allocator: zx.Allocator) zx.Component {
    const is_admin = true;
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
                            if ((is_admin)) _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("Admin"),
                                    },
                                },
                            ) else _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("User"),
                                    },
                                },
                            ),
                        },
                    },
                ),
                _zx.zx(
                    .section,
                    .{
                        .children = &.{
                            _zx.txt(if (is_admin) ("Powerful") else ("Powerless")),
                        },
                    },
                ),
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
