pub fn Page(allocator: zx.Allocator) zx.Component {
    const user_type: UserType = .admin;
    const admin_users = [_][]const u8{ "John", "Jane" };
    const member_users = [_][]const u8{ "Jim", "Jill" };
    var _zx = zx.initWithAllocator(allocator);
    return _zx.zx(
        .main,
        .{
            .allocator = allocator,
            .children = switch (user_type) {
                .admin => blk: {
                    const __zx_children = _zx.getAllocator().alloc(zx.Component, admin_users.len) catch unreachable;
                    for (admin_users, 0..) |name, _zx_i| {
                        __zx_children[_zx_i] = _zx.zx(
                            .p,
                            .{
                                .children = &.{
                                    _zx.txt(name),
                                },
                            },
                        );
                    }
                    break :blk __zx_children;
                },
                .member => blk: {
                    const __zx_children = _zx.getAllocator().alloc(zx.Component, member_users.len) catch unreachable;
                    for (member_users, 0..) |name, _zx_i| {
                        __zx_children[_zx_i] = _zx.zx(
                            .p,
                            .{
                                .children = &.{
                                    _zx.txt(name),
                                },
                            },
                        );
                    }
                    break :blk __zx_children;
                },
            },
        },
    );
}

const zx = @import("zx");

const UserType = enum { admin, member };
