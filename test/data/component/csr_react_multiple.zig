pub fn Page(allocator: zx.Allocator) zx.Component {
    const max_count = 10;

    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = &.{
                _zx.client(.{ .name = "CounterComponent", .path = "./csr_react.tsx", .id = "zx-dcde04c415da9d1b15ca2690d8b497ae" }, .{ .max_count = max_count }),
                _zx.client(.{ .name = "AnotherComponent", .path = "./csr_react_multiple.tsx", .id = "zx-817a92c3e8f78257d9993f89eb0cb6bb" }, .{}),
            },
        },
    );
}

const zx = @import("zx");
// const CounterComponent = @jsImport("csr_react.tsx");
// const AnotherComponent = @jsImport("csr_react_multiple.tsx");
