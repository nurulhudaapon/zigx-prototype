pub fn Page(allocator: zx.Allocator) zx.Component {
    const groups = [_]struct { name: []const u8, members: []const []const u8 }{
        .{ .name = "Team A", .members = &[_][]const u8{ "John", "Jane" } },
        .{ .name = "Team B", .members = &[_][]const u8{ "Jim", "Jill" } },
    };
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, groups.len) catch unreachable;
                for (groups, 0..) |group, _zx_i| {
                    __zx_children[_zx_i] = _zx.zx(
                        .div,
                        .{
                            .children = blk1: {
                                const __zx_children1 = _zx.getAllocator().alloc(zx.Component, group.members.len) catch unreachable;
                                for (group.members, 0..) |member, _zx_i1| {
                                    __zx_children1[_zx_i1] = _zx.zx(
                                        .p,
                                        .{
                                            .children = &.{
                                                _zx.txt(member),
                                            },
                                        },
                                    );
                                }
                                break :blk1 __zx_children1;
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
