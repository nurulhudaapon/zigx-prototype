pub fn Page(allocator: zx.Allocator) zx.Component {
    const greeting = zx.Component{ .text = "Hello!" };

    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .section,
        .{
            .allocator = allocator,
            .children = &.{
                greeting,
            },
        },
    );
}

const zx = @import("zx");
