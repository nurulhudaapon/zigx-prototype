pub fn Page(allocator: zx.Allocator) zx.Component {
    const user_name = "Alice & Bob";
    const html_content = "<script>alert('XSS')</script>";
    const unsafe_html = "<span>Test</span>";

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
                            _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("User: "),
                                        _zx.txt(user_name),
                                    },
                                },
                            ),
                            _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("Safe HTML: "),
                                        _zx.txt(html_content),
                                    },
                                },
                            ),
                            _zx.zx(
                                .p,
                                .{
                                    .children = &.{
                                        _zx.txt("Unsafe HTML: "),
                                        _zx.fmt("{s}", .{unsafe_html}),
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
