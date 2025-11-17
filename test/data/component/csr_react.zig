pub fn Page(allocator: zx.Allocator) zx.Component {
    const max_count = 10;

    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.client(.{ .name = "CounterComponent", .path = "./csr_react.tsx", .id = "zx-dcde04c415da9d1b15ca2690d8b497ae" }, .{ .max_count = max_count }),
            },
        },
    );
}

const zx = @import("zx");
// const CounterComponent = @jsImport("csr_react.tsx");
