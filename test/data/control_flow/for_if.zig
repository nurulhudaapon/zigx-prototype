pub fn Page(allocator: zx.Allocator) zx.Component {
    const users = [_]struct { name: []const u8, is_active: bool }{
        .{ .name = "John", .is_active = true },
        .{ .name = "Jane", .is_active = false },
        .{ .name = "Jim", .is_active = true },
    };
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, users.len) catch unreachable;
                for (users, 0..) |user, _zx_i| {
                    __zx_children[_zx_i] = _zx.zx(
                        .fragment,
                        .{
                            .children = &.{
                                if (user.is_active) _zx.zx(
                                    .p,
                                    .{
                                        .children = &.{
                                            _zx.txt(user.name),
                                            _zx.txt(" (Active)"),
                                        },
                                    },
                                ) else _zx.zx(
                                    .p,
                                    .{
                                        .children = &.{
                                            _zx.txt(user.name),
                                            _zx.txt(" (Inactive)"),
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
