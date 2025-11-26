pub fn Page(ctx: zx.PageContext) zx.Component {
    const groups = [_]struct { name: []const u8, members: []const []const u8 }{
        .{ .name = "Team A", .members = &[_][]const u8{ "John", "Jane" } },
        .{ .name = "Team B", .members = &[_][]const u8{ "Jim", "Jill" } },
    };
    var _zx = zx.initWithAllocator(ctx.arena);
    return _zx.zx(
        .main,
        .{
            .allocator = ctx.arena,
            .children = blk: {
                const __zx_children = _zx.getAllocator().alloc(zx.Component, groups.len) catch unreachable;
                for (groups, 0..) |group, i| {
                    __zx_children[i] = _zx.zx(
                        .div,
                        .{
                            .children = blk: {
                                const __zx_children = _zx.getAllocator().alloc(zx.Component, group.members.len) catch unreachable;
                                for (group.members, 0..) |member, i| {
                                    __zx_children[i] = _zx.zx(
                                        .p,
                                        .{
                                            .children = &.{
                                                _zx.txt(member),
                                            },
                                        },
                                    );
                                }
                                break :blk __zx_children;
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
