pub fn Page(allocator: zx.Allocator) zx.Component {
    const count = 42;
    const hex_value = 255;
    const percentage = 75;

    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .section,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.zx(
                    .p,
                    .{
                        .children = &.{
                            _zx.txt("Count: "),
                            _zx.fmt("{d}", .{count}),
                        },
                    },
                ),
                _zx.zx(
                    .p,
                    .{
                        .children = &.{
                            _zx.txt("Hex: 0x"),
                            _zx.fmt("{x}", .{hex_value}),
                        },
                    },
                ),
                _zx.zx(
                    .p,
                    .{
                        .children = &.{
                            _zx.txt("Percentage: "),
                            _zx.fmt("{d}", .{percentage}),
                            _zx.txt("%"),
                        },
                    },
                ),
            },
        },
    );
}

const zx = @import("zx");
